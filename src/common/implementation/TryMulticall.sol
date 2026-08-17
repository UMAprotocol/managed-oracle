// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/**
 * @title TryMulticall
 * @notice Executes a bounded batch of allowed self-delegatecalls without reverting successful siblings.
 */
abstract contract TryMulticall {
    uint256 public constant MAX_TRY_MULTICALL_CALLS = 8;
    uint256 public constant MAX_TRY_MULTICALL_CALLDATA = 96 * 1024;

    // The child cap isolates siblings; the reserves cover full revert-data hashing and return encoding.
    uint256 private constant CHILD_GAS_LIMIT = 1_500_000;
    uint256 private constant GAS_RESERVE_PER_CALL = 3_400_000;
    uint256 private constant FINAL_GAS_RESERVE = 100_000;

    bool private _tryMulticallEntered;

    event ProposalCallFailed(
        uint256 indexed index, bytes32 indexed callHash, bytes4 errorSelector, bytes32 revertDataHash
    );

    error TryMulticallReentrantCall();
    error TryMulticallTooManyCalls(uint256 provided, uint256 maximum);
    error TryMulticallCalldataTooLarge(uint256 provided, uint256 maximum);
    error TryMulticallInvalidSelector(uint256 index, bytes4 selector);
    error TryMulticallInsufficientGas(uint256 available, uint256 required);

    /**
     * @notice Executes allowed calls independently and returns their success values.
     * @dev Self-delegatecall preserves the original caller. Failures emit only bounded metadata.
     */
    function tryMulticall(bytes[] calldata calls) external returns (bool[] memory successes) {
        _checkTryMulticallCaller();
        if (_tryMulticallEntered) revert TryMulticallReentrantCall();

        uint256 callsLength = calls.length;
        if (callsLength > MAX_TRY_MULTICALL_CALLS) {
            revert TryMulticallTooManyCalls(callsLength, MAX_TRY_MULTICALL_CALLS);
        }

        uint256 totalCalldata;
        bytes4 allowedSelector = _tryMulticallSelector();
        for (uint256 i; i < callsLength; ++i) {
            bytes calldata callData = calls[i];
            totalCalldata += callData.length;
            if (totalCalldata > MAX_TRY_MULTICALL_CALLDATA) {
                revert TryMulticallCalldataTooLarge(totalCalldata, MAX_TRY_MULTICALL_CALLDATA);
            }

            bytes4 selector = callData.length >= 4 ? bytes4(callData[:4]) : bytes4(0);
            if (selector != allowedSelector) revert TryMulticallInvalidSelector(i, selector);
        }

        uint256 requiredGas = callsLength * GAS_RESERVE_PER_CALL + FINAL_GAS_RESERVE;
        if (gasleft() < requiredGas) revert TryMulticallInsufficientGas(gasleft(), requiredGas);

        successes = new bool[](callsLength);
        _tryMulticallEntered = true;
        for (uint256 i; i < callsLength; ++i) {
            bytes calldata callData = calls[i];
            bytes memory callDataMemory = callData;
            bool success;
            uint256 revertDataSize;
            assembly ("memory-safe") {
                success := delegatecall(
                    CHILD_GAS_LIMIT,
                    address(),
                    add(callDataMemory, 0x20),
                    mload(callDataMemory),
                    0,
                    0
                )
                revertDataSize := returndatasize()
            }
            successes[i] = success;

            if (!success) {
                bytes4 errorSelector;
                bytes32 revertDataHash;
                assembly {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, revertDataSize)
                    revertDataHash := keccak256(ptr, revertDataSize)
                    if iszero(lt(revertDataSize, 4)) { errorSelector := mload(ptr) }
                }
                emit ProposalCallFailed(i, keccak256(callData), errorSelector, revertDataHash);
            }
        }
        _tryMulticallEntered = false;
    }

    function _checkTryMulticallCaller() internal view virtual;

    function _tryMulticallSelector() internal view virtual returns (bytes4);
}
