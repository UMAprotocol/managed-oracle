// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {DisableableAddressWhitelist} from "../src/common/implementation/DisableableAddressWhitelist.sol";
import {AddressWhitelist} from "../src/common/implementation/AddressWhitelist.sol";
import {Timer} from "@uma/contracts/common/implementation/Timer.sol";

import {MockFinder} from "./mocks/MockFinder.sol";
import {MockStore} from "./mocks/MockStore.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockIdentifierWhitelist} from "./mocks/MockIdentifierWhitelist.sol";
import {MockCollateralWhitelist} from "./mocks/MockCollateralWhitelist.sol";

contract ManagedOptimisticOracleV2Test is Test {
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
    
    ERC20Mock public currency;
    
    // Test constants
    uint256 constant DEFAULT_LIVENESS = 7200;
    uint256 constant MINIMUM_LIVENESS = 3600;
    uint256 constant MAXIMUM_BOND = 1000e18;
    uint256 constant REWARD = 50e18;
    int256 constant PROPOSED_PRICE = 1000;
    uint256 constant FINAL_FEE = 100e18; // Updated to match MockStore
    uint256 constant TOTAL_BOND = FINAL_FEE * 2; // 200e18 (finalFee * 2 as per contract)
    uint256 constant CUSTOM_BOND = 500e18;
    uint256 constant CUSTOM_TOTAL_BOND = FINAL_FEE + CUSTOM_BOND; // 600e18
    
    bytes32 constant IDENTIFIER = keccak256("test identifier");
    bytes constant ANCILLARY_DATA = "test data";
    
    // Test addresses
    address constant admin = address(0x1);
    address constant requester = address(0x3); // RIPEMD-160
    address constant proposer = address(0x4); // Identity
    address constant requestManager = address(0x2); // SHA-256
    address constant disputer = address(0x6); // ECAdd
    
    bytes32 public constant REQUEST_MANAGER_ROLE = keccak256("REQUEST_MANAGER");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    event RequestManagerAdded(address indexed requestManager);
    event RequestManagerRemoved(address indexed requestManager);
    event MaximumBondUpdated(IERC20 indexed currency, uint256 newMaximumBond);
    event MinimumLivenessUpdated(uint256 newMinimumLiveness);
    event DefaultProposerWhitelistUpdated(address indexed newWhitelist);
    event RequesterWhitelistUpdated(address indexed newWhitelist);
    event CustomProposerWhitelistSet(
        bytes32 indexed requestId,
        address requester,
        bytes32 indexed identifier,
        bytes ancillaryData,
        address indexed newWhitelist
    );

    function setUp() public {
        // Deploy mock contracts
        finder = new MockFinder();
        store = new MockStore();
        mockOracle = new MockOracle();
        identifierWhitelist = new MockIdentifierWhitelist();
        collateralWhitelist = new MockCollateralWhitelist();
        timer = new Timer();
        currency = new ERC20Mock();
        
        // Deploy whitelists
        defaultProposerWhitelist = new DisableableAddressWhitelist();
        requesterWhitelist = new DisableableAddressWhitelist();
        
        // Enable whitelist enforcement
        defaultProposerWhitelist.setWhitelistEnforcement(true);
        requesterWhitelist.setWhitelistEnforcement(true);
        
        // Setup finder mappings
        finder.setImplementationAddress(bytes32("Oracle"), address(mockOracle));
        finder.setImplementationAddress(bytes32("Store"), address(store));
        finder.setImplementationAddress(bytes32("IdentifierWhitelist"), address(identifierWhitelist));
        finder.setImplementationAddress(bytes32("CollateralWhitelist"), address(collateralWhitelist));
        
        // Setup whitelists
        defaultProposerWhitelist.addToWhitelist(address(0x4)); // Identity
        requesterWhitelist.addToWhitelist(address(0x3)); // RIPEMD-160
        
        // Add currency to collateral whitelist
        collateralWhitelist.addToWhitelist(address(currency));
        
        // Add identifier to identifier whitelist
        identifierWhitelist.addToWhitelist(IDENTIFIER);
        
        // Deploy the oracle implementation
        oracle = new ManagedOptimisticOracleV2();
        
        // Deploy the proxy
        ManagedOptimisticOracleV2.Bond[] memory bonds = new ManagedOptimisticOracleV2.Bond[](1);
        bonds[0] = ManagedOptimisticOracleV2.Bond({
            currency: currency,
            amount: MAXIMUM_BOND
        });
        proxy = new ERC1967Proxy(
            address(oracle),
            abi.encodeWithSelector(
                ManagedOptimisticOracleV2.initialize.selector,
                DEFAULT_LIVENESS,
                address(finder),
                address(timer),
                address(defaultProposerWhitelist),
                address(requesterWhitelist),
                bonds,
                MINIMUM_LIVENESS,
                admin
            )
        );
        
        // Cast the proxy to the oracle interface
        oracle = ManagedOptimisticOracleV2(address(proxy));
        
        // Grant request manager role to test address
        vm.startPrank(admin);
        oracle.grantRole(oracle.REQUEST_MANAGER(), address(0x2)); // SHA-256
        vm.stopPrank();
        
        // Mint tokens to test addresses
        currency.mint(address(0x3), 1000000e18); // RIPEMD-160
        currency.mint(address(0x4), 1000000e18); // Identity
        currency.mint(address(0x6), 1000000e18); // ECAdd
        
        // Approve tokens for the oracle
        vm.prank(address(0x3));
        currency.approve(address(oracle), type(uint256).max);
        vm.prank(address(0x4));
        currency.approve(address(oracle), type(uint256).max);
        vm.prank(address(0x6));
        currency.approve(address(oracle), type(uint256).max);
    }

    // ============ Initialization Tests ============

    function test_Initialize() public {
        assertEq(oracle.defaultLiveness(), DEFAULT_LIVENESS);
        assertEq(address(oracle.finder()), address(finder));
        assertEq(address(oracle.defaultProposerWhitelist()), address(defaultProposerWhitelist));
        assertEq(address(oracle.requesterWhitelist()), address(requesterWhitelist));
        assertEq(oracle.minimumLiveness(), MINIMUM_LIVENESS);
        assertEq(oracle.maximumBonds(currency), MAXIMUM_BOND);
        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_Initialize_RevertIfAlreadyInitialized() public {
        ManagedOptimisticOracleV2.Bond[] memory maximumBonds = new ManagedOptimisticOracleV2.Bond[](1);
        maximumBonds[0] = ManagedOptimisticOracleV2.Bond({
            currency: currency,
            amount: MAXIMUM_BOND
        });
        
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
        
        // Try to initialize the already initialized oracle - should fail
        vm.expectRevert("Initializable: contract is already initialized");
        address(oracle).call(initData);
    }

    function test_Initialize_RevertIfZeroWhitelist() public {
        ManagedOptimisticOracleV2 newImplementation = new ManagedOptimisticOracleV2();
        
        ManagedOptimisticOracleV2.Bond[] memory maximumBonds = new ManagedOptimisticOracleV2.Bond[](1);
        maximumBonds[0] = ManagedOptimisticOracleV2.Bond({
            currency: currency,
            amount: MAXIMUM_BOND
        });
        
        bytes memory initData = abi.encodeWithSelector(
            ManagedOptimisticOracleV2.initialize.selector,
            DEFAULT_LIVENESS,
            address(finder),
            address(timer),
            address(0), // Zero whitelist
            address(requesterWhitelist),
            maximumBonds,
            MINIMUM_LIVENESS,
            admin
        );
        
        vm.expectRevert("Whitelist cannot be zero address");
        new ERC1967Proxy(address(newImplementation), initData);
    }

    // ============ Access Control Tests ============

    function test_AddRequestManager() public {
        address newRequestManager = address(0x6);
        
        vm.expectEmit(true, false, false, false);
        emit RequestManagerAdded(newRequestManager);
        
        vm.prank(admin);
        oracle.addRequestManager(newRequestManager);
        
        assertTrue(oracle.hasRole(REQUEST_MANAGER_ROLE, newRequestManager));
    }

    function test_AddRequestManager_RevertIfNotAdmin() public {
        address newRequestManager = address(0x6);
        
        vm.expectRevert();
        vm.prank(requestManager);
        oracle.addRequestManager(newRequestManager);
    }

    function test_RemoveRequestManager() public {
        vm.expectEmit(true, false, false, false);
        emit RequestManagerRemoved(requestManager);
        
        vm.prank(admin);
        oracle.removeRequestManager(requestManager);
        
        assertFalse(oracle.hasRole(REQUEST_MANAGER_ROLE, requestManager));
    }

    function test_RemoveRequestManager_RevertIfNotAdmin() public {
        vm.expectRevert();
        vm.prank(requestManager);
        oracle.removeRequestManager(requestManager);
    }

    // ============ Bond Management Tests ============

    function test_SetMaximumBond() public {
        uint256 newMaxBond = 2000e18;
        
        vm.expectEmit(true, false, false, false);
        emit MaximumBondUpdated(currency, newMaxBond);
        
        vm.prank(admin);
        oracle.setMaximumBond(currency, newMaxBond);
        
        assertEq(oracle.maximumBonds(currency), newMaxBond);
    }

    function test_SetMaximumBond_RevertIfNotAdmin() public {
        vm.expectRevert();
        vm.prank(requestManager);
        oracle.setMaximumBond(currency, 2000e18);
    }

    function test_SetMaximumBond_RevertIfUnsupportedCurrency() public {
        ERC20Mock unsupportedCurrency = new ERC20Mock();
        
        vm.expectRevert("Unsupported currency");
        vm.prank(admin);
        oracle.setMaximumBond(unsupportedCurrency, 2000e18);
    }

    // ============ Liveness Management Tests ============

    function test_SetMinimumLiveness() public {
        uint256 newMinLiveness = 1800; // 30 minutes
        
        vm.expectEmit(false, false, false, false);
        emit MinimumLivenessUpdated(newMinLiveness);
        
        vm.prank(admin);
        oracle.setMinimumLiveness(newMinLiveness);
        
        assertEq(oracle.minimumLiveness(), newMinLiveness);
    }

    function test_SetMinimumLiveness_RevertIfNotAdmin() public {
        vm.expectRevert();
        vm.prank(requestManager);
        oracle.setMinimumLiveness(1800);
    }

    // ============ Whitelist Management Tests ============

    function test_SetDefaultProposerWhitelist() public {
        DisableableAddressWhitelist newWhitelist = new DisableableAddressWhitelist();
        
        vm.expectEmit(true, false, false, false);
        emit DefaultProposerWhitelistUpdated(address(newWhitelist));
        
        vm.prank(admin);
        oracle.setDefaultProposerWhitelist(address(newWhitelist));
        
        assertEq(address(oracle.defaultProposerWhitelist()), address(newWhitelist));
    }

    function test_SetDefaultProposerWhitelist_RevertIfNotAdmin() public {
        DisableableAddressWhitelist newWhitelist = new DisableableAddressWhitelist();
        
        vm.expectRevert();
        vm.prank(requestManager);
        oracle.setDefaultProposerWhitelist(address(newWhitelist));
    }

    function test_SetDefaultProposerWhitelist_RevertIfZeroAddress() public {
        vm.expectRevert("Whitelist cannot be zero address");
        vm.prank(admin);
        oracle.setDefaultProposerWhitelist(address(0));
    }

    function test_SetRequesterWhitelist() public {
        DisableableAddressWhitelist newWhitelist = new DisableableAddressWhitelist();
        
        vm.expectEmit(true, false, false, false);
        emit RequesterWhitelistUpdated(address(newWhitelist));
        
        vm.prank(admin);
        oracle.setRequesterWhitelist(address(newWhitelist));
        
        assertEq(address(oracle.requesterWhitelist()), address(newWhitelist));
    }

    function test_SetRequesterWhitelist_RevertIfNotAdmin() public {
        DisableableAddressWhitelist newWhitelist = new DisableableAddressWhitelist();
        
        vm.expectRevert();
        vm.prank(requestManager);
        oracle.setRequesterWhitelist(address(newWhitelist));
    }

    function test_SetRequesterWhitelist_RevertIfZeroAddress() public {
        vm.expectRevert("Whitelist cannot be zero address");
        vm.prank(admin);
        oracle.setRequesterWhitelist(address(0));
    }

    // ============ Price Request Tests ============

    function test_RequestPrice() public {
        bytes memory ancillaryData = "test data";
        
        vm.prank(requester);
        uint256 totalBond = oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        assertEq(totalBond, TOTAL_BOND);
        
        // Check request state
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 1); // Requested
    }

    function test_RequestPrice_RevertIfRequesterNotWhitelisted() public {
        address nonWhitelistedRequester = address(0x7); // Use a different address not in whitelist
        
        // Give tokens to non-whitelisted requester
        currency.mint(nonWhitelistedRequester, 10000e18);
        vm.prank(nonWhitelistedRequester);
        currency.approve(address(oracle), type(uint256).max);
        
        bytes memory ancillaryData = "test data";
        
        vm.expectRevert("Requester not whitelisted");
        vm.prank(nonWhitelistedRequester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
    }

    // ============ Request Manager Bond Tests ============

    function test_RequestManagerSetBond() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        uint256 customBond = 500e18;
        
        vm.prank(requestManager);
        uint256 totalBond = oracle.requestManagerSetBond(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            customBond
        );
        
        assertEq(totalBond, CUSTOM_TOTAL_BOND);
    }

    function test_RequestManagerSetBond_RevertIfNotRequestManager() public {
        bytes memory ancillaryData = "test data";
        
        vm.expectRevert();
        vm.prank(requester);
        oracle.requestManagerSetBond(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            500e18
        );
    }

    function test_RequestManagerSetBond_RevertIfBondExceedsMaximum() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        uint256 excessiveBond = MAXIMUM_BOND + 1;
        
        vm.expectRevert("Bond exceeds maximum bond");
        vm.prank(requestManager);
        oracle.requestManagerSetBond(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            excessiveBond
        );
    }

    function test_RequestManagerSetBond_RevertIfRequestNotInRequestedState() public {
        bytes memory ancillaryData = "test data";
        
        vm.expectRevert("setBond: Requested");
        vm.prank(requestManager);
        oracle.requestManagerSetBond(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            500e18
        );
    }

    // ============ Request Manager Liveness Tests ============

    function test_RequestManagerSetCustomLiveness() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        uint256 customLiveness = 5400; // 1.5 hours
        
        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            customLiveness
        );
    }

    function test_RequestManagerSetCustomLiveness_RevertIfNotRequestManager() public {
        bytes memory ancillaryData = "test data";
        
        vm.expectRevert();
        vm.prank(requester);
        oracle.requestManagerSetCustomLiveness(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            5400
        );
    }

    function test_RequestManagerSetCustomLiveness_RevertIfLivenessBelowMinimum() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        uint256 lowLiveness = MINIMUM_LIVENESS - 1;
        
        vm.expectRevert("Liveness is less than minimum");
        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            lowLiveness
        );
    }

    // ============ Custom Proposer Whitelist Tests ============

    function test_RequestManagerSetProposerWhitelist() public {
        bytes memory ancillaryData = "test data";
        DisableableAddressWhitelist customWhitelist = new DisableableAddressWhitelist();
        customWhitelist.addToWhitelist(proposer);
        
        vm.expectEmit(true, true, false, true);
        emit CustomProposerWhitelistSet(
            oracle.getInternalRequestId(requester, IDENTIFIER, ancillaryData),
            requester,
            IDENTIFIER,
            ancillaryData,
            address(customWhitelist)
        );
        
        vm.prank(requestManager);
        oracle.requestManagerSetProposerWhitelist(
            requester,
            IDENTIFIER,
            ancillaryData,
            address(customWhitelist)
        );
        
        assertEq(
            address(oracle.getCustomProposerWhitelist(requester, IDENTIFIER, ancillaryData)),
            address(customWhitelist)
        );
    }

    function test_RequestManagerSetProposerWhitelist_RevertIfNotRequestManager() public {
        bytes memory ancillaryData = "test data";
        DisableableAddressWhitelist customWhitelist = new DisableableAddressWhitelist();
        
        vm.expectRevert();
        vm.prank(requester);
        oracle.requestManagerSetProposerWhitelist(
            requester,
            IDENTIFIER,
            ancillaryData,
            address(customWhitelist)
        );
    }

    // ============ Proposer Whitelist Tests ============

    function test_GetProposerWhitelistWithEnforcementStatus_DefaultWhitelist() public {
        bytes memory ancillaryData = "test data";
        
        (address[] memory allowedProposers, bool isEnforced) = oracle.getProposerWhitelistWithEnforcementStatus(
            requester,
            IDENTIFIER,
            ancillaryData
        );
        
        assertEq(allowedProposers.length, 1);
        assertEq(allowedProposers[0], proposer);
        assertTrue(isEnforced);
    }

    function test_GetProposerWhitelistWithEnforcementStatus_CustomWhitelist() public {
        bytes memory ancillaryData = "test data";
        DisableableAddressWhitelist customWhitelist = new DisableableAddressWhitelist();
        address customProposer = address(0x7);
        customWhitelist.addToWhitelist(customProposer);
        customWhitelist.setWhitelistEnforcement(true); // Enable enforcement
        
        vm.prank(requestManager);
        oracle.requestManagerSetProposerWhitelist(
            requester,
            IDENTIFIER,
            ancillaryData,
            address(customWhitelist)
        );
        
        (address[] memory allowedProposers, bool isEnforced) = oracle.getProposerWhitelistWithEnforcementStatus(
            requester,
            IDENTIFIER,
            ancillaryData
        );
        
        assertEq(allowedProposers.length, 1);
        assertEq(allowedProposers[0], customProposer);
        assertTrue(isEnforced);
    }

    function test_GetProposerWhitelistWithEnforcementStatus_DisabledWhitelist() public {
        // Disable the default whitelist
        defaultProposerWhitelist.setWhitelistEnforcement(false);
        
        bytes memory ancillaryData = "test data";
        
        (address[] memory allowedProposers, bool isEnforced) = oracle.getProposerWhitelistWithEnforcementStatus(
            requester,
            IDENTIFIER,
            ancillaryData
        );
        
        assertEq(allowedProposers.length, 0);
        assertFalse(isEnforced);
    }

    // ============ Price Proposal Tests ============

    function test_ProposePriceFor() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        vm.prank(proposer);
        uint256 totalBond = oracle.proposePriceFor(
            proposer,
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            PROPOSED_PRICE
        );
        
        assertEq(totalBond, TOTAL_BOND);
        
        // Check proposal state
        assertEq(uint256(oracle.getState(requester, IDENTIFIER, block.timestamp, ancillaryData)), 2); // Proposed
    }

    function test_ProposePriceFor_RevertIfProposerNotWhitelisted() public {
        bytes memory ancillaryData = "test data";
        address nonWhitelistedProposer = address(0x7); // Use a different address not in whitelist
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        vm.expectRevert("Proposer not whitelisted");
        vm.prank(proposer);
        oracle.proposePriceFor(
            nonWhitelistedProposer,
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            PROPOSED_PRICE
        );
    }

    function test_ProposePriceFor_RevertIfSenderNotWhitelisted() public {
        bytes memory ancillaryData = "test data";
        address nonWhitelistedSender = address(0x7); // Use a different address not in whitelist
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        vm.expectRevert("Sender not whitelisted");
        vm.prank(nonWhitelistedSender);
        oracle.proposePriceFor(
            proposer,
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            PROPOSED_PRICE
        );
    }

    // ============ Utility Function Tests ============

    function test_GetInternalRequestId() public {
        bytes memory ancillaryData = "test data";
        
        bytes32 requestId = oracle.getInternalRequestId(requester, IDENTIFIER, ancillaryData);
        
        // Should be deterministic and not zero
        assertTrue(requestId != bytes32(0));
        
        // Should be the same when called twice
        bytes32 requestId2 = oracle.getInternalRequestId(requester, IDENTIFIER, ancillaryData);
        assertEq(requestId, requestId2);
    }

    // ============ Upgrade Tests ============

    function test_AuthorizeUpgrade_RevertIfNotOwner() public {
        ManagedOptimisticOracleV2 newImplementation = new ManagedOptimisticOracleV2();
        
        vm.expectRevert(); // Expect any revert
        vm.prank(requestManager);
        // Try to call upgradeToAndCall through the proxy (this will trigger _authorizeUpgrade)
        address(oracle).call(
            abi.encodeWithSelector(
                bytes4(keccak256("upgradeToAndCall(address,bytes)")),
                address(newImplementation),
                ""
            )
        );
    }

    function test_AuthorizeUpgrade_Success() public {
        ManagedOptimisticOracleV2 newImplementation = new ManagedOptimisticOracleV2();
        
        vm.prank(admin);
        // Call upgradeToAndCall through the proxy (this will trigger _authorizeUpgrade)
        (bool success,) = address(oracle).call(
            abi.encodeWithSelector(
                bytes4(keccak256("upgradeToAndCall(address,bytes)")),
                address(newImplementation),
                ""
            )
        );
        require(success, "Upgrade should succeed");
        
        // Verify the upgrade was successful by checking that the contract still works
        assertEq(oracle.defaultLiveness(), DEFAULT_LIVENESS);
    }

    // ============ Multicall Tests ============

    function test_Multicall() public {
        bytes[] memory calls = new bytes[](2);
        
        // Call 1: Add request manager
        calls[0] = abi.encodeWithSelector(
            oracle.addRequestManager.selector,
            address(0x8)
        );
        
        // Call 2: Set maximum bond
        calls[1] = abi.encodeWithSelector(
            oracle.setMaximumBond.selector,
            currency,
            1500e18
        );
        
        vm.prank(admin);
        bytes[] memory results = oracle.multicall(calls);
        
        // Verify results
        assertTrue(oracle.hasRole(REQUEST_MANAGER_ROLE, address(0x8)));
        assertEq(oracle.maximumBonds(currency), 1500e18);
    }

    // ============ Edge Cases and Error Handling ============

    function test_RequestPriceWithZeroReward() public {
        bytes memory ancillaryData = "test data";
        
        vm.prank(requester);
        uint256 totalBond = oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            0 // Zero reward
        );
        
        assertEq(totalBond, TOTAL_BOND);
    }

    function test_RequestManagerSetBondWithZeroBond() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        vm.prank(requestManager);
        uint256 totalBond = oracle.requestManagerSetBond(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            0 // Zero bond
        );
        
        assertEq(totalBond, FINAL_FEE);
    }

    function test_RequestManagerSetCustomLivenessEqualToMinimum() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(
            requester,
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            MINIMUM_LIVENESS // Equal to minimum
        );
    }

    // ============ Gas Optimization Tests ============

    function test_GasOptimization_RepeatedCalls() public {
        bytes memory ancillaryData = "test data";
        
        // First request a price
        vm.prank(requester);
        oracle.requestPrice(
            IDENTIFIER,
            block.timestamp,
            ancillaryData,
            currency,
            REWARD
        );
        
        // Multiple bond updates should be efficient
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(requestManager);
            oracle.requestManagerSetBond(
                requester,
                IDENTIFIER,
                block.timestamp,
                ancillaryData,
                100e18 + i * 50e18
            );
        }
    }
} 