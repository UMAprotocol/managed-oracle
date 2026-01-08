// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {stdJson} from "forge-std/StdJson.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MultiCaller} from "../src/common/implementation/MultiCaller.sol";
import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {UpgradeManagedOptimisticOracleV2Base} from "./UpgradeManagedOptimisticOracleV2.s.sol";

/**
 * @title ManagedOptimisticOracleV2 upgrade script (runs initializeV2 + optional role migration)
 * @notice Upgrades the proxy, runs `initializeV2`, and optionally updates CONFIG_ADMIN_ROLE and RESOLVER_ROLE
 * membership atomically.
 * @dev
 * Uses `multicall(bytes[])` (via MultiCaller) so that initialization and role changes occur in a single
 * `upgradeToAndCall` transaction.
 *
 * Environment variables:
 * - MINIMUM_DISPUTE_WINDOW: Required. uint256 passed to initializeV2.
 * - RESOLVER_GRANTS:        Optional. JSON array of addresses to grant RESOLVER_ROLE to.
 * - CONFIG_ADMIN_GRANTS:    Optional. JSON array of addresses to grant CONFIG_ADMIN_ROLE to.
 * - CONFIG_ADMIN_REVOKES:   Optional. JSON array of addresses to revoke CONFIG_ADMIN_ROLE from.
 */

contract UpgradeManagedOptimisticOracleV2_InitV2 is UpgradeManagedOptimisticOracleV2Base {
    function run() external {
        uint256 minimumDisputeWindow = vm.envUint("MINIMUM_DISPUTE_WINDOW");
        address[] memory resolverGrants = _envAddressArray("RESOLVER_GRANTS");
        address[] memory configAdminGrants = _envAddressArray("CONFIG_ADMIN_GRANTS");
        address[] memory configAdminRevokes = _envAddressArray("CONFIG_ADMIN_REVOKES");

        ManagedOptimisticOracleV2 managedOptimisticOracleV2 = ManagedOptimisticOracleV2(vm.envAddress("PROXY_ADDRESS"));
        address upgradeAdmin = managedOptimisticOracleV2.owner();
        bytes32 configAdminRole = managedOptimisticOracleV2.CONFIG_ADMIN_ROLE();

        bool tempGrantConfigAdminRole =
            resolverGrants.length > 0 && !managedOptimisticOracleV2.hasRole(configAdminRole, upgradeAdmin);

        bytes[] memory calls = new bytes[](
            1 + resolverGrants.length + (tempGrantConfigAdminRole ? 2 : 0) + configAdminGrants.length
                + configAdminRevokes.length
        );
        uint256 callIdx = 0;

        calls[callIdx++] = abi.encodeCall(ManagedOptimisticOracleV2.initializeV2, (minimumDisputeWindow));

        if (tempGrantConfigAdminRole) {
            calls[callIdx++] = abi.encodeCall(IAccessControl.grantRole, (configAdminRole, upgradeAdmin));
        }

        for (uint256 i = 0; i < resolverGrants.length; i++) {
            calls[callIdx++] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (resolverGrants[i]));
        }

        if (tempGrantConfigAdminRole) {
            calls[callIdx++] = abi.encodeCall(IAccessControl.revokeRole, (configAdminRole, upgradeAdmin));
        }

        for (uint256 i = 0; i < configAdminGrants.length; i++) {
            calls[callIdx++] = abi.encodeCall(IAccessControl.grantRole, (configAdminRole, configAdminGrants[i]));
        }

        for (uint256 i = 0; i < configAdminRevokes.length; i++) {
            calls[callIdx++] = abi.encodeCall(IAccessControl.revokeRole, (configAdminRole, configAdminRevokes[i]));
        }

        bytes memory callData = abi.encodeCall(MultiCaller.multicall, (calls));

        _runUpgrade(callData);
    }

    function _envAddressArray(string memory key) internal view returns (address[] memory) {
        string memory raw = vm.envOr(key, string(""));
        if (bytes(raw).length == 0) return new address[](0);

        return stdJson.readAddressArray(raw, "$");
    }
}
