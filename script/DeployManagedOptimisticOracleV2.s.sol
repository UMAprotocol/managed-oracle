// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";

import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Deployment script for ManagedOptimisticOracleV2
 * @notice Deploys the ManagedOptimisticOracleV2 contract with proxy using OZ Upgrades
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the deployer wallet
 * - FINDER_ADDRESS: Optional. Address of the Finder contract. If not provided, will use network-specific defaults:
 *   - Sepolia (11155111): 0xf4C48eDAd256326086AEfbd1A53e1896815F8f13
 *   - Amoy (80002): 0x28077B47Cd03326De7838926A63699849DD4fa87
 *   - Ethereum Mainnet (1): 0x40f941E48A552bF496B154Af6bf55725f18D77c3
 *   - Polygon Mainnet (137): 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64
 * - DEFAULT_PROPOSER_WHITELIST: Required. Address of the default proposer whitelist
 * - REQUESTER_WHITELIST: Required. Address of the requester whitelist
 * - CONFIG_ADMIN: Optional. Address of the config admin (defaults to deployer if not provided)
 * - UPGRADE_ADMIN: Optional. Address of the upgrade admin (defaults to deployer if not provided)
 * - DEFAULT_LIVENESS: Optional. Default liveness period in seconds (defaults to 7200 if not provided)
 * - MINIMUM_LIVENESS: Optional. Minimum liveness period in seconds (defaults to 1800 if not provided)
 * - MAXIMUM_BONDS: Optional. Comma-separated list of "currency_address:amount" pairs
 */
contract DeployManagedOptimisticOracleV2 is Script {
    function run() external {
        // Get required environment variables
        string memory mnemonic = vm.envString("MNEMONIC");
        
        // Get Finder address with network-specific defaults
        address finderAddress = vm.envOr("FINDER_ADDRESS", address(0));
        if (finderAddress == address(0)) {
            finderAddress = _getDefaultFinderAddress();
        }
        
        address defaultProposerWhitelist = vm.envAddress("DEFAULT_PROPOSER_WHITELIST");
        address requesterWhitelist = vm.envAddress("REQUESTER_WHITELIST");
        
        uint256 defaultLiveness = vm.envOr("DEFAULT_LIVENESS", uint256(7200)); // Default to 2 hours (7200 seconds)
        uint256 minimumLiveness = vm.envOr("MINIMUM_LIVENESS", uint256(1800)); // Default to 30 minutes (1800 seconds)

        // Parse maximum bonds from environment (optional for testing)
        ManagedOptimisticOracleV2.MaximumBond[] memory maximumBonds;
        try vm.envString("MAXIMUM_BONDS") returns (string memory maximumBondsStr) {
            console.log("MAXIMUM_BONDS from env:", maximumBondsStr);
            maximumBonds = _parseMaximumBonds(maximumBondsStr);
            console.log("Parsed", maximumBonds.length, "bonds");
        } catch {
            // For testing, use empty array if MAXIMUM_BONDS is not set
            console.log("MAXIMUM_BONDS not found in env, using empty array");
            maximumBonds = new ManagedOptimisticOracleV2.MaximumBond[](0);
        }

        // Derive the 0 index address from mnemonic
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Get admin addresses with deployer as default
        address configAdmin = vm.envOr("CONFIG_ADMIN", deployer);
        address upgradeAdmin = vm.envOr("UPGRADE_ADMIN", deployer);

        console.log("Deployer:", deployer);
        console.log("Finder Address:", finderAddress);
        console.log("Default Proposer Whitelist:", defaultProposerWhitelist);
        console.log("Requester Whitelist:", requesterWhitelist);
        console.log("Config Admin:", configAdmin);
        console.log("Upgrade Admin:", upgradeAdmin);
        console.log("Default Liveness:", defaultLiveness);
        console.log("Minimum Liveness:", minimumLiveness);

        // Start broadcasting transactions with the derived private key
        vm.startBroadcast(deployerPrivateKey);

        // Create initialization parameters
        ManagedOptimisticOracleV2.InitializeParams memory params = ManagedOptimisticOracleV2.InitializeParams({
            defaultLiveness: defaultLiveness,
            finderAddress: finderAddress,
            defaultProposerWhitelist: defaultProposerWhitelist,
            requesterWhitelist: requesterWhitelist,
            maximumBonds: maximumBonds,
            minimumLiveness: minimumLiveness,
            configAdmin: configAdmin,
            upgradeAdmin: upgradeAdmin
        });

        // Deploy implementation and proxy using OZ Upgrades
        ManagedOptimisticOracleV2 proxy = ManagedOptimisticOracleV2(
            Upgrades.deployUUPSProxy(
                "ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2",
                abi.encodeWithSelector(ManagedOptimisticOracleV2.initialize.selector, params)
            )
        );

        vm.stopBroadcast();

        // Output deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("Proxy Address:", address(proxy));
        console.log("Implementation Address:", Upgrades.getImplementationAddress(address(proxy)));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Config Admin:", configAdmin);
        console.log("Upgrade Admin:", upgradeAdmin);
        console.log("Default Liveness:", defaultLiveness);
        console.log("Minimum Liveness:", minimumLiveness);
        console.log("Default Proposer Whitelist:", defaultProposerWhitelist);
        console.log("Requester Whitelist:", requesterWhitelist);
        
        console.log("\nMaximum Bonds:");
        for (uint256 i = 0; i < maximumBonds.length; i++) {
            console.log("  Currency:", address(maximumBonds[i].currency));
            console.log("  Amount:", maximumBonds[i].amount);
        }
    }

    /**
     * @notice Parses maximum bonds from a comma-separated string
     * @param bondsStr String in format "currency1:amount1,currency2:amount2,..."
     * @return maximumBonds Array of MaximumBond structs
     */
    function _parseMaximumBonds(string memory bondsStr) internal pure returns (ManagedOptimisticOracleV2.MaximumBond[] memory maximumBonds) {
        // Handle empty string case
        if (bytes(bondsStr).length == 0) {
            return new ManagedOptimisticOracleV2.MaximumBond[](0);
        }
        
        // Split the string and parse each bond
        string[] memory bondStrings = _splitString(bondsStr, ",");
        maximumBonds = new ManagedOptimisticOracleV2.MaximumBond[](bondStrings.length);
        
        for (uint256 i = 0; i < bondStrings.length; i++) {
            string[] memory parts = _splitString(bondStrings[i], ":");
            require(parts.length == 2, "Invalid bond format");
            
            address currency = vm.parseAddress(parts[0]);
            uint256 amount = vm.parseUint(parts[1]);
            
            maximumBonds[i] = ManagedOptimisticOracleV2.MaximumBond({
                currency: IERC20(currency),
                amount: amount
            });
        }
    }

    /**
     * @notice Splits a string by delimiter
     * @param str String to split
     * @param delimiter Delimiter to split by
     * @return parts Array of substrings
     */
    function _splitString(string memory str, string memory delimiter) internal pure returns (string[] memory parts) {
        // Count delimiters to determine array size
        uint256 count = 0;
        for (uint256 i = 0; i < bytes(str).length - bytes(delimiter).length + 1; i++) {
            bool isMatch = true;
            for (uint256 j = 0; j < bytes(delimiter).length; j++) {
                if (bytes(str)[i + j] != bytes(delimiter)[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (isMatch) count++;
        }
        
        parts = new string[](count + 1);
        uint256 partIndex = 0;
        uint256 startIndex = 0;
        
        for (uint256 i = 0; i < bytes(str).length - bytes(delimiter).length + 1; i++) {
            bool isMatch = true;
            for (uint256 j = 0; j < bytes(delimiter).length; j++) {
                if (bytes(str)[i + j] != bytes(delimiter)[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (isMatch) {
                parts[partIndex] = _substring(str, startIndex, i);
                partIndex++;
                startIndex = i + bytes(delimiter).length;
                i += bytes(delimiter).length - 1;
            }
        }
        
        // Add the last part
        parts[partIndex] = _substring(str, startIndex, bytes(str).length);
    }

    /**
     * @notice Extracts a substring from a string
     * @param str Original string
     * @param startIndex Start index
     * @param endIndex End index
     * @return substring The extracted substring
     */
    function _substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory substring) {
        bytes memory strBytes = bytes(str);
        require(endIndex <= strBytes.length, "End index out of bounds");
        require(startIndex <= endIndex, "Start index greater than end index");
        
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        
        substring = string(result);
    }

    /**
     * @notice Returns the default Finder address for the current network
     * @return finderAddress The default Finder address for the current chain
     */
    function _getDefaultFinderAddress() internal view returns (address finderAddress) {
        uint256 chainId = block.chainid;
        
        if (chainId == 11155111) {
            // Sepolia
            return 0xf4C48eDAd256326086AEfbd1A53e1896815F8f13;
        } else if (chainId == 80002) {
            // Amoy
            return 0x28077B47Cd03326De7838926A63699849DD4fa87;
        } else if (chainId == 1) {
            // Ethereum Mainnet
            return 0x40f941E48A552bF496B154Af6bf55725f18D77c3;
        } else if (chainId == 137) {
            // Polygon Mainnet
            return 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        } else {
            revert("No default Finder address for this network. Please set FINDER_ADDRESS explicitly.");
        }
    }
} 