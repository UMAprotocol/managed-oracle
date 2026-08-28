// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SignedProposerPermit2Test is Test, DeployPermit2 {
    bytes32 internal constant IDENTIFIER = keccak256("PRICE_ID");
    bytes internal constant ANCILLARY = bytes(":memo: test");
    uint256 internal constant LEGACY_DEFAULT_LIVENESS = 2 hours;
    uint256 internal constant MINIMUM_DISPUTE_WINDOW = 5 minutes;
    uint256 internal constant BOND = 100 ether;
    uint256 internal constant FINAL_FEE = 10 ether;
    uint256 internal constant TOTAL_BOND = BOND + FINAL_FEE;

    bytes32 internal constant DELEGATED_PROPOSER_ROLE = keccak256("DELEGATED_PROPOSER_ROLE");
    bytes32 internal constant PROPOSAL_TYPEHASH = keccak256(
        "Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)"
    );
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    SignedProposer internal signedProposer;
    ManagedOptimisticOracleV2 internal moo;

    address internal admin;
    address internal configAdmin;
    address internal upgradeAdmin;
    address internal resolverAdmin;
    address internal requestManager;
    address internal requester;
    address internal relayer;

    uint256 internal proposerKey;
    address internal proposer;
    address internal permit2Address;

    FinderInterface internal finder;
    AddressWhitelist internal collateralWhitelist;
    AddressWhitelist internal defaultProposerWhitelist;
    AddressWhitelist internal requesterWhitelist;
    MockIdentifierWhitelist internal idWhitelist;
    MockStore internal store;
    MockOracle internal oracle;
    ERC20Mock internal currency;

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

        vm.label(admin, "admin");
        vm.label(configAdmin, "configAdmin");
        vm.label(upgradeAdmin, "upgradeAdmin");
        vm.label(resolverAdmin, "resolverAdmin");
        vm.label(requestManager, "requestManager");
        vm.label(requester, "requester");
        vm.label(relayer, "relayer");
        vm.label(proposer, "PROPOSER");

        finder = new MockFinder();
        collateralWhitelist = new AddressWhitelist();
        defaultProposerWhitelist = new AddressWhitelist();
        requesterWhitelist = new AddressWhitelist();
        idWhitelist = new MockIdentifierWhitelist();
        store = new MockStore();
        oracle = new MockOracle();
        currency = new ERC20Mock();

        collateralWhitelist.addToWhitelist(address(currency));
        idWhitelist.addSupportedIdentifier(IDENTIFIER);

        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateralWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(idWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.Oracle, address(oracle));

        store.setFinalFee(address(currency), FINAL_FEE);

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

        permit2Address = deployPermit2();
        vm.label(permit2Address, "PERMIT2");

        signedProposer = new SignedProposer(ISignatureTransfer(permit2Address), admin);
        vm.prank(admin);
        signedProposer.addDelegatedProposer(relayer);

        // Pre-whitelist the proposer here to keep this suite focused on real Permit2 signature validation.
        // In production the expected path is often for SignedProposer to own the whitelist and temporarily
        // add the proposer during execution; that whitelist-management path is already covered in
        // SignedProposer.t.sol.
        defaultProposerWhitelist.addToWhitelist(proposer);
        defaultProposerWhitelist.addToWhitelist(address(signedProposer));
        requesterWhitelist.addToWhitelist(requester);
    }

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
        currency.approve(permit2Address, amount);
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

    function _getPermitWitnessTransferSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        SignedProposer.Proposal memory proposal,
        address spender
    ) internal view returns (bytes memory) {
        bytes32 tokenPermissionsHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 witnessTypeHash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB, signedProposer.WITNESS_TYPE_STRING())
        );
        bytes32 structHash = keccak256(
            abi.encode(
                witnessTypeHash,
                tokenPermissionsHash,
                spender,
                permit.nonce,
                permit.deadline,
                _computeWitnessHash(proposal)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IEIP712(permit2Address).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(proposerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_propose_realPermit2Signature() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        uint256 payment = 5 ether;
        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether, payment);
        ISignatureTransfer.PermitTransferFrom memory permit =
            _buildPermit(TOTAL_BOND + payment, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND + payment);
        bytes memory signature = _getPermitWitnessTransferSignature(permit, proposal, address(signedProposer));

        vm.prank(relayer);
        uint256 totalBond = signedProposer.propose(proposal, proposer, permit, signature, payment);

        assertEq(totalBond, TOTAL_BOND);

        OptimisticOracleV2Interface.Request memory request = moo.getRequest(requester, IDENTIFIER, timestamp, ANCILLARY);
        assertEq(request.proposer, proposer);
        assertEq(request.proposedPrice, 1 ether);
        assertEq(currency.balanceOf(address(signedProposer)), payment);
    }

    function test_revert_propose_realPermit2Signature_wrongSpender() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory proposal = _buildProposal(timestamp, 1 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);
        bytes memory signature = _getPermitWitnessTransferSignature(permit, proposal, address(this));

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        vm.prank(relayer);
        signedProposer.propose(proposal, proposer, permit, signature, 0);
    }

    function test_revert_propose_realPermit2Signature_alteredWitness() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory signedProposal = _buildProposal(timestamp, 1 ether);
        SignedProposer.Proposal memory submittedProposal = _buildProposal(timestamp, 2 ether);
        ISignatureTransfer.PermitTransferFrom memory permit = _buildPermit(TOTAL_BOND, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND);
        bytes memory signature = _getPermitWitnessTransferSignature(permit, signedProposal, address(signedProposer));

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        vm.prank(relayer);
        signedProposer.propose(submittedProposal, proposer, permit, signature, 0);
    }

    function test_revert_propose_realPermit2Signature_alteredMaxPayment() public {
        uint256 timestamp = block.timestamp;
        _makeRequest(timestamp, 0);
        _setBond();

        SignedProposer.Proposal memory signedProposal = _buildProposal(timestamp, 1 ether, 5 ether);
        SignedProposer.Proposal memory submittedProposal = _buildProposal(timestamp, 1 ether, 6 ether);
        ISignatureTransfer.PermitTransferFrom memory permit =
            _buildPermit(TOTAL_BOND + submittedProposal.maxPayment, 0, block.timestamp + 1 hours);
        _fundAndApproveProposer(TOTAL_BOND + submittedProposal.maxPayment);
        bytes memory signature = _getPermitWitnessTransferSignature(permit, signedProposal, address(signedProposer));

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        vm.prank(relayer);
        signedProposer.propose(submittedProposal, proposer, permit, signature, 0);
    }
}
