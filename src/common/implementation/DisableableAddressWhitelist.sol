// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {AddressWhitelistInterface} from "../interfaces/AddressWhitelistInterface.sol";
import {DisableableAddressWhitelistInterface} from "../interfaces/DisableableAddressWhitelistInterface.sol";
import {AddressWhitelist} from "./AddressWhitelist.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title A contract to track a whitelist of addresses with ability to toggle its enforcement.
 */
contract DisableableAddressWhitelist is AddressWhitelist, DisableableAddressWhitelistInterface, ERC165 {
    bool public isEnforced;

    event WhitelistEnforcementSet(bool enforced);

    /**
     * @notice Disables or enables the whitelist restrictions.
     * @param enforced True to enforce the whitelist, False to disable it.
     */
    function setWhitelistEnforcement(bool enforced) external nonReentrant onlyOwner {
        isEnforced = enforced;
        emit WhitelistEnforcementSet(enforced);
    }

    /**
     * @notice Checks whether an address is on the whitelist and if the whitelist is enabled.
     * @param elementToCheck the address to check.
     * @return True if whitelist enforcement is disabled, or if the address is whitelisted when enforcement is enabled.
     */
    function isOnWhitelist(address elementToCheck)
        public
        view
        override(AddressWhitelist, AddressWhitelistInterface)
        nonReentrantView
        returns (bool)
    {
        return !isEnforced || super.isOnWhitelist(elementToCheck);
    }

    /**
     * @notice Returns true if this contract implements the interface defined by interfaceId.
     * @param interfaceId The interface identifier, as specified in ERC-165.
     * @return True if the contract implements the interface defined by interfaceId.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(DisableableAddressWhitelistInterface).interfaceId || super.supportsInterface(interfaceId);
    }
}
