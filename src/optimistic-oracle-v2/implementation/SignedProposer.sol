// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OptimisticOracleV2Interface} from "../interfaces/OptimisticOracleV2Interface.sol";
import {SignedProposerOracleInterface} from "../interfaces/SignedProposerOracleInterface.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {AddressWhitelist} from "../../common/implementation/AddressWhitelist.sol";
import {AddressWhitelistInterface} from "../../common/interfaces/AddressWhitelistInterface.sol";
import {TryMulticall} from "../../common/implementation/TryMulticall.sol";

/**
 * @title SignedProposer
 * @notice Allows proposers to sign Permit2 witness proposals off-chain and have them submitted by
 * a delegated relayer. The proposal parameters are embedded as the Permit2 witness so a single
 * signature authorises both the token transfer and the specific proposal.
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
 * The contract is permissioned:
 * - `DELEGATED_PROPOSER_ROLE` — may call `propose` and `tryMulticall`.
 * - `WHITELIST_ADMIN_ROLE` — may directly add/remove entries on whitelists owned by this contract.
 */
contract SignedProposer is AccessControl, Multicall, ReentrancyGuard, TryMulticall {
    using SafeERC20 for IERC20;

    // ─── Structs ──────────────────────────────────────────────────────────────────

    /// @notice Proposal witness — token amount, nonce & deadline live in the Permit2 permit.
    struct Proposal {
        address oracle;
        address requester;
        bytes32 identifier;
        uint256 timestamp;
        bytes ancillaryData;
        int256 proposedPrice;
        uint256 maxPayment;
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

    // ─── Immutables ───────────────────────────────────────────────────────────────

    ISignatureTransfer public immutable permit2;

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

    error PaymentExceedsMaxPayment();
    error PermitTransferAmountMismatch(uint256 expectedAmount, uint256 receivedAmount);
    error PermitTokenMismatch(address requestCurrency, address permitToken);
    error CannotRemoveSelfFromWhitelist();
    error NewOwnerNotWhitelisted(address newOwner);
    // ─── Constructor ──────────────────────────────────────────────────────────────

    constructor(ISignatureTransfer _permit2, address admin) {
        permit2 = _permit2;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

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
        _permit2Transfer(proposal, permit, proposer, signature);
        totalBond = _executeProposal(proposal, proposer, currency, permit.permitted.amount, payment);
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

    function _permit2Transfer(
        Proposal calldata proposal,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        address proposer,
        bytes calldata signature
    ) internal {
        IERC20 currency = IERC20(permit.permitted.token);
        uint256 balanceBefore = currency.balanceOf(address(this));

        bytes32 witness = keccak256(
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

        permit2.permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted.amount}),
            proposer,
            witness,
            WITNESS_TYPE_STRING,
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
        uint256 payment
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
        if (excess > 0) currency.safeTransfer(proposer, excess);

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
