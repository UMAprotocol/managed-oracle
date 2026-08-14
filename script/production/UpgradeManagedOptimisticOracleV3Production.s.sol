// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {Options} from "@openzeppelin/foundry-upgrades/Options.sol";

import {ManagedOptimisticOracleV3} from "../../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV3.sol";
import {ManagedOptimisticOracleV3ProductionUpgradeChecks} from "./ManagedOptimisticOracleV3ProductionUpgradeChecks.sol";

interface IUUPSProductionUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @notice Validates storage compatibility and deploys the reviewed implementation with a CLI-provided signer.
contract DeployManagedOptimisticOracleV3ProductionImplementation is
    Script,
    ManagedOptimisticOracleV3ProductionUpgradeChecks
{
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address expectedReporter = vm.envOr("EXPECTED_REPORTER", address(0));
        address expectedRequestManager = vm.envOr("EXPECTED_REQUEST_MANAGER", address(0));
        require(deployer != address(0) && deployer != SAFE, "invalid implementation deployer");
        require(
            keccak256(type(ManagedOptimisticOracleV3).creationCode) == TARGET_CREATION_CODEHASH,
            "target creation bytecode drift"
        );

        _assertProductionState(CURRENT_IMPLEMENTATION, false, expectedReporter, expectedRequestManager);
        StateSnapshot memory beforeState = _snapshot(expectedReporter, expectedRequestManager);

        Options memory opts;
        opts.referenceContract = "build-info-prod-current:ManagedOptimisticOracleV2";
        opts.referenceBuildInfoDir = "old-builds/build-info-prod-current";
        Upgrades.validateUpgrade("ManagedOptimisticOracleV3.sol:ManagedOptimisticOracleV3", opts);

        vm.startBroadcast(deployer);
        address targetImplementation = address(new ManagedOptimisticOracleV3());
        vm.stopBroadcast();

        _assertTargetImplementation(targetImplementation);
        _assertProductionState(CURRENT_IMPLEMENTATION, false, expectedReporter, expectedRequestManager);
        _assertSnapshotUnchanged(beforeState, expectedReporter, expectedRequestManager);

        bytes memory safeData = _safeUpgradeData(targetImplementation);
        console2.log("Implementation deployer:", deployer);
        console2.log("Target implementation:", targetImplementation);
        console2.logBytes32(targetImplementation.codehash);
        console2.log("Safe target:", PROXY);
        console2.log("Safe value: 0");
        console2.log("Safe operation: 0 (Call)");
        console2.logBytes(safeData);
        console2.log("Safe calldata hash:");
        console2.logBytes32(keccak256(safeData));
        console2.log("Pre-upgrade native balance:", beforeState.nativeBalance);
        console2.log("Pre-upgrade USDC.e balance:", beforeState.rewardCurrencyBalance);
    }

    function _safeUpgradeData(address targetImplementation) private pure returns (bytes memory) {
        return abi.encodeCall(IUUPSProductionUpgrade.upgradeToAndCall, (targetImplementation, bytes("")));
    }
}

/// @notice Produces and locally simulates the Safe call. This script never broadcasts the proxy upgrade.
contract PrepareManagedOptimisticOracleV3ProductionSafeUpgrade is
    Script,
    ManagedOptimisticOracleV3ProductionUpgradeChecks
{
    function run() external {
        address targetImplementation = vm.envAddress("TARGET_IMPLEMENTATION");
        address expectedReporter = vm.envOr("EXPECTED_REPORTER", address(0));
        address expectedRequestManager = vm.envOr("EXPECTED_REQUEST_MANAGER", address(0));

        _assertProductionState(CURRENT_IMPLEMENTATION, false, expectedReporter, expectedRequestManager);
        _assertTargetImplementation(targetImplementation);
        StateSnapshot memory beforeState = _snapshot(expectedReporter, expectedRequestManager);

        bytes memory safeData =
            abi.encodeCall(IUUPSProductionUpgrade.upgradeToAndCall, (targetImplementation, bytes("")));
        vm.prank(SAFE);
        (bool success, bytes memory result) = PROXY.call(safeData);
        if (!success) _revertWith(result);

        _assertProductionState(targetImplementation, true, expectedReporter, expectedRequestManager);
        _assertSnapshotUnchanged(beforeState, expectedReporter, expectedRequestManager);
        _assertPostUpgradeGetters();

        console2.log("Safe:", SAFE);
        console2.log("Safe target:", PROXY);
        console2.log("Safe value: 0");
        console2.log("Safe operation: 0 (Call)");
        console2.logBytes(safeData);
        console2.log("Safe calldata hash:");
        console2.logBytes32(keccak256(safeData));
        console2.log("Target implementation:", targetImplementation);
        console2.logBytes32(targetImplementation.codehash);
        console2.log("Expected post-upgrade native balance:", beforeState.nativeBalance);
        console2.log("Expected post-upgrade USDC.e balance:", beforeState.rewardCurrencyBalance);
    }

    function _revertWith(bytes memory result) private pure {
        assembly ("memory-safe") {
            revert(add(result, 0x20), mload(result))
        }
    }
}

/// @notice Re-runs all production invariants after the Safe transaction has executed.
contract VerifyManagedOptimisticOracleV3ProductionUpgrade is
    Script,
    ManagedOptimisticOracleV3ProductionUpgradeChecks
{
    function run() external view {
        address targetImplementation = vm.envAddress("TARGET_IMPLEMENTATION");
        address expectedReporter = vm.envOr("EXPECTED_REPORTER", address(0));
        address expectedRequestManager = vm.envOr("EXPECTED_REQUEST_MANAGER", address(0));
        uint256 expectedNativeBalance = vm.envUint("PRE_UPGRADE_NATIVE_BALANCE");
        uint256 expectedRewardCurrencyBalance = vm.envUint("PRE_UPGRADE_USDC_BALANCE");

        _assertProductionState(targetImplementation, true, expectedReporter, expectedRequestManager);
        _assertExpectedBalances(expectedNativeBalance, expectedRewardCurrencyBalance);
        _assertPostUpgradeGetters();

        console2.log("ManagedOO proxy:", PROXY);
        console2.log("Implementation:", targetImplementation);
        console2.log("Post-upgrade checks: PASS");
    }
}
