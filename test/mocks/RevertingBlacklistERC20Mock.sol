// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title Mock ERC20 that reverts on transfer (simulates strict blacklist) without a revert reason
 */
contract RevertingBlacklistERC20Mock is ERC20Mock {
    mapping(address => bool) public blacklisted;

    function setBlacklisted(address account, bool _blacklisted) external {
        blacklisted[account] = _blacklisted;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[msg.sender] || blacklisted[to]) {
            revert();
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blacklisted[from] || blacklisted[to]) {
            revert();
        }
        return super.transferFrom(from, to, amount);
    }
}
