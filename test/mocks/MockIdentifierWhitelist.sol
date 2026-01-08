// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IdentifierWhitelistInterface} from
    "@uma/contracts/data-verification-mechanism/interfaces/IdentifierWhitelistInterface.sol";

contract MockIdentifierWhitelist is IdentifierWhitelistInterface {
    mapping(bytes32 => bool) public supported;

    function addSupportedIdentifier(bytes32 identifier) external override {
        supported[identifier] = true;
    }

    function removeSupportedIdentifier(bytes32 identifier) external override {
        supported[identifier] = false;
    }

    function isIdentifierSupported(bytes32 identifier) external view override returns (bool) {
        return supported[identifier];
    }
}
