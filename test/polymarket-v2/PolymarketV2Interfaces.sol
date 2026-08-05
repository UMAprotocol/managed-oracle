// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPolymarketAggregator {
    enum ResolutionStatus {
        None,
        Active,
        ArbitrationRequested,
        Resolved
    }

    enum MarketType {
        BINARY,
        INCREMENTAL_NEGRISK,
        ATOMIC_NEGRISK
    }

    struct ModuleConfig {
        address module;
        bytes initData;
    }

    struct InitParams {
        bytes29 eventId;
        MarketType marketType;
        address targetContract;
        uint16 resultLength;
        ModuleConfig[] reporterModules;
        uint16 reporterThreshold;
        ModuleConfig[] disputerModules;
        uint16 disputerThreshold;
        address arbitratorModule;
        bytes arbitratorInitData;
        uint32 livenessWindow;
        address finalizer;
    }

    function initializeRequest(InitParams calldata params) external;
    function owner() external view returns (address);
    function hasAllRoles(address user, uint256 roles) external view returns (bool);
    function isReporterModule(bytes29 eventId, address module) external view returns (bool);
    function isDisputerModule(bytes29 eventId, address module) external view returns (bool);
    function getRequestShape(bytes32 requestId) external view returns (uint8 marketType, uint16 outcomeCount);
    function getRequestState(bytes32 requestId)
        external
        view
        returns (ResolutionStatus status, bytes32 proposedResultHash, uint256 disputeWindowEnd, uint256 disputeCount);
}

interface IOOReporterModuleLike {
    struct RequestRegistration {
        bytes32 requestId;
        bytes requestRules;
        uint64 minimumLiveness;
        uint64 maximumLiveness;
    }

    function owner() external view returns (address);
    function aggregator() external view returns (address);
    function ooReporter() external view returns (address);
    function hasAllRoles(address user, uint256 roles) external view returns (bool);
    function requestInitialized(bytes31 scopeId) external view returns (bool);
    function finalize(bytes32 requestId) external;
}

interface IPolymarketOOReporterLike {
    struct RequestData {
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

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function optimisticOracle() external view returns (address);
    function rewardCurrency() external view returns (address);
    function isRequester(address candidate) external view returns (bool);
    function isOracleInitializer(address candidate) external view returns (bool);
    function registerRequest(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes calldata requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) external;
    function initializeRequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness) external;
    function isRequestResolved(bytes32 requestId) external view returns (bool);
    function getRequestResolution(bytes32 requestId) external view returns (int256);
    function getRequest(bytes32 requestId) external view returns (RequestData memory);
}

interface IManagedOptimisticOracleLike {
    struct RequestSettings {
        bool eventBased;
        bool refundOnDispute;
        bool callbackOnPriceProposed;
        bool callbackOnPriceDisputed;
        bool callbackOnPriceSettled;
        uint256 bond;
        uint256 customLiveness;
    }

    struct Request {
        address proposer;
        address disputer;
        IERC20 currency;
        bool settled;
        RequestSettings requestSettings;
        int256 proposedPrice;
        int256 resolvedPrice;
        uint256 expirationTime;
        uint256 reward;
        uint256 finalFee;
        uint256 proposalTime;
    }

    function defaultAdmin() external view returns (address);
    function defaultAdminDelay() external view returns (uint48);
    function pendingDefaultAdmin() external view returns (address newAdmin, uint48 schedule);
    function requesterWhitelist() external view returns (address);
    function defaultProposerWhitelist() external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function getRequest(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        external
        view
        returns (Request memory);
    function proposePriceFor(
        address proposer,
        address requester,
        bytes32 identifier,
        uint256 timestamp,
        bytes memory requestRules,
        int256 proposedPrice
    ) external returns (uint256 totalBond);
    function settle(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        external
        returns (uint256 payout);
}

interface IAddressWhitelistLike {
    function isOnWhitelist(address account) external view returns (bool);
}

interface IOwnableLike {
    function owner() external view returns (address);
}

interface IBinaryModuleLike {
    function hasAllRoles(address user, uint256 roles) external view returns (bool);
    function getResult(bytes31 conditionId) external view returns (uint256[] memory);
}

interface IERC1822ProxiableLike {
    function proxiableUUID() external view returns (bytes32);
}
