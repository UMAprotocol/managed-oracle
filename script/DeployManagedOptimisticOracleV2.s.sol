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
 * - MINIMUM_LIVENESS: Optional. Minimum liveness period in seconds (defaults to 3600 if not provided)
 * - CUSTOM_CURRENCY: Optional. Address of a custom currency bond range to initialize
 * - MINIMUM_BOND_AMOUNT: Optional. Minimum bond amount for the custom currency
 * - MAXIMUM_BOND_AMOUNT: Optional. Maximum bond amount for the custom currency
 */
contract DeployManagedOptimisticOracleV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = _getDeployerPrivateKey();
        address deployer = vm.addr(deployerPrivateKey);

        // Get Finder address with network-specific defaults
        address finderAddress = vm.envOr("FINDER_ADDRESS", address(0));
        if (finderAddress == address(0)) {
            finderAddress = _getDefaultFinderAddress();
        }

        address defaultProposerWhitelist = vm.envAddress("DEFAULT_PROPOSER_WHITELIST");
        address requesterWhitelist = vm.envAddress("REQUESTER_WHITELIST");

        uint256 defaultLiveness = vm.envOr("DEFAULT_LIVENESS", uint256(7200)); // Default to 2 hours (7200 seconds)
        uint256 minimumLiveness = vm.envOr("MINIMUM_LIVENESS", uint256(3600)); // Default to 1 hour (3600 seconds)

        address customCurrency = vm.envOr("CUSTOM_CURRENCY", address(0));
        uint128 minimumBondAmount = uint128(vm.envOr("MINIMUM_BOND_AMOUNT", uint256(0)));
        uint128 maximumBondAmount = uint128(vm.envOr("MAXIMUM_BOND_AMOUNT", uint256(0)));

        ManagedOptimisticOracleV2.CurrencyBondRange[] memory currencyBondRanges;
        if (customCurrency != address(0)) {
            // If custom currency is provided, create a single bond range.
            currencyBondRanges = new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
            currencyBondRanges[0] = ManagedOptimisticOracleV2.CurrencyBondRange({
                currency: IERC20(customCurrency),
                range: ManagedOptimisticOracleV2.BondRange({minimumBond: minimumBondAmount, maximumBond: maximumBondAmount})
            });
        } else {
            // If no custom currency is provided, use default bond ranges based on the network.
            currencyBondRanges = _getDefaultCurrencyBondRanges();
        }

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

        // Deploy implementation and proxy using OZ Upgrades
        ManagedOptimisticOracleV2 proxy = ManagedOptimisticOracleV2(
            Upgrades.deployUUPSProxy(
                "ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2",
                abi.encodeWithSelector(
                    ManagedOptimisticOracleV2.initialize.selector,
                    defaultLiveness,
                    finderAddress,
                    defaultProposerWhitelist,
                    requesterWhitelist,
                    currencyBondRanges,
                    minimumLiveness,
                    configAdmin,
                    upgradeAdmin
                )
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

        console.log("\nBond ranges:");
        for (uint256 i = 0; i < currencyBondRanges.length; i++) {
            console.log("  Currency:", address(currencyBondRanges[i].currency));
            console.log("  Minimum Bond Amount:", currencyBondRanges[i].range.minimumBond);
            console.log("  Maximum Bond Amount:", currencyBondRanges[i].range.maximumBond);
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

    function _getDefaultCurrencyBondRanges()
        internal
        view
        returns (ManagedOptimisticOracleV2.CurrencyBondRange[] memory)
    {
        uint256 chainId = block.chainid;

        if (chainId == 137) {
            // Polygon default bond range
            ManagedOptimisticOracleV2.CurrencyBondRange[] memory currencyBondRanges =
                new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
            currencyBondRanges[0] = ManagedOptimisticOracleV2.CurrencyBondRange({
                currency: IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174), // USDC.e on Polygon
                range: ManagedOptimisticOracleV2.BondRange({minimumBond: 100 * 10 ** 6, maximumBond: 100_000 * 10 ** 6}) // 100 to 100,000 USDC.e
            });
            return currencyBondRanges;
        }

        // Returns empty array for other networks
        return new ManagedOptimisticOracleV2.CurrencyBondRange[](0);
    }
}
