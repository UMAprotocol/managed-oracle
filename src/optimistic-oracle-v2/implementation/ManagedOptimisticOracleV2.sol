// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AddressWhitelistInterface} from "../../common/interfaces/AddressWhitelistInterface.sol";
import {ManagedOptimisticOracleV2Interface} from "../interfaces/ManagedOptimisticOracleV2Interface.sol";
import {MultiCaller} from "../../common/implementation/MultiCaller.sol";
import {OptimisticOracleV2} from "./OptimisticOracleV2.sol";

/**
 * @title Managed Optimistic Oracle V2.
 * @notice Pre-DVM escalation contract that allows faster settlement and management of price requests.
 * @custom:security-contact bugs@umaproject.org
 */
contract ManagedOptimisticOracleV2 is ManagedOptimisticOracleV2Interface, OptimisticOracleV2, MultiCaller {
    struct BondRange {
        uint128 minimumBond;
        uint128 maximumBond;
    }

    struct CurrencyBondRange {
        IERC20 currency;
        BondRange range;
    }

    struct CustomBond {
        uint256 amount;
        bool isSet;
    }

    struct CustomLiveness {
        uint256 liveness;
        bool isSet;
    }

    // Config admin role is used to manage request managers and set other default parameters.
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");

    // Request manager role is used to manage proposer whitelists, bonds, and liveness for individual requests.
    bytes32 public constant REQUEST_MANAGER_ROLE = keccak256("REQUEST_MANAGER_ROLE");

    // Default whitelist for proposers.
    AddressWhitelistInterface public defaultProposerWhitelist;
    AddressWhitelistInterface public requesterWhitelist;

    // Custom bonds set by request managers for specific request and currency combinations.
    mapping(bytes32 => mapping(IERC20 => CustomBond)) public customBonds;

    // Custom liveness values set by request managers for specific requests.
    mapping(bytes32 => CustomLiveness) public customLivenessValues;

    // Custom proposer whitelists set by request managers for specific requests.
    mapping(bytes32 => AddressWhitelistInterface) public customProposerWhitelists;

    // Admin controlled ranges limiting the changes that can be made by request managers.
    // Unset currency -> (0,0) range; manager-set custom bonds revert until explicitly set.
    mapping(IERC20 => BondRange) public allowedBondRanges;

    // Admin controlled minimum liveness that can be set by request managers.
    uint256 public minimumLiveness;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer.
     * @param _defaultLiveness applied to each price request.
     * @param _finderAddress to use to get addresses of DVM contracts.
     * @param _defaultProposerWhitelist address of the default whitelist.
     * @param _requesterWhitelist address of the requester whitelist.
     * @param _allowedBondRanges array of allowed bond ranges for different currencies.
     * @param _minimumLiveness that can be overridden for a request.
     * @param configAdmin address, which is used for managing request managers and contract parameters.
     * @param upgradeAdmin address, which also can manage the config admin role.
     */
    function initialize(
        uint256 _defaultLiveness,
        address _finderAddress,
        address _defaultProposerWhitelist,
        address _requesterWhitelist,
        CurrencyBondRange[] calldata _allowedBondRanges,
        uint256 _minimumLiveness,
        address configAdmin,
        address upgradeAdmin
    ) external initializer {
        __OptimisticOracleV2_init(_defaultLiveness, _finderAddress, upgradeAdmin);

        // Config admin is managing the request manager role.
        // Contract upgrade admin retains the default admin role that can also manage the config admin role.
        _grantRole(CONFIG_ADMIN_ROLE, configAdmin);
        _setRoleAdmin(REQUEST_MANAGER_ROLE, CONFIG_ADMIN_ROLE);

        _setDefaultProposerWhitelist(_defaultProposerWhitelist);
        _setRequesterWhitelist(_requesterWhitelist);
        // Explicit ranges enable manager-set custom bonds per currency (forbid-by-default).
        for (uint256 i = 0; i < _allowedBondRanges.length; i++) {
            _setAllowedBondRange(_allowedBondRanges[i].currency, _allowedBondRanges[i].range);
        }
        _setMinimumLiveness(_minimumLiveness);
    }

    /**
     * @dev Throws if called by any account other than the config admin.
     */
    modifier onlyConfigAdmin() {
        _checkRole(CONFIG_ADMIN_ROLE);
        _;
    }

    /**
     * @dev Throws if called by any account other than the request manager.
     */
    modifier onlyRequestManager() {
        _checkRole(REQUEST_MANAGER_ROLE);
        _;
    }

    /**
     * @notice Adds a request manager.
     * @dev Only callable by the config admin (checked in grantRole of AccessControlUpgradeable).
     * @param requestManager address of the request manager to set.
     */
    function addRequestManager(address requestManager) external nonReentrant {
        grantRole(REQUEST_MANAGER_ROLE, requestManager);
    }

    /**
     * @notice Removes a request manager.
     * @dev Only callable by the config admin (checked in revokeRole of AccessControlUpgradeable).
     * @param requestManager address of the request manager to remove.
     */
    function removeRequestManager(address requestManager) external nonReentrant {
        revokeRole(REQUEST_MANAGER_ROLE, requestManager);
    }

    /**
     * @notice Sets the bounds for a bond that can be set for a request.
     * @dev This can be used to limit the bond amount that can be set by request managers, callable by the config admin.
     * @param currency the ERC20 token used for bonding proposals and disputes. Must be approved for use with the DVM.
     * @param newRange new allowed range for the bond.
     */
    function setAllowedBondRange(IERC20 currency, BondRange calldata newRange) external nonReentrant onlyConfigAdmin {
        _setAllowedBondRange(currency, newRange);
    }

    /**
     * @notice Sets the minimum liveness that can be set for a request.
     * @dev This can be used to limit the liveness period that can be set by request managers, callable by the config admin.
     * @param _minimumLiveness new minimum liveness period.
     */
    function setMinimumLiveness(uint256 _minimumLiveness) external nonReentrant onlyConfigAdmin {
        _setMinimumLiveness(_minimumLiveness);
    }

    /**
     * @notice Sets the default proposer whitelist.
     * @dev Only callable by the config admin.
     * @param whitelist address of the whitelist to set.
     */
    function setDefaultProposerWhitelist(address whitelist) external nonReentrant onlyConfigAdmin {
        _setDefaultProposerWhitelist(whitelist);
    }

    /**
     * @notice Sets the requester whitelist.
     * @dev Only callable by the config admin.
     * @param whitelist address of the whitelist to set.
     */
    function setRequesterWhitelist(address whitelist) external nonReentrant onlyConfigAdmin {
        _setRequesterWhitelist(whitelist);
    }

    /**
     * @notice Requests a new price.
     * @param identifier price identifier being requested.
     * @param timestamp timestamp of the price being requested.
     * @param ancillaryData ancillary data representing additional args being passed with the price request.
     * @param currency ERC20 token used for payment of rewards and fees. Must be approved for use with the DVM.
     * @param reward reward offered to a successful proposer. Will be pulled from the caller. Note: this can be 0,
     *               which could make sense if the contract requests and proposes the value in the same call or
     *               provides its own reward system.
     * @return totalBond default bond (final fee) + final fee that the proposer and disputer will be required to pay.
     * This can be changed with a subsequent call to setBond().
     */
    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        IERC20 currency,
        uint256 reward
    ) public override returns (uint256 totalBond) {
        require(requesterWhitelist.isOnWhitelist(msg.sender), RequesterNotWhitelisted());
        return super.requestPrice(identifier, timestamp, ancillaryData, currency, reward);
    }

    /**
     * @notice Set the proposal bond associated with a price request.
     * @dev This would also override any subsequent calls to setBond() by the requester.
     * @param requester sender of the initial price request.
     * @param identifier price identifier to identify the existing request.
     * @param ancillaryData ancillary data of the price being requested.
     * @param currency ERC20 token used for payment of rewards and fees. Must be approved for use with the DVM.
     * @param bond custom bond amount to set.
     */
    function requestManagerSetBond(
        address requester,
        bytes32 identifier,
        bytes memory ancillaryData,
        IERC20 currency,
        uint256 bond
    ) external nonReentrant onlyRequestManager {
        require(_getCollateralWhitelist().isOnWhitelist(address(currency)), UnsupportedCurrency());
        _validateBond(currency, bond);
        bytes32 managedRequestId = getManagedRequestId(requester, identifier, ancillaryData);
        customBonds[managedRequestId][currency] = CustomBond({amount: bond, isSet: true});
        emit CustomBondSet(managedRequestId, requester, identifier, ancillaryData, currency, bond);
    }

    /**
     * @notice Sets a custom liveness value for the request. Liveness is the amount of time a proposal must wait before
     * being auto-resolved.
     * @dev This would also override any subsequent calls to setLiveness() by the requester.
     * @param requester sender of the initial price request.
     * @param identifier price identifier to identify the existing request.
     * @param ancillaryData ancillary data of the price being requested.
     * @param customLiveness new custom liveness.
     */
    function requestManagerSetCustomLiveness(
        address requester,
        bytes32 identifier,
        bytes memory ancillaryData,
        uint256 customLiveness
    ) external nonReentrant onlyRequestManager {
        _validateLiveness(customLiveness);
        bytes32 managedRequestId = getManagedRequestId(requester, identifier, ancillaryData);
        customLivenessValues[managedRequestId] = CustomLiveness({liveness: customLiveness, isSet: true});
        emit CustomLivenessSet(managedRequestId, requester, identifier, ancillaryData, customLiveness);
    }

    /**
     * @notice Sets the proposer whitelist for a request.
     * @dev This can also be set in advance of the request as the timestamp is omitted from the mapping key derivation.
     * @param requester sender of the initial price request.
     * @param identifier price identifier to identify the existing request.
     * @param ancillaryData ancillary data of the price being requested.
     * @param whitelist address of the whitelist to set.
     */
    function requestManagerSetProposerWhitelist(
        address requester,
        bytes32 identifier,
        bytes memory ancillaryData,
        address whitelist
    ) external nonReentrant onlyRequestManager {
        // Zero address is allowed to disable the custom proposer whitelist.
        if (whitelist != address(0)) {
            _validateWhitelistInterface(whitelist);
        }
        bytes32 managedRequestId = getManagedRequestId(requester, identifier, ancillaryData);
        customProposerWhitelists[managedRequestId] = AddressWhitelistInterface(whitelist);
        emit CustomProposerWhitelistSet(managedRequestId, requester, identifier, ancillaryData, whitelist);
    }

    /**
     * @notice Proposes a price value on another address' behalf. Note: this address will receive any rewards that come
     * from this proposal. However, any bonds are pulled from the caller.
     * @param proposer address to set as the proposer.
     * @param requester sender of the initial price request.
     * @param identifier price identifier to identify the existing request.
     * @param timestamp timestamp to identify the existing request.
     * @param ancillaryData ancillary data of the price being requested.
     * @param proposedPrice price being proposed.
     * @return totalBond the amount that's pulled from the caller's wallet as a bond. The bond will be returned to
     * the proposer once settled if the proposal is correct.
     */
    function proposePriceFor(
        address proposer,
        address requester,
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        int256 proposedPrice
    ) public override returns (uint256 totalBond) {
        // Apply the custom bond and liveness overrides if set.
        Request storage request = _getRequest(requester, identifier, timestamp, ancillaryData);
        bytes32 managedRequestId = getManagedRequestId(requester, identifier, ancillaryData);
        if (customBonds[managedRequestId][request.currency].isSet) {
            request.requestSettings.bond = customBonds[managedRequestId][request.currency].amount;
        }
        if (customLivenessValues[managedRequestId].isSet) {
            request.requestSettings.customLiveness = customLivenessValues[managedRequestId].liveness;
        }

        AddressWhitelistInterface whitelist = _getEffectiveProposerWhitelist(requester, identifier, ancillaryData);

        require(whitelist.isOnWhitelist(proposer), ProposerNotWhitelisted());
        require(whitelist.isOnWhitelist(msg.sender), SenderNotWhitelisted());
        return super.proposePriceFor(proposer, requester, identifier, timestamp, ancillaryData, proposedPrice);
    }

    /**
     * @notice Gets the custom proposer whitelist for a request.
     * @dev This omits the timestamp from the key derivation, so the whitelist might have been set in advance of the
     * request.
     * @param requester sender of the initial price request.
     * @param identifier price identifier to identify the existing request.
     * @param ancillaryData ancillary data of the price being requested.
     * @return AddressWhitelistInterface the custom proposer whitelist for the request or zero address if not set.
     */
    function getCustomProposerWhitelist(address requester, bytes32 identifier, bytes memory ancillaryData)
        external
        view
        returns (AddressWhitelistInterface)
    {
        return customProposerWhitelists[getManagedRequestId(requester, identifier, ancillaryData)];
    }

    /**
     * @notice Returns the proposer whitelist and whether whitelist is enabled for a given request.
     * @dev If no custom proposer whitelist is set for the request, the default proposer whitelist is used.
     * If whitelist used is DisabledAddressWhitelist, the returned proposer list will be empty and isEnabled will be false,
     * indicating that any address is allowed to propose.
     * @param requester The address that made or will make the price request.
     * @param identifier The identifier of the price request.
     * @param ancillaryData Additional data used to uniquely identify the request.
     * @return allowedProposers The list of addresses allowed to propose, if whitelist is enabled. Otherwise, an empty array.
     * @return isEnabled A boolean indicating whether whitelist is enabled for this request.
     */
    function getProposerWhitelistWithEnabledStatus(address requester, bytes32 identifier, bytes memory ancillaryData)
        external
        view
        returns (address[] memory allowedProposers, bool isEnabled)
    {
        AddressWhitelistInterface whitelist = _getEffectiveProposerWhitelist(requester, identifier, ancillaryData);
        return (whitelist.getWhitelist(), whitelist.isWhitelistEnabled());
    }

    /**
     * @notice Gets the ID for a managed request.
     * @dev This omits the timestamp from the key derivation, so it can be used for managed requests in advance.
     * @param requester sender of the initial price request.
     * @param identifier price identifier to identify the existing request.
     * @param ancillaryData ancillary data of the price being requested.
     * @return bytes32 the ID for the managed request.
     */
    function getManagedRequestId(address requester, bytes32 identifier, bytes memory ancillaryData)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(requester, identifier, ancillaryData));
    }

    /**
     * @notice Sets the bounds for a bond that can be set for a request.
     * @dev This can be used to limit the bond amount that can be set by request managers. Setting the minimum and
     * maximum both to 0 effectively blocks the request manager from overriding the bond for a given currency.
     * @param currency the ERC20 token used for bonding proposals and disputes. Must be approved for use with the DVM.
     * @param newRange new allowed range for the bond.
     */
    function _setAllowedBondRange(IERC20 currency, BondRange calldata newRange) internal {
        require(_getCollateralWhitelist().isOnWhitelist(address(currency)), UnsupportedCurrency());
        require(newRange.minimumBond <= newRange.maximumBond, MinimumBondAboveMaximumBond());
        allowedBondRanges[currency] = newRange;
        emit AllowedBondRangeUpdated(currency, newRange.minimumBond, newRange.maximumBond);
    }

    /**
     * @notice Sets the minimum liveness that can be set for a request.
     * @dev This can be used to limit the liveness period that can be set by request managers.
     * @param _minimumLiveness new minimum liveness period.
     */
    function _setMinimumLiveness(uint256 _minimumLiveness) internal {
        super._validateLiveness(_minimumLiveness);
        minimumLiveness = _minimumLiveness;
        emit MinimumLivenessUpdated(_minimumLiveness);
    }

    /**
     * @notice Sets the default proposer whitelist.
     * @param whitelist address of the whitelist to set.
     */
    function _setDefaultProposerWhitelist(address whitelist) internal {
        _validateWhitelistInterface(whitelist);
        defaultProposerWhitelist = AddressWhitelistInterface(whitelist);
        emit DefaultProposerWhitelistUpdated(whitelist);
    }

    /**
     * @notice Sets the requester whitelist.
     * @param whitelist address of the whitelist to set.
     */
    function _setRequesterWhitelist(address whitelist) internal {
        _validateWhitelistInterface(whitelist);
        requesterWhitelist = AddressWhitelistInterface(whitelist);
        emit RequesterWhitelistUpdated(whitelist);
    }

    /**
     * @notice Validates that the given address implements the AddressWhitelistInterface.
     * @dev Reverts if the address does not implement the interface.
     * @param whitelist address of the whitelist to validate.
     */
    function _validateWhitelistInterface(address whitelist) internal view {
        require(
            ERC165Checker.supportsInterface(whitelist, type(AddressWhitelistInterface).interfaceId),
            UnsupportedWhitelistInterface()
        );
    }

    /**
     * @notice Validates the bond amount.
     * @dev Reverts if the bond is outside the allowed bond range (controllable by the config admin) or it is 0 (which
     * makes sure the allowed bond range was explicitly set).
     * @param currency the ERC20 token used for bonding proposals and disputes. Must be approved for use with the DVM.
     * @param bond the bond amount to validate.
     */
    function _validateBond(IERC20 currency, uint256 bond) internal view {
        require(bond != 0, ZeroBondNotAllowed());
        BondRange memory allowedRange = allowedBondRanges[currency];
        require(bond >= uint256(allowedRange.minimumBond), BondBelowMinimumBond());
        require(bond <= uint256(allowedRange.maximumBond), BondExceedsMaximumBond());
    }

    /**
     * @notice Validates the liveness period.
     * @dev Reverts if the liveness period is less than the minimum liveness (controllable by the config admin) or
     * above the maximum liveness (which is set in the parent contract).
     * @param liveness the liveness period to validate.
     */
    function _validateLiveness(uint256 liveness) internal view override {
        require(liveness >= minimumLiveness, LivenessTooLow());
        super._validateLiveness(liveness);
    }

    /**
     * @notice Gets the effective proposer whitelist contract for a given request.
     * @dev Returns the custom proposer whitelist if set; otherwise falls back to the default. Timestamp is omitted from
     * the key derivation, so this can be used for checks before the request is made.
     * @param requester The address that made or will make the price request.
     * @param identifier The identifier of the price request.
     * @param ancillaryData Additional data used to uniquely identify the request.
     * @return whitelist The effective AddressWhitelistInterface for the request.
     */
    function _getEffectiveProposerWhitelist(address requester, bytes32 identifier, bytes memory ancillaryData)
        internal
        view
        returns (AddressWhitelistInterface whitelist)
    {
        whitelist = customProposerWhitelists[getManagedRequestId(requester, identifier, ancillaryData)];
        if (address(whitelist) == address(0)) {
            whitelist = defaultProposerWhitelist;
        }
    }

    /**
     * @dev Reserve storage slots for future versions of this base contract to add state variables without affecting the
     * storage layout of child contracts. Decrement the size of __gap whenever state variables are added. This is at the
     * bottom of contract to make sure its always at the end of storage.
     * See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
     */
    uint256[993] private __gap;
}
