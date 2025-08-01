// SPDX-License-Identifier: AGPL-3.0-only
// Based on https://github.com/UMAprotocol/protocol/blob/%40uma/core%402.62.0/packages/core/contracts/common/interfaces/AddressWhitelistInterface.sol
// adding the functionality to check if the whitelist is enabled.

pragma solidity ^0.8.0;

interface AddressWhitelistInterface {
    function addToWhitelist(address newElement) external;

    function removeFromWhitelist(address newElement) external;

    function isOnWhitelist(address newElement) external view returns (bool);

    function getWhitelist() external view returns (address[] memory);

    function isWhitelistEnabled() external view returns (bool);
}
