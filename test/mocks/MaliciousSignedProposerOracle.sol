// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressWhitelistInterface} from "src/common/interfaces/AddressWhitelistInterface.sol";
import {OptimisticOracleV2Interface} from "src/optimistic-oracle-v2/interfaces/OptimisticOracleV2Interface.sol";

interface IMaliciousSignedProposerOracle {
    function attemptDrain() external;
}

contract MaliciousSignedProposerWhitelist is AddressWhitelistInterface {
    IMaliciousSignedProposerOracle public immutable oracle;
    mapping(address => bool) internal whitelist;
    bool internal drainOnAdd;
    bool internal drainOnRemove;

    constructor(IMaliciousSignedProposerOracle _oracle) {
        oracle = _oracle;
    }

    function setDrainOnAdd(bool enabled) external {
        require(msg.sender == address(oracle), "MaliciousWhitelist: unauthorized");
        drainOnAdd = enabled;
    }

    function setDrainOnRemove(bool enabled) external {
        require(msg.sender == address(oracle), "MaliciousWhitelist: unauthorized");
        drainOnRemove = enabled;
    }

    function setWhitelisted(address account, bool enabled) external {
        require(msg.sender == address(oracle), "MaliciousWhitelist: unauthorized");
        whitelist[account] = enabled;
    }

    function addToWhitelist(address newElement) external override {
        whitelist[newElement] = true;
        if (drainOnAdd) oracle.attemptDrain();
    }

    function removeFromWhitelist(address elementToRemove) external override {
        whitelist[elementToRemove] = false;
        if (drainOnRemove) oracle.attemptDrain();
    }

    function isOnWhitelist(address elementToCheck) external view override returns (bool) {
        return whitelist[elementToCheck];
    }

    function getWhitelist() external pure override returns (address[] memory activeWhitelist) {
        activeWhitelist = new address[](0);
    }

    function isWhitelistEnabled() external pure override returns (bool enabled) {
        return true;
    }
}

contract MaliciousSignedProposerOracle is IMaliciousSignedProposerOracle {
    IERC20 public immutable token;
    address public immutable target;
    address public immutable attacker;
    MaliciousSignedProposerWhitelist public immutable whitelist;
    uint256 public bondAmount;
    bool public exhaustGasAfterTransfer;

    constructor(IERC20 _token, address _target, address _attacker) {
        token = _token;
        target = _target;
        attacker = _attacker;
        whitelist = new MaliciousSignedProposerWhitelist(this);
    }

    function setBondAmount(uint256 newBondAmount) external {
        bondAmount = newBondAmount;
    }

    function setExhaustGasAfterTransfer(bool enabled) external {
        exhaustGasAfterTransfer = enabled;
    }

    function setDrainOnAdd(bool enabled) external {
        whitelist.setDrainOnAdd(enabled);
    }

    function setDrainOnRemove(bool enabled) external {
        whitelist.setDrainOnRemove(enabled);
    }

    function setWhitelisted(address account, bool enabled) external {
        whitelist.setWhitelisted(account, enabled);
    }

    function defaultProposerWhitelist() external view returns (AddressWhitelistInterface) {
        return whitelist;
    }

    function getCustomProposerWhitelist(address, bytes32, bytes memory)
        external
        view
        returns (AddressWhitelistInterface)
    {
        return whitelist;
    }

    function getRequest(address, bytes32, uint256, bytes memory)
        external
        view
        returns (OptimisticOracleV2Interface.Request memory request)
    {
        request.currency = token;
    }

    function proposePriceFor(address, address, bytes32, uint256, bytes memory, int256) external returns (uint256) {
        if (bondAmount > 0) token.transferFrom(msg.sender, address(this), bondAmount);
        if (exhaustGasAfterTransfer) {
            assembly {
                for {} 1 {} {}
            }
        }
        return bondAmount;
    }

    function attemptDrain() external {
        require(msg.sender == address(whitelist), "MaliciousOracle: unauthorized");

        uint256 allowance = token.allowance(target, address(this));
        uint256 balance = token.balanceOf(target);
        uint256 amount = allowance < balance ? allowance : balance;
        if (amount > 0) token.transferFrom(target, attacker, amount);
    }
}
