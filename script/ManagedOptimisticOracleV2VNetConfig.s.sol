// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AddressWhitelistInterface} from "../src/common/interfaces/AddressWhitelistInterface.sol";
import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";

interface IOOReporterVNetSentinel {
    function optimisticOracle() external view returns (address);
}

/**
 * @notice Constants and environment guards for the Polymarket Polygon Tenderly VNet deployment.
 * @dev The VNet reports Polygon's chain id, so chain id alone is not a sufficient broadcast guard.
 */
abstract contract ManagedOptimisticOracleV2VNetConfig is Script {
    uint256 internal constant POLYGON_CHAIN_ID = 137;

    address internal constant EXPECTED_DEPLOYER = 0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D;
    address internal constant FINDER = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    address internal constant DEFAULT_PROPOSER_WHITELIST = 0x9F35885CE8f67a942D7B2f4Fbf937987DA08c463;
    address internal constant REQUESTER_WHITELIST = 0x0f79d0039956D58a7d5d006a6Dd64a35616Aa2c6;
    address internal constant CONFIG_ADMIN = 0x3dcE0a29139A851Da1dFCa56Af8e8a6440b4D952;
    address internal constant UPGRADE_ADMIN_SAFE = 0x7FB4492Ff58E4326a99D7d4F66aE1f47c8286Fc6;
    address internal constant RESOLVER_ADMIN = 0x6ee4D971142afadEa1828445124D6137080B4146;

    address internal constant USDC_E = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    uint128 internal constant MINIMUM_USDC_E_BOND = 100e6;
    uint128 internal constant MAXIMUM_USDC_E_BOND = 100_000e6;
    uint256 internal constant DEFAULT_LIVENESS = 2 hours;
    uint256 internal constant MINIMUM_DISPUTE_WINDOW = 5 minutes;

    address internal constant LEGACY_MOO = 0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1;
    address internal constant LEGACY_MOO_IMPLEMENTATION = 0x7d660195eD02AC61A42408780233F06dDd6A2E42;
    address internal constant OO_REPORTER = 0x2df52c80E4Fae386fc63EBfb550C64880848852c;
    address internal constant OO_REPORTER_IMPLEMENTATION = 0x9ee4bF4EE8c1b946b7cC48FEADf41bc8E304d7f7;

    address internal constant RESOLVER_1 = 0x33965F7D08F61A62B86C1Ab9Be5d82C42F4c3081;
    address internal constant RESOLVER_2 = 0x9725e8172A108f2BaD87ef31eA4Ea729e939d869;
    address internal constant RESOLVER_3 = 0x561Cbe8b8022A9530D47478420EdfEB66b5c4720;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _assertVNet(address deployer) internal view {
        require(block.chainid == POLYGON_CHAIN_ID, "VNet guard: wrong chain id");
        require(deployer == EXPECTED_DEPLOYER, "VNet guard: wrong deployer");

        require(FINDER.code.length != 0, "VNet guard: Finder missing");
        require(DEFAULT_PROPOSER_WHITELIST.code.length != 0, "VNet guard: proposer whitelist missing");
        require(REQUESTER_WHITELIST.code.length != 0, "VNet guard: requester whitelist missing");
        require(LEGACY_MOO.code.length != 0, "VNet guard: legacy MOO missing");
        require(OO_REPORTER.code.length != 0, "VNet guard: OOReporter missing");

        require(_implementationOf(LEGACY_MOO) == LEGACY_MOO_IMPLEMENTATION, "VNet guard: legacy MOO changed");
        require(
            _implementationOf(OO_REPORTER) == OO_REPORTER_IMPLEMENTATION, "VNet guard: OOReporter changed"
        );
        require(
            IOOReporterVNetSentinel(OO_REPORTER).optimisticOracle() == LEGACY_MOO,
            "VNet guard: reporter oracle changed"
        );
        require(
            AddressWhitelistInterface(REQUESTER_WHITELIST).isOnWhitelist(OO_REPORTER),
            "VNet guard: reporter not whitelisted"
        );

        ManagedOptimisticOracleV2 legacyMoo = ManagedOptimisticOracleV2(LEGACY_MOO);
        _assertBaseConfiguration(legacyMoo);
        require(legacyMoo.minimumDisputeWindow() == MINIMUM_DISPUTE_WINDOW, "VNet guard: dispute window changed");
    }

    function _assertFreshV1Configuration(ManagedOptimisticOracleV2 moo) internal view {
        require(address(moo).code.length != 0, "Deployment check: proxy missing");
        require(_implementationOf(address(moo)).code.length != 0, "Deployment check: implementation missing");
        _assertBaseConfiguration(moo);
        require(moo.minimumDisputeWindow() == 0, "Deployment check: V2 already initialized");
        require(
            !moo.hasRole(moo.RESOLVER_ADMIN_ROLE(), RESOLVER_ADMIN), "Deployment check: resolver admin already set"
        );
    }

    function _assertBaseConfiguration(ManagedOptimisticOracleV2 moo) private view {
        require(address(moo.finder()) == FINDER, "Configuration check: wrong Finder");
        require(
            address(moo.defaultProposerWhitelist()) == DEFAULT_PROPOSER_WHITELIST,
            "Configuration check: wrong proposer whitelist"
        );
        require(
            address(moo.requesterWhitelist()) == REQUESTER_WHITELIST,
            "Configuration check: wrong requester whitelist"
        );
        require(moo.defaultLiveness() == DEFAULT_LIVENESS, "Configuration check: wrong default liveness");
        require(moo.owner() == UPGRADE_ADMIN_SAFE, "Configuration check: wrong upgrade admin");
        require(
            moo.hasRole(moo.CONFIG_ADMIN_ROLE(), CONFIG_ADMIN), "Configuration check: config admin role missing"
        );

        (uint128 minimumBond, uint128 maximumBond) = moo.allowedBondRanges(IERC20(USDC_E));
        require(minimumBond == MINIMUM_USDC_E_BOND, "Configuration check: wrong minimum bond");
        require(maximumBond == MAXIMUM_USDC_E_BOND, "Configuration check: wrong maximum bond");
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }
}
