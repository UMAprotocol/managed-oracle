// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {AddressWhitelistInterface} from "./AddressWhitelistInterface.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title An interface for a contract that can disable the address whitelist enforcement.
 */
interface DisableableAddressWhitelistInterface is AddressWhitelistInterface, IERC165 {
    function isEnforced() external view returns (bool);
}
