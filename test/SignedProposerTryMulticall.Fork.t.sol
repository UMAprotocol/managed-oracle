// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {SignedProposer} from "src/optimistic-oracle-v2/implementation/SignedProposer.sol";
import {MaliciousSignedProposerOracle} from "./mocks/MaliciousSignedProposerOracle.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @notice Polygon fork coverage for partial-success batching against canonical Permit2.
 * @dev Uses a pinned block so Permit2 bytecode and EIP-712 domain behavior are deterministic.
 */
contract SignedProposerTryMulticallForkTest is Test {
    address internal constant POLYGON_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant FORK_BLOCK = 81_683_818;
    uint256 internal constant BOND = 1 ether;

    bytes32 internal constant IDENTIFIER = keccak256("FORK_PRICE_ID");
    bytes32 internal constant PROPOSAL_TYPEHASH = keccak256(
        "Proposal(address oracle,address requester,bytes32 identifier,uint256 timestamp,bytes ancillaryData,int256 proposedPrice,uint256 maxPayment)"
    );
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    event ProposalCallFailed(
        uint256 indexed index, bytes32 indexed callHash, bytes4 errorSelector, bytes32 revertDataHash
    );

    SignedProposer internal signedProposer;
    MaliciousSignedProposerOracle internal oracle;
    ERC20Mock internal currency;

    address internal relayer;
    uint256 internal firstProposerKey;
    uint256 internal secondProposerKey;
    address internal firstProposer;
    address internal secondProposer;

    function setUp() public {
        vm.createSelectFork(vm.envString("NODE_URL_137"), FORK_BLOCK);
        assertGt(POLYGON_PERMIT2.code.length, 0, "canonical Polygon Permit2 missing");

        address admin = makeAddr("admin");
        relayer = makeAddr("relayer");
        firstProposerKey = _findEoaKey(0xA11CE);
        secondProposerKey = _findEoaKey(0xB0B);
        firstProposer = vm.addr(firstProposerKey);
        secondProposer = vm.addr(secondProposerKey);
        assertEq(firstProposer.code.length, 0, "first proposer must be an EOA");
        assertEq(secondProposer.code.length, 0, "second proposer must be an EOA");
        assertNotEq(firstProposer, secondProposer, "proposers must differ");

        currency = new ERC20Mock();
        signedProposer = new SignedProposer(ISignatureTransfer(POLYGON_PERMIT2), admin);
        oracle = new MaliciousSignedProposerOracle(currency, address(signedProposer), address(0));
        oracle.setBondAmount(BOND);

        vm.prank(admin);
        signedProposer.addDelegatedProposer(relayer);

        currency.mint(firstProposer, BOND);
        currency.mint(secondProposer, BOND);
        vm.prank(firstProposer);
        currency.approve(POLYGON_PERMIT2, BOND);
        vm.prank(secondProposer);
        currency.approve(POLYGON_PERMIT2, BOND);
    }

    function testFork_tryMulticall_mixedPermit2SignersAndNonces() public {
        SignedProposer.Proposal memory firstProposal = _proposal(block.timestamp, 1 ether);
        SignedProposer.Proposal memory failedProposal = _proposal(block.timestamp + 1, 2 ether);
        SignedProposer.Proposal memory secondProposal = _proposal(block.timestamp + 2, 3 ether);
        ISignatureTransfer.PermitTransferFrom memory firstPermit = _permit(7);
        ISignatureTransfer.PermitTransferFrom memory failedPermit = _permit(999);
        ISignatureTransfer.PermitTransferFrom memory secondPermit = _permit(513);

        bytes[] memory calls = new bytes[](3);
        calls[0] =
            _call(firstProposal, firstProposer, firstPermit, _signature(firstProposerKey, firstPermit, firstProposal));
        calls[1] = _call(
            failedProposal, secondProposer, failedPermit, _signature(firstProposerKey, failedPermit, failedProposal)
        );
        calls[2] = _call(
            secondProposal, secondProposer, secondPermit, _signature(secondProposerKey, secondPermit, secondProposal)
        );

        bytes memory revertData = abi.encodeWithSelector(SignatureVerification.InvalidSigner.selector);
        vm.expectEmit(true, true, false, true, address(signedProposer));
        emit ProposalCallFailed(
            1, keccak256(calls[1]), SignatureVerification.InvalidSigner.selector, keccak256(revertData)
        );

        vm.prank(relayer);
        bool[] memory successes = signedProposer.tryMulticall(calls);

        assertTrue(successes[0]);
        assertFalse(successes[1]);
        assertTrue(successes[2]);
        assertEq(currency.balanceOf(address(oracle)), BOND * 2);
        assertEq(ISignatureTransfer(POLYGON_PERMIT2).nonceBitmap(firstProposer, 0), 1 << 7);
        assertEq(ISignatureTransfer(POLYGON_PERMIT2).nonceBitmap(secondProposer, 2), 1 << 1);
        assertEq(ISignatureTransfer(POLYGON_PERMIT2).nonceBitmap(secondProposer, 3), 0);
    }

    function _proposal(uint256 timestamp, int256 price) internal view returns (SignedProposer.Proposal memory) {
        return SignedProposer.Proposal({
            oracle: address(oracle),
            requester: address(this),
            identifier: IDENTIFIER,
            timestamp: timestamp,
            ancillaryData: bytes(":fork: polygon"),
            proposedPrice: price,
            maxPayment: 0
        });
    }

    function _permit(uint256 nonce) internal view returns (ISignatureTransfer.PermitTransferFrom memory) {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(currency), amount: BOND}),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _findEoaKey(uint256 candidate) internal returns (uint256) {
        while (vm.addr(candidate).code.length != 0) ++candidate;
        return candidate;
    }

    function _call(
        SignedProposer.Proposal memory proposal,
        address proposer,
        ISignatureTransfer.PermitTransferFrom memory permit,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(SignedProposer.propose, (proposal, proposer, permit, signature, 0));
    }

    function _signature(
        uint256 signerKey,
        ISignatureTransfer.PermitTransferFrom memory permit,
        SignedProposer.Proposal memory proposal
    ) internal view returns (bytes memory) {
        bytes32 tokenPermissionsHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 witnessTypeHash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB, signedProposer.WITNESS_TYPE_STRING())
        );
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
        bytes32 structHash = keccak256(
            abi.encode(
                witnessTypeHash, tokenPermissionsHash, address(signedProposer), permit.nonce, permit.deadline, witness
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IEIP712(POLYGON_PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
