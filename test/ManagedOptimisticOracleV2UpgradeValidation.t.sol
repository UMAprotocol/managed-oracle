// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {Options} from "@openzeppelin/foundry-upgrades/Options.sol";

contract ManagedOptimisticOracleV2UpgradeValidationTest {
    function testProductionStorageLayoutUpgradeIsSafe() public {
        Options memory opts;
        opts.referenceContract = "build-info-prod-current:ManagedOptimisticOracleV2";
        opts.referenceBuildInfoDir = "old-builds/build-info-prod-current";

        Upgrades.validateUpgrade("ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2", opts);
    }
}
