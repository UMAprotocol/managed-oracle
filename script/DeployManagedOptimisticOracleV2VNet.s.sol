// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";

import {MultiCaller} from "../src/common/implementation/MultiCaller.sol";
import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {ManagedOptimisticOracleV2VNetConfig} from "./ManagedOptimisticOracleV2VNetConfig.s.sol";

/**
 * @notice Deploys a fresh ManagedOptimisticOracleV2 proxy on the Polymarket Polygon Tenderly VNet.
 * @dev Uses an address-only broadcast. The signer must be supplied to Forge externally.
 */
contract DeployManagedOptimisticOracleV2VNet is ManagedOptimisticOracleV2VNetConfig {
    function run() external returns (address proxyAddress, address implementationAddress) {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        _assertVNet(deployer);

        ManagedOptimisticOracleV2.CurrencyBondRange[] memory currencyBondRanges =
            new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
        currencyBondRanges[0] = ManagedOptimisticOracleV2.CurrencyBondRange({
            currency: IERC20(USDC_E),
            range: ManagedOptimisticOracleV2.BondRange({minimumBond: MINIMUM_USDC_E_BOND, maximumBond: MAXIMUM_USDC_E_BOND})
        });

        vm.startBroadcast(deployer);
        ManagedOptimisticOracleV2 proxy = ManagedOptimisticOracleV2(
            Upgrades.deployUUPSProxy(
                "ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2",
                abi.encodeCall(
                    ManagedOptimisticOracleV2.initialize,
                    (
                        DEFAULT_LIVENESS,
                        FINDER,
                        DEFAULT_PROPOSER_WHITELIST,
                        REQUESTER_WHITELIST,
                        currencyBondRanges,
                        CONFIG_ADMIN,
                        EXPECTED_DEPLOYER
                    )
                )
            )
        );
        vm.stopBroadcast();

        _assertFreshV1Configuration(proxy);

        bytes memory v2InitializationData = buildV2InitializationCalldata();
        vm.startBroadcast(deployer);
        (bool success, bytes memory returnData) = address(proxy).call(v2InitializationData);
        vm.stopBroadcast();
        if (!success) _revertWithData(returnData);

        _assertFreshV2Configuration(proxy);
        proxyAddress = address(proxy);
        implementationAddress = _implementationOf(proxyAddress);

        console.log("ManagedOptimisticOracleV2 proxy:", proxyAddress);
        console.log("ManagedOptimisticOracleV2 implementation:", implementationAddress);
        console.log("ManagedOptimisticOracleV2 upgrade/default admin:", EXPECTED_DEPLOYER);
    }

    function buildV2InitializationCalldata() public pure returns (bytes memory) {
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(ManagedOptimisticOracleV2.initializeV2, (MINIMUM_DISPUTE_WINDOW, EXPECTED_DEPLOYER));
        calls[1] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (RESOLVER_1));
        calls[2] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (RESOLVER_2));
        calls[3] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (RESOLVER_3));
        calls[4] = abi.encodeCall(IAccessControl.grantRole, (keccak256("RESOLVER_ADMIN_ROLE"), RESOLVER_ADMIN));
        calls[5] = abi.encodeCall(IAccessControl.revokeRole, (keccak256("RESOLVER_ADMIN_ROLE"), EXPECTED_DEPLOYER));
        return abi.encodeCall(MultiCaller.multicall, (calls));
    }

    function _revertWithData(bytes memory returnData) private pure {
        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }
}
