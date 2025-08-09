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

contract MockStore is StoreInterface {
    mapping(address => uint256) public finalFeeByCurrency;

    function setFinalFee(address currency, uint256 amount) external {
        finalFeeByCurrency[currency] = amount;
    }

    function payOracleFees() external payable {}

    function payOracleFeesErc20(address, /*erc20Address*/ FixedPointInterface.Unsigned calldata /*amount*/ ) external {}

    function computeRegularFee(uint256, uint256, FixedPointInterface.Unsigned calldata)
        external
        pure
        returns (FixedPointInterface.Unsigned memory regularFee, FixedPointInterface.Unsigned memory latePenalty)
    {
        regularFee = FixedPointInterface.Unsigned({rawValue: 0});
        latePenalty = FixedPointInterface.Unsigned({rawValue: 0});
    }

    function computeFinalFee(address currency) external view returns (FixedPointInterface.Unsigned memory) {
        return FixedPointInterface.Unsigned({rawValue: finalFeeByCurrency[currency]});
    }
}

contract MockIdentifierWhitelist is IdentifierWhitelistInterface {
    mapping(bytes32 => bool) public supported;

    function addSupportedIdentifier(bytes32 identifier) external override {
        supported[identifier] = true;
    }

    function removeSupportedIdentifier(bytes32 identifier) external override {
        supported[identifier] = false;
    }

    function isIdentifierSupported(bytes32 identifier) external view override returns (bool) {
        return supported[identifier];
    }
}

contract MockFinder is FinderInterface {
    mapping(bytes32 => address) public interfacesImplemented;

    function changeImplementationAddress(bytes32 interfaceName, address implementationAddress) external override {
        interfacesImplemented[interfaceName] = implementationAddress;
    }

    function getImplementationAddress(bytes32 interfaceName) external view override returns (address) {
        address implementationAddress = interfacesImplemented[interfaceName];
        require(implementationAddress != address(0), "Implementation not found");
        return implementationAddress;
    }
}

contract ManagedOptimisticOracleV2Test is Test {
    // Actors (assigned via makeAddr in setUp for clarity and determinism)
    address internal configAdmin;
    address internal upgradeAdmin;
    address internal requestManager;
    address internal requester;
    address internal nonRequester;
    address internal proposer;
    address internal otherProposer;
    address internal sender;
    address internal otherSender;

    // Core contracts
    ManagedOptimisticOracleV2 internal moo;
    FinderInterface internal finder;
    AddressWhitelist internal collateralWhitelist;
    AddressWhitelist internal defaultProposerWhitelist;
    AddressWhitelist internal requesterWhitelist;
    DisabledAddressWhitelist internal disabledWhitelist;
    MockIdentifierWhitelist internal idWhitelist;
    MockStore internal store;
    ERC20Mock internal currency;
    ERC20Mock internal otherCurrency;

    // Common constants
    bytes32 internal constant IDENTIFIER = keccak256("PRICE_ID");
    bytes internal constant ANCILLARY = bytes(":memo: test");

    function setUp() public {
        // Addresses
        configAdmin = makeAddr("configAdmin");
        upgradeAdmin = makeAddr("upgradeAdmin");
        requestManager = makeAddr("requestManager");
        requester = makeAddr("requester");
        nonRequester = makeAddr("nonRequester");
        proposer = makeAddr("proposer");
        otherProposer = makeAddr("otherProposer");
        sender = makeAddr("sender");
        otherSender = makeAddr("otherSender");
        vm.label(configAdmin, "CONFIG_ADMIN");
        vm.label(upgradeAdmin, "UPGRADE_ADMIN");
        vm.label(requestManager, "REQUEST_MANAGER");
        vm.label(requester, "REQUESTER");
        vm.label(nonRequester, "NON_REQUESTER");
        vm.label(proposer, "PROPOSER");
        vm.label(otherProposer, "OTHER_PROPOSER");
        vm.label(sender, "SENDER");
        vm.label(otherSender, "OTHER_SENDER");

        // Deploy infra and register in Finder
        finder = new MockFinder();

        collateralWhitelist = new AddressWhitelist();
        defaultProposerWhitelist = new AddressWhitelist();
        requesterWhitelist = new AddressWhitelist();
        disabledWhitelist = new DisabledAddressWhitelist();
        idWhitelist = new MockIdentifierWhitelist();
        store = new MockStore();

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
            2 days,
            address(finder),
            address(defaultProposerWhitelist),
            address(requesterWhitelist),
            ranges,
            1 hours,
            configAdmin,
            upgradeAdmin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        moo = ManagedOptimisticOracleV2(address(proxy));

        // Grant request manager
        vm.startPrank(configAdmin);
        moo.addRequestManager(requestManager);
        vm.stopPrank();
    }

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
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequesterNotWhitelisted.selector);
        moo.requestPrice(IDENTIFIER, block.timestamp, ANCILLARY, IERC20(address(currency)), 0);

        // role admin configuration
        bytes32 CONFIG_ADMIN_ROLE = moo.CONFIG_ADMIN_ROLE();
        bytes32 REQUEST_MANAGER_ROLE = moo.REQUEST_MANAGER_ROLE();
        assertTrue(moo.hasRole(CONFIG_ADMIN_ROLE, configAdmin));
        // request manager role uses config admin as its admin
        assertEq(moo.getRoleAdmin(REQUEST_MANAGER_ROLE), CONFIG_ADMIN_ROLE);
    }

    function testOnlyConfigAdminSetters() external {
        // setAllowedBondRange as non-admin -> revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setAllowedBondRange(IERC20(address(currency)), ManagedOptimisticOracleV2.BondRange(1, 2));

        // setMinimumLiveness as non-admin -> revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setMinimumLiveness(1);

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
        emit ManagedOptimisticOracleV2Interface.RequestManagerAdded(newMgr);
        moo.addRequestManager(newMgr);
        vm.stopPrank();
        assertTrue(moo.hasRole(REQUEST_MANAGER_ROLE, newMgr));

        // Admin removes
        vm.startPrank(configAdmin);
        vm.expectEmit(true, false, false, true);
        emit ManagedOptimisticOracleV2Interface.RequestManagerRemoved(newMgr);
        moo.removeRequestManager(newMgr);
        vm.stopPrank();
        assertFalse(moo.hasRole(REQUEST_MANAGER_ROLE, newMgr));
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
        vm.expectRevert(ManagedOptimisticOracleV2Interface.RequesterNotWhitelisted.selector);
        moo.requestPrice(IDENTIFIER, block.timestamp, ANCILLARY, IERC20(address(currency)), 0);

        // Whitelisted requester -> ok
        uint256 totalBond = _makeRequest(requester, block.timestamp, 0);
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
        uint256 t = block.timestamp;
        _makeRequest(requester, t, 0);

        // Valid proposer and sender in default whitelist
        uint256 totalBond = _proposeFor(sender, proposer, requester, t, 42);
        assertGt(totalBond, 0);

        // Invalid proposer: create a new request for t+1 and use non-whitelisted proposer
        vm.warp(t + 1);
        _makeRequest(requester, block.timestamp, 0);
        _prepareFunds(sender);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.ProposerNotWhitelisted.selector);
        vm.prank(sender);
        moo.proposePriceFor(otherProposer, requester, IDENTIFIER, t + 1, ANCILLARY, 1);

        // Invalid sender
        vm.warp(t + 2);
        _makeRequest(requester, block.timestamp, 0);
        _prepareFunds(otherSender);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.SenderNotWhitelisted.selector);
        vm.prank(otherSender);
        moo.proposePriceFor(proposer, requester, IDENTIFIER, t + 2, ANCILLARY, 1);
    }

    function testProposePriceForWithCustomDisabledWhitelist() external {
        uint256 t = block.timestamp;
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
        uint256 t = block.timestamp;
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

    // -------------------- Liveness Management --------------------

    function testSetMinimumLivenessAndValidation() external {
        // Only config admin
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), moo.CONFIG_ADMIN_ROLE()
            )
        );
        moo.setMinimumLiveness(2 hours);

        // Invalid values
        vm.prank(configAdmin);
        vm.expectRevert(OptimisticOracleV2Interface.LivenessCannotBeZero.selector);
        moo.setMinimumLiveness(0);

        vm.prank(configAdmin);
        vm.expectRevert(OptimisticOracleV2Interface.LivenessTooLarge.selector);
        moo.setMinimumLiveness(type(uint256).max);

        // Valid update
        vm.prank(configAdmin);
        moo.setMinimumLiveness(6 hours);
        assertEq(moo.minimumLiveness(), 6 hours);
    }

    function testRequestManagerSetCustomLivenessValidationAndEffect() external {
        uint256 t = block.timestamp;
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
        assertEq(req.expirationTime, block.timestamp + 3 hours);
    }

    // -------------------- Utility --------------------

    function testGetManagedRequestId() external view {
        bytes32 id1 = moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY);
        bytes32 id2 = keccak256(abi.encodePacked(requester, IDENTIFIER, ANCILLARY));
        assertEq(id1, id2);
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
        uint256 prevMinLiveness = moo.minimumLiveness();
        vm.prank(upgradeAdmin);
        moo.upgradeToAndCall(address(impl2), "");
        // State preserved
        assertEq(moo.minimumLiveness(), prevMinLiveness);
        assertEq(moo.defaultLiveness(), 2 days);
    }

    function testUpgradeAdminCannotCallConfigSetters() external {
        // DEFAULT_ADMIN (upgrade admin) cannot call config-admin-only functions
        vm.expectRevert();
        vm.prank(upgradeAdmin);
        moo.setMinimumLiveness(4 hours);
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
        uint256 t = block.timestamp;
        _makeRequest(requester, t, 0);

        // Disable whitelist per-request
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(disabledWhitelist));

        // Any addresses can propose
        address freeSender = makeAddr("freeSender");
        address freeProposer = makeAddr("freeProposer");
        _proposeFor(freeSender, freeProposer, requester, t, 7);

        // Reset to default by setting zero address
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(0));

        // Now free addresses should be blocked by default whitelist (first check proposer)
        vm.prank(freeSender);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.ProposerNotWhitelisted.selector);
        moo.proposePriceFor(freeProposer, requester, IDENTIFIER, t + 1, ANCILLARY, 1);
    }

    function testAllowedBondRangeEventAndBehavior() external {
        // Event on set
        vm.prank(configAdmin);
        vm.expectEmit(true, false, false, true);
        emit ManagedOptimisticOracleV2Interface.AllowedBondRangeUpdated(IERC20(address(currency)), 2 ether, 3 ether);
        moo.setAllowedBondRange(IERC20(address(currency)), ManagedOptimisticOracleV2.BondRange(2 ether, 3 ether));
    }

    function testMinimumLivenessEvent() external {
        vm.prank(configAdmin);
        vm.expectEmit(false, false, false, true);
        emit ManagedOptimisticOracleV2Interface.MinimumLivenessUpdated(8 hours);
        moo.setMinimumLiveness(8 hours);
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
}
