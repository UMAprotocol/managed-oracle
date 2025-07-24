// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IdentifierWhitelistInterface} from "@uma/contracts/data-verification-mechanism/interfaces/IdentifierWhitelistInterface.sol";

/**
 * @title Mock Identifier Whitelist contract for testing.
 * @notice Implements IdentifierWhitelistInterface for testing the ManagedOptimisticOracleV2 contract.
 */
contract MockIdentifierWhitelist is IdentifierWhitelistInterface {
    mapping(bytes32 => bool) private whitelistedIdentifiers;

    /**
     * @notice Adds an identifier to the whitelist.
     * @param identifier The identifier to add.
     */
    function addToWhitelist(bytes32 identifier) external {
        whitelistedIdentifiers[identifier] = true;
    }

    /**
     * @notice Removes an identifier from the whitelist.
     * @param identifier The identifier to remove.
     */
    function removeFromWhitelist(bytes32 identifier) external {
        whitelistedIdentifiers[identifier] = false;
    }

    /**
     * @notice Adds the provided identifier as a supported identifier.
     * @param identifier bytes32 encoding of the string identifier. Eg: BTC/USD.
     */
    function addSupportedIdentifier(bytes32 identifier) external override {
        whitelistedIdentifiers[identifier] = true;
    }

    /**
     * @notice Removes the identifier from the whitelist.
     * @param identifier bytes32 encoding of the string identifier. Eg: BTC/USD.
     */
    function removeSupportedIdentifier(bytes32 identifier) external override {
        whitelistedIdentifiers[identifier] = false;
    }

    /**
     * @notice Checks whether an identifier is on the whitelist.
     * @param identifier bytes32 encoding of the string identifier. Eg: BTC/USD.
     * @return bool if the identifier is supported (or not).
     */
    function isIdentifierSupported(bytes32 identifier) external view override returns (bool) {
        return whitelistedIdentifiers[identifier];
    }

    /**
     * @notice Checks if an identifier is on the whitelist.
     * @param identifier The identifier to check.
     * @return True if the identifier is whitelisted, false otherwise.
     */
    function isOnWhitelist(bytes32 identifier) external view returns (bool) {
        return whitelistedIdentifiers[identifier];
    }

    /**
     * @notice Gets all whitelisted identifiers.
     * @return An array of all whitelisted identifiers.
     */
    function getWhitelist() external view returns (bytes32[] memory) {
        // Mock implementation - return empty array
        return new bytes32[](0);
    }
} 