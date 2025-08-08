// SPDX-License-Identifier: AGPL-3.0-only
// Based on https://github.com/UMAprotocol/protocol/blob/%40uma/core%402.62.0/packages/core/contracts/common/implementation/AddressWhitelist.sol
// adding the functionality to check if the whitelist is enabled and to be compatible with OpenZeppelin v5.x. This also
// uses named imports and linting from Foundry.

pragma solidity ^0.8.0;

import {AddressWhitelistInterface} from "../interfaces/AddressWhitelistInterface.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Lockable} from "@uma/contracts/common/implementation/Lockable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title A contract to track a whitelist of addresses.
 * @custom:security-contact bugs@umaproject.org
 */
contract AddressWhitelist is AddressWhitelistInterface, Ownable, Lockable, ERC165 {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Holds the entire whitelist of addresses. Order is not guaranteed and may change over time.
    EnumerableSet.AddressSet whitelistedSet;

    event AddedToWhitelist(address indexed addedAddress);
    event RemovedFromWhitelist(address indexed removedAddress);

    /**
     * @notice Constructor to initialize the contract.
     * @dev This makes it compatible with v5.x of OpenZeppelin's Ownable contract.
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Adds an address to the whitelist.
     * @param newElement the new address to add.
     */
    function addToWhitelist(address newElement) external override nonReentrant onlyOwner {
        bool added = whitelistedSet.add(newElement);
        if (added) {
            emit AddedToWhitelist(newElement);
        }
    }

    /**
     * @notice Removes an address from the whitelist.
     * @param elementToRemove the existing address to remove.
     */
    function removeFromWhitelist(address elementToRemove) external override nonReentrant onlyOwner {
        bool removed = whitelistedSet.remove(elementToRemove);
        if (removed) {
            emit RemovedFromWhitelist(elementToRemove);
        }
    }

    /**
     * @notice Checks whether an address is on the whitelist.
     * @param elementToCheck the address to check.
     * @return True if `elementToCheck` is on the whitelist, or False.
     */
    function isOnWhitelist(address elementToCheck) public view virtual override nonReentrantView returns (bool) {
        return whitelistedSet.contains(elementToCheck);
    }

    /**
     * @notice Gets all addresses that are currently included in the whitelist.
     * @dev Returns a copy of the entire set via EnumerableSet.values(). This operation is O(n) in the number of
     * addresses and theoretically unbounded. In practice, in the context of `ManagedOptimisticOracleV2.sol` this list
     * is expected to remain small, so this method is not expected to run out of gas.
     * Order of addresses is arbitrary and not guaranteed to be stable across calls.
     * @return activeWhitelist the list of addresses on the whitelist.
     */
    function getWhitelist() external view override nonReentrantView returns (address[] memory activeWhitelist) {
        return whitelistedSet.values();
    }

    /**
     * @notice Checks if the whitelist is enabled.
     * @dev For this implementation, the whitelist is always considered enabled.
     * @return enabled Always returns true.
     */
    function isWhitelistEnabled() external pure override returns (bool enabled) {
        return true;
    }

    /**
     * @notice Returns true if this contract implements the interface defined by interfaceId.
     * @param interfaceId The interface identifier, as specified in ERC-165.
     * @return True if the contract implements the interface defined by interfaceId.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(AddressWhitelistInterface).interfaceId || super.supportsInterface(interfaceId);
    }
}
