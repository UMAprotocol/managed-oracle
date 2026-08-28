// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployOOReporter} from "./DeployOOReporter.s.sol";
import {PolymarketOOReporter} from "src/reporters/integrations/PolymarketOOReporter.sol";

/// @title Deployment script for PolymarketOOReporter
/// @notice Deploys the callback-enabled implementation using DeployOOReporter's proxy initialization flow.
contract DeployPolymarketOOReporter is DeployOOReporter {
    function _deployImplementation() internal override returns (address) {
        return address(new PolymarketOOReporter());
    }
}
