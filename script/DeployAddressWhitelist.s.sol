// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AddressWhitelist} from "../src/common/implementation/AddressWhitelist.sol";

/**
 * @title Deployment script for AddressWhitelist
 * @notice Deploys the AddressWhitelist contract with configurable ownership
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the deployer wallet
 * - WHITELIST_OWNER: Optional. The address to set as owner. If not set, uses deployer address.
 *                    If set to 0x0000000000000000000000000000000000000000, burns ownership.
 */
contract DeployAddressWhitelist is Script {
    function run() external {
        // Load environment variables from .env file (if it exists)
        // This will automatically load variables from .env file in the project root

        // Get required environment variables
        string memory mnemonic = vm.envString("MNEMONIC");

        // Derive the 0 index address from mnemonic
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Check if WHITELIST_OWNER is set, default to deployer if not set
        address whitelistOwner = vm.envOr("WHITELIST_OWNER", deployer);

        // Start broadcasting transactions with the derived private key
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the contract with deployer as owner (always safe)
        AddressWhitelist whitelist = new AddressWhitelist();

        console.log("AddressWhitelist deployed at:", address(whitelist));

        // Handle ownership logic
        if (whitelistOwner == address(0)) {
            // If WHITELIST_OWNER is set to 0 address, burn ownership
            console.log("Burning ownership to zero address...");
            whitelist.renounceOwnership();
            console.log("Ownership burned to zero address");
        } else if (whitelistOwner != deployer) {
            // If WHITELIST_OWNER is set to a different address, transfer ownership
            console.log("Transferring ownership to:", whitelistOwner);
            whitelist.transferOwnership(whitelistOwner);
            console.log("Ownership transferred to:", whitelistOwner);
        } else {
            // If WHITELIST_OWNER is not set or same as deployer, keep deployer as owner
            console.log("Keeping deployer as owner:", deployer);
        }

        vm.stopBroadcast();

        // Output deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("Contract:", address(whitelist));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Final Owner:", whitelist.owner());
    }
}
