// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AddressWhitelistInterface} from "../interfaces/AddressWhitelistInterface.sol";

/**
 * @notice This contract is an implementation of AddressWhitelistInterface where the whitelist is permanently disabled.
 * @dev All addresses are considered to be on this whitelist.
 * @custom:security-contact bugs@umaproject.org
 */
contract DisabledAddressWhitelist is AddressWhitelistInterface, ERC165 {
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

    /**
     * @notice Returns true if this contract implements the interface defined by interfaceId.
     * @param interfaceId The interface identifier, as specified in ERC-165.
     * @return True if the contract implements the interface defined by interfaceId.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(AddressWhitelistInterface).interfaceId || super.supportsInterface(interfaceId);
    }
}
