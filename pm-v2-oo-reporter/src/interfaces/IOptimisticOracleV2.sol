// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IOptimisticOracleV2
/// @notice Minimal Managed Optimistic Oracle V2 surface used by OOReporter.
/// @custom:security-contact bugs@umaproject.org
interface IOptimisticOracleV2 {
    /// @notice Custom settings associated with a Managed Optimistic Oracle request.
    struct RequestSettings {
        /// @notice True if the request is set to be event-based.
        bool eventBased;
        /// @notice True if the requester should be refunded its reward on dispute.
        bool refundOnDispute;
        /// @notice True if the price-proposed callback is enabled.
        bool callbackOnPriceProposed;
        /// @notice True if the price-disputed callback is enabled.
        bool callbackOnPriceDisputed;
        /// @notice True if the price-settled callback is enabled.
        bool callbackOnPriceSettled;
        /// @notice Bond that the proposer and disputer must pay on top of the final fee.
        uint256 bond;
        /// @notice Custom liveness value set by the requester.
        uint256 customLiveness;
    }

    /// @notice Current data structure containing all information about a price request.
    struct Request {
        /// @notice Address of the proposer.
        address proposer;
        /// @notice Address of the disputer.
        address disputer;
        /// @notice ERC20 token used to pay rewards and fees.
        IERC20 currency;
        /// @notice True if the request is settled.
        bool settled;
        /// @notice Custom settings associated with the request.
        RequestSettings requestSettings;
        /// @notice Price that the proposer submitted.
        int256 proposedPrice;
        /// @notice Price resolved once the request is settled.
        int256 resolvedPrice;
        /// @notice Time at which the request auto-settles without a dispute.
        uint256 expirationTime;
        /// @notice Amount of the currency to pay to the proposer on settlement.
        uint256 reward;
        /// @notice Final fee to pay to the Store upon request to the DVM.
        uint256 finalFee;
        /// @notice Time of the proposal.
        uint256 proposalTime;
    }

    /// @notice Requests a new price.
    /// @param identifier Price identifier being requested.
    /// @param timestamp Timestamp of the price being requested.
    /// @param requestRules Request rules representing additional args being passed with the price request.
    /// @param currency ERC20 token used for payment of rewards and fees.
    /// @param reward Reward offered to a successful proposer. Will be pulled from the caller.
    /// @return totalBond Default bond plus final fee that the proposer and disputer will be required to pay.
    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory requestRules,
        IERC20 currency,
        uint256 reward
    ) external returns (uint256 totalBond);

    /// @notice Set the proposal bond associated with a price request.
    /// @param identifier Price identifier to identify the existing request.
    /// @param timestamp Timestamp to identify the existing request.
    /// @param requestRules Request rules of the price being requested.
    /// @param bond Custom bond amount to set.
    /// @return totalBond New bond plus final fee that the proposer and disputer will be required to pay.
    function setBond(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256 bond)
        external
        returns (uint256 totalBond);

    /// @notice Sets a custom liveness value for the request.
    /// @dev Liveness is the amount of time a proposal must wait before being auto-resolved.
    /// @param identifier Price identifier to identify the existing request.
    /// @param timestamp Timestamp to identify the existing request.
    /// @param requestRules Request rules of the price being requested.
    /// @param customLiveness New custom liveness.
    function setCustomLiveness(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256 customLiveness)
        external;

    /// @notice Sets the request to be event-based.
    /// @dev Event-based requests are evaluated at proposal time, disallow the too early response, and automatically
    /// enable reward refunds on dispute.
    /// @param identifier Price identifier to identify the existing request.
    /// @param timestamp Timestamp to identify the existing request.
    /// @param requestRules Request rules of the price being requested.
    function setEventBased(bytes32 identifier, uint256 timestamp, bytes memory requestRules) external;

    /// @notice Sets which callbacks should be enabled for the request.
    /// @param identifier Price identifier to identify the existing request.
    /// @param timestamp Timestamp to identify the existing request.
    /// @param requestRules Request rules of the price being requested.
    /// @param callbackOnPriceProposed Whether to enable the price-proposed callback.
    /// @param callbackOnPriceDisputed Whether to enable the price-disputed callback.
    /// @param callbackOnPriceSettled Whether to enable the price-settled callback.
    function setCallbacks(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory requestRules,
        bool callbackOnPriceProposed,
        bool callbackOnPriceDisputed,
        bool callbackOnPriceSettled
    ) external;

    /// @notice Records a request rules update against the request identified by the caller, identifier, and rules.
    /// @dev Keyed without a timestamp, so it applies before initialization and across re-requests.
    /// @param identifier Price identifier to identify the existing request.
    /// @param requestRules Request rules of the price being requested.
    /// @param updatedRules Updated request rules to record for the request.
    function updateRequestRules(bytes32 identifier, bytes memory requestRules, bytes memory updatedRules) external;

    /// @notice Gets current request data for an OO request tuple.
    /// @param requester Sender of the initial price request.
    /// @param identifier Price identifier to identify the existing request.
    /// @param timestamp Timestamp to identify the existing request.
    /// @param requestRules Request rules of the price being requested.
    /// @return The Request data structure.
    function getRequest(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        external
        view
        returns (Request memory);

    /// @notice Returns the deferred payout amount owed to a recipient for a currency.
    /// @param currency ERC20 token used for the deferred payout.
    /// @param deferredRecipient Original recipient whose payout was deferred.
    /// @return Deferred payout amount.
    function deferredPayouts(IERC20 currency, address deferredRecipient) external view returns (uint256);

    /// @notice Claims a deferred payout for a given currency to the provided repayment address.
    /// @param currency ERC20 token used for the deferred payout.
    /// @param repaymentAddress Address to which the payout will be sent.
    function claimDeferredPayout(IERC20 currency, address repaymentAddress) external;

    /// @notice Returns the current minimum liveness accepted by Managed OO custom liveness validation.
    /// @return Current minimum dispute window.
    function minimumDisputeWindow() external view returns (uint256);
}
