// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {DisableableAddressWhitelist} from "../src/common/implementation/DisableableAddressWhitelist.sol";
import {Timer} from "@uma/contracts/common/implementation/Timer.sol";

import {MockFinder} from "./mocks/MockFinder.sol";
import {MockStore} from "./mocks/MockStore.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockIdentifierWhitelist} from "./mocks/MockIdentifierWhitelist.sol";
import {MockCollateralWhitelist} from "./mocks/MockCollateralWhitelist.sol";

contract ManagedOptimisticOracleV2IntegrationTest is Test {
    ManagedOptimisticOracleV2 public oracle;
    ManagedOptimisticOracleV2 public implementation;
    ERC1967Proxy public proxy;

    DisableableAddressWhitelist public defaultProposerWhitelist;
    DisableableAddressWhitelist public requesterWhitelist;

    MockFinder public finder;
    MockStore public store;
    MockOracle public mockOracle;
    MockIdentifierWhitelist public identifierWhitelist;
    MockCollateralWhitelist public collateralWhitelist;
    Timer public timer;

    ERC20Mock public currency1;
    ERC20Mock public currency2;

    // Test constants
    uint256 constant DEFAULT_LIVENESS = 7200;
    uint256 constant MINIMUM_LIVENESS = 3600;
    uint256 constant MAXIMUM_BOND = 1000e18;
    uint256 constant REWARD = 50e18;
    int256 constant PROPOSED_PRICE = 1000;
    uint256 constant FINAL_FEE = 100e18; // Updated to match MockStore
    uint256 constant TOTAL_BOND = FINAL_FEE * 2; // 200e18 (finalFee * 2 as per contract)

    bytes32 constant IDENTIFIER = keccak256("integration test identifier");
    bytes constant ANCILLARY_DATA = "integration test data";

    // Test addresses (avoiding precompiled contract addresses 0x1-0x9)
    address constant admin = address(0x1001);
    address constant requester = address(0x1002);
    address constant proposer = address(0x1003);
    address constant requestManager = address(0x1004);
    address constant disputer = address(0x1005);

    function setUp() public {
        // Deploy mock contracts
        finder = new MockFinder();
        store = new MockStore();
        mockOracle = new MockOracle();
        identifierWhitelist = new MockIdentifierWhitelist();
        collateralWhitelist = new MockCollateralWhitelist();
        timer = new Timer();
        currency1 = new ERC20Mock();
        currency2 = new ERC20Mock();

        // Setup finder mappings
        finder.setImplementationAddress(bytes32("Oracle"), address(mockOracle));
        finder.setImplementationAddress(bytes32("Store"), address(store));
        finder.setImplementationAddress(bytes32("IdentifierWhitelist"), address(identifierWhitelist));
        finder.setImplementationAddress(bytes32("CollateralWhitelist"), address(collateralWhitelist));

        // Setup whitelists
        defaultProposerWhitelist = new DisableableAddressWhitelist();
        requesterWhitelist = new DisableableAddressWhitelist();

        // Add addresses to whitelists
        defaultProposerWhitelist.addToWhitelist(proposer);
        requesterWhitelist.addToWhitelist(requester);

        // Setup collateral whitelist
        collateralWhitelist.addToWhitelist(address(currency1));
        collateralWhitelist.addToWhitelist(address(currency2));

        // Setup identifier whitelist
        identifierWhitelist.addToWhitelist(IDENTIFIER);

        // Deploy implementation and proxy
        implementation = new ManagedOptimisticOracleV2();

        // Prepare initialization data with multiple currencies
        ManagedOptimisticOracleV2.Bond[] memory maximumBonds = new ManagedOptimisticOracleV2.Bond[](2);
        maximumBonds[0] = ManagedOptimisticOracleV2.Bond({currency: currency1, amount: MAXIMUM_BOND});
        maximumBonds[1] = ManagedOptimisticOracleV2.Bond({currency: currency2, amount: MAXIMUM_BOND});

        bytes memory initData = abi.encodeWithSelector(
            ManagedOptimisticOracleV2.initialize.selector,
            DEFAULT_LIVENESS,
            address(finder),
            address(timer),
            address(defaultProposerWhitelist),
            address(requesterWhitelist),
            maximumBonds,
            MINIMUM_LIVENESS,
            admin
        );

        proxy = new ERC1967Proxy(address(implementation), initData);
        oracle = ManagedOptimisticOracleV2(address(proxy));

        // Setup initial state
        vm.startPrank(admin);
        oracle.addRequestManager(requestManager);
        oracle.addRequestManager(disputer);
        vm.stopPrank();

        // Setup token balances
        currency1.mint(requester, 10000e18);
        currency1.mint(proposer, 10000e18);
        currency1.mint(disputer, 10000e18);

        currency2.mint(requester, 10000e18);
        currency2.mint(proposer, 10000e18);
        currency2.mint(disputer, 10000e18);

        // Approve tokens
        vm.startPrank(requester);
        currency1.approve(address(oracle), type(uint256).max);
        currency2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(proposer);
        currency1.approve(address(oracle), type(uint256).max);
        currency2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(disputer);
        currency1.approve(address(oracle), type(uint256).max);
        currency2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Complex Integration Tests ============

    function test_CompletePriceRequestFlow() public {
        bytes memory ancillaryData = "complete flow test";

        // Step 1: Request price
        vm.prank(requester);
        uint256 totalBond = oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);

        assertEq(totalBond, TOTAL_BOND);
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 1); // Requested

        // Step 2: Request manager sets custom bond
        vm.prank(requestManager);
        uint256 customBond = 500e18;
        totalBond = oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData, customBond);

        assertEq(totalBond, customBond + FINAL_FEE);

        // Step 3: Request manager sets custom liveness
        vm.prank(requestManager);
        uint256 customLiveness = 5400; // 1.5 hours
        oracle.requestManagerSetCustomLiveness(requester, IDENTIFIER, block.timestamp, ancillaryData, customLiveness);

        // Step 4: Request manager sets custom proposer whitelist
        DisableableAddressWhitelist customWhitelist = new DisableableAddressWhitelist();
        customWhitelist.addToWhitelist(proposer);

        vm.prank(requestManager);
        oracle.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ancillaryData, address(customWhitelist));

        // Step 5: Propose price (should use custom whitelist)
        vm.prank(proposer);
        totalBond =
            oracle.proposePriceFor(proposer, requester, IDENTIFIER, block.timestamp, ancillaryData, PROPOSED_PRICE);

        assertEq(totalBond, customBond + FINAL_FEE);
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 2); // Proposed
    }

    function test_MultipleCurrenciesAndRequestManagers() public {
        bytes memory ancillaryData1 = "currency1 test";
        bytes memory ancillaryData2 = "currency2 test";

        // Request 1 with currency1 managed by requestManager
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData1, currency1, REWARD);

        vm.prank(requestManager);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData1, 300e18);

        // Request 2 with currency2 managed by requestManager
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData2, currency2, REWARD);

        vm.prank(requestManager);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData2, 600e18);

        // Verify different bonds for different currencies
        assertEq(oracle.maximumBonds(currency1), MAXIMUM_BOND);
        assertEq(oracle.maximumBonds(currency2), MAXIMUM_BOND);

        // Verify both requests are in Requested state
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData1)), 1);
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData2)), 1);
    }

    function test_WhitelistEnforcementScenarios() public {
        bytes memory ancillaryData = "whitelist enforcement test";

        // Request a price
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);

        // Test 1: Default whitelist enabled (should work)
        vm.prank(proposer);
        oracle.proposePriceFor(proposer, requester, IDENTIFIER, block.timestamp, ancillaryData, PROPOSED_PRICE);

        // Reset state
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, "whitelist test 2", currency1, REWARD);

        // Test 2: Disable default whitelist (should work for any proposer)
        defaultProposerWhitelist.setWhitelistEnforcement(false);

        address nonWhitelistedProposer = address(0x1009);
        currency1.mint(nonWhitelistedProposer, 10000e18);
        vm.prank(nonWhitelistedProposer);
        currency1.approve(address(oracle), type(uint256).max);

        vm.prank(nonWhitelistedProposer);
        oracle.proposePriceFor(
            nonWhitelistedProposer, requester, IDENTIFIER, block.timestamp, "whitelist test 2", PROPOSED_PRICE
        );

        // Test 3: Custom whitelist with enforcement disabled
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, "custom whitelist test", currency1, REWARD);

        DisableableAddressWhitelist customWhitelist = new DisableableAddressWhitelist();
        customWhitelist.addToWhitelist(proposer);
        customWhitelist.setWhitelistEnforcement(false);

        vm.prank(requestManager);
        oracle.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ancillaryData, address(customWhitelist));

        vm.prank(nonWhitelistedProposer);
        oracle.proposePriceFor(
            nonWhitelistedProposer, requester, IDENTIFIER, block.timestamp, "custom whitelist test", PROPOSED_PRICE
        );
    }

    function test_StateTransitions() public {
        bytes memory ancillaryData = "state transitions test";

        // Initial state: Invalid
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 0); // Invalid

        // Step 1: Request price -> Requested
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 1); // Requested

        // Step 2: Propose price -> Proposed
        vm.prank(proposer);
        oracle.proposePriceFor(proposer, requester, IDENTIFIER, block.timestamp, ancillaryData, PROPOSED_PRICE);
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 2); // Proposed

        // Step 3: Fast forward time to expire proposal -> Expired
        vm.warp(1 + DEFAULT_LIVENESS + 1);
        timer.setCurrentTime(1 + DEFAULT_LIVENESS + 1);
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, 1, ancillaryData)), 3); // Expired
    }

    function test_RequestManagerPermissions() public {
        bytes memory ancillaryData = "permissions test";

        // Request a price
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);

        // Test: requestManager can modify request
        vm.prank(requestManager);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData, 400e18);

        // Test: requestManager2 can also modify the same request
        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(requester, IDENTIFIER, block.timestamp, ancillaryData, 5400);

        // Test: Remove requestManager and verify it can no longer modify
        vm.prank(admin);
        oracle.removeRequestManager(requestManager);

        vm.expectRevert();
        vm.prank(requestManager);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData, 500e18);

        // Test: Another request manager can still modify
        vm.prank(disputer);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData, 500e18);
    }

    function test_EdgeCasesAndBoundaries() public {
        bytes memory ancillaryData = "edge cases test";

        // Test 1: Maximum bond boundary
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);

        vm.prank(requestManager);
        oracle.requestManagerSetBond(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            MAXIMUM_BOND // Exactly at maximum
        );

        // Test 2: Minimum liveness boundary
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, "min liveness test", currency1, REWARD);

        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(
            requester,
            IDENTIFIER,
            block.timestamp,
            "min liveness test",
            MINIMUM_LIVENESS // Exactly at minimum
        );

        // Test 3: Zero values
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            "zero values test",
            currency1,
            0 // Zero reward
        );

        vm.prank(requestManager);
        oracle.requestManagerSetBond(
            requester,
            IDENTIFIER,
            block.timestamp,
            "zero values test",
            0 // Zero bond
        );
    }

    function test_MulticallComplexScenario() public {
        bytes memory ancillaryData = "multicall test";

        // Request a price first
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);

        // Create a complex multicall with multiple operations
        bytes[] memory calls = new bytes[](3);

        // Call 1: Set bond
        calls[0] = abi.encodeWithSelector(
            oracle.requestManagerSetBond.selector, requester, IDENTIFIER, block.timestamp, ancillaryData, 300e18
        );

        // Call 2: Set custom liveness
        calls[1] = abi.encodeWithSelector(
            oracle.requestManagerSetCustomLiveness.selector, requester, IDENTIFIER, block.timestamp, ancillaryData, 5400
        );

        // Call 3: Set custom proposer whitelist
        DisableableAddressWhitelist customWhitelist = new DisableableAddressWhitelist();
        customWhitelist.addToWhitelist(proposer);

        calls[2] = abi.encodeWithSelector(
            oracle.requestManagerSetProposerWhitelist.selector,
            requester,
            IDENTIFIER,
            ancillaryData,
            address(customWhitelist)
        );

        vm.prank(requestManager);
        bytes[] memory results = oracle.multicall(calls);

        // Verify all operations were successful
        assertEq(results.length, 3);
    }

    function test_UpgradeScenario() public {
        // Create a new implementation
        ManagedOptimisticOracleV2 newImplementation = new ManagedOptimisticOracleV2();

        // Upgrade the contract
        vm.prank(admin);
        (bool success,) = address(oracle).call(
            abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(newImplementation), "")
        );
        require(success, "Upgrade should succeed");

        // Verify the contract still works after upgrade
        bytes memory ancillaryData = "upgrade test";

        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);

        vm.prank(requestManager);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData, 400e18);

        // Verify state is maintained
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 1); // Requested
        assertTrue(oracle.hasRole(keccak256("REQUEST_MANAGER"), requestManager));
    }

    function test_GasOptimizationAndStressTest() public {
        bytes memory ancillaryData = "stress test";

        // Create multiple requests
        for (uint256 i = 0; i < 10; i++) {
            bytes memory requestData = abi.encodePacked(ancillaryData, i);

            vm.prank(requester);
            oracle.requestPrice(IDENTIFIER, block.timestamp, requestData, currency1, REWARD);

            vm.prank(requestManager);
            oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, requestData, 100e18 + i * 50e18);

            vm.prank(proposer);
            oracle.proposePriceFor(
                proposer, requester, IDENTIFIER, block.timestamp, requestData, PROPOSED_PRICE + int256(i)
            );
        }

        // Verify all requests are in Proposed state
        for (uint256 i = 0; i < 10; i++) {
            bytes memory requestData = abi.encodePacked(ancillaryData, i);
            assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, requestData)), 2); // Proposed
        }
    }

    function test_ErrorHandlingAndRecovery() public {
        bytes memory ancillaryData = "error handling test";

        // Test 1: Try to set bond on non-existent request
        vm.expectRevert("setBond: Requested");
        vm.prank(requestManager);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData, 500e18);

        // Test 2: Try to set liveness on non-existent request
        vm.expectRevert("setCustomLiveness: Requested");
        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(requester, IDENTIFIER, block.timestamp, ancillaryData, 5400);

        // Test 3: Create request and then try invalid operations
        vm.prank(requester);
        oracle.requestPrice(IDENTIFIER, block.timestamp, ancillaryData, currency1, REWARD);

        // Try to set bond above maximum
        vm.expectRevert("Bond exceeds maximum bond");
        vm.prank(requestManager);
        oracle.requestManagerSetBond(requester, IDENTIFIER, block.timestamp, ancillaryData, MAXIMUM_BOND + 1);

        // Try to set liveness below minimum
        vm.expectRevert("Liveness is less than minimum");
        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(
            requester, IDENTIFIER, block.timestamp, ancillaryData, MINIMUM_LIVENESS - 1
        );

        // Verify the request is still in Requested state
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 1); // Requested
    }
}
