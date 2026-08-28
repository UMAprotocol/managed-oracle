// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {OOReporter} from "../OOReporter.sol";
import {IOOReporterModule} from "../interfaces/IOOReporterModule.sol";

/// @title PolymarketOOReporter
/// @notice OOReporter variant that automatically relays final results to the registering Polymarket V2 module.
/// @custom:security-contact bugs@umaproject.org
contract PolymarketOOReporter is OOReporter {
    /// @notice Emitted when automatic reporting returns without reverting.
    event ReportCallbackSucceeded(bytes32 indexed requestId, address indexed reporterModule);

    /// @notice Emitted when automatic reporting fails and the permissionless report must be retried.
    event ReportCallbackFailed(bytes32 indexed requestId, address indexed reporterModule);

    /// @dev Keeps Managed OO settlement nonblocking when the downstream Polymarket report reverts.
    function _onRequestResolved(bytes32 requestId, address requester) internal override {
        try IOOReporterModule(requester).report(requestId) {
            emit ReportCallbackSucceeded(requestId, requester);
        } catch {
            emit ReportCallbackFailed(requestId, requester);
        }
    }
}
