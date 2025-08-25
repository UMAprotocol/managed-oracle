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
 * - DEPLOYER_MULTISIG: Optional. The address of a Safe multisig to use for batching transactions
 * - MULTISEND_ADDRESS: Optional. The address of the MultiSend contract (defaults to MultiSendCallOnly v1.4.1)
 */
contract RedeployAddressWhitelist is Script {
    function run() external {
        // Load environment variables
        string memory mnemonic = vm.envString("MNEMONIC");
        address previousWhitelist = vm.envAddress("PREVIOUS_ADDRESS_WHITELIST");
        address deployerMultisig = vm.envOr("DEPLOYER_MULTISIG", address(0));
        // MultiSend address (defaults to MultiSendCallOnly v1.4.1 if not provided)
        address multisendAddress = vm.envOr("MULTISEND_ADDRESS", 0x9641d764fc13c8B624c04430C7356C1C7C8102e2);

        // Derive deployer address from mnemonic
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Previous AddressWhitelist:", previousWhitelist);
        console.log("Deployer:", deployer);

        // Validate multisig configuration if provided
        if (deployerMultisig != address(0)) {
            console.log("Multisig address provided:", deployerMultisig);
            validateMultisig(deployerMultisig, deployer);
            console.log("MultiSend address:", multisendAddress);
        }

        // Get previous contract configuration
        AddressWhitelist previousWhitelistContract = AddressWhitelist(previousWhitelist);
        address previousOwner = previousWhitelistContract.owner();
        address[] memory whitelistedAddresses = previousWhitelistContract.getWhitelist();

        console.log("Previous Owner:", previousOwner);
        console.log("Number of whitelisted addresses to copy:", whitelistedAddresses.length);

        // Deploy new contract
        vm.startBroadcast(deployerPrivateKey);
        AddressWhitelist newWhitelist = new AddressWhitelist();
        console.log("New AddressWhitelist deployed at:", address(newWhitelist));

        // Determine executor for whitelist operations
        address executor = deployerMultisig != address(0) ? deployerMultisig : deployer;
        console.log("Using executor for whitelist operations:", executor);

        // Handle whitelist copying and ownership
        if (deployerMultisig != address(0)) {
            // Transfer ownership to multisig for batch execution
            console.log("Transferring ownership to multisig for batching...");
            newWhitelist.transferOwnership(deployerMultisig);

            // Execute batch transaction through multisig (includes whitelist additions + ownership)
            console.log("Batching whitelist additions and ownership operations through multisig...");
            batchAddToWhitelistWithOwnership(
                newWhitelist, whitelistedAddresses, deployerMultisig, multisendAddress, deployer, previousOwner
            );
        } else {
            // Use deployer directly for individual transactions
            console.log("Copying whitelisted addresses using deployer...");
            for (uint256 i = 0; i < whitelistedAddresses.length; i++) {
                address addr = whitelistedAddresses[i];
                newWhitelist.addToWhitelist(addr);
                console.log("Added to whitelist:", addr);
            }
            console.log("Finished copying whitelisted addresses");

            // Handle ownership for non-multisig deployments
            if (previousOwner == address(0)) {
                console.log("Previous contract had no owner, burning ownership on new contract...");
                newWhitelist.renounceOwnership();
                console.log("Ownership burned to zero address");
            } else if (previousOwner != executor) {
                console.log("Transferring ownership to previous owner:", previousOwner);
                newWhitelist.transferOwnership(previousOwner);
                console.log("Ownership transferred to:", previousOwner);
            } else {
                console.log("Keeping executor as owner:", executor);
            }
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

        // Verify whitelist content
        address[] memory newWhitelistAddresses = newWhitelist.getWhitelist();
        console.log("New Contract Whitelist Count:", newWhitelistAddresses.length);

        bool countMatches = whitelistedAddresses.length == newWhitelistAddresses.length;
        bool allAddressesPresent = true;

        if (countMatches) {
            for (uint256 i = 0; i < whitelistedAddresses.length; i++) {
                bool isPresent = newWhitelist.isOnWhitelist(whitelistedAddresses[i]);
                if (!isPresent) {
                    console.log("Missing address from new whitelist:", whitelistedAddresses[i]);
                    allAddressesPresent = false;
                }
            }
        }

        if (countMatches && allAddressesPresent) {
            console.log("[SUCCESS] Whitelist copy verification: SUCCESS");
        } else {
            console.log("[FAILED] Whitelist copy verification: FAILED");
            if (!countMatches) {
                console.log("Count mismatch - Expected:", whitelistedAddresses.length);
                console.log("Count mismatch - Actual:", newWhitelistAddresses.length);
            }
            if (!allAddressesPresent) {
                console.log("Some addresses are missing from the new whitelist");
            }
            revert("Whitelist copy verification failed");
        }

        // Verify ownership restoration
        address finalOwner = newWhitelist.owner();
        if (finalOwner == previousOwner) {
            console.log("[SUCCESS] Ownership verification: SUCCESS");
        } else {
            console.log("[FAILED] Ownership verification: FAILED");
            console.log("Expected:", previousOwner);
            console.log("Actual:", finalOwner);
            revert("Ownership verification failed");
        }
    }

    /**
     * @notice Validates multisig configuration: deployer must be a signer and threshold must be 1
     * @param multisig The multisig contract address
     * @param deployer The deployer address to validate as signer
     */
    function validateMultisig(address multisig, address deployer) internal view {
        uint256 threshold = getMultisigThreshold(multisig);
        if (threshold != 1) {
            revert("Multisig threshold must be 1 for single signature");
        }
        console.log("Multisig threshold validated:", threshold);

        bool isSigner = isMultisigSigner(multisig, deployer);
        if (!isSigner) {
            revert("Deployer is not a signer of the multisig");
        }
        console.log("Deployer signer validation: SUCCESS");
    }

    /**
     * @notice Gets the multisig threshold value
     * @param multisig The multisig contract address
     * @return threshold The threshold value
     */
    function getMultisigThreshold(address multisig) internal view returns (uint256 threshold) {
        bytes memory result = callMultisigFunction(multisig, "getThreshold()");
        return abi.decode(result, (uint256));
    }

    /**
     * @notice Checks if an address is a multisig signer
     * @param multisig The multisig contract address
     * @param signer The signer address to check
     * @return isSigner Whether the address is a signer
     */
    function isMultisigSigner(address multisig, address signer) internal view returns (bool isSigner) {
        bytes memory result = callMultisigFunction(multisig, "isOwner(address)", abi.encode(signer));
        return abi.decode(result, (bool));
    }

    /**
     * @notice Helper function to call multisig functions with optional data
     * @param target The target contract address
     * @param signature The function signature
     * @param data The encoded function data (optional)
     * @return result The function result
     */
    function callMultisigFunction(address target, string memory signature, bytes memory data)
        internal
        view
        returns (bytes memory result)
    {
        bytes memory callData = data.length > 0
            ? abi.encodePacked(abi.encodeWithSignature(signature), data)
            : abi.encodeWithSignature(signature);
        (bool success, bytes memory returndata) = target.staticcall(callData);
        if (!success) {
            revert("Multisig function call failed");
        }
        return returndata;
    }

    /**
     * @notice Helper function to call multisig functions without data
     * @param target The target contract address
     * @param signature The function signature
     * @return result The function result
     */
    function callMultisigFunction(address target, string memory signature)
        internal
        view
        returns (bytes memory result)
    {
        return callMultisigFunction(target, signature, "");
    }

    /**
     * @notice Batch add addresses to whitelist and handle ownership through Safe multisig using execTransaction
     * @param whitelist The whitelist contract
     * @param addresses Array of addresses to add
     * @param multisig The Safe multisig contract address
     * @param multisend The MultiSend contract address
     * @param deployer The deployer address (must be a signer)
     * @param previousOwner The previous owner address to restore
     */
    function batchAddToWhitelistWithOwnership(
        AddressWhitelist whitelist,
        address[] memory addresses,
        address multisig,
        address multisend,
        address deployer,
        address previousOwner
    ) internal {
        // Create batch transaction data using MultiSend contract pattern
        // MultiSend contract allows batching multiple calls in a single transaction
        bytes memory batchData = createMultiSendBatchWithOwnership(whitelist, addresses, previousOwner);

        // Construct v=1 signature (approved hash): r=deployer address, s=0, v=1
        bytes memory signature = abi.encodePacked(
            bytes32(uint256(uint160(deployer))), // r = deployer address
            bytes32(0), // s = 0
            uint8(1) // v = 1 (approved hash)
        );

        console.log("Executing batch transaction through Safe multisig via MultiSend...");

        // Execute batch via Safe's execTransaction with delegatecall to MultiSend
        (bool success,) = multisig.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                multisend, // to: MultiSend contract
                0, // value
                batchData, // data: MultiSend batch data
                1, // operation: delegatecall
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                address(0), // gasToken
                address(0), // refundReceiver
                signature // signatures
            )
        );

        if (success) {
            console.log("Batch execution through multisig successful");
        } else {
            revert("Batch execution through multisig failed");
        }
    }

    /**
     * @notice Creates MultiSend batch data for whitelist additions and ownership operations
     * @param whitelist The whitelist contract
     * @param addresses Array of addresses to add
     * @param previousOwner The previous owner address to restore
     * @return batchData The encoded MultiSend batch data
     */
    function createMultiSendBatchWithOwnership(
        AddressWhitelist whitelist,
        address[] memory addresses,
        address previousOwner
    ) internal pure returns (bytes memory batchData) {
        bytes memory operations = new bytes(0);

        // Add all whitelist addresses
        for (uint256 i = 0; i < addresses.length; i++) {
            bytes memory callData = abi.encodeWithSignature("addToWhitelist(address)", addresses[i]);
            operations = appendOperation(operations, 0, address(whitelist), 0, callData);
        }

        // Handle ownership based on previous owner
        if (previousOwner == address(0)) {
            // Burn ownership if previous contract had no owner
            bytes memory renounceOwnershipData = abi.encodeWithSignature("renounceOwnership()");
            operations = appendOperation(operations, 0, address(whitelist), 0, renounceOwnershipData);
        } else {
            // Transfer ownership to previous owner
            bytes memory transferOwnershipData = abi.encodeWithSignature("transferOwnership(address)", previousOwner);
            operations = appendOperation(operations, 0, address(whitelist), 0, transferOwnershipData);
        }

        batchData = abi.encodeWithSignature("multiSend(bytes)", operations);
    }

    /**
     * @notice Appends a MultiSend operation to the operations array
     * @param operations The existing operations array
     * @param operationType The operation type (0 for call, 1 for delegatecall)
     * @param target The target contract address
     * @param value The ETH value to send
     * @param callData The encoded function call data
     * @return The updated operations array
     */
    function appendOperation(
        bytes memory operations,
        uint8 operationType,
        address target,
        uint256 value,
        bytes memory callData
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            operations,
            operationType, // operation: call or delegatecall
            target, // to: target contract
            value, // value: ETH value
            uint256(callData.length), // dataLength
            callData // data
        );
    }
}
