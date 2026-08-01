// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MulticallUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IOOReporter, RequestData, RerequestTrigger, RerequestType} from "./interfaces/IOOReporter.sol";
import {IOptimisticOracleV2} from "./interfaces/IOptimisticOracleV2.sol";
import {IOptimisticRequester} from "./interfaces/IOptimisticRequester.sol";

/// @title OOReporter
/// @notice UMA-owned Managed OO requester and raw outcome source for prediction market request IDs.
/// @dev Approved requesters register request IDs here. UMA initializes and manages the OO lifecycle,
///      then this reporter stores the final raw UMA price for market-side translation. Enabled requesters
///      share one owner-managed request namespace and are expected to coordinate on request identity.
/// @custom:security-contact bugs@umaproject.org
contract OOReporter is
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    MulticallUpgradeable,
    IOOReporter,
    IOptimisticRequester
{
    using SafeERC20 for IERC20;

    error OwnershipRenunciationDisabled();

    /*--------------------------------------------------------------
                             CONSTANTS
    --------------------------------------------------------------*/

    /// @notice Maximum request rules length accepted by the Optimistic Oracle.
    uint256 public constant MAX_REQUEST_RULES = 8139;
    /// @notice Upper bound inherited from OptimisticOracleV2 custom liveness validation.
    uint256 public constant MAXIMUM_CUSTOM_LIVENESS = 5200 weeks;
    /// @notice UMA sentinel price for "too early" / unresolvable (P4).
    int256 public constant P4_PRICE = type(int256).min;

    /*--------------------------------------------------------------
                              STORAGE
    --------------------------------------------------------------*/

    /// @custom:storage-location erc7201:uma.storage.OOReporter
    struct OOReporterStorage {
        /// @notice Managed Optimistic Oracle V2 used for reporter-created requests.
        IOptimisticOracleV2 optimisticOracle;
        /// @notice ERC20 reward currency used for all reporter-created requests.
        IERC20 rewardCurrency;
        /// @notice Mapping of requester address to enabled status.
        mapping(address requester => bool enabled) isRequester;
        /// @notice Mapping of UMA oracle initializer address to enabled status.
        mapping(address oracleInitializer => bool enabled) isOracleInitializer;
        /// @notice Mapping of requester-defined request ID to reporter request state.
        mapping(bytes32 requestId => RequestData request) requests;
        /// @notice Mapping of `(priceIdentifier, requestRules)` key to requester-defined request ID.
        mapping(bytes32 reporterRequestKey => bytes32 requestId) requestIdsByReporterKey;
        /// @notice Default re-request budget seeded onto each request at initialization.
        uint256 defaultRerequestBudget;
        /// @notice Whether first-dispute and P4 automatic re-requests are enabled.
        bool automaticRerequestsEnabled;
    }

    // keccak256(abi.encode(uint256(keccak256("uma.storage.OOReporter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OOReporterStorageLocation =
        0xe597f8c3629f5ca2bbd4f416c338811ff317bd2d6db5ce34f2567207506cc400;

    /*--------------------------------------------------------------
                      CONSTRUCTOR & MODIFIERS
    --------------------------------------------------------------*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _getStorage() private pure returns (OOReporterStorage storage $) {
        assembly {
            $.slot := OOReporterStorageLocation
        }
    }

    modifier onlyRequester() {
        if (!isRequester(msg.sender)) revert CallerNotRequester();
        _;
    }

    modifier onlyOracleInitializer() {
        if (!isOracleInitializer(msg.sender)) revert CallerNotOracleInitializer();
        _;
    }

    modifier onlyOptimisticOracle() {
        if (msg.sender != address(optimisticOracle())) revert CallerNotOptimisticOracle();
        _;
    }

    /*--------------------------------------------------------------
                    EXTERNAL & PUBLIC FUNCTIONS
    --------------------------------------------------------------*/

    /// @inheritdoc IOOReporter
    function initialize(
        address initialOwner,
        address _optimisticOracle,
        address _rewardCurrency,
        address initialOracleInitializer,
        address initialRequester,
        uint256 initialDefaultRerequestBudget
    ) external initializer {
        if (initialOwner == address(0) || _optimisticOracle == address(0) || _rewardCurrency == address(0)) {
            revert AddressCannotBeZero();
        }

        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __Multicall_init();

        OOReporterStorage storage $ = _getStorage();
        $.optimisticOracle = IOptimisticOracleV2(_optimisticOracle);
        $.rewardCurrency = IERC20(_rewardCurrency);

        if (initialOracleInitializer != address(0)) {
            _setOracleInitializerEnabled(initialOracleInitializer, true);
        }
        if (initialRequester != address(0)) {
            _setRequesterEnabled(initialRequester, true);
        }

        $.defaultRerequestBudget = initialDefaultRerequestBudget;
        $.automaticRerequestsEnabled = true;
        emit DefaultRerequestBudgetSet(initialDefaultRerequestBudget);
        emit AutomaticRerequestsEnabledSet(true);
    }

    /// @notice Ownership renunciation is disabled to preserve administrative and upgrade authority.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    /// @notice Returns the configured Managed Optimistic Oracle V2 address.
    /// @return Configured Managed Optimistic Oracle V2.
    function optimisticOracle() public view returns (IOptimisticOracleV2) {
        return _getStorage().optimisticOracle;
    }

    /// @notice Returns the reward currency used for reporter-created Managed OO requests.
    /// @return Configured ERC20 reward currency.
    function rewardCurrency() public view returns (IERC20) {
        return _getStorage().rewardCurrency;
    }

    /// @inheritdoc IOOReporter
    function isRequester(address candidate) public view returns (bool) {
        return _getStorage().isRequester[candidate];
    }

    /// @inheritdoc IOOReporter
    function isOracleInitializer(address candidate) public view returns (bool) {
        return _getStorage().isOracleInitializer[candidate];
    }

    /// @notice Returns the request ID registered for a reporter request key.
    /// @param reporterRequestKey Key derived from the UMA price identifier and request rules.
    /// @return requestId Registered request ID, or zero if none is registered.
    function requestIdsByReporterKey(bytes32 reporterRequestKey) public view returns (bytes32 requestId) {
        return _getStorage().requestIdsByReporterKey[reporterRequestKey];
    }

    /// @inheritdoc IOOReporter
    function defaultRerequestBudget() public view returns (uint256) {
        return _getStorage().defaultRerequestBudget;
    }

    /// @inheritdoc IOOReporter
    function automaticRerequestsEnabled() public view returns (bool) {
        return _getStorage().automaticRerequestsEnabled;
    }

    /// @inheritdoc IOOReporter
    function setRequesterEnabled(address requester, bool enabled) external onlyOwner {
        _setRequesterEnabled(requester, enabled);
    }

    /// @inheritdoc IOOReporter
    function setOracleInitializerEnabled(address oracleInitializer, bool enabled) external onlyOwner {
        _setOracleInitializerEnabled(oracleInitializer, enabled);
    }

    /// @inheritdoc IOOReporter
    function setDefaultRerequestBudget(uint256 newDefaultRerequestBudget) external onlyOwner {
        if (defaultRerequestBudget() == newDefaultRerequestBudget) revert DefaultRerequestBudgetUnchanged();

        _getStorage().defaultRerequestBudget = newDefaultRerequestBudget;
        emit DefaultRerequestBudgetSet(newDefaultRerequestBudget);
    }

    /// @inheritdoc IOOReporter
    function setAutomaticRerequestsEnabled(bool enabled) external onlyOwner {
        if (automaticRerequestsEnabled() == enabled) revert AutomaticRerequestsEnabledUnchanged();

        _getStorage().automaticRerequestsEnabled = enabled;
        emit AutomaticRerequestsEnabledSet(enabled);
    }

    /// @inheritdoc IOOReporter
    function registerRequest(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes calldata requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) external onlyRequester {
        if (requestId == bytes32(0) || priceIdentifier == bytes32(0)) {
            revert InvalidRequestKey();
        }
        if (requestRules.length == 0 || requestRules.length > MAX_REQUEST_RULES) {
            revert InvalidRequestRules();
        }
        if (minimumLiveness > maximumLiveness) revert InvalidLivenessRange(minimumLiveness, maximumLiveness);

        // This is a registration-time sanity check; oracle liveness config can drift before initialization.
        // Requesters should preserve an admin override path for ranges that later become invalid.
        uint256 oracleMinimumLiveness = optimisticOracle().minimumDisputeWindow();
        if (minimumLiveness >= MAXIMUM_CUSTOM_LIVENESS || maximumLiveness < oracleMinimumLiveness) {
            revert LivenessRangeOutsideManagedBounds(
                minimumLiveness, maximumLiveness, oracleMinimumLiveness, MAXIMUM_CUSTOM_LIVENESS
            );
        }

        OOReporterStorage storage $ = _getStorage();
        RequestData storage request = $.requests[requestId];
        if (request.registered) revert RequestAlreadyRegistered();

        bytes32 reporterRequestKey = _reporterRequestKey(priceIdentifier, requestRules);
        bytes32 existingRequestId = requestIdsByReporterKey(reporterRequestKey);
        if (existingRequestId != bytes32(0)) revert ReporterRequestKeyAlreadyRegistered(existingRequestId);

        request.registered = true;
        request.requester = msg.sender;
        request.priceIdentifier = priceIdentifier;
        request.requestRules = requestRules;
        request.minimumLiveness = minimumLiveness;
        request.maximumLiveness = maximumLiveness;
        $.requestIdsByReporterKey[reporterRequestKey] = requestId;

        emit RequestRegistered(requestId, msg.sender, priceIdentifier, requestRules, minimumLiveness, maximumLiveness);
    }

    /// @inheritdoc IOOReporter
    function updateRequestRules(bytes32 requestId, bytes calldata updatedRules) external onlyRequester {
        RequestData storage request = _requireRegistered(requestId);
        if (request.resolved) revert RequestAlreadyResolved();
        if (msg.sender != request.requester) revert CallerNotRequestRegistrar();

        optimisticOracle().updateRequestRules(request.priceIdentifier, request.requestRules, updatedRules);

        emit RequestRulesUpdated(requestId, block.timestamp, msg.sender, updatedRules);
    }

    /// @inheritdoc IOOReporter
    function initializeRequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness)
        external
        onlyOracleInitializer
    {
        RequestData storage request = _requireRegistered(requestId);
        if (request.initialized) revert RequestAlreadyInitialized();
        if (request.resolved) revert RequestAlreadyResolved();
        _requireValidRequestLiveness(request, liveness);

        uint256 requestTimestamp = block.timestamp;
        uint256 manualRerequestsRemaining = defaultRerequestBudget();
        request.initialized = true;
        request.oracleInitializer = msg.sender;
        request.requestTimestamp = requestTimestamp;
        request.reward = reward;
        request.proposalBond = proposalBond;
        request.liveness = liveness;
        request.manualRerequestsRemaining = manualRerequestsRemaining;

        _requestPrice(request.priceIdentifier, requestTimestamp, request.requestRules, reward, proposalBond, liveness);

        emit RequestInitialized(
            requestId,
            requestTimestamp,
            msg.sender,
            request.priceIdentifier,
            request.requestRules,
            address(rewardCurrency()),
            reward,
            proposalBond,
            liveness,
            manualRerequestsRemaining
        );
    }

    /// @inheritdoc IOOReporter
    function rerequest(bytes32 requestId, uint256 reward, uint256 proposalBond, uint64 liveness)
        external
        onlyOracleInitializer
    {
        RequestData storage request = _requireRegistered(requestId);
        if (!request.initialized) revert RequestNotInitialized();
        if (request.resolved) revert RequestAlreadyResolved();
        if (!request.rerequestAllowed) revert RequestRerequestNotAllowed();
        if (request.manualRerequestsRemaining == 0) revert RequestRerequestBudgetExhausted();
        _requireValidRequestLiveness(request, liveness);

        uint256 previousRequestTimestamp = _executeRerequest(request, reward, proposalBond, liveness, msg.sender);

        request.manualRerequestsRemaining -= 1;

        _emitRequestRerequested(requestId, request, previousRequestTimestamp, msg.sender, RerequestType.Manual);
    }

    /// @inheritdoc IOOReporter
    function setRequestRerequestBudget(bytes32 requestId, uint256 newManualRerequestsRemaining) external onlyOwner {
        RequestData storage request = _requireRegistered(requestId);
        if (!request.initialized) revert RequestNotInitialized();
        if (request.resolved) revert RequestAlreadyResolved();
        uint256 budgetCeiling = defaultRerequestBudget();
        if (newManualRerequestsRemaining > budgetCeiling) {
            revert RequestRerequestBudgetAboveDefault(newManualRerequestsRemaining, budgetCeiling);
        }
        if (request.manualRerequestsRemaining == newManualRerequestsRemaining) {
            revert RequestRerequestBudgetUnchanged();
        }

        request.manualRerequestsRemaining = newManualRerequestsRemaining;

        emit RequestRerequestBudgetSet(requestId, newManualRerequestsRemaining);
    }

    /// @notice Managed OO dispute callback. Attempts one auto re-request, otherwise opens the manual gate.
    /// @inheritdoc IOptimisticRequester
    function priceDisputed(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256)
        external
        override
        onlyOptimisticOracle
    {
        (bytes32 requestId, RequestData storage request, bool shouldIgnore) =
            _loadCallbackRequest(identifier, timestamp, requestRules);
        if (shouldIgnore || request.resolved) return;

        if (!request.automaticDisputeRerequestUsed && _shouldAttemptAutomaticRerequest(request)) {
            try this.executeAutomaticRerequest(requestId, RerequestType.AutomaticDispute) {
                request.automaticDisputeRerequestUsed = true;
                return;
            } catch {
                emit AutomaticRerequestFailed(requestId, timestamp, RerequestType.AutomaticDispute);
            }
        }

        _allowRerequest(requestId, timestamp, request, RerequestTrigger.Dispute);
    }

    /// @notice Managed OO settlement callback. Stores final prices; on P4, attempts an auto re-request or opens the gate.
    /// @inheritdoc IOptimisticRequester
    function priceSettled(bytes32 identifier, uint256 timestamp, bytes memory requestRules, int256 price)
        external
        override
        onlyOptimisticOracle
    {
        (bytes32 requestId, RequestData storage request, bool shouldIgnore) =
            _loadCallbackRequest(identifier, timestamp, requestRules);
        if (shouldIgnore || request.resolved) return;

        if (price == P4_PRICE) {
            // Reporter requests are event-based, so Managed OO rejects proposed P4; P4 here is DVM-resolved.
            // Refill the manual budget so an enabled UMA-controlled oracle initializer can continue recovery without
            // owner intervention if automation is unavailable.
            uint256 budget = defaultRerequestBudget();
            if (request.manualRerequestsRemaining != budget) {
                request.manualRerequestsRemaining = budget;
                emit RequestRerequestBudgetSet(requestId, budget);
            }
            if (_shouldAttemptAutomaticRerequest(request)) {
                try this.executeAutomaticRerequest(requestId, RerequestType.AutomaticInvalidSettlement) {
                    return;
                } catch {
                    emit AutomaticRerequestFailed(requestId, timestamp, RerequestType.AutomaticInvalidSettlement);
                }
            }
            _allowRerequest(requestId, timestamp, request, RerequestTrigger.InvalidSettlement);
        } else {
            request.resolved = true;
            request.outcome = price;
            request.rerequestAllowed = false;

            emit RequestResolved(requestId, timestamp, price);
        }
    }

    /// @inheritdoc IOOReporter
    function isRequestResolved(bytes32 requestId) external view returns (bool) {
        return _requireRegistered(requestId).resolved;
    }

    /// @inheritdoc IOOReporter
    function getRequestResolution(bytes32 requestId) external view returns (int256) {
        RequestData storage request = _requireRegistered(requestId);
        if (!request.resolved) revert RequestResolutionUnavailable();
        return request.outcome;
    }

    /// @inheritdoc IOOReporter
    function getRequest(bytes32 requestId) external view returns (RequestData memory) {
        return _requireRegistered(requestId);
    }

    /// @inheritdoc IOOReporter
    function getRequestId(bytes32 priceIdentifier, bytes calldata requestRules)
        public
        view
        returns (bytes32 requestId)
    {
        requestId = requestIdsByReporterKey(_reporterRequestKey(priceIdentifier, requestRules));
        if (requestId == bytes32(0)) revert RequestNotRegistered();
    }

    /// @dev Keeps all re-request failure points inside the call frame caught by the callbacks.
    function executeAutomaticRerequest(bytes32 requestId, RerequestType rerequestType) external {
        if (msg.sender != address(this)) revert CallerNotSelf();

        RequestData storage request = _requireRegistered(requestId);
        _executeAutomaticRerequest(requestId, request, rerequestType);
    }

    /// @inheritdoc IOOReporter
    function claimDeferredPayout(address repaymentAddress) external onlyOwner {
        if (repaymentAddress == address(0)) revert AddressCannotBeZero();

        IERC20 currency = rewardCurrency();
        IOptimisticOracleV2 oracle = optimisticOracle();
        uint256 amount = oracle.deferredPayouts(currency, address(this));
        if (amount == 0) revert DeferredPayoutUnavailable(address(currency));

        oracle.claimDeferredPayout(currency, repaymentAddress);

        emit DeferredPayoutClaimed(address(currency), repaymentAddress, amount);
    }

    /// @inheritdoc IOOReporter
    function sweep(address token, address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert AddressCannotBeZero();

        if (token == address(0)) {
            Address.sendValue(payable(recipient), amount);
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }

        emit FundsSwept(token, recipient, amount);
    }

    /*--------------------------------------------------------------
                         INTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @dev Creates a replacement request with a strictly greater request timestamp than the previous request.
    function _executeRerequest(
        RequestData storage request,
        uint256 reward,
        uint256 proposalBond,
        uint64 liveness,
        address oracleInitializer
    ) private returns (uint256 previousRequestTimestamp) {
        previousRequestTimestamp = request.requestTimestamp;
        uint256 requestTimestamp = block.timestamp;
        if (requestTimestamp <= previousRequestTimestamp) {
            revert RequestRerequestTimestampNotAdvanced(requestTimestamp, previousRequestTimestamp);
        }

        request.requestTimestamp = requestTimestamp;
        request.reward = reward;
        request.proposalBond = proposalBond;
        request.liveness = liveness;
        request.oracleInitializer = oracleInitializer;
        request.rerequestAllowed = false;

        _requestPrice(request.priceIdentifier, requestTimestamp, request.requestRules, reward, proposalBond, liveness);
    }

    /// @dev Creates a replacement request without spending manual budget.
    function _executeAutomaticRerequest(bytes32 requestId, RequestData storage request, RerequestType rerequestType)
        private
    {
        uint256 previousRequestTimestamp =
            _executeRerequest(request, request.reward, request.proposalBond, request.liveness, address(this));
        _emitRequestRerequested(requestId, request, previousRequestTimestamp, address(this), rerequestType);
    }

    /// @dev External checks must remain inside the catchable self-call.
    function _shouldAttemptAutomaticRerequest(RequestData storage request) private view returns (bool) {
        if (!automaticRerequestsEnabled()) return false;
        return block.timestamp > request.requestTimestamp;
    }

    /// @dev Emits the post-state for a replacement Managed OO request.
    function _emitRequestRerequested(
        bytes32 requestId,
        RequestData storage request,
        uint256 previousRequestTimestamp,
        address rerequester,
        RerequestType rerequestType
    ) private {
        emit RequestRerequested(
            requestId,
            request.requestTimestamp,
            rerequester,
            rerequestType,
            previousRequestTimestamp,
            address(rewardCurrency()),
            request.reward,
            request.proposalBond,
            request.liveness,
            request.manualRerequestsRemaining
        );
    }

    /// @dev Creates a Managed OO request and applies event-based, callback, bond, and liveness settings.
    function _requestPrice(
        bytes32 priceIdentifier,
        uint256 requestTimestamp,
        bytes memory requestRules,
        uint256 reward,
        uint256 proposalBond,
        uint64 liveness
    ) private {
        IERC20 currency = rewardCurrency();
        IOptimisticOracleV2 oracle = optimisticOracle();
        if (reward > 0) {
            uint256 balance = currency.balanceOf(address(this));
            if (balance < reward) revert InsufficientRewardBalance(address(currency), balance, reward);
            if (currency.allowance(address(this), address(oracle)) < reward) {
                currency.forceApprove(address(oracle), type(uint256).max);
            }
        }

        oracle.requestPrice(priceIdentifier, requestTimestamp, requestRules, currency, reward);
        oracle.setEventBased(priceIdentifier, requestTimestamp, requestRules);
        oracle.setCallbacks(priceIdentifier, requestTimestamp, requestRules, false, true, true);
        if (proposalBond > 0) {
            oracle.setBond(priceIdentifier, requestTimestamp, requestRules, proposalBond);
        }

        oracle.setCustomLiveness(priceIdentifier, requestTimestamp, requestRules, liveness);
    }

    /// @dev Keeps the reporter off Managed OO's default liveness path and within the registered bounds.
    function _requireValidRequestLiveness(RequestData storage request, uint64 liveness) private view {
        if (liveness == 0) revert RequestLivenessCannotBeZero();
        if (liveness < request.minimumLiveness || liveness > request.maximumLiveness) {
            revert RequestLivenessOutOfRange(liveness, request.minimumLiveness, request.maximumLiveness);
        }
    }

    /// @dev Updates requester membership and rejects zero addresses or unchanged state.
    function _setRequesterEnabled(address requester, bool enabled) private {
        if (requester == address(0)) revert AddressCannotBeZero();
        if (isRequester(requester) == enabled) revert RequesterEnabledUnchanged();

        _getStorage().isRequester[requester] = enabled;
        emit RequesterEnabledSet(requester, enabled);
    }

    /// @dev Updates UMA oracle initializer membership and rejects zero addresses or unchanged state.
    function _setOracleInitializerEnabled(address oracleInitializer, bool enabled) private {
        if (oracleInitializer == address(0)) revert AddressCannotBeZero();
        if (isOracleInitializer(oracleInitializer) == enabled) revert OracleInitializerEnabledUnchanged();

        _getStorage().isOracleInitializer[oracleInitializer] = enabled;
        emit OracleInitializerEnabledSet(oracleInitializer, enabled);
    }

    /// @dev Loads the callback request for the exact active request and marks stale or unknown callbacks as ignored.
    function _loadCallbackRequest(bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        private
        view
        returns (bytes32 requestId, RequestData storage request, bool shouldIgnore)
    {
        requestId = requestIdsByReporterKey(_reporterRequestKey(identifier, requestRules));
        request = _getStorage().requests[requestId];
        shouldIgnore = !request.initialized || timestamp != request.requestTimestamp;
    }

    /// @dev Opens the re-request gate once for the active request timestamp.
    function _allowRerequest(
        bytes32 requestId,
        uint256 requestTimestamp,
        RequestData storage request,
        RerequestTrigger trigger
    ) private {
        if (request.rerequestAllowed) return;

        request.rerequestAllowed = true;
        emit RequestRerequestAllowed(requestId, requestTimestamp, trigger);
    }

    /// @dev Returns a registered request or reverts for unknown IDs.
    function _requireRegistered(bytes32 requestId) private view returns (RequestData storage request) {
        request = _getStorage().requests[requestId];
        if (!request.registered) revert RequestNotRegistered();
    }

    /// @dev Derives the callback lookup key from UMA request identity fields that are stable across re-requests.
    function _reporterRequestKey(bytes32 identifier, bytes memory requestRules) internal pure returns (bytes32) {
        return keccak256(abi.encode(identifier, requestRules));
    }

    /// @dev Restricts implementation upgrades to the current owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
