// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @notice Minimal mock of Permit2's SignatureTransfer for unit testing.
/// @dev Does NOT verify signatures — it only transfers tokens and records the witness for assertions.
/// In production, the canonical Permit2 deployment handles signature verification.
contract MockPermit2 {
    bytes32 public lastWitness;
    string public lastWitnessTypeString;
    address public lastOwner;

    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata /* signature */
    ) external {
        require(block.timestamp <= permit.deadline, "MockPermit2: expired");
        require(transferDetails.requestedAmount <= permit.permitted.amount, "MockPermit2: amount exceeded");

        lastWitness = witness;
        lastWitnessTypeString = witnessTypeString;
        lastOwner = owner;

        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}
