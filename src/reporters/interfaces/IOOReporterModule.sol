// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IOOReporterModule
/// @notice Minimal Polymarket V2 reporter module surface used for automatic result reporting.
/// @custom:security-contact bugs@umaproject.org
interface IOOReporterModule {
    /// @notice Pulls and reports the settled result for a Polymarket request.
    /// @param requestId Polymarket request identifier registered with OOReporter.
    function report(bytes32 requestId) external;
}
