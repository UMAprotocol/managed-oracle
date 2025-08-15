// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DisabledAddressWhitelist} from "../src/common/implementation/DisabledAddressWhitelist.sol";

/**
 * @title Deployment script for DisabledAddressWhitelist
 * @notice Deploys the DisabledAddressWhitelist contract with optional configuration
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the deployer wallet
 */
contract DeployDisabledAddressWhitelist is Script {
    function run() external {
        // Load environment variables from .env file (if it exists)
        // This will automatically load variables from .env file in the project root

        // Get required environment variables
        string memory mnemonic = vm.envString("MNEMONIC");

        // Derive the 0 index address from mnemonic
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Start broadcasting transactions with the derived private key
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the contract
        DisabledAddressWhitelist whitelist = new DisabledAddressWhitelist();

        console.log("DisabledAddressWhitelist deployed at:", address(whitelist));

        vm.stopBroadcast();

        // Output deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("Contract:", address(whitelist));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
    }
}
