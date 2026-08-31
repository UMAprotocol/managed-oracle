// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {SignedProposer} from "src/optimistic-oracle-v2/implementation/SignedProposer.sol";
import {TryMulticall} from "src/common/implementation/TryMulticall.sol";
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

contract ShortTransferERC20Mock is ERC20Mock {
    uint256 internal constant TRANSFER_FEE_BPS = 1_000;
    uint256 internal constant BPS = 10_000;

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * TRANSFER_FEE_BPS / BPS;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract SignedProposerTest is Test {
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

    event ProposalCallFailed(
        uint256 indexed index, bytes32 indexed callHash, bytes4 errorSelector, bytes32 revertDataHash
    );

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

    function _setAllowedBondRange() internal {
        vm.prank(configAdmin);
        moo.setAllowedBondRange(
            IERC20(address(currency)),
            ManagedOptimisticOracleV2.BondRange({minimumBond: uint128(1 ether), maximumBond: uint128(1_000 ether)})
        );
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
        return _buildPermitForToken(address(currency), amount, nonce, deadline);
    }

    function _buildPermitForToken(address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
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

    function _encodeProposalCall(
        SignedProposer.Proposal memory proposal,
        address proposalOwner,
        ISignatureTransfer.PermitTransferFrom memory permit,
        bytes memory signature,
        uint256 payment
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(SignedProposer.propose, (proposal, proposalOwner, permit, signature, payment));
    }

    function _revertSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(revertData, 0x20))
            }
        }
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

    function test_revert_propose_permitTokenMismatch() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        ERC20Mock otherCurrency = new ERC20Mock();
        uint256 permitAmount = TOTAL_BOND;
        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit =
            _buildPermitForToken(address(otherCurrency), permitAmount, 0, block.timestamp + 1 hours);

        otherCurrency.mint(proposer, permitAmount);
        vm.prank(proposer);
        otherCurrency.approve(address(mockPermit2), permitAmount);
        uint256 proposerBalanceBefore = otherCurrency.balanceOf(proposer);

        vm.expectRevert(
            abi.encodeWithSelector(
                SignedProposer.PermitTokenMismatch.selector, address(currency), address(otherCurrency)
            )
        );
        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", 0);

        assertEq(mockPermit2.lastOwner(), address(0));
        assertEq(mockPermit2.lastWitness(), bytes32(0));
        assertEq(otherCurrency.balanceOf(proposer), proposerBalanceBefore);
        assertEq(otherCurrency.balanceOf(address(signedProposer)), 0);
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

    // ─── Partial-success batch tests ────────────────────────────────────────────

    function test_tryMulticall_allSuccess_preservesProposalEventsAndAccounting() public {
        vm.warp(block.timestamp + 2);
        uint256 firstTimestamp = block.timestamp - 1;
        uint256 secondTimestamp = block.timestamp;
        _makeRequest(firstTimestamp, 0);
        _makeRequest(secondTimestamp, 0);
        _setBond();

        uint256 payment = 5 ether;
        uint256 excess = 7 ether;
        SignedProposer.Proposal memory firstProposal = _buildProposal(firstTimestamp, 1 ether, payment);
        SignedProposer.Proposal memory secondProposal = _buildProposal(secondTimestamp, 2 ether);
        ISignatureTransfer.PermitTransferFrom memory firstPermit =
            _buildPermit(TOTAL_BOND + payment + excess, 0, block.timestamp + 1 hours);
        ISignatureTransfer.PermitTransferFrom memory secondPermit =
            _buildPermit(TOTAL_BOND, 1, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND * 2 + payment + excess);
        uint256 proposerBalanceBefore = currency.balanceOf(proposer);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeProposalCall(firstProposal, proposer, firstPermit, "", payment);
        calls[1] = _encodeProposalCall(secondProposal, proposer, secondPermit, "", 0);

        vm.expectEmit(true, true, false, true, address(moo));
        emit OptimisticOracleV2Interface.ProposePrice(
            requester,
            proposer,
            IDENTIFIER,
            firstTimestamp,
            ANCILLARY,
            1 ether,
            block.timestamp + LEGACY_DEFAULT_LIVENESS,
            address(currency)
        );
        vm.expectEmit(true, true, true, true, address(signedProposer));
        emit ProposalExecuted(
            proposer, address(moo), requester, IDENTIFIER, firstTimestamp, 1 ether, TOTAL_BOND, payment
        );
        vm.expectEmit(true, true, false, true, address(moo));
        emit OptimisticOracleV2Interface.ProposePrice(
            requester,
            proposer,
            IDENTIFIER,
            secondTimestamp,
            ANCILLARY,
            2 ether,
            block.timestamp + LEGACY_DEFAULT_LIVENESS,
            address(currency)
        );
        vm.expectEmit(true, true, true, true, address(signedProposer));
        emit ProposalExecuted(proposer, address(moo), requester, IDENTIFIER, secondTimestamp, 2 ether, TOTAL_BOND, 0);

        vm.prank(relayer);
        bool[] memory successes = signedProposer.tryMulticall(calls);

        assertEq(successes.length, 2);
        assertTrue(successes[0]);
        assertTrue(successes[1]);
        assertEq(proposerBalanceBefore - currency.balanceOf(proposer), TOTAL_BOND * 2 + payment);
        assertEq(currency.balanceOf(address(signedProposer)), payment);
    }

    function test_tryMulticall_mixedFailure_continuesToLaterProposalAndEmitsExactFailure() public {
        vm.warp(block.timestamp + 2);
        uint256 firstTimestamp = block.timestamp - 1;
        uint256 secondTimestamp = block.timestamp;
        _makeRequest(firstTimestamp, 0);
        _makeRequest(secondTimestamp, 0);
        _setBond();

        SignedProposer.Proposal memory firstProposal = _buildProposal(firstTimestamp, 1 ether);
        SignedProposer.Proposal memory failedProposal = _buildProposal(firstTimestamp, 9 ether, 0);
        SignedProposer.Proposal memory secondProposal = _buildProposal(secondTimestamp, 2 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND * 2);

        bytes[] memory calls = new bytes[](3);
        calls[0] = _encodeProposalCall(firstProposal, proposer, permit, "", 0);
        calls[1] = _encodeProposalCall(failedProposal, proposer, permit, "", 1);
        calls[2] = _encodeProposalCall(secondProposal, proposer, permit, "", 0);
        bytes memory revertData = abi.encodeWithSelector(SignedProposer.PaymentExceedsMaxPayment.selector);

        vm.expectEmit(true, true, false, true, address(signedProposer));
        emit ProposalCallFailed(
            1, keccak256(calls[1]), SignedProposer.PaymentExceedsMaxPayment.selector, keccak256(revertData)
        );

        vm.prank(relayer);
        bool[] memory successes = signedProposer.tryMulticall(calls);

        assertTrue(successes[0]);
        assertFalse(successes[1]);
        assertTrue(successes[2]);
        assertEq(moo.getRequest(requester, IDENTIFIER, firstTimestamp, ANCILLARY).proposedPrice, 1 ether);
        assertEq(moo.getRequest(requester, IDENTIFIER, secondTimestamp, ANCILLARY).proposedPrice, 2 ether);
    }

    function test_tryMulticall_allFailure_returnsPerCallResultsAndEvents() public {
        SignedProposer.Proposal memory proposal = _buildProposal(block.timestamp, 1 ether, 0);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(0, 0, block.timestamp + 1 hours);
        bytes[] memory calls = new bytes[](9);
        bytes memory revertData = abi.encodeWithSelector(SignedProposer.PaymentExceedsMaxPayment.selector);

        for (uint256 i; i < calls.length; ++i) {
            calls[i] = _encodeProposalCall(proposal, proposer, permit, "", i + 1);
            vm.expectEmit(true, true, false, true, address(signedProposer));
            emit ProposalCallFailed(
                i, keccak256(calls[i]), SignedProposer.PaymentExceedsMaxPayment.selector, keccak256(revertData)
            );
        }

        vm.prank(relayer);
        bool[] memory successes = signedProposer.tryMulticall(calls);

        for (uint256 i; i < successes.length; ++i) {
            assertFalse(successes[i]);
        }
    }

    function test_tryMulticall_lateProposalCollision_doesNotBlockLaterProposal() public {
        vm.warp(block.timestamp + 2);
        uint256 collisionTimestamp = block.timestamp - 1;
        uint256 freshTimestamp = block.timestamp;
        _makeRequest(collisionTimestamp, 0);
        _makeRequest(freshTimestamp, 0);
        _setBond();
        _fundAndApproveProposer(TOTAL_BOND * 3);

        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        SignedProposer.Proposal memory collisionProposal = _buildProposal(collisionTimestamp, 1 ether);
        SignedProposer.Proposal memory freshProposal = _buildProposal(freshTimestamp, 2 ether);

        vm.prank(relayer);
        signedProposer.propose(collisionProposal, proposer, permit, "", 0);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeProposalCall(collisionProposal, proposer, permit, "", 0);
        calls[1] = _encodeProposalCall(freshProposal, proposer, permit, "", 0);

        vm.prank(relayer);
        (bool directSuccess, bytes memory collisionRevertData) = address(signedProposer).call(calls[0]);
        assertFalse(directSuccess);

        vm.expectEmit(true, true, false, true, address(signedProposer));
        emit ProposalCallFailed(
            0, keccak256(calls[0]), _revertSelector(collisionRevertData), keccak256(collisionRevertData)
        );

        vm.prank(relayer);
        bool[] memory successes = signedProposer.tryMulticall(calls);

        assertFalse(successes[0]);
        assertTrue(successes[1]);
        assertEq(moo.getRequest(requester, IDENTIFIER, freshTimestamp, ANCILLARY).proposedPrice, 2 ether);
    }

    function test_revert_tryMulticall_rejectsSelectorBeforeAnyExecution() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();
        _fundAndApproveProposer(TOTAL_BOND);

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeProposalCall(proposal, proposer, permit, "", 0);
        calls[1] = abi.encodeCall(SignedProposer.withdrawPayments, (IERC20(address(currency)), relayer, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                TryMulticall.TryMulticallInvalidSelector.selector, 1, SignedProposer.withdrawPayments.selector
            )
        );
        vm.prank(relayer);
        signedProposer.tryMulticall(calls);

        assertEq(moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY).proposer, address(0));
        assertEq(currency.balanceOf(proposer), TOTAL_BOND);
    }

    function test_revert_tryMulticall_rejectsShortCalldata() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = hex"123456";

        vm.expectRevert(abi.encodeWithSelector(TryMulticall.TryMulticallInvalidSelector.selector, 0, bytes4(0)));
        vm.prank(relayer);
        signedProposer.tryMulticall(calls);
    }

    function test_revert_tryMulticall_notDelegatedProposer() public {
        bytes[] memory calls = new bytes[](0);
        address nobody = makeAddr("nobody");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DELEGATED_PROPOSER_ROLE
            )
        );
        vm.prank(nobody);
        signedProposer.tryMulticall(calls);
    }

    function test_multicall_remainsAtomic() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();
        _fundAndApproveProposer(TOTAL_BOND * 2);
        uint256 balanceBefore = currency.balanceOf(proposer);

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeProposalCall(proposal, proposer, permit, "", 0);
        calls[1] = _encodeProposalCall(proposal, proposer, permit, "", 0);

        vm.expectRevert();
        vm.prank(relayer);
        signedProposer.multicall(calls);

        assertEq(moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY).proposer, address(0));
        assertEq(currency.balanceOf(proposer), balanceBefore);
    }

    function test_tryMulticall_blocksNestedBatchWithoutBlockingOuterProposal() public {
        ReentrantTryMulticallRequester callbackRequester =
            new ReentrantTryMulticallRequester(moo, signedProposer, IERC20(address(currency)));
        requester = address(callbackRequester);
        requesterWhitelist.addToWhitelist(requester);
        vm.prank(admin);
        signedProposer.addDelegatedProposer(requester);

        uint256 timestamp = block.timestamp;
        callbackRequester.requestWithProposalCallback(IDENTIFIER, timestamp, ANCILLARY);
        _setBond();
        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);

        bytes[] memory calls = new bytes[](1);
        calls[0] = _encodeProposalCall(proposal, proposer, permit, "", 0);
        callbackRequester.setNestedCalls(calls);

        vm.prank(relayer);
        bool[] memory successes = signedProposer.tryMulticall(calls);

        assertTrue(successes[0]);
        assertTrue(callbackRequester.attemptedNestedBatch());
        assertFalse(callbackRequester.nestedBatchSucceeded());
        assertEq(
            callbackRequester.nestedRevertData(),
            abi.encodeWithSelector(TryMulticall.TryMulticallReentrantCall.selector)
        );
    }

    function test_tryMulticall_gasExhaustingChildCanRevertEntireBatch() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();
        _fundAndApproveProposer(TOTAL_BOND);

        RevertingSignedProposerOracle gasExhaustingOracle =
            new RevertingSignedProposerOracle(IERC20(address(currency)), true, 0);
        SignedProposer.Proposal memory gasExhaustingProposal = SignedProposer.Proposal({
            oracle: address(gasExhaustingOracle),
            requester: requester,
            identifier: IDENTIFIER,
            timestamp: timestamp,
            ancillaryData: ANCILLARY,
            proposedPrice: 1 ether,
            maxPayment: 0
        });
        SignedProposer.Proposal memory validProposal = _buildProposal(timestamp, 2 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeProposalCall(gasExhaustingProposal, proposer, permit, "", 0);
        calls[1] = _encodeProposalCall(validProposal, proposer, permit, "", 0);

        vm.prank(relayer);
        (bool success,) =
            address(signedProposer).call{gas: 1_000_000}(abi.encodeCall(TryMulticall.tryMulticall, (calls)));

        assertFalse(success);
        assertEq(moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY).proposer, address(0));
    }

    function test_tryMulticall_hashesCompleteLargeRevertData() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();
        _fundAndApproveProposer(TOTAL_BOND);

        uint256 revertDataSize = 512 * 1024;
        RevertingSignedProposerOracle revertingOracle =
            new RevertingSignedProposerOracle(IERC20(address(currency)), false, revertDataSize);
        SignedProposer.Proposal memory failedProposal = SignedProposer.Proposal({
            oracle: address(revertingOracle),
            requester: requester,
            identifier: IDENTIFIER,
            timestamp: timestamp,
            ancillaryData: ANCILLARY,
            proposedPrice: 1 ether,
            maxPayment: 0
        });
        SignedProposer.Proposal memory validProposal = _buildProposal(timestamp, 2 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeProposalCall(failedProposal, proposer, permit, "", 0);
        calls[1] = _encodeProposalCall(validProposal, proposer, permit, "", 0);

        vm.expectEmit(true, true, false, true, address(signedProposer));
        emit ProposalCallFailed(0, keccak256(calls[0]), bytes4(0), keccak256(new bytes(revertDataSize)));

        vm.prank(relayer);
        bool[] memory successes = signedProposer.tryMulticall(calls);

        assertFalse(successes[0]);
        assertTrue(successes[1]);
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

    function test_revert_removeFromWhitelist_self() public {
        address whitelistAdmin = makeAddr("whitelistAdmin");
        vm.prank(admin);
        signedProposer.addWhitelistAdmin(whitelistAdmin);

        AddressWhitelist wl = new AddressWhitelist();
        wl.addToWhitelist(address(signedProposer));
        wl.transferOwnership(address(signedProposer));

        vm.expectRevert(SignedProposer.CannotRemoveSelfFromWhitelist.selector);
        vm.prank(whitelistAdmin);
        signedProposer.removeFromWhitelist(wl, address(signedProposer));

        assertTrue(wl.isOnWhitelist(address(signedProposer)));
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
        address newOwner = makeAddr("newOwner");

        wl.addToWhitelist(newOwner);
        wl.transferOwnership(address(signedProposer));

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
        address newOwner = makeAddr("newOwner");
        wl.addToWhitelist(newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(signedProposer)));
        vm.prank(admin);
        signedProposer.transferWhitelistOwnership(wl, newOwner);
    }

    function test_revert_transferWhitelistOwnership_whenNewOwnerNotWhitelisted() public {
        AddressWhitelist wl = new AddressWhitelist();
        wl.transferOwnership(address(signedProposer));
        address newOwner = makeAddr("newOwner");

        vm.expectRevert(abi.encodeWithSelector(SignedProposer.NewOwnerNotWhitelisted.selector, newOwner));
        vm.prank(admin);
        signedProposer.transferWhitelistOwnership(wl, newOwner);
    }

    function test_transferWhitelistOwnership_toReplacementSignedProposer() public {
        defaultProposerWhitelist.removeFromWhitelist(proposer);

        address replacementAdmin = makeAddr("replacementAdmin");
        SignedProposer replacement = new SignedProposer(ISignatureTransfer(address(mockPermit2)), replacementAdmin);

        defaultProposerWhitelist.addToWhitelist(address(replacement));
        defaultProposerWhitelist.transferOwnership(address(signedProposer));

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

    function test_propose_paymentCanBeLessThanMaxPayment() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        uint256 maxPayment = 20 ether;
        uint256 payment = 5 ether;
        uint256 permitAmount = TOTAL_BOND + maxPayment;

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, maxPayment);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);
        uint256 balanceBefore = currency.balanceOf(proposer);

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, "", payment);

        assertEq(totalBond, TOTAL_BOND);
        assertEq(balanceBefore - currency.balanceOf(proposer), TOTAL_BOND + payment);
        assertEq(currency.balanceOf(address(signedProposer)), payment);
    }

    function test_revert_propose_permitTransferAmountMismatch() public {
        currency = new ShortTransferERC20Mock();
        collateralWhitelist.addToWhitelist(address(currency));
        store.setFinalFee(address(currency), FINAL_FEE);
        _setAllowedBondRange();

        uint256 retainedBalance = 25 ether;
        uint256 timestamp = block.timestamp;
        currency.mint(address(signedProposer), retainedBalance);
        _makeRequest(timestamp, 0);
        _setBond();

        uint256 payment = 5 ether;
        uint256 permitAmount = TOTAL_BOND + payment;
        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, payment);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(permitAmount, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(permitAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                SignedProposer.PermitTransferAmountMismatch.selector, permitAmount, permitAmount * 9_000 / 10_000
            )
        );
        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, "", payment);

        assertEq(currency.balanceOf(address(signedProposer)), retainedBalance);

        OptimisticOracleV2Interface.Request memory request = moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY);
        assertEq(request.proposer, address(0));
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

contract ReentrantTryMulticallRequester {
    ManagedOptimisticOracleV2 internal immutable oracle;
    SignedProposer internal immutable signedProposer;
    IERC20 internal immutable currency;

    bytes[] internal nestedCalls;

    bool public attemptedNestedBatch;
    bool public nestedBatchSucceeded;
    bytes public nestedRevertData;

    constructor(ManagedOptimisticOracleV2 _oracle, SignedProposer _signedProposer, IERC20 _currency) {
        oracle = _oracle;
        signedProposer = _signedProposer;
        currency = _currency;
    }

    function requestWithProposalCallback(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external {
        oracle.requestPrice(identifier, timestamp, ancillaryData, currency, 0);
        oracle.setCallbacks(identifier, timestamp, ancillaryData, true, false, false);
    }

    function setNestedCalls(bytes[] calldata calls) external {
        delete nestedCalls;
        for (uint256 i; i < calls.length; ++i) {
            nestedCalls.push(calls[i]);
        }
    }

    function priceProposed(bytes32, uint256, bytes memory) external {
        require(msg.sender == address(oracle), "ReentrantRequester: unauthorized");

        attemptedNestedBatch = true;
        try signedProposer.tryMulticall(nestedCalls) returns (bool[] memory) {
            nestedBatchSucceeded = true;
        } catch (bytes memory reason) {
            nestedRevertData = reason;
        }
    }
}

contract RevertingSignedProposerOracle {
    IERC20 internal immutable currency;
    bool internal immutable exhaustGas;
    uint256 internal immutable revertDataSize;

    constructor(IERC20 _currency, bool _exhaustGas, uint256 _revertDataSize) {
        currency = _currency;
        exhaustGas = _exhaustGas;
        revertDataSize = _revertDataSize;
    }

    function getRequest(address, bytes32, uint256, bytes memory)
        external
        view
        returns (OptimisticOracleV2Interface.Request memory request)
    {
        if (exhaustGas) {
            assembly {
                for {} 1 {} {}
            }
        }

        bytes memory revertData = new bytes(revertDataSize);
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }

        request.currency = currency;
    }
}
