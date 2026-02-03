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
 * - MINIMUM_DISPUTE_WINDOW: Optional. uint256 _minimumDisputeWindow passed to initializeV2, defaults to 5 minutes.
 * - RESOLVER_ADMIN:         Required. Address to grant RESOLVER_ADMIN_ROLE to in initializeV2.
 * - RESOLVER_GRANTS:        Optional. JSON array of addresses to grant RESOLVER_ROLE to.
 * - CONFIG_ADMIN_GRANTS:    Optional. JSON array of addresses to grant CONFIG_ADMIN_ROLE to.
 * - CONFIG_ADMIN_REVOKES:   Optional. JSON array of addresses to revoke CONFIG_ADMIN_ROLE from.
 */
contract UpgradeManagedOptimisticOracleV2_InitV2 is UpgradeManagedOptimisticOracleV2Base {
    function run() external {
        uint256 minimumDisputeWindow = vm.envOr("MINIMUM_DISPUTE_WINDOW", uint256(5 minutes)); // Default to 5 minutes
        address resolverAdmin = vm.envAddress("RESOLVER_ADMIN");
        address[] memory resolverGrants = _envAddressArray("RESOLVER_GRANTS");
        address[] memory configAdminGrants = _envAddressArray("CONFIG_ADMIN_GRANTS");
        address[] memory configAdminRevokes = _envAddressArray("CONFIG_ADMIN_REVOKES");

        ManagedOptimisticOracleV2 managedOptimisticOracleV2 = ManagedOptimisticOracleV2(vm.envAddress("PROXY_ADDRESS"));
        address upgradeAdmin = managedOptimisticOracleV2.owner();
        bytes32 configAdminRole = managedOptimisticOracleV2.CONFIG_ADMIN_ROLE();
        // RESOLVER_ADMIN_ROLE() doesn't exist on non-upgraded implementation, compute it directly
        bytes32 resolverAdminRole = keccak256("RESOLVER_ADMIN_ROLE");

        // If we need to add resolvers during upgrade and resolverAdmin != upgradeAdmin, we must temporarily
        // make upgradeAdmin the resolverAdmin, add resolvers, then transfer to final resolverAdmin.
        // This is because RESOLVER_ADMIN_ROLE is self-governing after initializeV2.
        bool needTempResolverAdmin = resolverGrants.length > 0 && resolverAdmin != upgradeAdmin;
        address initialResolverAdmin = needTempResolverAdmin ? upgradeAdmin : resolverAdmin;

        bytes[] memory calls = new bytes[](
            1 + resolverGrants.length + (needTempResolverAdmin ? 2 : 0) + configAdminGrants.length
                + configAdminRevokes.length
        );
        uint256 callIdx = 0;

        // Initialize V2 with minimum dispute window and initial resolver admin (may be temporary)
        calls[callIdx++] =
            abi.encodeCall(ManagedOptimisticOracleV2.initializeV2, (minimumDisputeWindow, initialResolverAdmin));

        // Grant resolver role (upgradeAdmin has RESOLVER_ADMIN_ROLE at this point if needTempResolverAdmin)
        for (uint256 i = 0; i < resolverGrants.length; i++) {
            calls[callIdx++] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (resolverGrants[i]));
        }

        // Transfer RESOLVER_ADMIN_ROLE to final resolverAdmin and revoke from upgradeAdmin
        if (needTempResolverAdmin) {
            calls[callIdx++] = abi.encodeCall(IAccessControl.grantRole, (resolverAdminRole, resolverAdmin));
            calls[callIdx++] = abi.encodeCall(IAccessControl.revokeRole, (resolverAdminRole, upgradeAdmin));
        }

        for (uint256 i = 0; i < configAdminGrants.length; i++) {
            calls[callIdx++] = abi.encodeCall(IAccessControl.grantRole, (configAdminRole, configAdminGrants[i]));
        }

        // Revoke config admin roles if needed
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
