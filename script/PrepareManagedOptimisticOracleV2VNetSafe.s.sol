// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MultiCaller} from "../src/common/implementation/MultiCaller.sol";
import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {ManagedOptimisticOracleV2VNetConfig} from "./ManagedOptimisticOracleV2VNetConfig.s.sol";

/**
 * @notice Builds and locally simulates the Safe transaction that completes a fresh VNet MOO deployment.
 * @dev This script never broadcasts. Submit the printed target/value/data as a Safe CALL transaction.
 */
contract PrepareManagedOptimisticOracleV2VNetSafe is ManagedOptimisticOracleV2VNetConfig {
    function run() external returns (bytes memory safeData) {
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        _assertVNet(EXPECTED_DEPLOYER);

        ManagedOptimisticOracleV2 moo = ManagedOptimisticOracleV2(proxyAddress);
        _assertFreshV1Configuration(moo);
        safeData = buildSafeCalldata();

        console.log("Safe address:", UPGRADE_ADMIN_SAFE);
        console.log("Safe transaction target:", proxyAddress);
        console.log("Safe transaction value: 0");
        console.log("Safe transaction operation: CALL (0)");
        console.log("Safe transaction data:");
        console.logBytes(safeData);

        vm.prank(UPGRADE_ADMIN_SAFE);
        (bool success, bytes memory returnData) = proxyAddress.call(safeData);
        if (!success) _revertWithData(returnData);

        _assertV2Configuration(moo);
        console.log("Safe transaction simulation: success");
    }

    function buildSafeCalldata() public pure returns (bytes memory) {
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(
            ManagedOptimisticOracleV2.initializeV2, (MINIMUM_DISPUTE_WINDOW, UPGRADE_ADMIN_SAFE)
        );
        calls[1] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (RESOLVER_1));
        calls[2] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (RESOLVER_2));
        calls[3] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (RESOLVER_3));
        calls[4] = abi.encodeCall(IAccessControl.grantRole, (keccak256("RESOLVER_ADMIN_ROLE"), RESOLVER_ADMIN));
        calls[5] =
            abi.encodeCall(IAccessControl.revokeRole, (keccak256("RESOLVER_ADMIN_ROLE"), UPGRADE_ADMIN_SAFE));
        return abi.encodeCall(MultiCaller.multicall, (calls));
    }

    function _assertV2Configuration(ManagedOptimisticOracleV2 moo) private view {
        require(
            moo.minimumDisputeWindow() == MINIMUM_DISPUTE_WINDOW, "Post-deployment check: wrong dispute window"
        );
        require(
            moo.hasRole(moo.RESOLVER_ADMIN_ROLE(), RESOLVER_ADMIN),
            "Post-deployment check: resolver admin role missing"
        );
        require(
            !moo.hasRole(moo.RESOLVER_ADMIN_ROLE(), UPGRADE_ADMIN_SAFE),
            "Post-deployment check: temporary resolver admin remains"
        );
        require(moo.hasRole(moo.RESOLVER_ROLE(), RESOLVER_1), "Post-deployment check: resolver 1 missing");
        require(moo.hasRole(moo.RESOLVER_ROLE(), RESOLVER_2), "Post-deployment check: resolver 2 missing");
        require(moo.hasRole(moo.RESOLVER_ROLE(), RESOLVER_3), "Post-deployment check: resolver 3 missing");
    }

    function _revertWithData(bytes memory returnData) private pure {
        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }
}
