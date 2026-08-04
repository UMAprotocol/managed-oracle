// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {OOReporter} from "../src/OOReporter.sol";
import {PolymarketOOReporter} from "../src/PolymarketOOReporter.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title Upgrade script for OOReporter
/// @notice Upgrades an existing OOReporter UUPS proxy to the latest PolymarketOOReporter implementation.
/// @dev The upgrade does not execute a reinitializer because PolymarketOOReporter adds no storage.
///      When the deployer owns the proxy, the script executes the upgrade directly. Otherwise it deploys and
///      validates the implementation, simulates the owner call, and prints calldata for the owner or multisig.
///      Environment variables:
///      - MNEMONIC: Required. Mnemonic for the implementation deployer (derivation index 0).
///      - PROXY_ADDRESS: Required. Existing OOReporter proxy to upgrade.
///      - EXPECTED_CHAIN_ID: Required. Chain ID guard for the intended deployment.
///      - EXPECTED_CURRENT_IMPLEMENTATION: Required. Current implementation guard for the proxy.
contract UpgradeOOReporter is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    error ChainIdMismatch(uint256 expected, uint256 actual);
    error AddressHasNoCode(address target);
    error CurrentImplementationMismatch(address expected, address actual);
    error OwnerCannotBeZero();
    error InvalidProxiableUUID(bytes32 actual);
    error PostUpgradeImplementationMismatch(address expected, address actual);
    error PostUpgradeStateMismatch();

    struct ReporterState {
        address owner;
        address optimisticOracle;
        address rewardCurrency;
        uint256 defaultRerequestBudget;
        bool automaticRerequestsEnabled;
    }

    function run() external returns (address newImplementation) {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) revert ChainIdMismatch(expectedChainId, block.chainid);

        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        address expectedCurrentImplementation = vm.envAddress("EXPECTED_CURRENT_IMPLEMENTATION");
        _requireCode(proxyAddress);
        _requireCode(expectedCurrentImplementation);

        address currentImplementation = _getImplementation(proxyAddress);
        if (currentImplementation != expectedCurrentImplementation) {
            revert CurrentImplementationMismatch(expectedCurrentImplementation, currentImplementation);
        }

        OOReporter reporter = OOReporter(proxyAddress);
        ReporterState memory currentState = _getReporterState(reporter);
        if (currentState.owner == address(0)) revert OwnerCannotBeZero();

        uint256 deployerPrivateKey = _getDeployerPrivateKey();
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Proxy address:", proxyAddress);
        console.log("Current owner:", currentState.owner);
        console.log("Current implementation:", currentImplementation);
        console.log("Expected chain ID:", expectedChainId);

        vm.startBroadcast(deployerPrivateKey);
        PolymarketOOReporter implementation = new PolymarketOOReporter();
        vm.stopBroadcast();

        newImplementation = address(implementation);
        _requireCode(newImplementation);
        bytes32 proxiableUUID = implementation.proxiableUUID();
        if (proxiableUUID != IMPLEMENTATION_SLOT) revert InvalidProxiableUUID(proxiableUUID);

        bytes memory upgradeData = abi.encodeCall(IUUPSUpgradeable.upgradeToAndCall, (newImplementation, bytes("")));

        bool executesDirectly = deployer == currentState.owner;
        if (executesDirectly) {
            console.log("\n=== Direct owner upgrade ===");
            vm.startBroadcast(deployerPrivateKey);
            _callUpgrade(proxyAddress, upgradeData);
            vm.stopBroadcast();
        } else {
            console.log("\n=== Owner or multisig execution required ===");
            vm.startPrank(currentState.owner);
            _callUpgrade(proxyAddress, upgradeData);
            vm.stopPrank();

            console.log("Upgrade simulation successful.");
            console.log("Transaction target:", proxyAddress);
            console.log("Transaction value: 0");
            console.log("Transaction data:");
            console.logBytes(upgradeData);
        }

        _validateUpgrade(reporter, newImplementation, currentState);

        if (executesDirectly) {
            console.log("\n=== Upgrade Summary ===");
        } else {
            console.log("\n=== Simulated Upgrade Summary ===");
            console.log("The proxy upgrade was not broadcast. The owner must submit the transaction above.");
        }
        console.log("Proxy address:", proxyAddress);
        console.log("New implementation address:", newImplementation);
        console.log("Chain ID:", block.chainid);
        console.log("Owner:", reporter.owner());
        console.log("Optimistic Oracle:", address(reporter.optimisticOracle()));
        console.log("Reward currency:", address(reporter.rewardCurrency()));
        console.log("Default re-request budget:", reporter.defaultRerequestBudget());
        console.log("Automatic re-requests enabled:", reporter.automaticRerequestsEnabled());
    }

    function _getDeployerPrivateKey() private view returns (uint256) {
        return vm.deriveKey(vm.envString("MNEMONIC"), 0);
    }

    function _getImplementation(address proxyAddress) private view returns (address) {
        return address(uint160(uint256(vm.load(proxyAddress, IMPLEMENTATION_SLOT))));
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert AddressHasNoCode(target);
    }

    function _callUpgrade(address proxyAddress, bytes memory upgradeData) private {
        (bool success, bytes memory returnData) = proxyAddress.call(upgradeData);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _getReporterState(OOReporter reporter) private view returns (ReporterState memory state) {
        state.owner = reporter.owner();
        state.optimisticOracle = address(reporter.optimisticOracle());
        state.rewardCurrency = address(reporter.rewardCurrency());
        state.defaultRerequestBudget = reporter.defaultRerequestBudget();
        state.automaticRerequestsEnabled = reporter.automaticRerequestsEnabled();
    }

    function _validateUpgrade(OOReporter reporter, address expectedImplementation, ReporterState memory expectedState)
        private
        view
    {
        address actualImplementation = _getImplementation(address(reporter));
        if (actualImplementation != expectedImplementation) {
            revert PostUpgradeImplementationMismatch(expectedImplementation, actualImplementation);
        }

        ReporterState memory actualState = _getReporterState(reporter);
        if (
            actualState.owner != expectedState.owner || actualState.optimisticOracle != expectedState.optimisticOracle
                || actualState.rewardCurrency != expectedState.rewardCurrency
                || actualState.defaultRerequestBudget != expectedState.defaultRerequestBudget
                || actualState.automaticRerequestsEnabled != expectedState.automaticRerequestsEnabled
        ) revert PostUpgradeStateMismatch();
    }
}
