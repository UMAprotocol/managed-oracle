// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DisableableAddressWhitelist} from "../src/common/implementation/DisableableAddressWhitelist.sol";

/**
 * @title Deployment script for DisableableAddressWhitelist
 * @notice Deploys the DisableableAddressWhitelist contract with optional configuration
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the deployer wallet
 * - IS_ENFORCED: Optional. If set to "true", enables whitelist enforcement
 * - NEW_OWNER: Optional. If set, transfers ownership to this address
 */
contract DeployDisableableAddressWhitelist is Script {
    function run() external {
        // Load environment variables from .env file (if it exists)
        // This will automatically load variables from .env file in the project root

        // Get required environment variables
        string memory mnemonic = vm.envString("MNEMONIC");

        // Derive the 0 index address from mnemonic
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Handle optional environment variables
        bool isEnforced = vm.envOr("IS_ENFORCED", false);
        address newOwner = vm.envOr("NEW_OWNER", address(0));

        // Start broadcasting transactions with the derived private key
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the contract
        DisableableAddressWhitelist whitelist = new DisableableAddressWhitelist();

        console.log("DisableableAddressWhitelist deployed at:", address(whitelist));

        // Set whitelist enforcement if IS_ENFORCED is true
        if (isEnforced) {
            whitelist.setWhitelistEnforcement(true);
            console.log("Whitelist enforcement enabled");
        } else {
            console.log("Whitelist enforcement disabled (default)");
        }

        // Transfer ownership if NEW_OWNER is set
        if (newOwner != address(0)) {
            whitelist.transferOwnership(newOwner);
            console.log("Ownership transferred to:", newOwner);
        }

        vm.stopBroadcast();

        // Output deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("Contract:", address(whitelist));
        console.log("Enforcement enabled:", isEnforced);
        console.log("Owner:", newOwner == address(0) ? deployer : newOwner);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
    }
}
