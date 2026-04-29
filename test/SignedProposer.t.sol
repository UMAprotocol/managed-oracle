// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {SignedProposer} from "src/optimistic-oracle-v2/implementation/SignedProposer.sol";
import {ManagedOptimisticOracleV2} from "src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {OptimisticOracleV2Interface} from "src/optimistic-oracle-v2/interfaces/OptimisticOracleV2Interface.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {OracleInterfaces} from "@uma/contracts/data-verification-mechanism/implementation/Constants.sol";
import {FinderInterface} from "@uma/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

import {AddressWhitelist} from "src/common/implementation/AddressWhitelist.sol";
import {MockStore} from "./mocks/MockStore.sol";
import {MockIdentifierWhitelist} from "./mocks/MockIdentifierWhitelist.sol";
import {MockFinder} from "./mocks/MockFinder.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MaliciousSignedProposerOracle} from "./mocks/MaliciousSignedProposerOracle.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SignedProposerTest is Test {
    SignedProposer internal signedProposer;
    ManagedOptimisticOracleV2 internal moo;
    MockPermit2 internal mockPermit2;

    address internal admin;
    address internal configAdmin;
    address internal upgradeAdmin;
    address internal resolverAdmin;
    address internal requestManager;
    address internal requester;
    address internal relayer;

    uint256 internal proposerKey;
    address internal proposer;

    FinderInterface internal finder;
    AddressWhitelist internal collateralWhitelist;
    AddressWhitelist internal defaultProposerWhitelist;
    AddressWhitelist internal requesterWhitelist;
    MockIdentifierWhitelist internal idWhitelist;
    MockStore internal store;
    MockOracle internal oracle;
    ERC20Mock internal currency;

    bytes32 internal constant IDENTIFIER = keccak256("PRICE_ID");
    bytes internal constant ANCILLARY = bytes(":memo: test");
    uint256 internal constant LEGACY_DEFAULT_LIVENESS = 2 hours;
    uint256 internal constant MINIMUM_DISPUTE_WINDOW = 5 minutes;
    uint256 internal constant BOND = 100 ether;
    uint256 internal constant FINAL_FEE = 10 ether;
    uint256 internal constant TOTAL_BOND = BOND + FINAL_FEE;

    bytes32 internal constant DELEGATED_PROPOSER_ROLE = keccak256("DELEGATED_PROPOSER_ROLE");
    bytes32 internal constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    bytes32 internal constant PROPOSAL_TYPEHASH = keccak256(
        "Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)"
    );

    function setUp() public {
        admin = makeAddr("admin");
        configAdmin = makeAddr("configAdmin");
        upgradeAdmin = makeAddr("upgradeAdmin");
        resolverAdmin = makeAddr("resolverAdmin");
        requestManager = makeAddr("requestManager");
        requester = makeAddr("requester");
        relayer = makeAddr("relayer");

        proposerKey = 0xA11CE;
        proposer = vm.addr(proposerKey);
        vm.label(proposer, "PROPOSER");

        finder = new MockFinder();
        collateralWhitelist = new AddressWhitelist();
        defaultProposerWhitelist = new AddressWhitelist();
        requesterWhitelist = new AddressWhitelist();
        idWhitelist = new MockIdentifierWhitelist();
        store = new MockStore();
        oracle = new MockOracle();
        currency = new ERC20Mock();
        mockPermit2 = new MockPermit2();

        collateralWhitelist.addToWhitelist(address(currency));
        idWhitelist.addSupportedIdentifier(IDENTIFIER);

        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateralWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(idWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.Oracle, address(oracle));

        store.setFinalFee(address(currency), FINAL_FEE);

        // Deploy MOOv2.
        ManagedOptimisticOracleV2 impl = new ManagedOptimisticOracleV2();
        ManagedOptimisticOracleV2.CurrencyBondRange[] memory ranges =
            new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
        ranges[0] = ManagedOptimisticOracleV2.CurrencyBondRange({
            currency: IERC20(address(currency)),
            range: ManagedOptimisticOracleV2.BondRange({minimumBond: uint128(1 ether), maximumBond: uint128(1_000 ether)})
        });

        bytes memory initData = abi.encodeWithSelector(
            ManagedOptimisticOracleV2.initialize.selector,
            LEGACY_DEFAULT_LIVENESS,
            address(finder),
            address(defaultProposerWhitelist),
            address(requesterWhitelist),
            ranges,
            configAdmin,
            upgradeAdmin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        moo = ManagedOptimisticOracleV2(address(proxy));

        vm.prank(upgradeAdmin);
        moo.initializeV2(MINIMUM_DISPUTE_WINDOW, resolverAdmin);

        vm.prank(configAdmin);
        moo.addRequestManager(requestManager);

        // Deploy SignedProposer with admin, then grant relayer the delegated proposer role.
        signedProposer = new SignedProposer(ISignatureTransfer(address(mockPermit2)), admin);
        vm.prank(admin);
        signedProposer.addDelegatedProposer(relayer);

        // Whitelist the proposer and the SignedProposer contract on the oracle.
        defaultProposerWhitelist.addToWhitelist(proposer);
        defaultProposerWhitelist.addToWhitelist(address(signedProposer));

        // Whitelist requester.
        requesterWhitelist.addToWhitelist(requester);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    function _makeRequest(uint256 timestamp, uint256 reward) internal returns (uint256 totalBond) {
        currency.mint(requester, reward);
        vm.startPrank(requester);
        currency.approve(address(moo), type(uint256).max);
        totalBond = moo.requestPrice(IDENTIFIER, timestamp, ANCILLARY, IERC20(address(currency)), reward);
        vm.stopPrank();
    }

    function _setBond() internal {
        vm.prank(requestManager);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), BOND);
    }

    function _fundAndApproveProposer(uint256 amount) internal {
        currency.mint(proposer, amount);
        vm.prank(proposer);
        currency.approve(address(mockPermit2), amount);
    }

    function _buildProposal(uint256 timestamp, int256 price) internal view returns (SignedProposer.Proposal memory) {
        return _buildProposal(timestamp, price, 0);
    }

    function _buildProposal(uint256 timestamp, int256 price, uint256 maxPayment)
        internal
        view
        returns (SignedProposer.Proposal memory)
    {
        return SignedProposer.Proposal({
            oracle: address(moo),
            requester: requester,
            identifier: IDENTIFIER,
            timestamp: timestamp,
            ancillaryData: ANCILLARY,
            proposedPrice: price,
            maxPayment: maxPayment
        });
    }

    function _buildPermit(uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(currency), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
    }

    function _computeWitnessHash(SignedProposer.Proposal memory proposal) internal pure returns (bytes32) {
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

    // ─── Propose tests ──────────────────────────────────────────────────────────

    function test_propose() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(totalBond, TOTAL_BOND);

        // Proposer is set correctly on the oracle.
        OptimisticOracleV2Interface.Request memory request = moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY);
        assertEq(request.proposer, proposer);
        assertEq(request.proposedPrice, 1 ether);

        // Verify the witness was computed correctly.
        assertEq(mockPermit2.lastWitness(), _computeWitnessHash(proposal));
        assertEq(mockPermit2.lastOwner(), proposer);
        assertEq(
            keccak256(bytes(mockPermit2.lastWitnessTypeString())),
            keccak256(bytes(signedProposer.WITNESS_TYPE_STRING()))
        );

        // SignedProposer holds no tokens.
        assertEq(currency.balanceOf(address(signedProposer)), 0);
    }

    function test_propose_refundsExcess() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        uint256 maxBond = TOTAL_BOND + 50 ether;
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(maxBond, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(maxBond);
        uint256 balanceBefore = currency.balanceOf(proposer);

        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(balanceBefore - currency.balanceOf(proposer), TOTAL_BOND);
        assertEq(currency.balanceOf(address(signedProposer)), 0);
    }

    function test_witnessHash_matchesExpected() public view {
        SignedProposer.Proposal memory proposal = _buildProposal(block.timestamp, 1 ether);

        bytes32 expected = keccak256(
            abi.encode(
                PROPOSAL_TYPEHASH,
                address(moo),
                requester,
                IDENTIFIER,
                block.timestamp,
                keccak256(ANCILLARY),
                int256(1 ether),
                uint256(0)
            )
        );

        assertEq(_computeWitnessHash(proposal), expected);
    }

    function test_propose_blocksReentrantCallbackPropose() public {
        ReentrantSignedProposerRequester callbackRequester =
            new ReentrantSignedProposerRequester(moo, signedProposer, IERC20(address(currency)));
        requester = address(callbackRequester);
        requesterWhitelist.addToWhitelist(requester);

        vm.prank(admin);
        signedProposer.addDelegatedProposer(requester);

        uint256 timestamp = block.timestamp;
        callbackRequester.requestWithProposalCallback(IDENTIFIER, timestamp, ANCILLARY);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        callbackRequester.setReentrantProposal(proposal, proposer, permit, "", 0);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(totalBond, TOTAL_BOND);
        assertTrue(callbackRequester.attemptedReentrantPropose());
        assertFalse(callbackRequester.reentrantProposeSucceeded());
        assertEq(
            callbackRequester.reentrantRevertData(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    // ─── Delegated proposer role tests ───────────────────────────────────────────

    function test_revert_propose_notDelegatedProposer() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        address nobody = makeAddr("nobody");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DELEGATED_PROPOSER_ROLE
            )
        );
        vm.prank(nobody);
        signedProposer.propose(proposal, proposer, permit, "", 0);
    }

    function test_addAndRemoveDelegatedProposer() public {
        address newProposer = makeAddr("newDelegatedProposer");

        assertFalse(signedProposer.hasRole(DELEGATED_PROPOSER_ROLE, newProposer));

        vm.prank(admin);
        signedProposer.addDelegatedProposer(newProposer);
        assertTrue(signedProposer.hasRole(DELEGATED_PROPOSER_ROLE, newProposer));

        vm.prank(admin);
        signedProposer.removeDelegatedProposer(newProposer);
        assertFalse(signedProposer.hasRole(DELEGATED_PROPOSER_ROLE, newProposer));
    }

    function test_revert_grantRole_notAdmin() public {
        address nobody = makeAddr("nobody");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(nobody);
        signedProposer.grantRole(DELEGATED_PROPOSER_ROLE, nobody);
    }

    function test_revert_addDelegatedProposer_notAdmin() public {
        address nobody = makeAddr("nobody");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(nobody);
        signedProposer.addDelegatedProposer(nobody);
    }

    function test_revokedDelegatedProposer_cannotPropose() public {
        vm.prank(admin);
        signedProposer.removeDelegatedProposer(relayer);

        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, relayer, DELEGATED_PROPOSER_ROLE
            )
        );
        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", 0);
    }

    // ─── Whitelist tests ────────────────────────────────────────────────────────

    function test_propose_resolvesDefaultWhitelist() public {
        // Remove proposer from the default whitelist so the only way to propose is via temporary add.
        defaultProposerWhitelist.removeFromWhitelist(proposer);

        // Transfer whitelist ownership to the SignedProposer contract.
        defaultProposerWhitelist.transferOwnership(address(signedProposer));

        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(totalBond, TOTAL_BOND);

        // Proposer was temporarily added then removed — should not be on whitelist now.
        assertFalse(defaultProposerWhitelist.isOnWhitelist(proposer));

        // Proposal went through correctly.
        OptimisticOracleV2Interface.Request memory request = moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY);
        assertEq(request.proposer, proposer);
    }

    function test_propose_resolvesCustomWhitelistOverDefault() public {
        defaultProposerWhitelist.removeFromWhitelist(proposer);

        AddressWhitelist customProposerWhitelist = new AddressWhitelist();
        customProposerWhitelist.addToWhitelist(address(signedProposer));
        customProposerWhitelist.transferOwnership(address(signedProposer));

        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(customProposerWhitelist));

        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(totalBond, TOTAL_BOND);
        assertFalse(customProposerWhitelist.isOnWhitelist(proposer));
        assertFalse(defaultProposerWhitelist.isOnWhitelist(proposer));

        OptimisticOracleV2Interface.Request memory request = moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY);
        assertEq(request.proposer, proposer);
    }

    function test_propose_resolvedWhitelist_preservesExistingEntry() public {
        // Proposer is already on the whitelist. Runtime resolution should not remove them.
        defaultProposerWhitelist.transferOwnership(address(signedProposer));

        assertTrue(defaultProposerWhitelist.isOnWhitelist(proposer));

        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", 0);

        // Proposer should still be on the whitelist.
        assertTrue(defaultProposerWhitelist.isOnWhitelist(proposer));
    }

    function test_propose_doesNotExposeAllowanceDuringWhitelistAdd() public {
        address attacker = makeAddr("attacker");
        MaliciousSignedProposerOracle maliciousOracle =
            new MaliciousSignedProposerOracle(IERC20(address(currency)), address(signedProposer), attacker);
        maliciousOracle.setDrainOnAdd(true);

        uint256 retainedBalance = 25 ether;
        uint256 permitAmount = 25 ether;
        currency.mint(address(signedProposer), retainedBalance);

        SignedProposer.Proposal memory proposal = SignedProposer.Proposal({
            oracle: address(maliciousOracle),
            requester: requester,
            identifier: IDENTIFIER,
            timestamp: block.timestamp,
            ancillaryData: ANCILLARY,
            proposedPrice: 1 ether,
            maxPayment: 0
        });
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);
        uint256 proposerBalanceBefore = currency.balanceOf(proposer);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(totalBond, 0);
        assertEq(currency.balanceOf(attacker), 0);
        assertEq(currency.balanceOf(address(signedProposer)), retainedBalance);
        assertEq(currency.balanceOf(proposer), proposerBalanceBefore);
    }

    function test_propose_doesNotExposeAllowanceDuringWhitelistRemoval() public {
        address attacker = makeAddr("attacker");
        MaliciousSignedProposerOracle maliciousOracle =
            new MaliciousSignedProposerOracle(IERC20(address(currency)), address(signedProposer), attacker);
        maliciousOracle.setBondAmount(5 ether);
        maliciousOracle.setDrainOnRemove(true);

        uint256 retainedBalance = 15 ether;
        uint256 permitAmount = 20 ether;
        currency.mint(address(signedProposer), retainedBalance);

        SignedProposer.Proposal memory proposal = SignedProposer.Proposal({
            oracle: address(maliciousOracle),
            requester: requester,
            identifier: IDENTIFIER,
            timestamp: block.timestamp,
            ancillaryData: ANCILLARY,
            proposedPrice: 1 ether,
            maxPayment: 0
        });
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);
        uint256 proposerBalanceBefore = currency.balanceOf(proposer);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(totalBond, 5 ether);
        assertEq(currency.balanceOf(attacker), 0);
        assertEq(currency.balanceOf(address(signedProposer)), retainedBalance);
        assertEq(currency.balanceOf(proposer), proposerBalanceBefore - 5 ether);
    }

    function test_whitelistAdmin_addAndRemove() public {
        address whitelistAdmin = makeAddr("whitelistAdmin");
        vm.prank(admin);
        signedProposer.addWhitelistAdmin(whitelistAdmin);

        // Create a fresh whitelist owned by SignedProposer.
        AddressWhitelist wl = new AddressWhitelist();
        wl.transferOwnership(address(signedProposer));

        address target = makeAddr("target");

        vm.prank(whitelistAdmin);
        signedProposer.addToWhitelist(wl, target);
        assertTrue(wl.isOnWhitelist(target));

        vm.prank(whitelistAdmin);
        signedProposer.removeFromWhitelist(wl, target);
        assertFalse(wl.isOnWhitelist(target));
    }

    function test_addAndRemoveWhitelistAdmin() public {
        address whitelistAdmin = makeAddr("whitelistAdmin");

        assertFalse(signedProposer.hasRole(WHITELIST_ADMIN_ROLE, whitelistAdmin));

        vm.prank(admin);
        signedProposer.addWhitelistAdmin(whitelistAdmin);
        assertTrue(signedProposer.hasRole(WHITELIST_ADMIN_ROLE, whitelistAdmin));

        vm.prank(admin);
        signedProposer.removeWhitelistAdmin(whitelistAdmin);
        assertFalse(signedProposer.hasRole(WHITELIST_ADMIN_ROLE, whitelistAdmin));
    }

    function test_revert_addWhitelistAdmin_notDefaultAdmin() public {
        address nobody = makeAddr("nobody");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(nobody);
        signedProposer.addWhitelistAdmin(nobody);
    }

    function test_revert_whitelistAdmin_notAuthorized() public {
        AddressWhitelist wl = new AddressWhitelist();
        wl.transferOwnership(address(signedProposer));

        address nobody = makeAddr("nobody");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(nobody);
        signedProposer.addToWhitelist(wl, nobody);
    }

    function test_delegatedProposer_cannotManageWhitelist() public {
        AddressWhitelist wl = new AddressWhitelist();
        wl.transferOwnership(address(signedProposer));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, relayer, WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(relayer);
        signedProposer.addToWhitelist(wl, relayer);
    }

    function test_defaultAdmin_canTransferWhitelistOwnership() public {
        AddressWhitelist wl = new AddressWhitelist();
        wl.transferOwnership(address(signedProposer));

        address newOwner = makeAddr("newOwner");

        vm.prank(admin);
        signedProposer.transferWhitelistOwnership(wl, newOwner);

        assertEq(wl.owner(), newOwner);
    }

    function test_revert_transferWhitelistOwnership_notDefaultAdmin() public {
        AddressWhitelist wl = new AddressWhitelist();
        wl.transferOwnership(address(signedProposer));

        address whitelistAdmin = makeAddr("whitelistAdmin");
        vm.prank(admin);
        signedProposer.addWhitelistAdmin(whitelistAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, whitelistAdmin, DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(whitelistAdmin);
        signedProposer.transferWhitelistOwnership(wl, makeAddr("newOwner"));
    }

    function test_revert_transferWhitelistOwnership_whenWhitelistNotOwnedBySignedProposer() public {
        AddressWhitelist wl = new AddressWhitelist();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(signedProposer)));
        vm.prank(admin);
        signedProposer.transferWhitelistOwnership(wl, makeAddr("newOwner"));
    }

    function test_transferWhitelistOwnership_toReplacementSignedProposer() public {
        defaultProposerWhitelist.removeFromWhitelist(proposer);
        defaultProposerWhitelist.transferOwnership(address(signedProposer));

        address replacementAdmin = makeAddr("replacementAdmin");
        SignedProposer replacement = new SignedProposer(ISignatureTransfer(address(mockPermit2)), replacementAdmin);

        vm.prank(replacementAdmin);
        replacement.addDelegatedProposer(relayer);

        vm.prank(admin);
        signedProposer.addWhitelistAdmin(admin);

        vm.prank(admin);
        signedProposer.transferWhitelistOwnership(defaultProposerWhitelist, address(replacement));

        assertEq(defaultProposerWhitelist.owner(), address(replacement));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(signedProposer)));
        vm.prank(admin);
        signedProposer.addToWhitelist(defaultProposerWhitelist, makeAddr("shouldFail"));

        vm.prank(replacementAdmin);
        replacement.addWhitelistAdmin(replacementAdmin);

        vm.prank(replacementAdmin);
        replacement.addToWhitelist(defaultProposerWhitelist, address(replacement));
        assertTrue(defaultProposerWhitelist.isOnWhitelist(address(replacement)));

        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.prank(relayer);
        uint256 totalBond = replacement.propose(proposal, proposer, permit, "", 0);

        assertEq(totalBond, TOTAL_BOND);
        assertFalse(defaultProposerWhitelist.isOnWhitelist(proposer));

        OptimisticOracleV2Interface.Request memory request = moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY);
        assertEq(request.proposer, proposer);
    }

    // ─── Payment tests ──────────────────────────────────────────────────────────

    function test_propose_withPayment() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        uint256 payment = 5 ether;
        uint256 permitAmount = TOTAL_BOND + payment;

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, payment);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);
        uint256 balanceBefore = currency.balanceOf(proposer);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", payment);

        assertEq(totalBond, TOTAL_BOND);

        // Proposer paid bond + payment.
        assertEq(balanceBefore - currency.balanceOf(proposer), TOTAL_BOND + payment);

        // Payment is held by the contract.
        assertEq(currency.balanceOf(address(signedProposer)), payment);
    }

    function test_propose_withPayment_refundsExcess() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        uint256 payment = 5 ether;
        uint256 excess = 20 ether;
        uint256 permitAmount = TOTAL_BOND + payment + excess;

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, payment);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);
        uint256 balanceBefore = currency.balanceOf(proposer);

        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", payment);

        // Proposer paid bond + payment, got excess back.
        assertEq(balanceBefore - currency.balanceOf(proposer), TOTAL_BOND + payment);
        assertEq(currency.balanceOf(address(signedProposer)), payment);
    }

    function test_revert_propose_paymentExceedsPermit() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        // Permit only covers the bond exactly — any payment should revert.
        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        vm.prank(relayer);
        vm.expectRevert();
        signedProposer.propose(proposal, proposer, permit, "", 1 ether);
    }

    function test_revert_propose_paymentExceedsMaxPayment() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        uint256 maxPayment = 5 ether;
        uint256 permitAmount = TOTAL_BOND + maxPayment + 1 ether;

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, maxPayment);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);

        vm.expectRevert(SignedProposer.PaymentExceedsMaxPayment.selector);
        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", maxPayment + 1 ether);
    }

    function test_withdrawPayments() public {
        // First, create a proposal with payment so the contract holds tokens.
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        uint256 payment = 10 ether;
        uint256 permitAmount = TOTAL_BOND + payment;

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, payment);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);

        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", payment);

        assertEq(currency.balanceOf(address(signedProposer)), payment);

        // Admin withdraws.
        address recipient = makeAddr("recipient");
        vm.prank(admin);
        signedProposer.withdrawPayments(IERC20(address(currency)), recipient, payment);

        assertEq(currency.balanceOf(address(signedProposer)), 0);
        assertEq(currency.balanceOf(recipient), payment);
    }

    function test_revert_withdrawPayments_notAdmin() public {
        address nobody = makeAddr("nobody");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(nobody);
        signedProposer.withdrawPayments(IERC20(address(currency)), nobody, 1 ether);
    }
}

contract ReentrantSignedProposerRequester {
    ManagedOptimisticOracleV2 internal immutable oracle;
    SignedProposer internal immutable signedProposer;
    IERC20 internal immutable currency;

    SignedProposer.Proposal internal reentrantProposal;
    ISignatureTransfer.PermitTransferFrom internal reentrantPermit;
    address internal reentrantProposer;
    bytes internal reentrantSignature;
    uint256 internal reentrantPayment;

    bool public attemptedReentrantPropose;
    bool public reentrantProposeSucceeded;
    bytes public reentrantRevertData;

    constructor(ManagedOptimisticOracleV2 _oracle, SignedProposer _signedProposer, IERC20 _currency) {
        oracle = _oracle;
        signedProposer = _signedProposer;
        currency = _currency;
    }

    function requestWithProposalCallback(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external {
        oracle.requestPrice(identifier, timestamp, ancillaryData, currency, 0);
        oracle.setCallbacks(identifier, timestamp, ancillaryData, true, false, false);
    }

    function setReentrantProposal(
        SignedProposer.Proposal calldata proposal,
        address proposer,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature,
        uint256 payment
    ) external {
        reentrantProposal = proposal;
        reentrantProposer = proposer;
        reentrantPermit = permit;
        reentrantSignature = signature;
        reentrantPayment = payment;
    }

    function priceProposed(bytes32, uint256, bytes memory) external {
        require(msg.sender == address(oracle), "ReentrantRequester: unauthorized");

        attemptedReentrantPropose = true;
        try signedProposer.propose(
            reentrantProposal, reentrantProposer, reentrantPermit, reentrantSignature, reentrantPayment
        ) returns (uint256) {
            reentrantProposeSucceeded = true;
        } catch (bytes memory reason) {
            reentrantRevertData = reason;
        }
    }
}
