// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {Options} from "@openzeppelin/foundry-upgrades/Options.sol";

import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";

/**
 * @title Upgrade script for ManagedOptimisticOracleV2
 * @notice Upgrades the ManagedOptimisticOracleV2 contract implementation using OZ Upgrades
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the upgrade admin wallet
 * - PROXY_ADDRESS: Required. Address of the existing proxy contract to upgrade
 * - REFERENCE_BUILD_VERSION: Required. Integer version number to derive reference contract and build info dir (e.g., 1 for "build-info-v1:ManagedOptimisticOracleV2" and "old-builds/build-info-v1")
 */
contract UpgradeManagedOptimisticOracleV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = _getDeployerPrivateKey();
        address deployerAddress = vm.addr(deployerPrivateKey);

        // Get the proxy address to upgrade
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        // Fetch the upgrade admin from the contract
        address upgradeAdmin = ManagedOptimisticOracleV2(proxyAddress).owner();

        // Required reference build version for upgrade validation
        uint256 referenceBuildVersion = vm.envUint("REFERENCE_BUILD_VERSION");

        // Build upgrade validation options
        Options memory opts;
        opts.referenceContract =
            string.concat("build-info-v", vm.toString(referenceBuildVersion), ":ManagedOptimisticOracleV2");
        opts.referenceBuildInfoDir = string.concat("old-builds/build-info-v", vm.toString(referenceBuildVersion));

        // Log initial setup
        console.log("Deployer Address:", deployerAddress);
        console.log("Upgrade Admin:", upgradeAdmin);
        console.log("Proxy Address:", proxyAddress);
        console.log("Reference Contract:", opts.referenceContract);
        console.log("Reference Build Info Dir:", opts.referenceBuildInfoDir);

        // Check if we need to impersonate or can execute directly
        bool shouldImpersonate = upgradeAdmin != deployerAddress;

        if (shouldImpersonate) {
            // Multisig mode - deploy implementation and generate transaction data
            console.log("\n=== IMPERSONATION MODE ===");
            console.log("MNEMONIC does not correspond to upgrade admin");
            console.log("Deploying new implementation and generating upgrade transaction data");

            // Deploy the new implementation
            console.log("\n=== DEPLOYING NEW IMPLEMENTATION ===");
            vm.startBroadcast(deployerPrivateKey);
            address newImplementationAddress =
                Upgrades.prepareUpgrade("ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2", opts);
            vm.stopBroadcast();
            console.log("New Implementation Address:", newImplementationAddress);

            // Generate upgrade transaction data
            bytes memory upgradeData =
                abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImplementationAddress, bytes(""));

            // Simulate the upgrade transaction to verify it would succeed
            console.log("\n=== SIMULATING UPGRADE TRANSACTION ===");
            vm.startPrank(upgradeAdmin);
            (bool success, bytes memory result) = proxyAddress.call(upgradeData);
            vm.stopPrank();

            if (success) {
                console.log("Upgrade simulation successful!");
            } else {
                console.log("Upgrade simulation failed!");
                console.log("Error:", vm.toString(result));
                revert("Upgrade simulation failed - check the error above");
            }

            // Log transaction data for multisig
            console.log("\n=== MULTISIG UPGRADE TRANSACTION DATA ===");
            console.log("Target Contract:", proxyAddress);
            console.log("Transaction Data:", vm.toString(upgradeData));
            console.log("Upgrade Admin:", upgradeAdmin);
            console.log("Chain ID:", block.chainid);
            console.log("\nUse this transaction data in your multisig wallet to execute the upgrade.");
            console.log("The new implementation has been deployed at:", newImplementationAddress);
        } else {
            // Direct mode - execute upgrade directly
            console.log("\n=== DIRECT EXECUTION MODE ===");
            console.log("MNEMONIC corresponds to upgrade admin");
            console.log("Executing upgrade directly");

            // Start broadcasting transactions with the derived private key
            vm.startBroadcast(deployerPrivateKey);

            // Upgrade the proxy
            Upgrades.upgradeProxy(
                proxyAddress, "ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2", bytes(""), opts
            );

            vm.stopBroadcast();

            // Output upgrade summary
            console.log("\n=== Upgrade Summary ===");
            console.log("Proxy Address:", proxyAddress);
            console.log("New Implementation Address:", Upgrades.getImplementationAddress(proxyAddress));
            console.log("Chain ID:", block.chainid);
            console.log("Upgrade Admin:", upgradeAdmin);
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
}
