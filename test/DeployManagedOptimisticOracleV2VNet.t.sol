// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OracleInterfaces} from "@uma/contracts/data-verification-mechanism/implementation/Constants.sol";

import {DeployManagedOptimisticOracleV2VNet} from "../script/DeployManagedOptimisticOracleV2VNet.s.sol";
import {AddressWhitelist} from "../src/common/implementation/AddressWhitelist.sol";
import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {MockFinder} from "./mocks/MockFinder.sol";

contract DeployManagedOptimisticOracleV2VNetTest is Test {
    address private constant EXPECTED_DEPLOYER = 0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D;
    address private constant CONFIG_ADMIN = 0x3dcE0a29139A851Da1dFCa56Af8e8a6440b4D952;
    address private constant RESOLVER_ADMIN = 0x6ee4D971142afadEa1828445124D6137080B4146;
    address private constant RESOLVER_1 = 0x33965F7D08F61A62B86C1Ab9Be5d82C42F4c3081;
    address private constant RESOLVER_2 = 0x9725e8172A108f2BaD87ef31eA4Ea729e939d869;
    address private constant RESOLVER_3 = 0x561Cbe8b8022A9530D47478420EdfEB66b5c4720;

    function testPostDeploymentCalldataInitializesV2AndTransfersResolverAdministration() public {
        ManagedOptimisticOracleV2 moo = _deployFreshMoo();
        DeployManagedOptimisticOracleV2VNet deployScript = new DeployManagedOptimisticOracleV2VNet();

        assertEq(moo.minimumDisputeWindow(), 0);
        assertEq(moo.owner(), EXPECTED_DEPLOYER);
        assertEq(moo.defaultAdmin(), EXPECTED_DEPLOYER);
        assertTrue(moo.hasRole(moo.DEFAULT_ADMIN_ROLE(), EXPECTED_DEPLOYER));

        bytes memory initializationData = deployScript.buildV2InitializationCalldata();
        vm.prank(EXPECTED_DEPLOYER);
        (bool success,) = address(moo).call(initializationData);
        assertTrue(success);

        assertEq(moo.minimumDisputeWindow(), 5 minutes);
        assertTrue(moo.hasRole(moo.RESOLVER_ADMIN_ROLE(), RESOLVER_ADMIN));
        assertFalse(moo.hasRole(moo.RESOLVER_ADMIN_ROLE(), EXPECTED_DEPLOYER));
        assertEq(moo.getRoleAdmin(moo.RESOLVER_ROLE()), moo.RESOLVER_ADMIN_ROLE());
        assertEq(moo.getRoleAdmin(moo.RESOLVER_ADMIN_ROLE()), moo.RESOLVER_ADMIN_ROLE());
        assertTrue(moo.hasRole(moo.RESOLVER_ROLE(), RESOLVER_1));
        assertTrue(moo.hasRole(moo.RESOLVER_ROLE(), RESOLVER_2));
        assertTrue(moo.hasRole(moo.RESOLVER_ROLE(), RESOLVER_3));
        assertEq(moo.owner(), EXPECTED_DEPLOYER);
        assertEq(moo.defaultAdmin(), EXPECTED_DEPLOYER);
        assertTrue(moo.hasRole(moo.DEFAULT_ADMIN_ROLE(), EXPECTED_DEPLOYER));
        assertTrue(moo.hasRole(moo.CONFIG_ADMIN_ROLE(), CONFIG_ADMIN));
    }

    function _deployFreshMoo() private returns (ManagedOptimisticOracleV2 moo) {
        AddressWhitelist proposerWhitelist = new AddressWhitelist();
        AddressWhitelist requesterWhitelist = new AddressWhitelist();
        AddressWhitelist collateralWhitelist = new AddressWhitelist();
        MockFinder finder = new MockFinder();
        IERC20 currency = IERC20(makeAddr("currency"));
        collateralWhitelist.addToWhitelist(address(currency));
        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateralWhitelist));

        ManagedOptimisticOracleV2.CurrencyBondRange[] memory ranges =
            new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
        ranges[0] = ManagedOptimisticOracleV2.CurrencyBondRange({
            currency: currency,
            range: ManagedOptimisticOracleV2.BondRange({minimumBond: 100e6, maximumBond: 100_000e6})
        });

        ManagedOptimisticOracleV2 implementation = new ManagedOptimisticOracleV2();
        vm.prank(EXPECTED_DEPLOYER);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                ManagedOptimisticOracleV2.initialize,
                (
                    2 hours,
                    address(finder),
                    address(proposerWhitelist),
                    address(requesterWhitelist),
                    ranges,
                    CONFIG_ADMIN,
                    EXPECTED_DEPLOYER
                )
            )
        );
        moo = ManagedOptimisticOracleV2(address(proxy));
    }
}
