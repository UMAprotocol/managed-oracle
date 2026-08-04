// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {OOReporter} from "../src/OOReporter.sol";
import {IOOReporter} from "../src/interfaces/IOOReporter.sol";

/// @title Deployment script for OOReporter
/// @notice Deploys and initializes an OOReporter implementation and ERC1967 proxy.
/// @dev Environment variables:
///      - MNEMONIC: Required. Mnemonic for the deployer wallet (derivation index 0).
///      - INITIAL_OWNER: Optional. Defaults to the deployer.
///      - OPTIMISTIC_ORACLE: Optional on Polygon. Defaults to the deployed Managed Optimistic Oracle V2.
///      - REWARD_CURRENCY: Optional on Polygon. Defaults to bridged USDC.e.
///      - INITIAL_ORACLE_INITIALIZER: Optional. Defaults to the zero address (no initial allowlist entry).
///      - INITIAL_REQUESTER: Optional. Defaults to the zero address (no initial allowlist entry).
///      - INITIAL_DEFAULT_REREQUEST_BUDGET: Optional. Defaults to 5.
contract DeployOOReporter is Script {
    address internal constant POLYGON_MANAGED_OPTIMISTIC_ORACLE_V2 = 0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1;
    address internal constant POLYGON_USDC_E = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    function run() external returns (OOReporter reporter) {
        uint256 deployerPrivateKey = _getDeployerPrivateKey();
        address deployer = vm.addr(deployerPrivateKey);

        address initialOwner = vm.envOr("INITIAL_OWNER", deployer);
        address optimisticOracle = vm.envOr("OPTIMISTIC_ORACLE", address(0));
        if (optimisticOracle == address(0)) {
            optimisticOracle = _getDefaultOptimisticOracle();
        }

        address rewardCurrency = vm.envOr("REWARD_CURRENCY", address(0));
        if (rewardCurrency == address(0)) {
            rewardCurrency = _getDefaultRewardCurrency();
        }

        address initialOracleInitializer = vm.envOr("INITIAL_ORACLE_INITIALIZER", address(0));
        address initialRequester = vm.envOr("INITIAL_REQUESTER", address(0));
        uint256 initialDefaultRerequestBudget = vm.envOr("INITIAL_DEFAULT_REREQUEST_BUDGET", uint256(5));

        console.log("Deployer:", deployer);
        console.log("Initial owner:", initialOwner);
        console.log("Optimistic Oracle:", optimisticOracle);
        console.log("Reward currency:", rewardCurrency);
        console.log("Initial oracle initializer:", initialOracleInitializer);
        console.log("Initial requester:", initialRequester);
        console.log("Initial default re-request budget:", initialDefaultRerequestBudget);

        bytes memory initData = abi.encodeCall(
            IOOReporter.initialize,
            (
                initialOwner,
                optimisticOracle,
                rewardCurrency,
                initialOracleInitializer,
                initialRequester,
                initialDefaultRerequestBudget
            )
        );

        vm.startBroadcast(deployerPrivateKey);

        address implementation = _deployImplementation();
        reporter = OOReporter(address(new ERC1967Proxy(implementation, initData)));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Proxy address:", address(reporter));
        console.log("Implementation address:", implementation);
        console.log("Chain ID:", block.chainid);
        console.log("Owner:", reporter.owner());
        console.log("Optimistic Oracle:", address(reporter.optimisticOracle()));
        console.log("Reward currency:", address(reporter.rewardCurrency()));
        console.log("Initial default re-request budget:", reporter.defaultRerequestBudget());
        console.log("Automatic re-requests enabled:", reporter.automaticRerequestsEnabled());
    }

    function _getDeployerPrivateKey() internal view returns (uint256) {
        return vm.deriveKey(vm.envString("MNEMONIC"), 0);
    }

    function _deployImplementation() internal virtual returns (address) {
        return address(new OOReporter());
    }

    function _getDefaultOptimisticOracle() internal view returns (address) {
        if (block.chainid == 137) return POLYGON_MANAGED_OPTIMISTIC_ORACLE_V2;

        revert("No default Optimistic Oracle for this network. Set OPTIMISTIC_ORACLE explicitly.");
    }

    function _getDefaultRewardCurrency() internal view returns (address) {
        if (block.chainid == 137) return POLYGON_USDC_E;

        revert("No default reward currency for this network. Set REWARD_CURRENCY explicitly.");
    }
}
