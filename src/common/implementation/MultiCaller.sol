// SPDX-License-Identifier: AGPL-3.0-only
// Originally ported from https://github.com/UMAprotocol/protocol/blob/%40uma/core%402.62.0/packages/core/contracts/common/implementation/MultiCaller.sol
// to be compatible for use in upgradeable contracts. Error handling has been modified to properly preserve custom errors.

pragma solidity ^0.8.0;

/**
 * @title MultiCaller
 * @notice Ported from "@uma/core/contracts/common/implementation/MultiCaller.sol" with modifications:
 * 1. Added comments to clarify why we allow delegatecall() in this contract, which is typically unsafe for use in
 *    upgradeable implementation contracts.
 * 2. Modified error handling to bubble raw revert data instead of attempting to decode as Error(string),
 *    ensuring custom errors and panic codes are properly preserved.
 * @dev See https://docs.openzeppelin.com/upgrades-plugins/1.x/faq#delegatecall-selfdestruct for more details.
 */
abstract contract MultiCaller {
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            // Typically, implementation contracts used in the upgradeable proxy pattern shouldn't call `delegatecall`
            // because it could allow a malicious actor to call this implementation contract directly (rather than
            // through a proxy contract) and then selfdestruct() the contract, thereby freezing the upgradeable
            // proxy. However, since we're only delegatecall-ing into this contract, then we can consider this
            // use of delegatecall() safe.

            /// @custom:oz-upgrades-unsafe-allow delegatecall
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // Bubble up the raw revert data to preserve custom errors and panic codes
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }

            results[i] = result;
        }
    }

    /**
     * @dev Reserve storage slots for future versions of this base contract to add state variables without affecting the
     * storage layout of child contracts. Decrement the size of __gap whenever state variables are added. This is at the
     * bottom of contract to make sure its always at the end of storage.
     * See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
     */
    uint256[50] private __gap;
}
