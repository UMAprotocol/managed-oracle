// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AddressWhitelist} from "../src/common/implementation/AddressWhitelist.sol";

/**
 * @title Redeployment script for AddressWhitelist
 * @notice Deploys a new AddressWhitelist contract duplicating the configuration from a previous deployment
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the deployer wallet
 * - PREVIOUS_ADDRESS_WHITELIST: Required. The address of the previous AddressWhitelist contract to duplicate
 */
contract RedeployAddressWhitelist is Script {
    function run() external {
        // Load environment variables from .env file (if it exists)
        // This will automatically load variables from .env file in the project root

        // Get required environment variables
        string memory mnemonic = vm.envString("MNEMONIC");
        address previousWhitelist = vm.envAddress("PREVIOUS_ADDRESS_WHITELIST");

        // Derive the 0 index address from mnemonic
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Previous AddressWhitelist:", previousWhitelist);
        console.log("Deployer:", deployer);

        // Get the previous contract instance
        AddressWhitelist previousWhitelistContract = AddressWhitelist(previousWhitelist);

        // Get the previous owner
        address previousOwner = previousWhitelistContract.owner();
        console.log("Previous Owner:", previousOwner);

        // Get all whitelisted addresses from the previous contract
        address[] memory whitelistedAddresses = previousWhitelistContract.getWhitelist();
        console.log("Number of whitelisted addresses to copy:", whitelistedAddresses.length);

        // Start broadcasting transactions with the derived private key
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the new contract with deployer as owner (always safe)
        AddressWhitelist newWhitelist = new AddressWhitelist();
        console.log("New AddressWhitelist deployed at:", address(newWhitelist));

        // Copy all whitelisted addresses from the previous contract
        if (whitelistedAddresses.length > 0) {
            console.log("Copying whitelisted addresses...");
            for (uint256 i = 0; i < whitelistedAddresses.length; i++) {
                address addr = whitelistedAddresses[i];
                newWhitelist.addToWhitelist(addr);
                console.log("Added to whitelist:", addr);
            }
            console.log("Finished copying whitelisted addresses");
        }

        // Handle ownership logic
        if (previousOwner == address(0)) {
            // If the previous contract had no owner (burned), burn ownership on the new contract
            console.log("Previous contract had no owner, burning ownership on new contract...");
            newWhitelist.renounceOwnership();
            console.log("Ownership burned to zero address");
        } else if (previousOwner != deployer) {
            // If the previous owner is different from deployer, transfer ownership to the same address
            console.log("Transferring ownership to previous owner:", previousOwner);
            newWhitelist.transferOwnership(previousOwner);
            console.log("Ownership transferred to:", previousOwner);
        } else {
            // If the previous owner is the same as deployer, keep deployer as owner
            console.log("Keeping deployer as owner:", deployer);
        }

        vm.stopBroadcast();

        // Output deployment summary
        console.log("\n=== Redeployment Summary ===");
        console.log("New Contract:", address(newWhitelist));
        console.log("Previous Contract:", previousWhitelist);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Previous Owner:", previousOwner);
        console.log("Final Owner:", newWhitelist.owner());
        console.log("Whitelisted Addresses Copied:", whitelistedAddresses.length);
        
        // Verify the whitelist was copied correctly
        address[] memory newWhitelistAddresses = newWhitelist.getWhitelist();
        console.log("New Contract Whitelist Count:", newWhitelistAddresses.length);
        
        if (whitelistedAddresses.length == newWhitelistAddresses.length) {
            console.log("[SUCCESS] Whitelist copy verification: SUCCESS");
        } else {
            console.log("[FAILED] Whitelist copy verification: FAILED");
            console.log("Expected:", whitelistedAddresses.length);
            console.log("Actual:", newWhitelistAddresses.length);
        }
    }
}
