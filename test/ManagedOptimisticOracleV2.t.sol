// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {ManagedOptimisticOracleV2} from "src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {ManagedOptimisticOracleV2Interface} from
    "src/optimistic-oracle-v2/interfaces/ManagedOptimisticOracleV2Interface.sol";
import {OptimisticOracleV2Interface} from "src/optimistic-oracle-v2/interfaces/OptimisticOracleV2Interface.sol";

import {OracleInterfaces} from "@uma/contracts/data-verification-mechanism/implementation/Constants.sol";
import {IdentifierWhitelistInterface} from
    "@uma/contracts/data-verification-mechanism/interfaces/IdentifierWhitelistInterface.sol";
import {FinderInterface} from "@uma/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

import {AddressWhitelist} from "src/common/implementation/AddressWhitelist.sol";
import {DisabledAddressWhitelist} from "src/common/implementation/DisabledAddressWhitelist.sol";
import {AddressWhitelistInterface} from "src/common/interfaces/AddressWhitelistInterface.sol";
import {StoreInterface} from "src/data-verification-mechanism/interfaces/StoreInterface.sol";
import {FixedPointInterface} from "src/common/interfaces/FixedPointInterface.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Import shared mocks
import {MockStore} from "./mocks/MockStore.sol";
import {MockIdentifierWhitelist} from "./mocks/MockIdentifierWhitelist.sol";
import {MockFinder} from "./mocks/MockFinder.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract ManagedOptimisticOracleV2Test is Test {
    // Actors (assigned via makeAddr in setUp for clarity and determinism)
    address internal configAdmin;
    address internal upgradeAdmin;
    address internal resolverAdmin;
    address internal requestManager;
    address internal requester;
    address internal nonRequester;
    address internal proposer;
    address internal otherProposer;
    address internal sender;
    address internal otherSender;
    address internal resolver;
    address internal disputer;

    // Core contracts
    ManagedOptimisticOracleV2 internal moo;
    FinderInterface internal finder;
    AddressWhitelist internal collateralWhitelist;
    AddressWhitelist internal defaultProposerWhitelist;
    AddressWhitelist internal requesterWhitelist;
    DisabledAddressWhitelist internal disabledWhitelist;
    MockIdentifierWhitelist internal idWhitelist;
    MockStore internal store;
    MockOracle internal oracle;
    ERC20Mock internal currency;
    ERC20Mock internal otherCurrency;

    // Common constants
    bytes32 internal constant IDENTIFIER = keccak256("PRICE_ID");
    bytes internal constant ANCILLARY = bytes(":memo: test");
    uint256 internal constant DEFAULT_LIVENESS = 2 hours;
    uint256 internal constant MINIMUM_DISPUTE_WINDOW = 5 minutes;

    function setUp() public {
        // Addresses
        configAdmin = makeAddr("configAdmin");
        upgradeAdmin = makeAddr("upgradeAdmin");
        resolverAdmin = makeAddr("resolverAdmin");
        requestManager = makeAddr("requestManager");
        requester = makeAddr("requester");
        nonRequester = makeAddr("nonRequester");
        proposer = makeAddr("proposer");
        otherProposer = makeAddr("otherProposer");
        sender = makeAddr("sender");
        otherSender = makeAddr("otherSender");
        resolver = makeAddr("resolver");
        disputer = makeAddr("disputer");
        vm.label(configAdmin, "CONFIG_ADMIN");
        vm.label(upgradeAdmin, "UPGRADE_ADMIN");
        vm.label(resolverAdmin, "RESOLVER_ADMIN");
        vm.label(requestManager, "REQUEST_MANAGER");
        vm.label(requester, "REQUESTER");
        vm.label(nonRequester, "NON_REQUESTER");
        vm.label(proposer, "PROPOSER");
        vm.label(otherProposer, "OTHER_PROPOSER");
        vm.label(sender, "SENDER");
        vm.label(otherSender, "OTHER_SENDER");
        vm.label(resolver, "RESOLVER");
        vm.label(disputer, "DISPUTER");

        // Deploy infra and register in Finder
        finder = new MockFinder();

        collateralWhitelist = new AddressWhitelist();
        defaultProposerWhitelist = new AddressWhitelist();
        requesterWhitelist = new AddressWhitelist();
        disabledWhitelist = new DisabledAddressWhitelist();
        idWhitelist = new MockIdentifierWhitelist();
        store = new MockStore();
        oracle = new MockOracle();

        // Tokens
        currency = new ERC20Mock();
        otherCurrency = new ERC20Mock();

        // Collateral whitelist: allow `currency`, disallow `otherCurrency` initially
        collateralWhitelist.addToWhitelist(address(currency));

        // Identifier whitelist
        idWhitelist.addSupportedIdentifier(IDENTIFIER);

        // Register in Finder
        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateralWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(idWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.Oracle, address(oracle));

        // Set a final fee for currency
        store.setFinalFee(address(currency), 10 ether);

        // Proposer whitelist and Requester whitelist initial setup
        defaultProposerWhitelist.addToWhitelist(proposer);
        defaultProposerWhitelist.addToWhitelist(sender);
        requesterWhitelist.addToWhitelist(requester);

        // Deploy MOOv2 implementation and initialize behind proxy
        ManagedOptimisticOracleV2 impl = new ManagedOptimisticOracleV2();

        ManagedOptimisticOracleV2.CurrencyBondRange[] memory ranges =
            new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
        ranges[0] = ManagedOptimisticOracleV2.CurrencyBondRange({
            currency: IERC20(address(currency)),
            range: ManagedOptimisticOracleV2.BondRange({minimumBond: uint128(1 ether), maximumBond: uint128(1_000 ether)})
        });

        bytes memory initData = abi.encodeWithSelector(
            ManagedOptimisticOracleV2.initialize.selector,
            DEFAULT_LIVENESS,
            address(finder),
            address(defaultProposerWhitelist),
            address(requesterWhitelist),
            ranges,
            configAdmin,
            upgradeAdmin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        moo = ManagedOptimisticOracleV2(address(proxy));

        // V2 init
        vm.prank(upgradeAdmin);
        moo.initializeV2(MINIMUM_DISPUTE_WINDOW, resolverAdmin);

        // Grant request manager (by config admin)
        vm.prank(configAdmin);
        moo.addRequestManager(requestManager);

        // Grant resolver (by resolver admin)
        vm.prank(resolverAdmin);
        moo.addResolver(resolver);
    }

    // Read current time via moo.getCurrentTime() rather than block.timestamp to protect from via-ir reorderings (that
    // will break the tests).

    function _makeRequest(address _requester, uint256 _timestamp, uint256 reward)
        internal
        returns (uint256 totalBond)
    {
        vm.prank(_requester);
        currency.mint(_requester, reward);
        vm.prank(_requester);
        currency.approve(address(moo), type(uint256).max);
        vm.prank(_requester);
        return moo.requestPrice(IDENTIFIER, _timestamp, ANCILLARY, IERC20(address(currency)), reward);
    }

    function _proposeFor(address _msgSender, address _proposer, address _requester, uint256 _timestamp, int256 _price)
        internal
        returns (uint256)
    {
        // Give and approve funds to msg.sender to cover totalBond
        vm.prank(_msgSender);
        currency.mint(_msgSender, 10_000 ether);
        vm.prank(_msgSender);
        currency.approve(address(moo), type(uint256).max);
        vm.prank(_msgSender);
        return moo.proposePriceFor(_proposer, _requester, IDENTIFIER, _timestamp, ANCILLARY, _price);
    }

    function _dispute(address _disputer, address _requester, uint256 _timestamp) internal returns (uint256) {
        // Give and approve funds to _disputer to cover totalBond
        vm.startPrank(_disputer);
        currency.mint(_disputer, 10_000 ether);
        currency.approve(address(moo), type(uint256).max);
        uint256 result = moo.disputePrice(_requester, IDENTIFIER, _timestamp, ANCILLARY);
        vm.stopPrank();
        return result;
    }

    function _prepareFunds(address _msgSender) internal {
        vm.prank(_msgSender);
        currency.mint(_msgSender, 10_000 ether);
        vm.prank(_msgSender);
        currency.approve(address(moo), type(uint256).max);
    }

    // -------------------- Initialization & Roles --------------------

    function testInitializeSetsState() external {
        // default proposer whitelist
        (address[] memory list, bool enabled) =
            moo.getProposerWhitelistWithEnabledStatus(requester, IDENTIFIER, ANCILLARY);
        assertTrue(enabled);
        assertEq(list.length, 2);

        // requester whitelist enforced
        uint256 nowTs = moo.getCurrentTime();
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequesterNotWhitelisted.selector);
        moo.requestPrice(IDENTIFIER, nowTs, ANCILLARY, IERC20(address(currency)), 0);

        // role admin configuration
        bytes32 CONFIG_ADMIN_ROLE = moo.CONFIG_ADMIN_ROLE();
        bytes32 REQUEST_MANAGER_ROLE = moo.REQUEST_MANAGER_ROLE();
        bytes32 RESOLVER_ROLE = moo.RESOLVER_ROLE();
        bytes32 RESOLVER_ADMIN_ROLE = moo.RESOLVER_ADMIN_ROLE();
        assertTrue(moo.hasRole(CONFIG_ADMIN_ROLE, configAdmin));
        // request manager role uses config admin as its admin
        assertEq(moo.getRoleAdmin(REQUEST_MANAGER_ROLE), CONFIG_ADMIN_ROLE);
        // resolver role uses resolver admin as its admin
        assertEq(moo.getRoleAdmin(RESOLVER_ROLE), RESOLVER_ADMIN_ROLE);
        // minimumDisputeWindow is set
        assertEq(moo.minimumDisputeWindow(), MINIMUM_DISPUTE_WINDOW);
    }

    function testOnlyConfigAdminSetters() external {
        // setAllowedBondRange as non-admin -> revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setAllowedBondRange(IERC20(address(currency)), ManagedOptimisticOracleV2.BondRange(1, 2));

        // setMinimumDisputeWindow as non-admin -> revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setMinimumDisputeWindow(5 minutes);

        // setDefaultProposerWhitelist as non-admin -> revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setDefaultProposerWhitelist(address(defaultProposerWhitelist));

        // setRequesterWhitelist as non-admin -> revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setRequesterWhitelist(address(requesterWhitelist));
    }

    function testAddAndRemoveRequestManager() external {
        bytes32 REQUEST_MANAGER_ROLE = moo.REQUEST_MANAGER_ROLE();

        // Non-admin cannot add manager
        address newMgr = address(0x1234);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.addRequestManager(newMgr);

        // Admin adds
        vm.startPrank(configAdmin);
        vm.expectEmit(true, false, false, true);
        emit IAccessControl.RoleGranted(REQUEST_MANAGER_ROLE, newMgr, configAdmin);
        moo.addRequestManager(newMgr);
        vm.stopPrank();
        assertTrue(moo.hasRole(REQUEST_MANAGER_ROLE, newMgr));

        // Admin removes
        vm.startPrank(configAdmin);
        vm.expectEmit(true, false, false, true);
        emit IAccessControl.RoleRevoked(REQUEST_MANAGER_ROLE, newMgr, configAdmin);
        moo.removeRequestManager(newMgr);
        vm.stopPrank();
        assertFalse(moo.hasRole(REQUEST_MANAGER_ROLE, newMgr));
    }

    function testAddAndRemoveResolver() external {
        bytes32 RESOLVER_ROLE = moo.RESOLVER_ROLE();

        // Non-admin cannot add resolver
        address newResolver = address(0x1234);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.RESOLVER_ADMIN_ROLE()
            )
        );
        moo.addResolver(newResolver);

        // Config admin cannot add resolver (only resolver admin can)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, configAdmin, moo.RESOLVER_ADMIN_ROLE()
            )
        );
        vm.prank(configAdmin);
        moo.addResolver(newResolver);

        // Resolver admin adds
        vm.startPrank(resolverAdmin);
        vm.expectEmit(true, false, false, true);
        emit IAccessControl.RoleGranted(RESOLVER_ROLE, newResolver, resolverAdmin);
        moo.addResolver(newResolver);
        vm.stopPrank();
        assertTrue(moo.hasRole(RESOLVER_ROLE, newResolver));

        // Resolver admin removes
        vm.startPrank(resolverAdmin);
        vm.expectEmit(true, false, false, true);
        emit IAccessControl.RoleRevoked(RESOLVER_ROLE, newResolver, resolverAdmin);
        moo.removeResolver(newResolver);
        vm.stopPrank();
        assertFalse(moo.hasRole(RESOLVER_ROLE, newResolver));
    }

    // -------------------- Whitelist Management --------------------

    function testSetDefaultProposerWhitelistValidations() external {
        // Invalid whitelist should revert (does not support interface via ERC165)
        vm.prank(configAdmin);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.UnsupportedWhitelistInterface.selector);
        moo.setDefaultProposerWhitelist(address(currency));

        // Valid update
        AddressWhitelist wl = new AddressWhitelist();
        vm.prank(configAdmin);
        vm.expectEmit(true, false, false, true);
        emit ManagedOptimisticOracleV2Interface.DefaultProposerWhitelistUpdated(address(wl));
        moo.setDefaultProposerWhitelist(address(wl));
    }

    function testSetRequesterWhitelistValidations() external {
        // Invalid whitelist should revert
        vm.prank(configAdmin);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.UnsupportedWhitelistInterface.selector);
        moo.setRequesterWhitelist(address(currency));

        // Valid update
        AddressWhitelist wl = new AddressWhitelist();
        vm.prank(configAdmin);
        vm.expectEmit(true, false, false, true);
        emit ManagedOptimisticOracleV2Interface.RequesterWhitelistUpdated(address(wl));
        moo.setRequesterWhitelist(address(wl));
    }

    function testRequesterWhitelistEnforcedOnRequestPrice() external {
        // Non-whitelisted requester -> revert
        uint256 nowTs = moo.getCurrentTime();
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequesterNotWhitelisted.selector);
        moo.requestPrice(IDENTIFIER, nowTs, ANCILLARY, IERC20(address(currency)), 0);

        // Whitelisted requester -> ok
        uint256 totalBond = _makeRequest(requester, moo.getCurrentTime(), 0);
        // finalFee is 10 ether; initial bond = finalFee*2 per base contract
        assertEq(totalBond, 20 ether);
    }

    function testGetProposerWhitelistWithEnabledStatus() external {
        (address[] memory list, bool enabled) =
            moo.getProposerWhitelistWithEnabledStatus(requester, IDENTIFIER, ANCILLARY);
        assertTrue(enabled);
        assertEq(list.length, 2);

        // Set custom disabled whitelist for the request
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(disabledWhitelist));

        (list, enabled) = moo.getProposerWhitelistWithEnabledStatus(requester, IDENTIFIER, ANCILLARY);
        assertFalse(enabled);
        assertEq(list.length, 0);
    }

    function testGetCustomProposerWhitelist() external {
        // Not set yet -> zero address
        AddressWhitelistInterface wl = moo.getCustomProposerWhitelist(requester, IDENTIFIER, ANCILLARY);
        assertEq(address(wl), address(0));

        // Set -> observed
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(defaultProposerWhitelist));
        wl = moo.getCustomProposerWhitelist(requester, IDENTIFIER, ANCILLARY);
        assertEq(address(wl), address(defaultProposerWhitelist));
    }

    // -------------------- Propose Access Control --------------------

    function testProposePriceForChecksDefaultWhitelist() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        // Valid proposer and sender in default whitelist
        uint256 totalBond = _proposeFor(sender, proposer, requester, t, 42);
        assertGt(totalBond, 0);

        // Invalid proposer: create a new request for t+1 and use non-whitelisted proposer
        vm.warp(t + 1);
        _makeRequest(requester, moo.getCurrentTime(), 0);
        _prepareFunds(sender);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.ProposerNotWhitelisted.selector);
        vm.prank(sender);
        moo.proposePriceFor(otherProposer, requester, IDENTIFIER, t + 1, ANCILLARY, 1);

        // Invalid sender
        vm.warp(t + 2);
        _makeRequest(requester, moo.getCurrentTime(), 0);
        _prepareFunds(otherSender);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.SenderNotWhitelisted.selector);
        vm.prank(otherSender);
        moo.proposePriceFor(proposer, requester, IDENTIFIER, t + 2, ANCILLARY, 1);
    }

    function testProposePriceForWithCustomDisabledWhitelist() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        // Set disabled custom whitelist for this request
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(disabledWhitelist));

        // Neither proposer nor sender are in default whitelist now (use other addresses) -> should still pass
        address freeSender = makeAddr("freeSender");
        address freeProposer = makeAddr("freeProposer");
        uint256 totalBond = _proposeFor(freeSender, freeProposer, requester, t, 7);
        assertGt(totalBond, 0);
    }

    // -------------------- Settle Flow Tests -------------------------

    function testNonResolverCannotSettle() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        _proposeFor(sender, proposer, requester, t, 42);
        uint256 expirationTime = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).expirationTime;

        // Invalid resolver should not be able to settle at expiration
        vm.warp(expirationTime);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, otherSender, moo.RESOLVER_ROLE()
            )
        );
        vm.prank(otherSender);
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);
    }

    function testResolverCannotSettleBeforeExpiration() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        _proposeFor(sender, proposer, requester, t, 42);
        uint256 expirationTime = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).expirationTime;

        // Valid resolver should not be able to settle before expiration
        vm.warp(expirationTime - 1);
        vm.expectRevert(OptimisticOracleV2Interface.RequestNotSettleable.selector);
        vm.prank(resolver);
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);
    }

    function testResolverCanSettleAfterExpiration() external {
        uint256 t = moo.getCurrentTime();
        int256 price = 42;
        _makeRequest(requester, t, 0);

        _proposeFor(sender, proposer, requester, t, price);
        uint256 expirationTime = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).expirationTime;

        // Valid resolver should be able to settle at expiration
        vm.warp(expirationTime);
        vm.prank(resolver);
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(
            uint8(moo.getState(requester, IDENTIFIER, t, ANCILLARY)), uint8(OptimisticOracleV2Interface.State.Settled)
        );
        assertTrue(moo.hasPrice(requester, IDENTIFIER, t, ANCILLARY));
        vm.prank(requester);
        assertEq(moo.settleAndGetPrice(IDENTIFIER, t, ANCILLARY), price);
    }

    function testNoExpiredState() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        _proposeFor(sender, proposer, requester, t, 42);
        uint256 expirationTime = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).expirationTime;

        // Even if we warp past expiration the state should still be Proposed with no price available
        vm.warp(expirationTime + 1);
        assertEq(
            uint8(moo.getState(requester, IDENTIFIER, t, ANCILLARY)), uint8(OptimisticOracleV2Interface.State.Proposed)
        );
        assertFalse(moo.hasPrice(requester, IDENTIFIER, t, ANCILLARY));
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequestNotSettled.selector);
        vm.prank(requester);
        moo.settleAndGetPrice(IDENTIFIER, t, ANCILLARY);

        // Dispute should still be possible before the resolver has settled post-expiration
        _dispute(disputer, requester, t);
        assertEq(
            uint8(moo.getState(requester, IDENTIFIER, t, ANCILLARY)), uint8(OptimisticOracleV2Interface.State.Disputed)
        );
    }

    // -------------------- Bond Range Management --------------------

    function testSetAllowedBondRangeValidations() external {
        // Currency must be on collateral whitelist
        vm.prank(configAdmin);
        vm.expectRevert(OptimisticOracleV2Interface.UnsupportedCurrency.selector);
        moo.setAllowedBondRange(IERC20(address(otherCurrency)), ManagedOptimisticOracleV2.BondRange(1, 2));

        // Min cannot be greater than max
        vm.prank(configAdmin);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.MinimumBondAboveMaximumBond.selector);
        moo.setAllowedBondRange(IERC20(address(currency)), ManagedOptimisticOracleV2.BondRange(10, 5));
    }

    function testRequestManagerSetBondEnforcementAndEvents() external {
        // Non-manager cannot set
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.REQUEST_MANAGER_ROLE()
            )
        );
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 2 ether);

        // Manager can set within range
        vm.expectEmit(true, true, true, true);
        bytes32 managedId = moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY);
        emit ManagedOptimisticOracleV2Interface.CustomBondSet(
            managedId, requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 2 ether
        );
        vm.prank(requestManager);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 2 ether);

        // Zero bond not allowed
        vm.prank(requestManager);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.ZeroBondNotAllowed.selector);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 0);

        // Below min
        vm.prank(requestManager);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.BondBelowMinimumBond.selector);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 0.5 ether);

        // Above max
        vm.prank(requestManager);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.BondExceedsMaximumBond.selector);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 2_000 ether);

        // If range not configured for other currency (min=max=0), any non-zero should revert (exceeds max)
        vm.prank(requestManager);
        vm.expectRevert(OptimisticOracleV2Interface.UnsupportedCurrency.selector);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(otherCurrency)), 1);
    }

    function testCustomBondAppliedOnPropose() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        // Set custom bond of 5 ether
        vm.prank(requestManager);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 5 ether);

        // Propose and verify total bond = custom bond + final fee (10 ether)
        uint256 totalBond = _proposeFor(sender, proposer, requester, t, 100);
        assertEq(totalBond, 15 ether);

        // Also read back the request and check bond updated
        OptimisticOracleV2Interface.Request memory req = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(req.requestSettings.bond, 5 ether);
    }

    // -------------------- Reward Management --------------------

    function testRequesterSetRewardUpdatesDeltaAndAllowsZero() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 10 ether);
        currency.mint(requester, 10 ether);

        vm.prank(nonRequester);
        vm.expectRevert(OptimisticOracleV2Interface.RequestStateNotRequested.selector);
        moo.setReward(IDENTIFIER, t, ANCILLARY, 1 ether);

        uint256 requesterBalance = currency.balanceOf(requester);
        uint256 oracleBalance = currency.balanceOf(address(moo));
        vm.expectEmit(true, false, false, true);
        emit OptimisticOracleV2Interface.RewardUpdated(
            requester, IDENTIFIER, t, ANCILLARY, requester, 10 ether, 15 ether
        );
        vm.prank(requester);
        moo.setReward(IDENTIFIER, t, ANCILLARY, 15 ether);
        assertEq(currency.balanceOf(requester), requesterBalance - 5 ether);
        assertEq(currency.balanceOf(address(moo)), oracleBalance + 5 ether);

        requesterBalance = currency.balanceOf(requester);
        oracleBalance = currency.balanceOf(address(moo));
        vm.prank(requester);
        moo.setReward(IDENTIFIER, t, ANCILLARY, 4 ether);
        assertEq(currency.balanceOf(requester), requesterBalance + 11 ether);
        assertEq(currency.balanceOf(address(moo)), oracleBalance - 11 ether);

        vm.prank(requester);
        moo.setReward(IDENTIFIER, t, ANCILLARY, 0);
        assertEq(moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).reward, 0);
        assertEq(
            uint8(moo.getState(requester, IDENTIFIER, t, ANCILLARY)), uint8(OptimisticOracleV2Interface.State.Requested)
        );

        _proposeFor(sender, proposer, requester, t, 42);
        assertEq(
            uint8(moo.getState(requester, IDENTIFIER, t, ANCILLARY)), uint8(OptimisticOracleV2Interface.State.Proposed)
        );
    }

    function testRequestManagerSetRewardUsesCallerFundsAndRefundsRequester() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 10 ether);
        currency.mint(requester, 100 ether);
        _prepareFunds(requestManager);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.REQUEST_MANAGER_ROLE()
            )
        );
        moo.requestManagerSetReward(requester, IDENTIFIER, t, ANCILLARY, 11 ether);

        vm.prank(requestManager);
        vm.expectRevert(OptimisticOracleV2Interface.RequestStateNotRequested.selector);
        moo.requestManagerSetReward(requester, IDENTIFIER, t + 1, ANCILLARY, 11 ether);

        uint256 requesterBalance = currency.balanceOf(requester);
        uint256 managerBalance = currency.balanceOf(requestManager);
        uint256 oracleBalance = currency.balanceOf(address(moo));
        vm.expectEmit(true, false, false, true);
        emit OptimisticOracleV2Interface.RewardUpdated(
            requester, IDENTIFIER, t, ANCILLARY, requestManager, 10 ether, 16 ether
        );
        vm.prank(requestManager);
        moo.requestManagerSetReward(requester, IDENTIFIER, t, ANCILLARY, 16 ether);
        assertEq(currency.balanceOf(requester), requesterBalance);
        assertEq(currency.balanceOf(requestManager), managerBalance - 6 ether);
        assertEq(currency.balanceOf(address(moo)), oracleBalance + 6 ether);

        requesterBalance = currency.balanceOf(requester);
        managerBalance = currency.balanceOf(requestManager);
        oracleBalance = currency.balanceOf(address(moo));
        vm.prank(requestManager);
        moo.requestManagerSetReward(requester, IDENTIFIER, t, ANCILLARY, 4 ether);
        assertEq(currency.balanceOf(requester), requesterBalance + 12 ether);
        assertEq(currency.balanceOf(requestManager), managerBalance);
        assertEq(currency.balanceOf(address(moo)), oracleBalance - 12 ether);

        vm.prank(requestManager);
        moo.requestManagerSetReward(requester, IDENTIFIER, t, ANCILLARY, 0);
        assertEq(moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).reward, 0);
        assertEq(currency.balanceOf(requestManager), managerBalance);
        assertEq(currency.balanceOf(requester), requesterBalance + 16 ether);
    }

    function testRewardUpdatesRevertAfterProposal() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 1 ether);
        _proposeFor(sender, proposer, requester, t, 42);

        vm.prank(requester);
        vm.expectRevert(OptimisticOracleV2Interface.RequestStateNotRequested.selector);
        moo.setReward(IDENTIFIER, t, ANCILLARY, 0);

        vm.prank(requestManager);
        vm.expectRevert(OptimisticOracleV2Interface.RequestStateNotRequested.selector);
        moo.requestManagerSetReward(requester, IDENTIFIER, t, ANCILLARY, 0);
    }

    // -------------------- Liveness Management --------------------

    function testSetMinimumDisputeWindowAndValidation() external {
        // Only config admin
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setMinimumDisputeWindow(MINIMUM_DISPUTE_WINDOW);

        // Invalid values
        vm.prank(configAdmin);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.MinimumDisputeWindowTooSmall.selector);
        moo.setMinimumDisputeWindow(MINIMUM_DISPUTE_WINDOW - 1);

        vm.prank(configAdmin);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.MinimumDisputeWindowTooLarge.selector);
        moo.setMinimumDisputeWindow(DEFAULT_LIVENESS + 1);

        // Valid update
        vm.prank(configAdmin);
        moo.setMinimumDisputeWindow(MINIMUM_DISPUTE_WINDOW);
        assertEq(moo.minimumDisputeWindow(), MINIMUM_DISPUTE_WINDOW);
    }

    function testSetDefaultLivenessAndValidation() external {
        // Only config admin can call
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setDefaultLiveness(1 hours);

        // Below minimumDisputeWindow -> revert
        vm.prank(configAdmin);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.LivenessTooLow.selector);
        moo.setDefaultLiveness(MINIMUM_DISPUTE_WINDOW - 1);

        // Above max liveness -> revert
        vm.prank(configAdmin);
        vm.expectRevert(OptimisticOracleV2Interface.LivenessTooLarge.selector);
        moo.setDefaultLiveness(5200 weeks);

        // Valid update and event emission
        uint256 newDefaultLiveness = 3 hours;
        vm.expectEmit(true, true, true, true);
        emit ManagedOptimisticOracleV2Interface.DefaultLivenessUpdated(newDefaultLiveness);

        vm.prank(configAdmin);
        moo.setDefaultLiveness(newDefaultLiveness);
        assertEq(moo.defaultLiveness(), newDefaultLiveness);
    }

    function testSetDefaultLivenessAppliedToNewRequests() external {
        // Set a new default liveness
        uint256 newDefaultLiveness = 3 hours;
        vm.prank(configAdmin);
        moo.setDefaultLiveness(newDefaultLiveness);

        // Create a request without custom liveness
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        // Propose and check that new default liveness is applied
        vm.warp(t + 10);
        _proposeFor(sender, proposer, requester, t, 123);

        OptimisticOracleV2Interface.Request memory req = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(req.expirationTime, moo.getCurrentTime() + newDefaultLiveness);
    }

    function testSetDefaultLivenessRequiresLoweringMinimumDisputeWindowFirst() external {
        // First set minimum dispute window to 30 minutes
        vm.prank(configAdmin);
        moo.setMinimumDisputeWindow(30 minutes);

        // Try to set default liveness lower than minimum dispute window -> should fail
        vm.prank(configAdmin);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.LivenessTooLow.selector);
        moo.setDefaultLiveness(20 minutes);

        // Lower minimum dispute window first
        vm.prank(configAdmin);
        moo.setMinimumDisputeWindow(15 minutes);

        // Now setting defaultLiveness to 20 minutes should work
        vm.prank(configAdmin);
        moo.setDefaultLiveness(20 minutes);
        assertEq(moo.defaultLiveness(), 20 minutes);
    }

    function testRequestManagerSetCustomLivenessValidationAndEffect() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        // Below minimum -> revert
        vm.prank(requestManager);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.LivenessTooLow.selector);
        moo.requestManagerSetCustomLiveness(requester, IDENTIFIER, ANCILLARY, 1);

        // Above base max -> revert
        vm.prank(requestManager);
        vm.expectRevert(OptimisticOracleV2Interface.LivenessTooLarge.selector);
        moo.requestManagerSetCustomLiveness(requester, IDENTIFIER, ANCILLARY, 5200 weeks);

        // Valid set and event
        vm.expectEmit(true, true, true, true);
        bytes32 managedId = moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY);
        emit ManagedOptimisticOracleV2Interface.CustomLivenessSet(managedId, requester, IDENTIFIER, ANCILLARY, 3 hours);
        vm.prank(requestManager);
        moo.requestManagerSetCustomLiveness(requester, IDENTIFIER, ANCILLARY, 3 hours);

        // Propose and check expiration time = now + 3 hours
        vm.warp(t + 10);
        _proposeFor(sender, proposer, requester, t, 123);
        OptimisticOracleV2Interface.Request memory req = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(req.expirationTime, moo.getCurrentTime() + 3 hours);
    }

    function testRequesterSetCustomLivenessValidation() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        // Below minimum -> revert
        vm.prank(requester);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.LivenessTooLow.selector);
        moo.setCustomLiveness(IDENTIFIER, t, ANCILLARY, 1);

        // Above base max -> revert
        vm.prank(requester);
        vm.expectRevert(OptimisticOracleV2Interface.LivenessTooLarge.selector);
        moo.setCustomLiveness(IDENTIFIER, t, ANCILLARY, 5200 weeks);

        // Valid set at minimum dispute window
        vm.prank(requester);
        moo.setCustomLiveness(IDENTIFIER, t, ANCILLARY, MINIMUM_DISPUTE_WINDOW);

        // Propose and check expiration time = now + MINIMUM_DISPUTE_WINDOW
        vm.warp(t + 10);
        _proposeFor(sender, proposer, requester, t, 123);
        OptimisticOracleV2Interface.Request memory req = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(req.expirationTime, moo.getCurrentTime() + MINIMUM_DISPUTE_WINDOW);
    }

    // -------------------- Utility --------------------

    function testGetManagedRequestId() external view {
        bytes32 id1 = moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY);
        bytes32 id2 = keccak256(abi.encodePacked(requester, IDENTIFIER, ANCILLARY));
        assertEq(id1, id2);
    }

    // -------------------- Request Rules Updates --------------------

    function testUpdateRequestRulesStoresAndEmits() external {
        bytes memory firstRules = bytes("first rules update");
        bytes memory secondRules = bytes("second rules update");
        bytes32 managedId = moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY);

        vm.expectEmit(true, true, false, true);
        emit ManagedOptimisticOracleV2Interface.RequestRulesUpdated(
            managedId, requester, IDENTIFIER, ANCILLARY, firstRules
        );
        vm.prank(requester);
        moo.updateRequestRules(IDENTIFIER, ANCILLARY, firstRules);

        vm.warp(moo.getCurrentTime() + 10);
        vm.prank(requester);
        moo.updateRequestRules(IDENTIFIER, ANCILLARY, secondRules);

        ManagedOptimisticOracleV2.RequestRulesUpdate[] memory updates =
            moo.getRequestRulesUpdates(requester, IDENTIFIER, ANCILLARY);
        assertEq(updates.length, 2);
        assertEq(updates[0].updatedRules, firstRules);
        assertEq(updates[1].updatedRules, secondRules);

        ManagedOptimisticOracleV2.RequestRulesUpdate memory latest =
            moo.getLatestRequestRulesUpdate(requester, IDENTIFIER, ANCILLARY);
        assertEq(latest.timestamp, moo.getCurrentTime());
        assertEq(latest.updatedRules, secondRules);
    }

    function testUpdateRequestRulesAllowedBeforeRequestExists() external {
        // No requestPrice has been made yet; like other manager settings, updates may be pre-configured.
        bytes memory rules = bytes("pre-config rules");
        vm.prank(requester);
        moo.updateRequestRules(IDENTIFIER, ANCILLARY, rules);

        ManagedOptimisticOracleV2.RequestRulesUpdate memory latest =
            moo.getLatestRequestRulesUpdate(requester, IDENTIFIER, ANCILLARY);
        assertEq(latest.updatedRules, rules);
    }

    function testUpdateRequestRulesOnlyWhitelistedRequester() external {
        vm.prank(nonRequester);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequesterNotWhitelisted.selector);
        moo.updateRequestRules(IDENTIFIER, ANCILLARY, bytes("rules"));
    }

    function testGetLatestRequestRulesUpdateRevertsWhenEmpty() external {
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequestRulesUpdateUnavailable.selector);
        moo.getLatestRequestRulesUpdate(requester, IDENTIFIER, ANCILLARY);
    }

    // -------------------- Ownership / Control Relationships --------------------

    function testRolesAndOwnershipRelations() external view {
        // UPGRADE_ADMIN_ROLE must equal DEFAULT_ADMIN_ROLE
        assertEq(moo.UPGRADE_ADMIN_ROLE(), moo.DEFAULT_ADMIN_ROLE());

        // upgradeAdmin holds default admin role; configAdmin doesn't
        assertTrue(moo.hasRole(moo.DEFAULT_ADMIN_ROLE(), upgradeAdmin));
        assertFalse(moo.hasRole(moo.DEFAULT_ADMIN_ROLE(), configAdmin));

        // CONFIG_ADMIN_ROLE is administered by DEFAULT_ADMIN_ROLE
        assertEq(moo.getRoleAdmin(moo.CONFIG_ADMIN_ROLE()), moo.DEFAULT_ADMIN_ROLE());

        // REQUEST_MANAGER_ROLE is administered by CONFIG_ADMIN_ROLE (already tested elsewhere but double-check)
        assertEq(moo.getRoleAdmin(moo.REQUEST_MANAGER_ROLE()), moo.CONFIG_ADMIN_ROLE());
        // RESOLVER_ROLE is administered by RESOLVER_ADMIN_ROLE
        assertEq(moo.getRoleAdmin(moo.RESOLVER_ROLE()), moo.RESOLVER_ADMIN_ROLE());
        // RESOLVER_ADMIN_ROLE is self-governing (administered by itself)
        assertEq(moo.getRoleAdmin(moo.RESOLVER_ADMIN_ROLE()), moo.RESOLVER_ADMIN_ROLE());
    }

    function testDefaultAdminManagesConfigAdminRole() external {
        address newConfig = makeAddr("newConfigAdmin");
        // DEFAULT_ADMIN can grant CONFIG_ADMIN_ROLE
        vm.startPrank(upgradeAdmin);
        moo.grantRole(moo.CONFIG_ADMIN_ROLE(), newConfig);
        // DEFAULT_ADMIN can revoke CONFIG_ADMIN_ROLE
        moo.revokeRole(moo.CONFIG_ADMIN_ROLE(), configAdmin);
        vm.stopPrank();
        assertTrue(moo.hasRole(moo.CONFIG_ADMIN_ROLE(), newConfig));
        assertFalse(moo.hasRole(moo.CONFIG_ADMIN_ROLE(), configAdmin));
    }

    function testResolverAdminRoleIsSelfGoverning() external {
        address newResolverAdmin = makeAddr("newResolverAdmin");
        bytes32 resolverAdminRole = moo.RESOLVER_ADMIN_ROLE();

        // RESOLVER_ADMIN_ROLE is self-governing, so DEFAULT_ADMIN cannot manage it
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, upgradeAdmin, resolverAdminRole
            )
        );
        vm.prank(upgradeAdmin);
        moo.grantRole(resolverAdminRole, newResolverAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, upgradeAdmin, resolverAdminRole
            )
        );
        vm.prank(upgradeAdmin);
        moo.revokeRole(resolverAdminRole, resolverAdmin);

        // But RESOLVER_ADMIN can grant and revoke RESOLVER_ADMIN_ROLE
        vm.startPrank(resolverAdmin);
        moo.grantRole(resolverAdminRole, newResolverAdmin);
        assertTrue(moo.hasRole(resolverAdminRole, newResolverAdmin));
        moo.revokeRole(resolverAdminRole, newResolverAdmin);
        assertFalse(moo.hasRole(resolverAdminRole, newResolverAdmin));
        vm.stopPrank();
    }

    function testConfigAdminCannotManageResolvers() external {
        address newResolver = makeAddr("newResolver");
        // Config admin cannot add resolver (only resolver admin can)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, configAdmin, moo.RESOLVER_ADMIN_ROLE()
            )
        );
        vm.prank(configAdmin);
        moo.addResolver(newResolver);

        // Config admin cannot remove resolver (only resolver admin can)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, configAdmin, moo.RESOLVER_ADMIN_ROLE()
            )
        );
        vm.prank(configAdmin);
        moo.removeResolver(resolver);
    }

    function testUpgradeAuthorization() external {
        // Non-upgrade admin cannot upgrade
        ManagedOptimisticOracleV2 impl2 = new ManagedOptimisticOracleV2();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.DEFAULT_ADMIN_ROLE()
            )
        );
        moo.upgradeToAndCall(address(impl2), "");

        // Upgrade admin can upgrade
        uint256 prevMinDisputeWindow = moo.minimumDisputeWindow();
        uint256 prevDefaultLiveness = moo.defaultLiveness();
        vm.prank(upgradeAdmin);
        moo.upgradeToAndCall(address(impl2), "");
        // State preserved
        assertEq(moo.minimumDisputeWindow(), prevMinDisputeWindow);
        assertEq(moo.defaultLiveness(), prevDefaultLiveness);
    }

    function testUpgradeAdminCannotCallConfigSetters() external {
        // DEFAULT_ADMIN (upgrade admin) cannot call config-admin-only functions
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, upgradeAdmin, moo.CONFIG_ADMIN_ROLE()
            )
        );
        vm.prank(upgradeAdmin);
        moo.setMinimumDisputeWindow(1 hours);
    }

    // -------------------- Additional Events & Validations --------------------

    function testRequestManagerSetProposerWhitelistValidationsAndEvent() external {
        // Invalid interface (non-whitelist) should revert; zero allowed
        vm.prank(requestManager);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.UnsupportedWhitelistInterface.selector);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(currency));

        // Event on set
        vm.expectEmit(true, true, false, true);
        bytes32 managedId = moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY);
        emit ManagedOptimisticOracleV2Interface.CustomProposerWhitelistSet(
            managedId, requester, IDENTIFIER, ANCILLARY, address(disabledWhitelist)
        );
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(disabledWhitelist));
    }

    function testResetCustomProposerWhitelistToDefault() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);

        // A real enabled whitelist with no members pauses proposals.
        AddressWhitelist emptyWhitelist = new AddressWhitelist();
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(emptyWhitelist));
        _prepareFunds(sender);
        vm.prank(sender);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.ProposerNotWhitelisted.selector);
        moo.proposePriceFor(proposer, requester, IDENTIFIER, t, ANCILLARY, 7);
        assertEq(
            uint8(moo.getState(requester, IDENTIFIER, t, ANCILLARY)), uint8(OptimisticOracleV2Interface.State.Requested)
        );

        // Zero restores the default whitelist rather than cancelling the request.
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(0));
        _proposeFor(sender, proposer, requester, t, 7);
        assertEq(
            uint8(moo.getState(requester, IDENTIFIER, t, ANCILLARY)), uint8(OptimisticOracleV2Interface.State.Proposed)
        );
    }

    function testAllowedBondRangeEventAndBehavior() external {
        // Event on set
        vm.prank(configAdmin);
        vm.expectEmit(true, false, false, true);
        emit ManagedOptimisticOracleV2Interface.AllowedBondRangeUpdated(IERC20(address(currency)), 2 ether, 3 ether);
        moo.setAllowedBondRange(IERC20(address(currency)), ManagedOptimisticOracleV2.BondRange(2 ether, 3 ether));
    }

    function testMinimumDisputeWindowEvent() external {
        vm.prank(configAdmin);
        vm.expectEmit(false, false, false, true);
        emit ManagedOptimisticOracleV2Interface.MinimumDisputeWindowUpdated(10 minutes);
        moo.setMinimumDisputeWindow(10 minutes);
    }

    function testBondOverrideBlockedForWhitelistedButUnconfiguredCurrency() external {
        // Add otherCurrency to collateral whitelist but do not set allowedBondRange
        collateralWhitelist.addToWhitelist(address(otherCurrency));

        // Manager attempts to set bond > 0 should fail as max allowed defaults to 0
        vm.prank(requestManager);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.BondExceedsMaximumBond.selector);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(otherCurrency)), 1);
    }

    function testRemovedRequestManagerCannotCall() external {
        address tempMgr = makeAddr("tempMgr");
        // Add then remove
        vm.startPrank(configAdmin);
        moo.addRequestManager(tempMgr);
        moo.removeRequestManager(tempMgr);
        vm.stopPrank();
        // Now calls must revert
        vm.startPrank(tempMgr);
        vm.expectRevert();
        moo.requestManagerSetCustomLiveness(requester, IDENTIFIER, ANCILLARY, 2 hours);
        vm.stopPrank();
    }

    function testOracleRequestTimeEventBasedDispute() external {
        uint256 t = moo.getCurrentTime();
        _makeRequest(requester, t, 0);
        vm.prank(requester);
        moo.setEventBased(IDENTIFIER, t, ANCILLARY);

        uint256 proposalTime = t + 3600;
        vm.warp(proposalTime);
        _proposeFor(sender, proposer, requester, t, 42);
        assertEq(moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).proposalTime, proposalTime);

        // Dispute should result in Oracle price request with proposal timestamp
        vm.expectCall(
            address(oracle),
            abi.encodeWithSelector(
                MockOracle.requestPrice.selector, IDENTIFIER, proposalTime, moo.stampAncillaryData(ANCILLARY, requester)
            )
        );
        _dispute(disputer, requester, t);
    }

    function testMulticallPreservesCustomErrors() external {
        // Test that multicall properly bubbles custom errors instead of corrupting them
        uint256 t = moo.getCurrentTime();

        // Create a multicall that should revert with RequesterNotWhitelisted()
        bytes[] memory calls = new bytes[](1);
        calls[0] =
            abi.encodeWithSelector(moo.requestPrice.selector, IDENTIFIER, t, ANCILLARY, IERC20(address(currency)), 0);

        // nonRequester is not whitelisted, so this should revert with RequesterNotWhitelisted()
        vm.prank(nonRequester);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequesterNotWhitelisted.selector);
        moo.multicall(calls);
    }
}
