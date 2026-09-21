// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/**
 * @title TryMulticall
 * @notice Executes allowed self-delegatecalls without reverting successful siblings.
 */
abstract contract TryMulticall {
    bool private _tryMulticallEntered;

    /// @notice Emitted when a child execution attempt returns unsuccessfully.
    /// @dev Empty failure metadata can mean either an empty revert or an out-of-gas child. This event does not prove
    /// the submitted operation itself is invalid; callers may retry it with a different gas allocation.
    event ProposalCallFailed(
        uint256 indexed index, bytes32 indexed callHash, bytes4 errorSelector, bytes32 revertDataHash
    );

    error TryMulticallReentrantCall();
    error TryMulticallInvalidSelector(uint256 index, bytes4 selector);

    /**
     * @notice Executes allowed calls independently and returns their execution-attempt success values.
     * @dev Self-delegatecall preserves the original caller. Ordinary failures emit only bounded metadata. There is no
     * child gas or revert-data cap. Under EIP-150, an out-of-gas child can return `false` while leaving the outer call
     * enough gas to continue, but later children may receive too little gas and also return `false`. If the remaining
     * outer gas cannot finish the loop or encode the result, the full batch reverts. A `false` value therefore means
     * only that the corresponding execution attempt failed; it does not prove the submitted operation is invalid.
     */
    function tryMulticall(bytes[] calldata calls) external returns (bool[] memory successes) {
        _checkTryMulticallCaller();
        if (_tryMulticallEntered) revert TryMulticallReentrantCall();

        uint256 callsLength = calls.length;
        bytes4 allowedSelector = _tryMulticallSelector();
        for (uint256 i; i < callsLength; ++i) {
            bytes calldata callData = calls[i];
            bytes4 selector = callData.length >= 4 ? bytes4(callData[:4]) : bytes4(0);
            if (selector != allowedSelector) revert TryMulticallInvalidSelector(i, selector);
        }

        successes = new bool[](callsLength);
        _tryMulticallEntered = true;
        for (uint256 i; i < callsLength; ++i) {
            bytes calldata callData = calls[i];
            (bool success, bytes memory revertData) = address(this).delegatecall(callData);
            successes[i] = success;

            if (!success) {
                bytes4 errorSelector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
                emit ProposalCallFailed(i, keccak256(callData), errorSelector, keccak256(revertData));
            }
        }
        _tryMulticallEntered = false;
    }

    function _checkTryMulticallCaller() internal view virtual;

    function _tryMulticallSelector() internal view virtual returns (bytes4);
}
