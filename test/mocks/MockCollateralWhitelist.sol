// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {AddressWhitelist} from "../../src/common/implementation/AddressWhitelist.sol";

/**
 * @title Mock Collateral Whitelist contract for testing.
 * @notice Extends AddressWhitelist for testing the ManagedOptimisticOracleV2 contract.
 */
contract MockCollateralWhitelist is AddressWhitelist {
// Inherits all functionality from AddressWhitelist
// This is just a wrapper to make the testing setup clearer
}
