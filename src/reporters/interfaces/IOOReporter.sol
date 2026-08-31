// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
    /// @notice Remaining manual re-request budget.
    /// @dev Seeded from the default at initialization, owner-adjustable, and intentionally refreshed to the default after
    /// DVM-resolved P4 settlements so UMA-controlled oracle initializers can keep recovery moving.
    uint256 manualRerequestsRemaining;
    /// @notice Minimum custom liveness enforced by the reporter for this request.
    uint64 minimumLiveness;
    /// @notice Target maximum custom liveness for offchain initializers, not an onchain runtime ceiling.
    uint64 maximumLiveness;
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
    /// @notice Thrown when an external self-call helper is called by another address.
    error CallerNotSelf();
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
    /// @notice Thrown when a duplicate OO request tuple has a different requester or liveness range.
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
    /// @notice Thrown when selected liveness is below the registered minimum.
    error RequestLivenessOutOfRange(uint64 liveness, uint64 minimumLiveness, uint64 maximumLiveness);
    /// @notice Thrown when a final reporter outcome is requested before one is available.
    error RequestResolutionUnavailable();
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
    /// @notice Emitted when an approved oracle initializer updates the active Managed OO request reward.
    event RequestRewardUpdated(
        bytes32 indexed requestId,
        uint256 indexed requestTimestamp,
        address indexed updater,
        address rewardCurrency,
        uint256 oldReward,
        uint256 newReward
    );
    /// @notice Emitted when a final raw UMA outcome is stored for a request.
    /// @dev Events for every linked request ID are emitted before the isolated callback batch.
    event RequestResolved(bytes32 indexed requestId, uint256 indexed requestTimestamp, int256 outcome);
    /// @notice Emitted when the isolated request-ID callback fan-out reverts after all resolution events are emitted.
    event ResolutionCallbacksFailed(bytes32 indexed requestId, uint256 indexed requestTimestamp);
    /// @notice Emitted when a callback opens the oracle-initializer re-request path.
    event RequestRerequestAllowed(
        bytes32 indexed requestId, uint256 indexed requestTimestamp, RerequestTrigger indexed trigger
    );
    /// @notice Emitted when an automatic re-request fails and the callback falls back to the manual gate.
    event AutomaticRerequestFailed(
        bytes32 indexed requestId, uint256 indexed requestTimestamp, RerequestType indexed rerequestType
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

    /// @notice Updates the default replacement-request budget for future initialized requests and P4 refreshes.
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
    /// @dev Up to ten request IDs with matching price identifier, request rules, requester, and liveness values share one
    /// Managed OO lifecycle. minimumLiveness is enforced as an onchain runtime floor, while maximumLiveness remains a
    /// registration-time bound and offchain target that does not cap initialization or re-requests.
    /// @param requestId Requester-defined request ID to bind to the UMA request identity.
    /// @param priceIdentifier UMA price identifier to request.
    /// @param requestRules Raw UMA request rules supplied by the requester.
    /// @param minimumLiveness Minimum custom liveness the oracle initializer may use.
    /// @param maximumLiveness Target maximum custom liveness for offchain initialization.
    function registerRequest(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes calldata requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) external;

    /// @notice Forwards updated request rules to the Managed OO, which records them against the active OO request.
    /// @dev Does not change the active OO request tuple or reporter lookup key. The reporter forwards the original
    /// request rules to Managed OO, so updates do not create or reserve a `(priceIdentifier, updatedRules)` alias.
    /// Consumers should treat requestId as the stable reporter identity and read canonical update history from Managed OO.
    /// @param requestId Registered request ID.
    /// @param updatedRules Updated prediction market request rules.
    function updateRequestRules(bytes32 requestId, bytes calldata updatedRules) external;

    /// @notice Updates the reward on an initialized, unresolved Managed OO request before a proposal is made.
    /// @dev Uses the reward currently stored by Managed OO as the source of truth. Reward increases are funded from
    /// this reporter's configured reward-currency balance.
    /// @param requestId Registered request ID.
    /// @param newReward New reward amount for the active Managed OO request.
    function setRequestReward(bytes32 requestId, uint256 newReward) external;

    /// @notice Creates the Managed OO request for a registered request.
    /// @dev Pays the reward from the reporter's reward-currency balance and, when the Managed OO allowance is below
    /// the reward, tops it up to an unbounded approval for the trusted oracle instead of approving per request. A
    /// duplicate ID reuses the shared request; if registered after resolution, its first initialization triggers the
    /// resolution hook immediately, while subsequent initializations are no-ops.
    /// @param requestId Registered request ID.
    /// @param reward Reward offered to a successful OO proposer.
    /// @param proposalBond Bond requested from OO proposers/disputers, or zero to use the OO default. The effective
    /// proposal bond can differ if Managed OO request-manager preconfigs apply at proposal time.
    /// @param liveness Custom OO liveness period at or above the registered minimum. It may exceed the registered
    /// target maximum and remains subject to Managed OO constraints. The effective proposal liveness can differ if
    /// Managed OO request-manager preconfigs apply at proposal time.
    function initializeRequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness) external;

    /// @notice Allows an enabled oracle initializer to create a replacement Managed OO request after a callback opens the gate.
    /// @dev Pays the reward from the reporter's reward-currency balance and, when the Managed OO allowance is below
    /// the reward, tops it up to an unbounded approval for the trusted oracle instead of approving per request.
    /// @param requestId Registered request ID.
    /// @param reward Reward amount for the replacement request.
    /// @param proposalBond Bond requested from OO proposers/disputers, or zero to use the OO default. The effective
    /// proposal bond can differ if Managed OO request-manager preconfigs apply at proposal time.
    /// @param liveness Custom OO liveness period at or above the registered minimum. It may exceed the registered
    /// target maximum and remains subject to Managed OO constraints. The effective proposal liveness can differ if
    /// Managed OO request-manager preconfigs apply at proposal time.
    function rerequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness) external;

    /// @notice Updates the remaining manual re-request budget for an initialized unresolved request.
    /// @dev This operational top-up/adjustment knob does not permanently cap P4 recovery. A DVM-resolved P4 settlement
    /// refreshes the request's manual budget to the current default before automatic or manual recovery continues.
    /// @param requestId Registered request ID.
    /// @param newManualRerequestsRemaining New remaining manual re-request budget, capped by the current default.
    function setRequestRerequestBudget(bytes32 requestId, uint256 newManualRerequestsRemaining) external;

    /// @notice Returns whether Managed OO settlement has produced a final reporter outcome for requestId.
    /// @param requestId Registered request ID.
    /// @return True if the reporter has stored a final outcome.
    function isRequestResolved(bytes32 requestId) external view returns (bool);

    /// @notice Returns the final raw UMA outcome for requestId after non-P4 trusted resolver settlement.
    /// @param requestId Registered request ID.
    /// @return Final raw UMA outcome.
    function getRequestResolution(bytes32 requestId) external view returns (int256);

    /// @notice Returns the stored reporter lifecycle state for requestId.
    /// @param requestId Registered request ID.
    /// @return Stored reporter request state.
    function getRequest(bytes32 requestId) external view returns (RequestData memory);

    /// @notice Returns the request ID registered for a UMA request identity.
    /// @dev `requestRules` must be the original rules supplied to registerRequest. Rules posted through
    /// updateRequestRules are informational history and are not valid replacement lookup keys.
    /// @param priceIdentifier UMA price identifier.
    /// @param requestRules Original raw UMA request rules registered for the request.
    /// @return requestId Registered request ID.
    function getRequestId(bytes32 priceIdentifier, bytes calldata requestRules) external view returns (bytes32);

    /// @notice Claims a Managed OO deferred reward payout owed to this reporter.
    /// @param repaymentAddress Address to receive the claimed payout.
    function claimDeferredPayout(address repaymentAddress) external;

    /// @notice Sweeps ERC20 or native token funds held by the reporter to recipient.
    /// @param token ERC20 token to sweep, or zero address for native token.
    /// @param recipient Address that receives swept funds.
    /// @param amount Amount to sweep.
    function sweep(address token, address recipient, uint256 amount) external;
}
