// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

import {AddressWhitelistInterface} from "../../common/interfaces/AddressWhitelistInterface.sol";

interface SignedProposerOracleInterface {
    function defaultProposerWhitelist() external view returns (AddressWhitelistInterface);

    function getCustomProposerWhitelist(address requester, bytes32 identifier, bytes memory ancillaryData)
        external
        view
        returns (AddressWhitelistInterface);
}
