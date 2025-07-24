// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {FinderInterface} from "@uma/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

/**
 * @title Mock Finder contract for testing.
 * @notice Implements FinderInterface for testing the ManagedOptimisticOracleV2 contract.
 */
contract MockFinder is FinderInterface {
    mapping(bytes32 => address) private implementationAddresses;

    /**
     * @notice Sets the implementation address for a given interface name.
     * @param interfaceName The name of the interface as bytes32.
     * @param implementationAddress The address of the implementation.
     */
    function setImplementationAddress(bytes32 interfaceName, address implementationAddress) external {
        implementationAddresses[interfaceName] = implementationAddress;
    }

    /**
     * @notice Gets the implementation address for a given interface name.
     * @param interfaceName The name of the interface.
     * @return The address of the implementation.
     */
    function getImplementationAddress(bytes32 interfaceName) external view override returns (address) {
        return implementationAddresses[interfaceName];
    }

    /**
     * @notice Changes the implementation address for a given interface name.
     * @param interfaceName The name of the interface.
     * @param implementationAddress The new address of the implementation.
     */
    function changeImplementationAddress(bytes32 interfaceName, address implementationAddress) external override {
        implementationAddresses[interfaceName] = implementationAddress;
    }
}
