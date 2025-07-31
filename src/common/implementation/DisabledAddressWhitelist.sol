// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {AddressWhitelistInterface} from "../interfaces/AddressWhitelistInterface.sol";

/**
 * @notice This contract is an implementation of AddressWhitelistInterface where the whitelist is permanently disabled.
 * @dev All addresses are considered to be on this whitelist.
 */
contract DisabledAddressWhitelist is AddressWhitelistInterface {
    function addToWhitelist(address) external pure {
        revert("Can't add to DisabledAddressWhitelist");
    }

    function removeFromWhitelist(address) external pure {
        revert("Can't remove from DisabledAddressWhitelist");
    }

    function isOnWhitelist(address) external pure returns (bool) {
        return true;
    }

    function getWhitelist() external pure returns (address[] memory) {
        return new address[](0);
    }

    function isWhitelistEnabled() external pure returns (bool enabled) {
        return false;
    }
}
