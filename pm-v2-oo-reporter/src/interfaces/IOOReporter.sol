// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

struct RequestData {
    /// @notice Timestamp of the active Managed OO request.
    uint256 requestTimestamp;
    /// @notice Reward amount used for the active Managed OO request.
    uint256 reward;
    /// @notice Proposal bond requested by the reporter for the active Managed OO request.
    /// @dev The effective proposal bond can differ if Managed OO request-manager preconfigs apply at proposal time.
    uint256 proposalBond;
    /// @notice Custom liveness requested by the reporter for the active Managed OO request.
    /// @dev The effective proposal liveness can differ if Managed OO request-manager preconfigs apply at proposal time.
    uint64 liveness;
    /// @notice Whether an approved requester has registered this request.
    bool registered;
    /// @notice Whether an approved oracle initializer has created the first Managed OO request.
    bool initialized;
    /// @notice Whether a final raw UMA outcome has been stored.
    bool resolved;
    /// @notice Whether a re-request is currently allowed.
    bool rerequestAllowed;
    /// @notice Whether this request has used its one automatic dispute re-request.
    bool automaticDisputeRerequestUsed;
    /// @notice Approved requester that registered the request.
    address requester;
    /// @notice Address that initiated the active Managed OO request.
    address oracleInitializer;
    /// @notice UMA price identifier for this request.
    bytes32 priceIdentifier;
    /// @notice Raw UMA request rules supplied by the requester.
    bytes requestRules;
    /// @notice Final raw UMA outcome after settlement.
    int256 outcome;
    /// @notice Remaining manual re-request budget. Seeded from the default at initialization and topped up by the owner.
    uint256 manualRerequestsRemaining;
    /// @notice Minimum liveness UMA is allowed to use for this request.
    uint64 minimumLiveness;
    /// @notice Maximum liveness UMA is allowed to use for this request.
    uint64 maximumLiveness;
}

struct RequestRulesUpdate {
    /// @notice Block timestamp when the rules update was posted.
    uint256 timestamp;
    /// @notice Updated prediction market request rules.
    bytes updatedRules;
}

enum RerequestTrigger {
    /// @dev Managed OO dispute callback opened the re-request gate.
    Dispute,
    /// @dev Managed OO settled to P4, so the request must be replaced.
    InvalidSettlement
}

enum RerequestType {
    /// @dev Oracle-initializer-triggered re-request that consumes the manual re-request budget.
    Manual,
    /// @dev First-dispute automatic re-request that does not consume the manual re-request budget.
    AutomaticDispute,
    /// @dev P4 settlement automatic re-request that does not consume the manual re-request budget.
    AutomaticInvalidSettlement
}

/// @title IOOReporter
/// @notice Request-oriented reporter interface for UMA-owned Managed OO initialization and raw outcome storage.
/// @custom:security-contact bugs@umaproject.org
interface IOOReporter {
    /*--------------------------------------------------------------
                               ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when a required address argument is zero.
    error AddressCannotBeZero();
    /// @notice Thrown when a request ID or price identifier is zero.
    error InvalidRequestKey();
    /// @notice Thrown when the caller is not an enabled requester.
    error CallerNotRequester();
    /// @notice Thrown when the caller did not register the request ID.
    error CallerNotRequestRegistrar();
    /// @notice Thrown when the caller is not the configured Managed Optimistic Oracle.
    error CallerNotOptimisticOracle();
    /// @notice Thrown when the caller is not an enabled UMA oracle initializer.
    error CallerNotOracleInitializer();
    /// @notice Thrown when a requester allowlist update would not change state.
    error RequesterEnabledUnchanged();
    /// @notice Thrown when an oracle initializer allowlist update would not change state.
    error OracleInitializerEnabledUnchanged();
    /// @notice Thrown when a default re-request budget update would not change state.
    error DefaultRerequestBudgetUnchanged();
    /// @notice Thrown when an automatic re-request setting update would not change state.
    error AutomaticRerequestsEnabledUnchanged();
    /// @notice Thrown when a per-request re-request budget update would not change state.
    error RequestRerequestBudgetUnchanged();
    /// @notice Thrown when a per-request re-request budget top-up exceeds the contract-level default budget.
    error RequestRerequestBudgetAboveDefault(uint256 requested, uint256 defaultRerequestBudget);
    /// @notice Thrown when creating an OO request for an already initialized request.
    error RequestAlreadyInitialized();
    /// @notice Thrown when registering a request ID that has already been registered.
    error RequestAlreadyRegistered();
    /// @notice Thrown when registering a duplicate OO request tuple for a different request ID.
    error ReporterRequestKeyAlreadyRegistered(bytes32 existingRequestId);
    /// @notice Thrown when an operation targets a request that already has a final outcome.
    error RequestAlreadyResolved();
    /// @notice Thrown when an operation requires an initialized Managed OO request.
    error RequestNotInitialized();
    /// @notice Thrown when an operation requires a registered request.
    error RequestNotRegistered();
    /// @notice Thrown when a re-request is attempted before the re-request gate opens.
    error RequestRerequestNotAllowed();
    /// @notice Thrown when a replacement request timestamp does not advance.
    error RequestRerequestTimestampNotAdvanced(uint256 currentTimestamp, uint256 previousRequestTimestamp);
    /// @notice Thrown when the manual re-request budget is exhausted.
    error RequestRerequestBudgetExhausted();
    /// @notice Thrown when raw request rules is empty or too large for the OO.
    error InvalidRequestRules();
    /// @notice Thrown when minimum liveness is greater than maximum liveness.
    error InvalidLivenessRange(uint64 minimumLiveness, uint64 maximumLiveness);
    /// @notice Thrown when registered liveness bounds do not overlap with Managed OO custom liveness bounds.
    error LivenessRangeOutsideManagedBounds(
        uint64 minimumLiveness, uint64 maximumLiveness, uint256 oracleMinimumLiveness, uint256 oracleMaximumLiveness
    );
    /// @notice Thrown when the oracle initializer tries to use the Managed OO default liveness path.
    error RequestLivenessCannotBeZero();
    /// @notice Thrown when selected liveness is outside the registered bounds.
    error RequestLivenessOutOfRange(uint64 liveness, uint64 minimumLiveness, uint64 maximumLiveness);
    /// @notice Thrown when a final reporter outcome is requested before one is available.
    error RequestResolutionUnavailable();
    /// @notice Thrown when the latest rules update is requested before any update is posted.
    error RequestRulesUpdateUnavailable();
    /// @notice Thrown when Managed OO has no deferred reward payout for the reporter.
    error DeferredPayoutUnavailable(address rewardCurrency);
    /// @notice Thrown when the reporter cannot fund a requested reward amount.
    error InsufficientRewardBalance(address rewardCurrency, uint256 balance, uint256 required);

    /*--------------------------------------------------------------
                               EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when the owner enables or disables a requester.
    event RequesterEnabledSet(address indexed requester, bool enabled);
    /// @notice Emitted when the owner enables or disables a UMA oracle initializer.
    event OracleInitializerEnabledSet(address indexed oracleInitializer, bool enabled);
    /// @notice Emitted when the owner updates the default per-request re-request budget.
    event DefaultRerequestBudgetSet(uint256 defaultRerequestBudget);
    /// @notice Emitted when the owner enables or disables automatic re-requests.
    event AutomaticRerequestsEnabledSet(bool enabled);
    /// @notice Emitted when an approved requester registers a request for UMA initialization.
    event RequestRegistered(
        bytes32 indexed requestId,
        address indexed requester,
        bytes32 indexed priceIdentifier,
        bytes requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    );
    /// @notice Emitted when an approved oracle initializer creates the first Managed OO request.
    /// @dev proposalBond and liveness are reporter-requested parameters. Effective proposal-time values can differ
    /// if Managed OO request-manager preconfigs apply.
    event RequestInitialized(
        bytes32 indexed requestId,
        uint256 indexed requestTimestamp,
        address indexed oracleInitializer,
        bytes32 priceIdentifier,
        bytes requestRules,
        address rewardCurrency,
        uint256 reward,
        uint256 proposalBond,
        uint64 liveness,
        uint256 manualRerequestsRemaining
    );
    /// @notice Emitted when the registering requester posts updated request rules for offchain consumers.
    event RequestRulesUpdated(
        bytes32 indexed requestId, uint256 indexed timestamp, address indexed updater, bytes updatedRules
    );
    /// @notice Emitted when a final raw UMA outcome is stored for a request.
    event RequestResolved(bytes32 indexed requestId, uint256 indexed requestTimestamp, int256 outcome);
    /// @notice Emitted when a callback opens the oracle-initializer re-request path.
    event RequestRerequestAllowed(
        bytes32 indexed requestId, uint256 indexed requestTimestamp, RerequestTrigger indexed trigger
    );
    /// @notice Emitted when the reporter creates a replacement Managed OO request.
    /// @dev proposalBond and liveness are reporter-requested parameters. Effective proposal-time values can differ
    /// if Managed OO request-manager preconfigs apply.
    event RequestRerequested(
        bytes32 indexed requestId,
        uint256 indexed requestTimestamp,
        address indexed rerequester,
        RerequestType rerequestType,
        uint256 previousRequestTimestamp,
        address rewardCurrency,
        uint256 reward,
        uint256 proposalBond,
        uint64 liveness,
        uint256 manualRerequestsRemaining
    );
    /// @notice Emitted when the owner updates the remaining re-request budget for one request.
    event RequestRerequestBudgetSet(bytes32 indexed requestId, uint256 manualRerequestsRemaining);
    /// @notice Emitted when the owner sweeps ERC20 or native token funds from the reporter.
    event FundsSwept(address indexed token, address indexed recipient, uint256 amount);
    /// @notice Emitted when the owner claims a deferred Managed OO payout owed to the reporter.
    event DeferredPayoutClaimed(address indexed rewardCurrency, address indexed repaymentAddress, uint256 amount);

    /*--------------------------------------------------------------
                             FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Initializes the upgradeable reporter.
    /// @param initialOwner Owner that can manage requesters, oracle initializers, budgets, and upgrades.
    /// @param optimisticOracle Managed Optimistic Oracle V2 address.
    /// @param rewardCurrency ERC20 reward currency used for all reporter-created OO requests.
    /// @param initialOracleInitializer Optional first UMA oracle initializer; pass zero to set later.
    /// @param initialRequester Optional first requester; pass zero to set later.
    /// @param initialDefaultRerequestBudget Default replacement-request budget seeded onto each initialized request.
    function initialize(
        address initialOwner,
        address optimisticOracle,
        address rewardCurrency,
        address initialOracleInitializer,
        address initialRequester,
        uint256 initialDefaultRerequestBudget
    ) external;

    /// @notice Enables or disables an address allowed to register requests.
    /// @param requester Requester address to update.
    /// @param enabled Whether requester should be enabled.
    function setRequesterEnabled(address requester, bool enabled) external;

    /// @notice Enables or disables an address allowed to initialize Managed OO requests.
    /// @param oracleInitializer Oracle initializer address to update.
    /// @param enabled Whether oracleInitializer should be enabled.
    function setOracleInitializerEnabled(address oracleInitializer, bool enabled) external;

    /// @notice Updates the default replacement-request budget for future initialized requests.
    /// @param newDefaultRerequestBudget New default re-request budget.
    function setDefaultRerequestBudget(uint256 newDefaultRerequestBudget) external;

    /// @notice Enables or disables automatic dispute and P4 re-requests.
    /// @param enabled Whether automatic re-requests should be enabled.
    function setAutomaticRerequestsEnabled(bool enabled) external;

    /// @notice Returns whether candidate is approved to register requests.
    /// @param candidate Address to check.
    /// @return True if candidate is an enabled requester.
    function isRequester(address candidate) external view returns (bool);

    /// @notice Returns whether candidate is approved to create Managed OO requests.
    /// @param candidate Address to check.
    /// @return True if candidate is an enabled UMA oracle initializer.
    function isOracleInitializer(address candidate) external view returns (bool);

    /// @notice Returns the default replacement-request budget seeded onto each initialized request.
    /// @return Current default re-request budget.
    function defaultRerequestBudget() external view returns (uint256);

    /// @notice Returns whether automatic dispute and P4 re-requests are enabled.
    /// @return True if automatic re-requests are enabled.
    function automaticRerequestsEnabled() external view returns (bool);

    /// @notice Registers a requester-defined request ID and its UMA request identity before OO initialization.
    /// @dev The reporter reserves each price identifier and request rules pair globally across approved requesters.
    /// Requesters should preserve an admin recovery path for rules or liveness ranges that become unusable before
    /// initialization.
    /// @param requestId Requester-defined request ID to bind to the UMA request identity.
    /// @param priceIdentifier UMA price identifier to request.
    /// @param requestRules Raw UMA request rules supplied by the requester.
    /// @param minimumLiveness Minimum custom liveness the oracle initializer may use.
    /// @param maximumLiveness Maximum custom liveness the oracle initializer may use.
    function registerRequest(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes calldata requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) external;

    /// @notice Posts updated request rules for offchain consumers without changing the active OO tuple.
    /// @param requestId Registered request ID.
    /// @param updatedRules Updated prediction market request rules.
    function updateRequestRules(bytes32 requestId, bytes calldata updatedRules) external;

    /// @notice Creates the Managed OO request for a registered request.
    /// @param requestId Registered request ID.
    /// @param reward Reward offered to a successful OO proposer.
    /// @param proposalBond Bond requested from OO proposers/disputers, or zero to use the OO default. The effective
    /// proposal bond can differ if Managed OO request-manager preconfigs apply at proposal time.
    /// @param liveness Custom OO liveness period within the registered bounds. The effective proposal liveness can
    /// differ if Managed OO request-manager preconfigs apply at proposal time.
    function initializeRequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness) external;

    /// @notice Allows an enabled oracle initializer to create a replacement Managed OO request after a callback opens the gate.
    /// @param requestId Registered request ID.
    /// @param reward Reward amount for the replacement request.
    /// @param proposalBond Bond requested from OO proposers/disputers, or zero to use the OO default. The effective
    /// proposal bond can differ if Managed OO request-manager preconfigs apply at proposal time.
    /// @param liveness Custom OO liveness period within the registered bounds. The effective proposal liveness can
    /// differ if Managed OO request-manager preconfigs apply at proposal time.
    function rerequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness) external;

    /// @notice Updates the remaining re-request budget for an initialized unresolved request.
    /// @param requestId Registered request ID.
    /// @param newManualRerequestsRemaining New remaining manual re-request budget, capped by the current default.
    function setRequestRerequestBudget(bytes32 requestId, uint256 newManualRerequestsRemaining) external;

    /// @notice Returns whether a final reporter outcome is available for requestId.
    /// @param requestId Registered request ID.
    /// @return True if the reporter has stored a final outcome.
    function isRequestResolved(bytes32 requestId) external view returns (bool);

    /// @notice Returns the final raw UMA outcome for requestId.
    /// @param requestId Registered request ID.
    /// @return Final raw UMA outcome.
    function getRequestResolution(bytes32 requestId) external view returns (int256);

    /// @notice Returns the stored reporter lifecycle state for requestId.
    /// @param requestId Registered request ID.
    /// @return Stored reporter request state.
    function getRequest(bytes32 requestId) external view returns (RequestData memory);

    /// @notice Returns the request ID registered for a UMA request identity.
    /// @param priceIdentifier UMA price identifier.
    /// @param requestRules Raw UMA request rules.
    /// @return requestId Registered request ID.
    function getRequestId(bytes32 priceIdentifier, bytes calldata requestRules) external view returns (bytes32);

    /// @notice Returns all request-rules updates posted for requestId.
    /// @param requestId Registered request ID.
    /// @return Request-rules update history.
    function getRequestRulesUpdates(bytes32 requestId) external view returns (RequestRulesUpdate[] memory);

    /// @notice Returns the latest request-rules update posted for requestId.
    /// @param requestId Registered request ID.
    /// @return Latest request-rules update.
    function getLatestRequestRulesUpdate(bytes32 requestId) external view returns (RequestRulesUpdate memory);

    /// @notice Returns all request-rules updates posted for a UMA request identity.
    /// @param priceIdentifier UMA price identifier.
    /// @param requestRules Raw UMA request rules.
    /// @return Request-rules update history.
    function getRequestRulesUpdates(bytes32 priceIdentifier, bytes calldata requestRules)
        external
        view
        returns (RequestRulesUpdate[] memory);

    /// @notice Returns the latest request-rules update posted for a UMA request identity.
    /// @param priceIdentifier UMA price identifier.
    /// @param requestRules Raw UMA request rules.
    /// @return Latest request-rules update.
    function getLatestRequestRulesUpdate(bytes32 priceIdentifier, bytes calldata requestRules)
        external
        view
        returns (RequestRulesUpdate memory);

    /// @notice Claims a Managed OO deferred reward payout owed to this reporter.
    /// @param repaymentAddress Address to receive the claimed payout.
    function claimDeferredPayout(address repaymentAddress) external;

    /// @notice Sweeps ERC20 or native token funds held by the reporter to recipient.
    /// @param token ERC20 token to sweep, or zero address for native token.
    /// @param recipient Address that receives swept funds.
    /// @param amount Amount to sweep.
    function sweep(address token, address recipient, uint256 amount) external;
}
