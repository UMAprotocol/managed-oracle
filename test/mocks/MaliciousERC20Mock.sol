// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title Mock ERC20 that returns true but doesn't actually transfer (simulates malicious token)
 */
contract MaliciousERC20Mock is ERC20Mock {
    mapping(address => bool) public blacklisted;

    function setBlacklisted(address account, bool _blacklisted) external {
        blacklisted[account] = _blacklisted;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[msg.sender] || blacklisted[to]) {
            // Return false to simulate transfer failure
            return false;
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blacklisted[from] || blacklisted[to]) {
            // Return false to simulate transfer failure
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}
