// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

contract MockOracle {
    mapping(bytes32 => mapping(uint256 => mapping(bytes => int256))) public prices;

    function setPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, int256 price) external {
        prices[identifier][timestamp][ancillaryData] = price;
    }

    function getPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        view
        returns (int256)
    {
        return prices[identifier][timestamp][ancillaryData];
    }

    function hasPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external view returns (bool) {
        return prices[identifier][timestamp][ancillaryData] != 0;
    }

    function requestPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external {
        // Mock implementation - in real scenario this would trigger DVM
    }
}
