// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";

/**
 * @title Update whitelists script for ManagedOptimisticOracleV2
 * @notice Updates the default proposer and/or requester whitelists using CONFIG_ADMIN_ROLE
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the deployer wallet
 * - PROXY_ADDRESS: Required. Address of the existing ManagedOptimisticOracleV2 proxy contract
 * - NEW_DEFAULT_PROPOSER_WHITELIST: Optional. New address for the default proposer whitelist
 * - NEW_REQUESTER_WHITELIST: Optional. New address for the requester whitelist
 * - CONFIG_ADMIN: Required if deployer doesn't hold CONFIG_ADMIN_ROLE. Address of the config admin for multisig mode
 * Note: At least one of NEW_DEFAULT_PROPOSER_WHITELIST or NEW_REQUESTER_WHITELIST must be provided
 */
contract UpdateManagedOptimisticOracleV2Whitelists is Script {
    function run() external {
        uint256 deployerPrivateKey = _getDeployerPrivateKey();
        address deployerAddress = vm.addr(deployerPrivateKey);

        // Get the proxy address to update
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        // Get the new whitelist addresses (at least one must be provided)
        address newDefaultProposerWhitelist = vm.envOr("NEW_DEFAULT_PROPOSER_WHITELIST", address(0));
        address newRequesterWhitelist = vm.envOr("NEW_REQUESTER_WHITELIST", address(0));

        // Validate that at least one whitelist is being updated
        require(
            newDefaultProposerWhitelist != address(0) || newRequesterWhitelist != address(0),
            "At least one whitelist must be provided"
        );

        // Get the contract instance
        ManagedOptimisticOracleV2 moo = ManagedOptimisticOracleV2(proxyAddress);

        // Check if deployer has CONFIG_ADMIN_ROLE
        bytes32 configAdminRole = moo.CONFIG_ADMIN_ROLE();
        bool hasConfigAdminRole = moo.hasRole(configAdminRole, deployerAddress);

        // Get the config admin address if deployer doesn't have the role
        address configAdminAddress = address(0);
        if (!hasConfigAdminRole) {
            configAdminAddress = vm.envAddress("CONFIG_ADMIN");
            console.log("Config Admin Address:", configAdminAddress);
        }

        // Log initial setup
        console.log("Deployer Address:", deployerAddress);
        console.log("Proxy Address:", proxyAddress);
        console.log("Has CONFIG_ADMIN_ROLE:", hasConfigAdminRole);

        if (newDefaultProposerWhitelist != address(0)) {
            console.log("New Default Proposer Whitelist:", newDefaultProposerWhitelist);
        }
        if (newRequesterWhitelist != address(0)) {
            console.log("New Requester Whitelist:", newRequesterWhitelist);
        }

        // Get current whitelist addresses for comparison
        address currentDefaultProposerWhitelist = address(moo.defaultProposerWhitelist());
        address currentRequesterWhitelist = address(moo.requesterWhitelist());

        console.log("Current Default Proposer Whitelist:", currentDefaultProposerWhitelist);
        console.log("Current Requester Whitelist:", currentRequesterWhitelist);

        // Check if we need to impersonate or can execute directly
        bool shouldImpersonate = !hasConfigAdminRole;

        if (shouldImpersonate) {
            // Multisig mode - simulate updates and generate transaction data
            console.log("\n=== IMPERSONATION MODE ===");
            console.log("MNEMONIC does not correspond to config admin");
            console.log("Simulating whitelist updates and generating transaction data");

            // Simulate the whitelist updates using multicall to verify they would succeed
            console.log("\n=== SIMULATING WHITELIST UPDATES ===");

            // Prepare multicall data for whitelist updates
            bytes[] memory multicallData = _prepareMulticallData(newDefaultProposerWhitelist, newRequesterWhitelist);

            // Generate multicall transaction data
            bytes memory multicallTransactionData = abi.encodeCall(moo.multicall, (multicallData));

            // Simulate multicall execution
            console.log("Simulating multicall execution...");
            vm.prank(configAdminAddress);
            moo.multicall(multicallData);
            console.log("Multicall simulation successful!");

            // Generate transaction data for multisig using multicall
            console.log("\n=== MULTISIG TRANSACTION DATA ===");
            console.log("Target Contract:", proxyAddress);
            console.log("Config Admin:", configAdminAddress);
            console.log("Chain ID:", block.chainid);
            console.log("Transaction Data:", vm.toString(multicallTransactionData));
            console.log("Number of operations:", multicallData.length);

            console.log("\nUse these transaction data in your multisig wallet to execute the whitelist updates.");
            console.log("The config admin address is:", configAdminAddress);
        } else {
            // Direct mode - execute updates directly
            console.log("\n=== DIRECT EXECUTION MODE ===");
            console.log("Deployer has CONFIG_ADMIN_ROLE");
            console.log("Executing whitelist updates directly");

            // Start broadcasting transactions with the derived private key
            vm.startBroadcast(deployerPrivateKey);

            // Prepare and execute multicall for atomic updates
            bytes[] memory multicallData = _prepareMulticallData(newDefaultProposerWhitelist, newRequesterWhitelist);
            moo.multicall(multicallData);

            vm.stopBroadcast();
        }

        // Verify the updates (common for both modes)
        console.log("\n=== VERIFICATION ===");
        _verifyWhitelistUpdates(moo, newDefaultProposerWhitelist, newRequesterWhitelist);

        // Output update summary
        console.log("\n=== Update Summary ===");
        console.log("Proxy Address:", proxyAddress);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployerAddress);
        console.log("CONFIG_ADMIN_ROLE:", hasConfigAdminRole);

        if (newDefaultProposerWhitelist != address(0)) {
            console.log("Default Proposer Whitelist:");
            console.log("  From:", currentDefaultProposerWhitelist);
            console.log("  To:", address(moo.defaultProposerWhitelist()));
        }

        if (newRequesterWhitelist != address(0)) {
            console.log("Requester Whitelist:");
            console.log("  From:", currentRequesterWhitelist);
            console.log("  To:", address(moo.requesterWhitelist()));
        }
    }

    /**
     * @notice Derives the deployer's private key from the mnemonic
     * @return deployerPrivateKey The derived private key for the deployer
     */
    function _getDeployerPrivateKey() internal view returns (uint256) {
        string memory mnemonic = vm.envString("MNEMONIC");
        // Derive the 0 index address from mnemonic
        return vm.deriveKey(mnemonic, 0);
    }

    /**
     * @notice Appends a bytes element to a bytes array
     * @param array The existing bytes array
     * @param element The bytes element to append
     * @return The updated bytes array
     */
    function _appendToBytesArray(bytes[] memory array, bytes memory element) internal pure returns (bytes[] memory) {
        bytes[] memory newArray = new bytes[](array.length + 1);
        for (uint256 i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }
        newArray[array.length] = element;
        return newArray;
    }

    /**
     * @notice Prepares multicall data for whitelist updates
     * @param newDefaultProposerWhitelist New default proposer whitelist address
     * @param newRequesterWhitelist New requester whitelist address
     * @return multicallData Array of encoded function calls for multicall
     */
    function _prepareMulticallData(address newDefaultProposerWhitelist, address newRequesterWhitelist)
        internal
        pure
        returns (bytes[] memory)
    {
        bytes[] memory multicallData = new bytes[](0);

        if (newDefaultProposerWhitelist != address(0)) {
            multicallData = _appendToBytesArray(
                multicallData,
                abi.encodeCall(ManagedOptimisticOracleV2.setDefaultProposerWhitelist, (newDefaultProposerWhitelist))
            );
        }

        if (newRequesterWhitelist != address(0)) {
            multicallData = _appendToBytesArray(
                multicallData, abi.encodeCall(ManagedOptimisticOracleV2.setRequesterWhitelist, (newRequesterWhitelist))
            );
        }

        return multicallData;
    }

    /**
     * @notice Verifies whitelist updates by checking the current state
     * @param moo The ManagedOptimisticOracleV2 contract instance
     * @param expectedDefaultProposerWhitelist Expected default proposer whitelist address
     * @param expectedRequesterWhitelist Expected requester whitelist address
     */
    function _verifyWhitelistUpdates(
        ManagedOptimisticOracleV2 moo,
        address expectedDefaultProposerWhitelist,
        address expectedRequesterWhitelist
    ) internal view {
        address currentDefaultProposerWhitelist = address(moo.defaultProposerWhitelist());
        address currentRequesterWhitelist = address(moo.requesterWhitelist());

        if (expectedDefaultProposerWhitelist != address(0)) {
            bool proposerUpdateSuccess = currentDefaultProposerWhitelist == expectedDefaultProposerWhitelist;
            console.log("Default Proposer Whitelist Update:", proposerUpdateSuccess ? "SUCCESS" : "FAILED");
            if (!proposerUpdateSuccess) {
                console.log("Expected:", expectedDefaultProposerWhitelist);
                console.log("Actual:", currentDefaultProposerWhitelist);
                revert("Default proposer whitelist update verification failed");
            }
        }

        if (expectedRequesterWhitelist != address(0)) {
            bool requesterUpdateSuccess = currentRequesterWhitelist == expectedRequesterWhitelist;
            console.log("Requester Whitelist Update:", requesterUpdateSuccess ? "SUCCESS" : "FAILED");
            if (!requesterUpdateSuccess) {
                console.log("Expected:", expectedRequesterWhitelist);
                console.log("Actual:", currentRequesterWhitelist);
                revert("Requester whitelist update verification failed");
            }
        }
    }
}
