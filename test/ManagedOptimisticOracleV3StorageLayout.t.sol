// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {Options} from "@openzeppelin/foundry-upgrades/Options.sol";

import {ManagedOptimisticOracleV3} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV3.sol";
import {ManagedOptimisticOracleV3ProductionUpgradeChecks} from
    "../script/production/ManagedOptimisticOracleV3ProductionUpgradeChecks.sol";

contract ManagedOptimisticOracleV3StorageLayoutTest is Test, ManagedOptimisticOracleV3ProductionUpgradeChecks {
    function testReviewedTargetBytecode() public {
        assertEq(
            keccak256(type(ManagedOptimisticOracleV3).creationCode),
            TARGET_CREATION_CODEHASH,
            "target creation bytecode drift"
        );

        _assertTargetImplementation(address(new ManagedOptimisticOracleV3()));
    }

    function testStorageLayoutIsCompatibleWithProductionV2() public {
        Options memory opts;
        opts.referenceContract = "build-info-prod-current:ManagedOptimisticOracleV2";
        opts.referenceBuildInfoDir = "old-builds/build-info-prod-current";

        Upgrades.validateUpgrade("ManagedOptimisticOracleV3.sol:ManagedOptimisticOracleV3", opts);
    }
}
