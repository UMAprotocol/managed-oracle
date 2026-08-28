// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {ManagedOptimisticOracleV2ProductionUpgradeChecks} from
    "../script/production/ManagedOptimisticOracleV2ProductionUpgradeChecks.sol";

interface IUUPSProductionUpgradeTest {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract ManagedOptimisticOracleV2ProductionUpgradeForkTest is
    Test,
    ManagedOptimisticOracleV2ProductionUpgradeChecks
{
    uint256 private constant FORK_BLOCK = 91_483_637;
    uint256 private constant TARGET_SELF_IMMUTABLE_OFFSET_1 = 5_158;
    uint256 private constant TARGET_SELF_IMMUTABLE_OFFSET_2 = 5_454;

    function setUp() public {
        vm.createSelectFork(vm.envString("NODE_URL_137"), FORK_BLOCK);
    }

    function testSafeUpgradePreservesProductionState() public {
        _assertProductionState(CURRENT_IMPLEMENTATION, false, address(0), address(0));
        StateSnapshot memory beforeState = _snapshot(address(0), address(0));
        assertEq(
            keccak256(type(ManagedOptimisticOracleV2).creationCode),
            TARGET_CREATION_CODEHASH,
            "target creation bytecode drift"
        );

        address targetImplementation = address(new ManagedOptimisticOracleV2());
        _assertTargetImplementation(targetImplementation);

        bytes memory safeData =
            abi.encodeCall(IUUPSProductionUpgradeTest.upgradeToAndCall, (targetImplementation, bytes("")));
        vm.prank(SAFE);
        (bool success, bytes memory result) = PROXY.call(safeData);
        if (!success) _revertWith(result);

        _assertProductionState(targetImplementation, true, address(0), address(0));
        _assertSnapshotUnchanged(beforeState, address(0), address(0));
        _assertPostUpgradeGetters();
    }

    function testRejectsTargetWithModifiedUUPSSelfImmutable() public {
        address targetImplementation = address(new ManagedOptimisticOracleV2());
        bytes memory runtimeCode = targetImplementation.code;
        bytes32 wrongSelf = bytes32(uint256(uint160(address(0xBEEF))));

        _overwriteWord(runtimeCode, TARGET_SELF_IMMUTABLE_OFFSET_1, wrongSelf);
        vm.etch(targetImplementation, runtimeCode);
        vm.expectRevert(bytes("target self immutable drift"));
        this.assertTargetImplementation(targetImplementation);

        targetImplementation = address(new ManagedOptimisticOracleV2());
        runtimeCode = targetImplementation.code;
        _overwriteWord(runtimeCode, TARGET_SELF_IMMUTABLE_OFFSET_2, wrongSelf);
        vm.etch(targetImplementation, runtimeCode);
        vm.expectRevert(bytes("target self immutable drift"));
        this.assertTargetImplementation(targetImplementation);
    }

    function assertTargetImplementation(address implementation) external view {
        _assertTargetImplementation(implementation);
    }

    function _overwriteWord(bytes memory runtimeCode, uint256 offset, bytes32 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(runtimeCode, 0x20), offset), value)
        }
    }

    function _revertWith(bytes memory result) private pure {
        assembly ("memory-safe") {
            revert(add(result, 0x20), mload(result))
        }
    }
}
