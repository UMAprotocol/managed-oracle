// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MulticallUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOptimisticOracleV2} from "src/interfaces/IOptimisticOracleV2.sol";
import {IOptimisticRequester} from "src/interfaces/IOptimisticRequester.sol";

/// @dev Frozen pre-callback request layout. Do not replace with the current production struct.
struct LegacyRequestData {
    uint256 requestTimestamp;
    uint256 reward;
    uint256 proposalBond;
    uint64 liveness;
    bool registered;
    bool initialized;
    bool resolved;
    bool rerequestAllowed;
    bool automaticDisputeRerequestUsed;
    address requester;
    address oracleInitializer;
    bytes32 priceIdentifier;
    bytes requestRules;
    int256 outcome;
    uint256 manualRerequestsRemaining;
    uint64 minimumLiveness;
    uint64 maximumLiveness;
}

/// @dev Frozen subset of OOReporter at commit 13dabea. It mirrors the inheritance order, namespaced storage,
/// initializer, registration, request initialization, settlement without downstream reporting, and owner-gated UUPS
/// authorization that define the upgrade boundary. Unrelated administration and re-request paths are omitted.
contract LegacyOOReporter is OwnableUpgradeable, UUPSUpgradeable, MulticallUpgradeable, IOptimisticRequester {
    struct OOReporterStorage {
        IOptimisticOracleV2 optimisticOracle;
        IERC20 rewardCurrency;
        mapping(address requester => bool enabled) isRequester;
        mapping(address oracleInitializer => bool enabled) isOracleInitializer;
        mapping(bytes32 requestId => LegacyRequestData request) requests;
        mapping(bytes32 reporterRequestKey => bytes32 requestId) requestIdsByReporterKey;
        uint256 defaultRerequestBudget;
        bool automaticRerequestsEnabled;
    }

    bytes32 private constant OO_REPORTER_STORAGE_LOCATION =
        0xe597f8c3629f5ca2bbd4f416c338811ff317bd2d6db5ce34f2567207506cc400;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address optimisticOracle_,
        address rewardCurrency_,
        address initialOracleInitializer,
        address initialRequester,
        uint256 initialDefaultRerequestBudget
    ) external initializer {
        __Ownable_init(initialOwner);
        __Multicall_init();

        OOReporterStorage storage $ = _getStorage();
        $.optimisticOracle = IOptimisticOracleV2(optimisticOracle_);
        $.rewardCurrency = IERC20(rewardCurrency_);
        $.isOracleInitializer[initialOracleInitializer] = true;
        $.isRequester[initialRequester] = true;
        $.defaultRerequestBudget = initialDefaultRerequestBudget;
        $.automaticRerequestsEnabled = true;
    }

    function optimisticOracle() external view returns (IOptimisticOracleV2) {
        return _getStorage().optimisticOracle;
    }

    function rewardCurrency() external view returns (IERC20) {
        return _getStorage().rewardCurrency;
    }

    function isRequester(address candidate) external view returns (bool) {
        return _getStorage().isRequester[candidate];
    }

    function isOracleInitializer(address candidate) external view returns (bool) {
        return _getStorage().isOracleInitializer[candidate];
    }

    function defaultRerequestBudget() external view returns (uint256) {
        return _getStorage().defaultRerequestBudget;
    }

    function automaticRerequestsEnabled() external view returns (bool) {
        return _getStorage().automaticRerequestsEnabled;
    }

    function registerRequest(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes calldata requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) external {
        OOReporterStorage storage $ = _getStorage();
        require($.isRequester[msg.sender], "caller not requester");

        LegacyRequestData storage request = $.requests[requestId];
        require(!request.registered, "already registered");

        request.registered = true;
        request.requester = msg.sender;
        request.priceIdentifier = priceIdentifier;
        request.requestRules = requestRules;
        request.minimumLiveness = minimumLiveness;
        request.maximumLiveness = maximumLiveness;
        $.requestIdsByReporterKey[_reporterRequestKey(priceIdentifier, requestRules)] = requestId;
    }

    function initializeRequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness) external {
        OOReporterStorage storage $ = _getStorage();
        require($.isOracleInitializer[msg.sender], "caller not oracle initializer");

        LegacyRequestData storage request = $.requests[requestId];
        require(request.registered, "not registered");
        require(!request.initialized, "already initialized");

        request.initialized = true;
        request.oracleInitializer = msg.sender;
        request.requestTimestamp = block.timestamp;
        request.reward = reward;
        request.proposalBond = proposalBond;
        request.liveness = liveness;
        request.manualRerequestsRemaining = $.defaultRerequestBudget;

        IOptimisticOracleV2 oracle = $.optimisticOracle;
        oracle.requestPrice(request.priceIdentifier, block.timestamp, request.requestRules, $.rewardCurrency, reward);
        oracle.setEventBased(request.priceIdentifier, block.timestamp, request.requestRules);
        oracle.setCallbacks(request.priceIdentifier, block.timestamp, request.requestRules, false, true, true);
        if (proposalBond > 0) {
            oracle.setBond(request.priceIdentifier, block.timestamp, request.requestRules, proposalBond);
        }
        oracle.setCustomLiveness(request.priceIdentifier, block.timestamp, request.requestRules, liveness);
    }

    function priceDisputed(bytes32, uint256, bytes memory, uint256) external view {
        require(msg.sender == address(_getStorage().optimisticOracle), "caller not oracle");
    }

    function priceSettled(bytes32 identifier, uint256 timestamp, bytes memory requestRules, int256 price) external {
        OOReporterStorage storage $ = _getStorage();
        require(msg.sender == address($.optimisticOracle), "caller not oracle");

        LegacyRequestData storage request =
            $.requests[$.requestIdsByReporterKey[_reporterRequestKey(identifier, requestRules)]];
        if (!request.initialized || timestamp != request.requestTimestamp || request.resolved) return;

        request.resolved = true;
        request.outcome = price;
        request.rerequestAllowed = false;
    }

    function isRequestResolved(bytes32 requestId) external view returns (bool) {
        return _getStorage().requests[requestId].resolved;
    }

    function getRequestResolution(bytes32 requestId) external view returns (int256) {
        return _getStorage().requests[requestId].outcome;
    }

    function getRequest(bytes32 requestId) external view returns (LegacyRequestData memory) {
        return _getStorage().requests[requestId];
    }

    function _getStorage() private pure returns (OOReporterStorage storage $) {
        assembly {
            $.slot := OO_REPORTER_STORAGE_LOCATION
        }
    }

    function _reporterRequestKey(bytes32 identifier, bytes memory requestRules) private pure returns (bytes32) {
        return keccak256(abi.encode(identifier, requestRules));
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
