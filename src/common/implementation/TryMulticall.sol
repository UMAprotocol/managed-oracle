// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/**
 * @title TryMulticall
 * @notice Executes allowed self-delegatecalls without reverting successful siblings.
 */
abstract contract TryMulticall {
    bool private _tryMulticallEntered;

    event ProposalCallFailed(
        uint256 indexed index, bytes32 indexed callHash, bytes4 errorSelector, bytes32 revertDataHash
    );

    error TryMulticallReentrantCall();
    error TryMulticallInvalidSelector(uint256 index, bytes4 selector);

    /**
     * @notice Executes allowed calls independently and returns their success values.
     * @dev Self-delegatecall preserves the original caller. Ordinary failures emit only bounded metadata. There is no
     * child gas or revert-data cap, so gas exhaustion while executing or recording a failure can revert the full batch.
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
