// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Upgrades, Options} from "@openzeppelin/foundry-upgrades/Upgrades.sol";

import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {ManagedOptimisticOracleV2Interface} from
    "../src/optimistic-oracle-v2/interfaces/ManagedOptimisticOracleV2Interface.sol";
import {AddressWhitelistInterface} from "../src/common/interfaces/AddressWhitelistInterface.sol";

/**
 * @title ManagedOptimisticOracleV2 Fork Tests
 * @notice Tests for upgrading and using the early resolver functionality on Polygon mainnet fork
 *
 * @dev IMPORTANT - Fork Block Pinning:
 * These tests are pinned to a specific block (pre-V2 upgrade) to ensure stable CI results.
 * This allows testing the V1->V2 upgrade path and prevents false failures after mainnet upgrade.
 * Keep this file as-is to preserve upgrade testing and documentation.
 *
 * @dev Run with: forge test --match-contract ManagedOptimisticOracleV2ForkTest --fork-url polygon -vvv
 */
contract ManagedOptimisticOracleV2ForkTest is Test {
    // Deployed contract on Polygon
    address constant PROXY_ADDRESS = 0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1;

    // Bridged USDC.e on Polygon (used by Polymarket)
    IERC20 constant USDC_E = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

    // Fork block number - IMPORTANT: This should be a block BEFORE the V2 upgrade
    // After upgrading to V2 on mainnet, these tests should be updated or archived
    // Current block represents pre-V2 state (January 2026)
    uint256 constant FORK_BLOCK = 81683818;

    ManagedOptimisticOracleV2 public managedOOv2;

    address public upgradeAdmin;
    address public configAdmin;
    address public resolver;
    address public requester;
    address public proposer;

    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant REQUEST_MANAGER_ROLE = keccak256("REQUEST_MANAGER_ROLE");

    // Test identifiers and ancillary data
    bytes32 public constant TEST_IDENTIFIER = bytes32("YES_OR_NO_QUERY");
    bytes public ancillaryData = bytes("q: Did the test pass?");

    function setUp() public {
        // Create a fork of Polygon mainnet at a specific block (pre-V2 upgrade)
        string memory rpcUrl = vm.envString("NODE_URL_137");
        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        // Load the existing proxy
        managedOOv2 = ManagedOptimisticOracleV2(PROXY_ADDRESS);

        // Get current roles
        upgradeAdmin = managedOOv2.owner();

        // Setup test accounts
        resolver = makeAddr("resolver");
        requester = makeAddr("requester");
        proposer = makeAddr("proposer");

        console.log("Fork Test Setup:");
        console.log("  Proxy Address:", PROXY_ADDRESS);
        console.log("  Upgrade Admin:", upgradeAdmin);
        console.log("  Block Number:", block.number);
    }

    function testForkDeploymentState() public view {
        console.log("\n=== Testing Current Deployment State ===");

        // Verify proxy is initialized
        assertTrue(address(managedOOv2.finder()) != address(0), "Finder should be set");
        assertTrue(managedOOv2.defaultLiveness() > 0, "Default liveness should be set");

        console.log("  Finder:", address(managedOOv2.finder()));
        console.log("  Default Liveness:", managedOOv2.defaultLiveness());
        console.log("  Upgrade Admin:", managedOOv2.owner());
        console.log("  Fork Block:", FORK_BLOCK);
    }

    function testForkPreV2State() public view {
        console.log("\n=== Verifying Pre-V2 State ===");

        // This test ensures we're on a fork BEFORE the V2 upgrade
        // If this fails, the FORK_BLOCK constant needs updating

        // Check that minimumDisputeWindow doesn't exist (will revert if V2 is deployed)
        // We expect this to return 0 or revert on V1
        try managedOOv2.minimumDisputeWindow() returns (uint256 window) {
            // If we can call this, we're already on V2 - tests will fail
            console.log("  WARNING: Contract appears to be V2 already!");
            console.log("  Minimum Dispute Window:", window);
            revert("FORK_BLOCK is set to post-V2 block. Update FORK_BLOCK to a block before V2 upgrade.");
        } catch {
            // Expected: method doesn't exist on V1
            console.log("  + Confirmed: Running on pre-V2 deployment");
        }
    }

    function testForkUpgradeToV2() public {
        console.log("\n=== Testing Upgrade to V2 ===");

        // Impersonate the upgrade admin
        vm.startPrank(upgradeAdmin);

        // Deploy new implementation
        address newImpl = address(new ManagedOptimisticOracleV2());
        console.log("  New Implementation:", newImpl);

        // Prepare initializeV2 call with 5 minute minimum dispute window
        uint256 minimumDisputeWindow = 5 minutes;
        bytes memory initData =
            abi.encodeCall(ManagedOptimisticOracleV2.initializeV2, (minimumDisputeWindow, upgradeAdmin));

        // Upgrade the proxy
        bytes memory upgradeData = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, initData);

        (bool success,) = PROXY_ADDRESS.call(upgradeData);
        require(success, "Upgrade failed");

        vm.stopPrank();

        // Verify upgrade
        assertEq(managedOOv2.minimumDisputeWindow(), minimumDisputeWindow, "Minimum dispute window not set");
        assertEq(
            managedOOv2.defaultLiveness(),
            minimumDisputeWindow,
            "Default liveness should sync with minimum dispute window"
        );

        console.log("  Minimum Dispute Window:", managedOOv2.minimumDisputeWindow());
        console.log("  Default Liveness:", managedOOv2.defaultLiveness());
        console.log("  + Upgrade successful");
    }

    function testForkUpgradeToV2WithRoleSetup() public {
        console.log("\n=== Testing Upgrade to V2 with Role Setup ===");

        vm.startPrank(upgradeAdmin);

        // Deploy new implementation
        address newImpl = address(new ManagedOptimisticOracleV2());

        // Prepare multicall data for upgrade + role setup
        bytes[] memory calls = new bytes[](2);

        // 1. Initialize V2 with minimum dispute window and upgrade admin as resolver admin
        calls[0] = abi.encodeCall(ManagedOptimisticOracleV2.initializeV2, (5 minutes, upgradeAdmin));

        // 2. Add resolver (upgradeAdmin now has RESOLVER_ADMIN_ROLE from initializeV2)
        calls[1] = abi.encodeCall(ManagedOptimisticOracleV2.addResolver, (resolver));

        // Create multicall
        bytes memory multicallData = abi.encodeWithSignature("multicall(bytes[])", calls);

        // Upgrade with multicall
        bytes memory upgradeData = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, multicallData);
        (bool success,) = PROXY_ADDRESS.call(upgradeData);
        require(success, "Upgrade with multicall failed");

        vm.stopPrank();

        // Verify resolver role
        assertTrue(managedOOv2.hasRole(RESOLVER_ROLE, resolver), "Resolver role not granted");
        console.log("  Resolver:", resolver);
        console.log("  + Resolver role granted during upgrade");
    }

    function testForkAddAndRemoveResolver() public {
        // First upgrade to V2
        _upgradeToV2(5 minutes);

        console.log("\n=== Testing Add/Remove Resolver ===");

        // Impersonate upgrade admin to grant RESOLVER_ADMIN_ROLE
        vm.startPrank(upgradeAdmin);
        managedOOv2.grantRole(managedOOv2.RESOLVER_ADMIN_ROLE(), upgradeAdmin);

        // Add resolver
        managedOOv2.addResolver(resolver);
        assertTrue(managedOOv2.hasRole(RESOLVER_ROLE, resolver), "Resolver not added");
        console.log("  + Resolver added:", resolver);

        // Remove resolver
        managedOOv2.removeResolver(resolver);
        assertFalse(managedOOv2.hasRole(RESOLVER_ROLE, resolver), "Resolver not removed");
        console.log("  + Resolver removed");

        vm.stopPrank();
    }

    function testForkMinimumDisputeWindowValidation() public {
        // First upgrade to V2
        _upgradeToV2(5 minutes);

        console.log("\n=== Testing Minimum Dispute Window Validation ===");

        vm.startPrank(upgradeAdmin);
        managedOOv2.grantRole(CONFIG_ADMIN_ROLE, upgradeAdmin);

        // Should revert if below 5 minutes
        vm.expectRevert(ManagedOptimisticOracleV2Interface.MinimumDisputeWindowTooSmall.selector);
        managedOOv2.setMinimumDisputeWindow(4 minutes);
        console.log("  + Reverts when < 5 minutes");

        // Should revert if above LEGACY_DEFAULT_LIVENESS (2 hours)
        vm.expectRevert(ManagedOptimisticOracleV2Interface.MinimumDisputeWindowTooLarge.selector);
        managedOOv2.setMinimumDisputeWindow(3 hours);
        console.log("  + Reverts when > 2 hours");

        // Should succeed with valid value
        managedOOv2.setMinimumDisputeWindow(30 minutes);
        assertEq(managedOOv2.minimumDisputeWindow(), 30 minutes);
        assertEq(managedOOv2.defaultLiveness(), 30 minutes, "Should sync with defaultLiveness");
        console.log("  + Accepts valid value (30 minutes)");

        vm.stopPrank();
    }

    function testForkEarlyResolutionWithUSDCe() public {
        // First upgrade to V2
        _upgradeToV2(5 minutes);

        console.log("\n=== Testing Early Resolution with USDC.e ===");

        // Setup roles - grant resolver admin role and add resolver
        vm.startPrank(upgradeAdmin);
        managedOOv2.grantRole(managedOOv2.RESOLVER_ADMIN_ROLE(), upgradeAdmin);
        managedOOv2.addResolver(resolver);

        vm.stopPrank();

        // Add requester to whitelist by impersonating the whitelist owner
        address requesterWhitelist = address(managedOOv2.requesterWhitelist());
        if (requesterWhitelist != address(0)) {
            AddressWhitelistInterface whitelist = AddressWhitelistInterface(requesterWhitelist);
            address whitelistOwner = Ownable(requesterWhitelist).owner();
            console.log("  Requester Whitelist Owner:", whitelistOwner);

            vm.prank(whitelistOwner);
            whitelist.addToWhitelist(requester);
            console.log("  + Requester added to whitelist");
        }

        // Add proposer to proposer whitelist
        address proposerWhitelist = address(managedOOv2.defaultProposerWhitelist());
        if (proposerWhitelist != address(0)) {
            AddressWhitelistInterface whitelist = AddressWhitelistInterface(proposerWhitelist);
            address whitelistOwner = Ownable(proposerWhitelist).owner();
            console.log("  Proposer Whitelist Owner:", whitelistOwner);

            vm.prank(whitelistOwner);
            whitelist.addToWhitelist(proposer);
            console.log("  + Proposer added to whitelist");
        }

        // Fund requester and proposer with USDC.e
        // Give them plenty to cover bond + final fees
        uint256 bondAmount = 100e6; // 100 USDC.e (6 decimals)
        deal(address(USDC_E), requester, 1000e6); // 1000 USDC.e
        deal(address(USDC_E), proposer, 1000e6); // 1000 USDC.e

        console.log("  Requester balance:", USDC_E.balanceOf(requester));
        console.log("  Proposer balance:", USDC_E.balanceOf(proposer));

        console.log("  Bond Amount:", bondAmount);
        console.log("  Token: USDC.e", address(USDC_E));

        // Request price
        vm.startPrank(requester);
        USDC_E.approve(address(managedOOv2), type(uint256).max);

        managedOOv2.requestPrice(
            TEST_IDENTIFIER,
            block.timestamp,
            ancillaryData,
            USDC_E,
            0 // no reward
        );
        console.log("  + Price request created");
        vm.stopPrank();

        // Propose price
        vm.startPrank(proposer);
        USDC_E.approve(address(managedOOv2), type(uint256).max);

        managedOOv2.proposePriceFor(
            proposer,
            requester,
            TEST_IDENTIFIER,
            block.timestamp,
            ancillaryData,
            1e18 // proposed price: YES
        );
        console.log("  + Price proposed");
        vm.stopPrank();

        // Wait for minimum dispute window
        vm.warp(block.timestamp + 5 minutes + 1);

        // Resolver settles early
        vm.prank(resolver);
        managedOOv2.settle(requester, TEST_IDENTIFIER, block.timestamp - 5 minutes - 1, ancillaryData);
        console.log("  + Resolver settled after minimum dispute window");
    }

    function testForkExtendedDisputeWindow() public {
        // First upgrade to V2
        _upgradeToV2(5 minutes);

        console.log("\n=== Testing Extended Dispute Window ===");

        // Setup: Create a price request and proposal
        _setupPriceRequestAndProposal();

        // Warp past expiration (default liveness is 5 minutes after upgrade)
        vm.warp(block.timestamp + 6 minutes);

        console.log("  Time after proposal: 6 minutes (past expiration)");

        // In the old system, this would be State.Expired
        // In the new system with early resolver, disputes should still be possible

        address disputer = makeAddr("disputer");
        deal(address(USDC_E), disputer, 1000e6); // Give plenty to cover bond + final fee

        vm.startPrank(disputer);
        USDC_E.approve(address(managedOOv2), type(uint256).max);

        // Dispute should work even though expired because of _getStateForDispute override
        managedOOv2.disputePriceFor(disputer, requester, TEST_IDENTIFIER, block.timestamp - 6 minutes, ancillaryData);
        console.log("  + Dispute succeeded even after expiration");
        console.log("  This proves extended dispute window works!");
        vm.stopPrank();
    }

    function testForkNonResolverCannotSettleEarly() public {
        // First upgrade to V2
        _upgradeToV2(5 minutes);

        console.log("\n=== Testing Non-Resolver Cannot Settle Early ===");

        // Setup: Create a price request and proposal
        _setupPriceRequestAndProposal();

        // Wait for minimum dispute window
        vm.warp(block.timestamp + 5 minutes + 1);

        // Try to settle as non-resolver (should fail)
        address nonResolver = makeAddr("nonResolver");
        vm.prank(nonResolver);

        vm.expectRevert();
        managedOOv2.settle(requester, TEST_IDENTIFIER, block.timestamp - 5 minutes - 1, ancillaryData);

        console.log("  + Non-resolver cannot settle (correctly reverted)");
    }

    function testForkStorageLayoutCompatibility() public {
        console.log("\n=== Testing Storage Layout Compatibility ===");

        // Record values before upgrade
        uint256 livenessBefore = managedOOv2.defaultLiveness();
        address finderBefore = address(managedOOv2.finder());
        address ownerBefore = managedOOv2.owner();

        // Perform upgrade
        _upgradeToV2(5 minutes);

        // Verify critical storage slots preserved
        assertEq(address(managedOOv2.finder()), finderBefore, "Finder address changed");
        assertEq(managedOOv2.owner(), ownerBefore, "Owner changed");

        console.log("  + Finder preserved:", finderBefore);
        console.log("  + Owner preserved:", ownerBefore);
        console.log("  Original liveness:", livenessBefore);
        console.log("  New minimum dispute window:", managedOOv2.minimumDisputeWindow());
    }

    // Helper Functions

    function _upgradeToV2(uint256 minimumDisputeWindow) internal {
        vm.startPrank(upgradeAdmin);

        address newImpl = address(new ManagedOptimisticOracleV2());
        bytes memory initData =
            abi.encodeCall(ManagedOptimisticOracleV2.initializeV2, (minimumDisputeWindow, upgradeAdmin));
        bytes memory upgradeData = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, initData);

        (bool success,) = PROXY_ADDRESS.call(upgradeData);
        require(success, "Upgrade failed in helper");

        vm.stopPrank();
    }

    function _setupPriceRequestAndProposal() internal {
        // Setup roles - grant resolver admin role and add resolver
        vm.startPrank(upgradeAdmin);
        managedOOv2.grantRole(managedOOv2.RESOLVER_ADMIN_ROLE(), upgradeAdmin);
        managedOOv2.addResolver(resolver);
        vm.stopPrank();

        // Add requester to whitelist
        address requesterWhitelist = address(managedOOv2.requesterWhitelist());
        if (requesterWhitelist != address(0)) {
            AddressWhitelistInterface whitelist = AddressWhitelistInterface(requesterWhitelist);
            address whitelistOwner = Ownable(requesterWhitelist).owner();
            vm.prank(whitelistOwner);
            whitelist.addToWhitelist(requester);
        }

        // Add proposer to proposer whitelist
        address proposerWhitelist = address(managedOOv2.defaultProposerWhitelist());
        if (proposerWhitelist != address(0)) {
            AddressWhitelistInterface whitelist = AddressWhitelistInterface(proposerWhitelist);
            address whitelistOwner = Ownable(proposerWhitelist).owner();
            vm.prank(whitelistOwner);
            whitelist.addToWhitelist(proposer);
        }

        // Fund accounts generously
        deal(address(USDC_E), requester, 1000e6);
        deal(address(USDC_E), proposer, 1000e6);

        // Create request
        vm.startPrank(requester);
        USDC_E.approve(address(managedOOv2), type(uint256).max);

        managedOOv2.requestPrice(TEST_IDENTIFIER, block.timestamp, ancillaryData, USDC_E, 0);
        vm.stopPrank();

        // Propose price
        vm.startPrank(proposer);
        USDC_E.approve(address(managedOOv2), type(uint256).max);

        managedOOv2.proposePriceFor(proposer, requester, TEST_IDENTIFIER, block.timestamp, ancillaryData, 1e18);
        vm.stopPrank();
    }
}
