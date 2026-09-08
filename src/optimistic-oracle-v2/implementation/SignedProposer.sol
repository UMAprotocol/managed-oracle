// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {MulticallUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OptimisticOracleV2Interface} from "../interfaces/OptimisticOracleV2Interface.sol";
import {SignedProposerOracleInterface} from "../interfaces/SignedProposerOracleInterface.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {AddressWhitelist} from "../../common/implementation/AddressWhitelist.sol";
import {AddressWhitelistInterface} from "../../common/interfaces/AddressWhitelistInterface.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TryMulticall} from "../../common/implementation/TryMulticall.sol";

/**
 * @title SignedProposer
 * @notice Allows proposers to sign Permit2 witness proposals off-chain and have them submitted by
 * a delegated relayer. The proposal parameters are embedded as the Permit2 witness so a single
 * signature authorises both the token transfer and a specific proposal or ordered proposal batch.
 *
 * The signer is set as the proposer (receiving rewards on settlement).
 *
 * SignedProposer resolves the effective proposer whitelist from ManagedOptimisticOracleV2 at
 * runtime. If the proposer is not already allowed, it attempts to temporarily add the proposer
 * before the oracle call and remove them immediately after. This requires SignedProposer to be
 * authorized by the resolved whitelist.
 *
 * It is assumed signers and delegated proposers verify `proposal.oracle` is an intended oracle
 * instance before signing or relaying. That oracle address is used as both the ERC20 allowance
 * spender and the `proposePriceFor` call target, so executing an unintended oracle can spend up to
 * the signer-approved Permit2 amount for that proposal.
 *
 * Deploy behind an ERC1967Proxy and initialize atomically. The default admin authorizes UUPS
 * upgrades; the proxy remains the Permit2 spender and whitelist owner across upgrades.
 *
 * The contract is permissioned:
 * - `DEFAULT_ADMIN_ROLE` — manages roles, payments, whitelist ownership, and upgrades.
 * - `DELEGATED_PROPOSER_ROLE` — may call `propose`, `proposeBatch`, and `tryMulticall`.
 * - `WHITELIST_ADMIN_ROLE` — may directly add/remove entries on whitelists owned by this contract.
 */
contract SignedProposer is
    AccessControlUpgradeable,
    MulticallUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    TryMulticall
{
    using SafeERC20 for IERC20;

    // ─── Structs ──────────────────────────────────────────────────────────────────

    /// @notice Proposal witness fields shared by individual permits and batch items.
    struct Proposal {
        address oracle;
        address requester;
        bytes32 identifier;
        uint256 timestamp;
        bytes ancillaryData;
        int256 proposedPrice;
        uint256 maxPayment;
    }

    /// @notice One signed batch item; maxAmount covers this proposal's bond and payment.
    struct BatchProposal {
        Proposal proposal;
        uint256 maxAmount;
    }

    // ─── Roles ─────────────────────────────────────────────────────────────────────

    bytes32 public constant DELEGATED_PROPOSER_ROLE = keccak256("DELEGATED_PROPOSER_ROLE");
    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────────

    bytes32 public constant PROPOSAL_TYPEHASH = keccak256(
        "Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)"
    );

    /// @dev Appended by Permit2 to build the full PermitWitnessTransferFrom EIP-712 type.
    string public constant WITNESS_TYPE_STRING =
        "Proposal witness)Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)TokenPermissions(address token,uint256 amount)";

    bytes32 public constant BATCH_PROPOSAL_TYPEHASH = keccak256(
        "BatchProposal(Proposal proposal,uint256 maxAmount)Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)"
    );
    bytes32 public constant BATCH_WITNESS_TYPEHASH = keccak256(
        "BatchWitness(BatchProposal[] proposals)BatchProposal(Proposal proposal,uint256 maxAmount)Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)"
    );
    string public constant BATCH_WITNESS_TYPE_STRING =
        "BatchWitness witness)BatchProposal(Proposal proposal,uint256 maxAmount)BatchWitness(BatchProposal[] proposals)Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)TokenPermissions(address token,uint256 amount)";

    // ─── Storage ───────────────────────────────────────────────────────────────

    ISignatureTransfer public permit2;

    // ─── Events ───────────────────────────────────────────────────────────────────

    event ProposalExecuted(
        address indexed proposer,
        address indexed oracle,
        address indexed requester,
        bytes32 identifier,
        uint256 timestamp,
        int256 proposedPrice,
        uint256 totalBond,
        uint256 payment
    );

    event PaymentWithdrawn(address indexed token, address indexed to, uint256 amount);

    event BatchProposalFailed(
        uint256 indexed index, bytes32 indexed proposalHash, bytes4 errorSelector, bytes32 revertDataHash
    );
    event BatchExecuted(
        address indexed proposer, address indexed token, uint256 indexed nonce, uint256 spent, uint256 refund
    );

    error EmptyBatch();
    error BatchLengthMismatch();
    error BatchAmountMismatch(uint256 totalBudget, uint256 permitAmount);
    error OnlySelf();
    error ZeroAddress();
    error PaymentExceedsMaxPayment();
    error PermitTransferAmountMismatch(uint256 expectedAmount, uint256 receivedAmount);
    error PermitTokenMismatch(address requestCurrency, address permitToken);
    error CannotRemoveSelfFromWhitelist();
    error NewOwnerNotWhitelisted(address newOwner);

    // ─── Constructor ──────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy with its Permit2 contract and role/upgrade administrator.
    function initialize(ISignatureTransfer _permit2, address admin) external initializer {
        if (address(_permit2) == address(0) || admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __Multicall_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        permit2 = _permit2;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @dev Reuses the existing admin role rather than introducing a separate upgrade authority.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─── Propose ──────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a proposal using a Permit2 witness signature.
     * @dev The signer must have approved the canonical Permit2 contract for the bond token. The
     * proposal parameters are embedded as the Permit2 witness, so one signature authorises both
     * the token transfer and the specific proposal. Token amount, nonce, and deadline are in the
     * permit — not the witness.
     *
     * `proposal.maxPayment` caps the retained order-flow payment the relayer may charge.
     * `permit.permitted.amount` is the proposer's aggregate spend cap covering both `totalBond`
     * and `payment`.
     *
     * Before the Permit2 transfer, this contract verifies that the permit token matches the
     * request currency recorded by the oracle. Permit2 then transfers `permit.permitted.amount`
     * to this contract. The oracle then pulls the exact bond during `proposePriceFor`, and any
     * excess above `totalBond + payment` is refunded to the proposer. The call reverts if
     * `payment > proposal.maxPayment` or if `payment + totalBond > permit.permitted.amount`.
     *
     * @param proposal The proposal parameters (oracle-specific fields only).
     * @param proposer Address of the proposer / token owner (verified by Permit2).
     * @param permit The Permit2 transfer parameters (token, amount, nonce, deadline).
     * @param signature Permit2 EIP-712 signature from the proposer.
     * @param payment Amount retained by the contract as order-flow payment. Must not exceed the
     * signer-approved `proposal.maxPayment`.
     * @return totalBond The exact bond amount the oracle pulled for the proposal.
     */
    function propose(
        Proposal calldata proposal,
        address proposer,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature,
        uint256 payment
    ) external onlyRole(DELEGATED_PROPOSER_ROLE) nonReentrant returns (uint256 totalBond) {
        if (payment > proposal.maxPayment) revert PaymentExceedsMaxPayment();
        IERC20 currency = _getRequestCurrency(proposal);
        if (address(currency) != permit.permitted.token) {
            revert PermitTokenMismatch(address(currency), permit.permitted.token);
        }
        _permit2Transfer(permit, proposer, signature, _hashProposal(proposal), WITNESS_TYPE_STRING);
        totalBond = _executeProposal(proposal, proposer, currency, permit.permitted.amount, payment, true);
    }

    /**
     * @notice Execute a same-token batch for one signer using one Permit2 witness signature.
     * @dev The ordered proposals and their individual budgets are signed. Their budgets must sum
     * exactly to permit.permitted.amount. Each child rolls back independently on failure; only
     * successful bonds/payments are charged, and all unused funds are refunded once at the end.
     * A completed batch consumes its nonce even if every child fails. Invalid signatures, invalid
     * batch shape/funding, a failed final refund, or insufficient outer gas revert the whole batch.
     * As with tryMulticall, there is no per-child gas cap or guarantee against gas starvation.
     * @param proposals Signed proposal fields and bond-plus-payment budgets, in execution order.
     * @param proposer Signer, token owner, and refund recipient for the entire batch.
     * @param permit Single-token Permit2 authorization covering the sum of all item budgets.
     * @param signature One signature over the permit and BatchWitness.
     * @param payments Actual per-item payments, bounded by each signed proposal.maxPayment.
     * @return successes Per-item execution results. Failed items require a fresh signed batch to retry.
     */
    function proposeBatch(
        BatchProposal[] calldata proposals,
        address proposer,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature,
        uint256[] memory payments
    ) external onlyRole(DELEGATED_PROPOSER_ROLE) nonReentrant returns (bool[] memory successes) {
        uint256 length = proposals.length;
        if (length == 0) revert EmptyBatch();
        if (length != payments.length) revert BatchLengthMismatch();

        // Permit2 needs the full ordered witness before it can authenticate and fund the batch.
        // This first pass hashes each item once and checks the total budget; the second executes
        // the funded items. A permissioned relayer must still prove the signer's exact authorization.
        bytes32[] memory hashes = new bytes32[](length);
        uint256 totalBudget;
        for (uint256 i; i < length; ++i) {
            hashes[i] = _hashBatchProposal(proposals[i]);
            totalBudget += proposals[i].maxAmount;
        }
        if (totalBudget != permit.permitted.amount) {
            revert BatchAmountMismatch(totalBudget, permit.permitted.amount);
        }
        bytes32 witness = keccak256(abi.encode(BATCH_WITNESS_TYPEHASH, keccak256(abi.encodePacked(hashes))));
        _permit2Transfer(permit, proposer, signature, witness, BATCH_WITNESS_TYPE_STRING);

        IERC20 currency = IERC20(permit.permitted.token);
        // Deduct only successful bond + payment spends; failed budgets remain refundable.
        uint256 refund = permit.permitted.amount;
        successes = new bool[](length);
        for (uint256 i; i < length; ++i) {
            try this.executeBatchProposal(proposals[i], proposer, currency, payments[i]) returns (uint256 spent) {
                successes[i] = true;
                refund -= spent;
            } catch (bytes memory reason) {
                bytes4 errorSelector = reason.length >= 4 ? bytes4(reason) : bytes4(0);
                emit BatchProposalFailed(i, hashes[i], errorSelector, keccak256(reason));
            }
        }
        if (refund > 0) currency.safeTransfer(proposer, refund);
        emit BatchExecuted(proposer, address(currency), permit.nonce, permit.permitted.amount - refund, refund);
    }

    /// @dev Only the funded batch may enter this call boundary. The outer nonReentrant guard stays
    /// active throughout child execution; token/oracle callbacks cannot enter propose or proposeBatch.
    /// An external self-call lets the parent catch failures and roll back every effect of this child.
    function executeBatchProposal(BatchProposal calldata item, address proposer, IERC20 currency, uint256 payment)
        external
        returns (uint256 spent)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (payment > item.proposal.maxPayment) revert PaymentExceedsMaxPayment();
        IERC20 requestCurrency = _getRequestCurrency(item.proposal);
        if (requestCurrency != currency) {
            revert PermitTokenMismatch(address(requestCurrency), address(currency));
        }
        // Defer refunds to the outer batch; the individual cap still bounds this oracle's allowance.
        spent = _executeProposal(item.proposal, proposer, currency, item.maxAmount, payment, false) + payment;
    }

    // ─── Internals ────────────────────────────────────────────────────────────────

    function _checkTryMulticallCaller() internal view override {
        _checkRole(DELEGATED_PROPOSER_ROLE);
    }

    function _tryMulticallSelector() internal pure override returns (bytes4) {
        return SignedProposer.propose.selector;
    }

    function _getRequestCurrency(Proposal calldata proposal) internal view returns (IERC20) {
        OptimisticOracleV2Interface.Request memory request = OptimisticOracleV2Interface(proposal.oracle).getRequest(
            proposal.requester, proposal.identifier, proposal.timestamp, proposal.ancillaryData
        );
        return request.currency;
    }

    function _hashProposal(Proposal calldata proposal) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PROPOSAL_TYPEHASH,
                proposal.oracle,
                proposal.requester,
                proposal.identifier,
                proposal.timestamp,
                keccak256(proposal.ancillaryData),
                proposal.proposedPrice,
                proposal.maxPayment
            )
        );
    }

    function _hashBatchProposal(BatchProposal calldata item) internal pure returns (bytes32) {
        return keccak256(abi.encode(BATCH_PROPOSAL_TYPEHASH, _hashProposal(item.proposal), item.maxAmount));
    }

    function _permit2Transfer(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        address proposer,
        bytes calldata signature,
        bytes32 witness,
        string memory witnessTypeString
    ) internal {
        IERC20 currency = IERC20(permit.permitted.token);
        uint256 balanceBefore = currency.balanceOf(address(this));

        permit2.permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted.amount}),
            proposer,
            witness,
            witnessTypeString,
            signature
        );

        uint256 balanceAfter = currency.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != permit.permitted.amount) {
            revert PermitTransferAmountMismatch(permit.permitted.amount, received);
        }
    }

    function _executeProposal(
        Proposal calldata proposal,
        address proposer,
        IERC20 currency,
        uint256 maxAmount,
        uint256 payment,
        bool refundExcess
    ) internal returns (uint256 totalBond) {
        AddressWhitelistInterface whitelist = _getEffectiveProposerWhitelist(proposal);
        bool addedToWhitelist;
        if (!whitelist.isOnWhitelist(proposer)) {
            whitelist.addToWhitelist(proposer);
            addedToWhitelist = true;
        }

        // Grant oracle allowance only for proposePriceFor; whitelist hooks must not observe live approval.
        currency.forceApprove(proposal.oracle, maxAmount - payment);
        totalBond = _proposePriceFor(proposal, proposer, currency);
        // Revoke any leftover allowance the oracle didn't spend.
        currency.forceApprove(proposal.oracle, 0);
        if (addedToWhitelist) whitelist.removeFromWhitelist(proposer);

        uint256 excess = maxAmount - totalBond - payment;
        if (refundExcess && excess > 0) currency.safeTransfer(proposer, excess);

        emit ProposalExecuted(
            proposer,
            proposal.oracle,
            proposal.requester,
            proposal.identifier,
            proposal.timestamp,
            proposal.proposedPrice,
            totalBond,
            payment
        );
    }

    /// @dev Calls proposePriceFor and returns the actual bond based on balance change.
    function _proposePriceFor(Proposal calldata proposal, address proposer, IERC20 currency)
        internal
        returns (uint256)
    {
        uint256 balanceBefore = currency.balanceOf(address(this));

        OptimisticOracleV2Interface(proposal.oracle).proposePriceFor(
            proposer,
            proposal.requester,
            proposal.identifier,
            proposal.timestamp,
            proposal.ancillaryData,
            proposal.proposedPrice
        );

        return balanceBefore - currency.balanceOf(address(this));
    }

    function _getEffectiveProposerWhitelist(Proposal calldata proposal)
        internal
        view
        returns (AddressWhitelistInterface whitelist)
    {
        SignedProposerOracleInterface oracle = SignedProposerOracleInterface(proposal.oracle);
        whitelist = oracle.getCustomProposerWhitelist(proposal.requester, proposal.identifier, proposal.ancillaryData);
        if (address(whitelist) == address(0)) whitelist = oracle.defaultProposerWhitelist();
    }

    // ─── Role management ───────────────────────────────────────────────────────────

    /**
     * @notice Adds a delegated proposer.
     * @dev Only callable by the default admin (checked in grantRole of AccessControl).
     * @param account The delegated proposer to add.
     */
    function addDelegatedProposer(address account) external {
        grantRole(DELEGATED_PROPOSER_ROLE, account);
    }

    /**
     * @notice Removes a delegated proposer.
     * @dev Only callable by the default admin (checked in revokeRole of AccessControl).
     * @param account The delegated proposer to remove.
     */
    function removeDelegatedProposer(address account) external {
        revokeRole(DELEGATED_PROPOSER_ROLE, account);
    }

    /**
     * @notice Adds a whitelist admin.
     * @dev Only callable by the default admin (checked in grantRole of AccessControl).
     * @param account The whitelist admin to add.
     */
    function addWhitelistAdmin(address account) external {
        grantRole(WHITELIST_ADMIN_ROLE, account);
    }

    /**
     * @notice Removes a whitelist admin.
     * @dev Only callable by the default admin (checked in revokeRole of AccessControl).
     * @param account The whitelist admin to remove.
     */
    function removeWhitelistAdmin(address account) external {
        revokeRole(WHITELIST_ADMIN_ROLE, account);
    }

    // ─── Whitelist management ──────────────────────────────────────────────────────

    /**
     * @notice Add an address to a whitelist owned by this contract.
     * @param whitelist The AddressWhitelist contract to modify.
     * @param account The address to add.
     */
    function addToWhitelist(AddressWhitelist whitelist, address account) external onlyRole(WHITELIST_ADMIN_ROLE) {
        whitelist.addToWhitelist(account);
    }

    /**
     * @notice Remove an address from a whitelist owned by this contract.
     * @param whitelist The AddressWhitelist contract to modify.
     * @param account The address to remove.
     */
    function removeFromWhitelist(AddressWhitelist whitelist, address account) external onlyRole(WHITELIST_ADMIN_ROLE) {
        if (account == address(this)) revert CannotRemoveSelfFromWhitelist();
        whitelist.removeFromWhitelist(account);
    }

    /**
     * @notice Transfer ownership of a whitelist owned by this contract.
     * @dev `newOwner` must be on the whitelist before ownership transfer so replacement relays
     * can continue to satisfy ManagedOptimisticOracleV2's sender whitelist check.
     * @param whitelist The AddressWhitelist contract to transfer.
     * @param newOwner The new owner of the whitelist.
     */
    function transferWhitelistOwnership(AddressWhitelist whitelist, address newOwner)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!whitelist.isOnWhitelist(newOwner)) revert NewOwnerNotWhitelisted(newOwner);
        whitelist.transferOwnership(newOwner);
    }

    // ─── Payment withdrawal ──────────────────────────────────────────────────────

    /**
     * @notice Withdraw accumulated order-flow payments from the contract.
     * @param token The ERC20 token to withdraw.
     * @param to The address to send the tokens to.
     * @param amount The amount to withdraw.
     */
    function withdrawPayments(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        token.safeTransfer(to, amount);
        emit PaymentWithdrawn(address(token), to, amount);
    }
}
