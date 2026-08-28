// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// Source: https://github.com/UMAprotocol/managed-oracle/blob/5fffebba9e3fecee6d6850dc4cc53f37647a6659/src/optimistic-oracle-v2/implementation/OptimisticOracleV2.sol#L31-L67
// Kept local to avoid importing the full OptimisticOracleV2 implementation and dependency graph for callback ABI only.

/// @title IOptimisticRequester
/// @notice Callback ABI used by Managed Optimistic Oracle V2.
/// @dev This contract does not work with ERC777 collateral currencies or any others that call into the receiver on
/// transfer(). Using an ERC777 token would allow a user to maliciously grief other participants while also losing
/// money themselves.
/// This local interface intentionally omits the original priceProposed callback because OOReporter does not enable
/// proposal callbacks for its Managed OO requests.
/// @custom:security-contact bugs@umaproject.org
interface IOptimisticRequester {
    /// @notice Callback for disputes.
    /// @param identifier Price identifier being requested.
    /// @param timestamp Timestamp of the price being requested.
    /// @param requestRules Request rules of the price being requested.
    /// @param refund Refund amount in the case that refundOnDispute was enabled. Note that the refund may be deferred
    /// instead of received immediately if the transfer fails, such as when the recipient is blacklisted. In such cases,
    /// the refund can be claimed later via claimDeferredPayout.
    function priceDisputed(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256 refund) external;

    /// @notice Callback for settlement.
    /// @param identifier Price identifier being requested.
    /// @param timestamp Timestamp of the price being requested.
    /// @param requestRules Request rules of the price being requested.
    /// @param price Price that was resolved by the escalation process.
    function priceSettled(bytes32 identifier, uint256 timestamp, bytes memory requestRules, int256 price) external;
}
