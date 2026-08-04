// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {console} from "forge-std/console.sol";

import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {ManagedOptimisticOracleV2VNetConfig} from "./ManagedOptimisticOracleV2VNetConfig.s.sol";

/**
 * @notice Verifies the fully initialized fresh MOO before the reporter migration.
 * @dev This script is read-only and deliberately retains the legacy reporter-wiring VNet sentinel.
 */
contract VerifyManagedOptimisticOracleV2VNet is ManagedOptimisticOracleV2VNetConfig {
    function run() external view returns (address proxyAddress, address implementationAddress) {
        proxyAddress = vm.envAddress("PROXY_ADDRESS");
        address expectedImplementation = vm.envAddress("EXPECTED_IMPLEMENTATION");
        _assertVNet(EXPECTED_DEPLOYER);

        ManagedOptimisticOracleV2 moo = ManagedOptimisticOracleV2(proxyAddress);
        implementationAddress = _implementationOf(proxyAddress);
        require(implementationAddress == expectedImplementation, "Verification check: wrong implementation");
        _assertFreshV2Configuration(moo);

        console.log("Fresh ManagedOptimisticOracleV2 verification: success");
        console.log("ManagedOptimisticOracleV2 proxy:", proxyAddress);
        console.log("ManagedOptimisticOracleV2 implementation:", implementationAddress);
    }
}
