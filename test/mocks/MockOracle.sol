// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OracleAncillaryInterface} from
    "@uma/contracts/data-verification-mechanism/interfaces/OracleAncillaryInterface.sol";

/**
 * @title Mock Oracle contract for testing.
 * @notice Implements OracleAncillaryInterface for testing the ManagedOptimisticOracleV2 contract.
 */
contract MockOracle is OracleAncillaryInterface {
    mapping(bytes32 => mapping(uint256 => mapping(bytes => bool))) private hasPriceMap;
    mapping(bytes32 => mapping(uint256 => mapping(bytes => int256))) private priceMap;

    /**
     * @notice Sets whether a price exists for a given identifier, timestamp, and ancillary data.
     * @param identifier The price identifier.
     * @param timestamp The timestamp.
     * @param ancillaryData The ancillary data.
     * @param priceExists Whether the price exists.
     */
    function setHasPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, bool priceExists)
        external
    {
        hasPriceMap[identifier][timestamp][ancillaryData] = priceExists;
    }

    /**
     * @notice Sets a price for a given identifier, timestamp, and ancillary data.
     * @param identifier The price identifier.
     * @param timestamp The timestamp.
     * @param ancillaryData The ancillary data.
     * @param price The price value.
     */
    function setPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, int256 price) external {
        priceMap[identifier][timestamp][ancillaryData] = price;
        hasPriceMap[identifier][timestamp][ancillaryData] = true;
    }

    /**
     * @notice Requests a price for a given identifier, timestamp, and ancillary data.
     * @param identifier The price identifier.
     * @param time The timestamp.
     * @param ancillaryData The ancillary data.
     */
    function requestPrice(bytes32 identifier, uint256 time, bytes memory ancillaryData) public override {
        // Mock implementation - just accept the request
    }

    /**
     * @notice Checks if a price exists for a given identifier, timestamp, and ancillary data.
     * @param identifier The price identifier.
     * @param time The timestamp.
     * @param ancillaryData The ancillary data.
     * @return True if the price exists, false otherwise.
     */
    function hasPrice(bytes32 identifier, uint256 time, bytes memory ancillaryData)
        public
        view
        override
        returns (bool)
    {
        return hasPriceMap[identifier][time][ancillaryData];
    }

    /**
     * @notice Gets the price for a given identifier, timestamp, and ancillary data.
     * @param identifier The price identifier.
     * @param time The timestamp.
     * @param ancillaryData The ancillary data.
     * @return The price value.
     */
    function getPrice(bytes32 identifier, uint256 time, bytes memory ancillaryData)
        public
        view
        override
        returns (int256)
    {
        require(hasPriceMap[identifier][time][ancillaryData], "Price not available");
        return priceMap[identifier][time][ancillaryData];
    }
}
