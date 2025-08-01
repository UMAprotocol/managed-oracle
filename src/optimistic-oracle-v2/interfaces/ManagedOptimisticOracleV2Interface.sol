// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Events and Errors for the ManagedOptimisticOracleV2 contract.
 * @notice Contains events for request manager management, bond and liveness updates, and whitelists,
 * and custom errors for various conditions.
 */
abstract contract ManagedOptimisticOracleV2Interface {
    /// @notice Thrown when a requester is not on the requester whitelist.
    error RequesterNotWhitelisted();
    /// @notice Thrown when a bond is set lower than the minimum allowed bond.
    error BondBelowMinimumBond();
    /// @notice Thrown when a bond is set higher than the maximum allowed bond.
    error BondExceedsMaximumBond();
    /// @notice Thrown when a liveness is set lower than the minimum allowed liveness.
    error LivenessTooLow();
    /// @notice Thrown when a proposer is not on the effective proposer whitelist.
    error ProposerNotWhitelisted();
    /// @notice Thrown when the message sender is not on the effective proposer whitelist for a proposal.
    error SenderNotWhitelisted();
    /// @notice Thrown when a whitelist does not support the required interface.
    error UnsupportedWhitelistInterface();
    /// @notice Thrown when minimum bond is higher than maximum bond.
    error MinimumBondAboveMaximumBond();

    event RequestManagerAdded(address indexed requestManager);
    event RequestManagerRemoved(address indexed requestManager);
    event AllowedBondRangeUpdated(IERC20 indexed currency, uint256 newMinimumBond, uint256 newMaximumBond);
    event MinimumLivenessUpdated(uint256 newMinimumLiveness);
    event DefaultProposerWhitelistUpdated(address indexed newWhitelist);
    event RequesterWhitelistUpdated(address indexed newWhitelist);
    event CustomBondSet(
        bytes32 indexed managedRequestId,
        address requester,
        bytes32 indexed identifier,
        bytes ancillaryData,
        IERC20 indexed currency,
        uint256 bond
    );
    event CustomLivenessSet(
        bytes32 indexed managedRequestId,
        address indexed requester,
        bytes32 indexed identifier,
        bytes ancillaryData,
        uint256 customLiveness
    );
    event CustomProposerWhitelistSet(
        bytes32 indexed managedRequestId,
        address requester,
        bytes32 indexed identifier,
        bytes ancillaryData,
        address indexed newWhitelist
    );
}
