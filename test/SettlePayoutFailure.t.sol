// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {OptimisticOracleV2} from "src/optimistic-oracle-v2/implementation/OptimisticOracleV2.sol";
import {OptimisticOracleV2Interface} from "src/optimistic-oracle-v2/interfaces/OptimisticOracleV2Interface.sol";

import {OracleInterfaces} from "@uma/contracts/data-verification-mechanism/implementation/Constants.sol";
import {IdentifierWhitelistInterface} from
    "@uma/contracts/data-verification-mechanism/interfaces/IdentifierWhitelistInterface.sol";
import {FinderInterface} from "@uma/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

import {AddressWhitelist} from "src/common/implementation/AddressWhitelist.sol";
import {StoreInterface} from "src/data-verification-mechanism/interfaces/StoreInterface.sol";
import {FixedPointInterface} from "src/common/interfaces/FixedPointInterface.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Mock ERC20 that returns false on transfer (simulates blacklist)
 */
contract BlacklistERC20Mock is ERC20Mock {
    mapping(address => bool) public blacklisted;

    function setBlacklisted(address account, bool _blacklisted) external {
        blacklisted[account] = _blacklisted;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[msg.sender] || blacklisted[to]) {
            return false;
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blacklisted[from] || blacklisted[to]) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}

/**
 * @title Mock ERC20 that reverts on transfer (simulates strict blacklist)
 */
contract RevertingBlacklistERC20Mock is ERC20Mock {
    mapping(address => bool) public blacklisted;

    function setBlacklisted(address account, bool _blacklisted) external {
        blacklisted[account] = _blacklisted;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[msg.sender] || blacklisted[to]) {
            revert("Transfer blocked - address blacklisted");
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blacklisted[from] || blacklisted[to]) {
            revert("Transfer blocked - address blacklisted");
        }
        return super.transferFrom(from, to, amount);
    }
}

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

contract MockStore is StoreInterface {
    mapping(address => uint256) public finalFeeByCurrency;

    function setFinalFee(address currency, uint256 amount) external {
        finalFeeByCurrency[currency] = amount;
    }

    function payOracleFees() external payable {}

    function payOracleFeesErc20(address, /*erc20Address*/ FixedPointInterface.Unsigned calldata /*amount*/ ) external {}

    function computeRegularFee(uint256, uint256, FixedPointInterface.Unsigned calldata)
        external
        pure
        returns (FixedPointInterface.Unsigned memory regularFee, FixedPointInterface.Unsigned memory latePenalty)
    {
        regularFee = FixedPointInterface.Unsigned({rawValue: 0});
        latePenalty = FixedPointInterface.Unsigned({rawValue: 0});
    }

    function computeFinalFee(address currency) external view returns (FixedPointInterface.Unsigned memory) {
        return FixedPointInterface.Unsigned({rawValue: finalFeeByCurrency[currency]});
    }
}

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

contract MockOracle {
    mapping(bytes32 => mapping(uint256 => mapping(bytes => int256))) public prices;

    function setPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, int256 price) external {
        prices[identifier][timestamp][ancillaryData] = price;
    }

    function getPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        view
        returns (int256)
    {
        return prices[identifier][timestamp][ancillaryData];
    }

    function hasPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external view returns (bool) {
        return prices[identifier][timestamp][ancillaryData] != 0;
    }

    function requestPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external {
        // Mock implementation - in real scenario this would trigger DVM
    }
}

contract MockFinder is FinderInterface {
    mapping(bytes32 => address) public interfacesImplemented;

    function changeImplementationAddress(bytes32 interfaceName, address implementationAddress) external override {
        interfacesImplemented[interfaceName] = implementationAddress;
    }

    function getImplementationAddress(bytes32 interfaceName) external view override returns (address) {
        address implementationAddress = interfacesImplemented[interfaceName];
        require(implementationAddress != address(0), "Implementation not found");
        return implementationAddress;
    }
}

contract SettlePayoutFailureTest is Test {
    // Actors
    address internal upgradeAdmin;
    address internal requester;
    address internal proposer;
    address internal disputer;
    address internal otherAddress;

    // Core contracts
    OptimisticOracleV2 internal oo;
    FinderInterface internal finder;
    AddressWhitelist internal collateralWhitelist;
    MockIdentifierWhitelist internal idWhitelist;
    MockStore internal store;
    MockOracle internal oracle;

    // Test tokens with different blacklist behaviors
    BlacklistERC20Mock internal blacklistToken;
    RevertingBlacklistERC20Mock internal revertingToken;
    MaliciousERC20Mock internal maliciousToken;

    // Common constants
    bytes32 internal constant IDENTIFIER = keccak256("PRICE_ID");
    bytes internal constant ANCILLARY = bytes(":memo: test");

    function setUp() public {
        // Addresses
        upgradeAdmin = makeAddr("upgradeAdmin");
        requester = makeAddr("requester");
        proposer = makeAddr("proposer");
        disputer = makeAddr("disputer");
        otherAddress = makeAddr("otherAddress");

        vm.label(upgradeAdmin, "UPGRADE_ADMIN");
        vm.label(requester, "REQUESTER");
        vm.label(proposer, "PROPOSER");
        vm.label(disputer, "DISPUTER");
        vm.label(otherAddress, "OTHER_ADDRESS");

        // Deploy infrastructure
        finder = new MockFinder();
        collateralWhitelist = new AddressWhitelist();
        idWhitelist = new MockIdentifierWhitelist();
        store = new MockStore();
        oracle = new MockOracle();

        // Deploy test tokens
        blacklistToken = new BlacklistERC20Mock();
        revertingToken = new RevertingBlacklistERC20Mock();
        maliciousToken = new MaliciousERC20Mock();

        // Configure whitelists
        collateralWhitelist.addToWhitelist(address(blacklistToken));
        collateralWhitelist.addToWhitelist(address(revertingToken));
        collateralWhitelist.addToWhitelist(address(maliciousToken));
        idWhitelist.addSupportedIdentifier(IDENTIFIER);

        // Register in Finder
        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateralWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(idWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.Oracle, address(oracle));

        // Set final fees
        store.setFinalFee(address(blacklistToken), 10 ether);
        store.setFinalFee(address(revertingToken), 10 ether);
        store.setFinalFee(address(maliciousToken), 10 ether);

        // Deploy OptimisticOracleV2
        OptimisticOracleV2 impl = new OptimisticOracleV2();
        bytes memory initData =
            abi.encodeWithSelector(OptimisticOracleV2.initialize.selector, 2 days, address(finder), upgradeAdmin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        oo = OptimisticOracleV2(address(proxy));

        // Mint tokens to actors
        blacklistToken.mint(requester, 1000 ether);
        blacklistToken.mint(proposer, 1000 ether);
        blacklistToken.mint(disputer, 1000 ether);
        blacklistToken.mint(otherAddress, 1000 ether);

        revertingToken.mint(requester, 1000 ether);
        revertingToken.mint(proposer, 1000 ether);
        revertingToken.mint(disputer, 1000 ether);
        revertingToken.mint(otherAddress, 1000 ether);

        maliciousToken.mint(requester, 1000 ether);
        maliciousToken.mint(proposer, 1000 ether);
        maliciousToken.mint(disputer, 1000 ether);
        maliciousToken.mint(otherAddress, 1000 ether);

        // Approve tokens
        vm.startPrank(requester);
        blacklistToken.approve(address(oo), type(uint256).max);
        revertingToken.approve(address(oo), type(uint256).max);
        maliciousToken.approve(address(oo), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(proposer);
        blacklistToken.approve(address(oo), type(uint256).max);
        revertingToken.approve(address(oo), type(uint256).max);
        maliciousToken.approve(address(oo), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(disputer);
        blacklistToken.approve(address(oo), type(uint256).max);
        revertingToken.approve(address(oo), type(uint256).max);
        maliciousToken.approve(address(oo), type(uint256).max);
        vm.stopPrank();
    }

    function _makeRequest(IERC20 currency, uint256 reward) internal returns (uint256 timestamp) {
        timestamp = block.timestamp;
        vm.prank(requester);
        oo.requestPrice(IDENTIFIER, timestamp, ANCILLARY, currency, reward);
    }

    function _proposePrice(IERC20 currency, uint256 timestamp, int256 price) internal {
        vm.prank(proposer);
        oo.proposePrice(requester, IDENTIFIER, timestamp, ANCILLARY, price);
    }

    function _disputePrice(IERC20 currency, uint256 timestamp) internal {
        vm.prank(disputer);
        oo.disputePrice(requester, IDENTIFIER, timestamp, ANCILLARY);
    }

    // -------------------- Blacklist Token Tests (Returns false) --------------------

    function testExpiredSettlementWithBlacklistedProposer() public {
        uint256 timestamp = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist the proposer before settlement
        blacklistToken.setBlacklisted(proposer, true);

        // Fast forward to expiration
        vm.warp(block.timestamp + 2 days + 1);

        // Settlement should succeed but payout should be accrued
        uint256 proposerBalanceBefore = blacklistToken.balanceOf(proposer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        vm.expectEmit(true, true, false, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(blacklistToken), proposer, 25 ether);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        // Check balances - proposer should not receive tokens directly
        assertEq(blacklistToken.balanceOf(proposer), proposerBalanceBefore);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 25 ether);
    }

    function testDisputedSettlementWithBlacklistedWinner() public {
        uint256 timestamp = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp, 100);
        _disputePrice(blacklistToken, timestamp);

        // Mock DVM resolution (disputer wins) - set a different price than proposed
        // Use the stamped ancillary data that the oracle will check
        bytes memory stampedAncillary = oo.stampAncillaryData(ANCILLARY, requester);
        oracle.setPrice(IDENTIFIER, timestamp, stampedAncillary, 200);

        // Blacklist the disputer before settlement
        blacklistToken.setBlacklisted(disputer, true);

        // Fast forward to allow settlement
        vm.warp(block.timestamp + 1 days);

        // Ensure the oracle has the price
        assertTrue(oracle.hasPrice(IDENTIFIER, timestamp, stampedAncillary));

        uint256 disputerBalanceBefore = blacklistToken.balanceOf(disputer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        vm.expectEmit(true, true, false, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(blacklistToken), disputer, 30 ether);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        // Check balances - disputer should not receive tokens directly
        assertEq(blacklistToken.balanceOf(disputer), disputerBalanceBefore);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(blacklistToken, disputer), 30 ether);
    }

    function testClaimSettlePayoutToSameAddress() public {
        uint256 timestamp = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertGt(accruedAmount, 0);

        // Remove blacklist and claim
        blacklistToken.setBlacklisted(proposer, false);

        uint256 proposerBalanceBefore = blacklistToken.balanceOf(proposer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.ClaimedSettlePayout(address(blacklistToken), proposer, proposer, accruedAmount);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);

        // Check balances
        assertEq(blacklistToken.balanceOf(proposer), proposerBalanceBefore + accruedAmount);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore - accruedAmount);
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
    }

    function testClaimSettlePayoutToDifferentAddress() public {
        uint256 timestamp = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertGt(accruedAmount, 0);

        // Claim to different address
        uint256 otherBalanceBefore = blacklistToken.balanceOf(otherAddress);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.ClaimedSettlePayout(
            address(blacklistToken), proposer, otherAddress, accruedAmount
        );
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, otherAddress);

        // Check balances
        assertEq(blacklistToken.balanceOf(otherAddress), otherBalanceBefore + accruedAmount);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore - accruedAmount);
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
    }

    // -------------------- Reverting Token Tests (Reverts on transfer) --------------------

    function testExpiredSettlementWithRevertingToken() public {
        uint256 timestamp = _makeRequest(revertingToken, 5 ether);
        _proposePrice(revertingToken, timestamp, 100);

        // Blacklist the proposer before settlement
        revertingToken.setBlacklisted(proposer, true);

        // Fast forward to expiration
        vm.warp(block.timestamp + 2 days + 1);

        // Settlement should succeed but payout should be accrued
        vm.expectEmit(true, true, false, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(revertingToken), proposer, 25 ether);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(revertingToken, proposer), 25 ether);
    }

    function testClaimSettlePayoutWithRevertingToken() public {
        uint256 timestamp = _makeRequest(revertingToken, 5 ether);
        _proposePrice(revertingToken, timestamp, 100);

        // Blacklist proposer and settle
        revertingToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        uint256 accruedAmount = oo.accruedSettlePayouts(revertingToken, proposer);
        assertGt(accruedAmount, 0);

        // Remove blacklist and claim
        revertingToken.setBlacklisted(proposer, false);

        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.ClaimedSettlePayout(address(revertingToken), proposer, proposer, accruedAmount);
        vm.prank(proposer);
        oo.claimSettlePayout(revertingToken, proposer);

        // Check that payout was claimed
        assertEq(oo.accruedSettlePayouts(revertingToken, proposer), 0);
    }

    // -------------------- Malicious Token Tests (Returns true but doesn't transfer) --------------------

    function testExpiredSettlementWithMaliciousToken() public {
        uint256 timestamp = _makeRequest(maliciousToken, 5 ether);
        _proposePrice(maliciousToken, timestamp, 100);

        // Blacklist the proposer before settlement
        maliciousToken.setBlacklisted(proposer, true);

        // Fast forward to expiration
        vm.warp(block.timestamp + 2 days + 1);

        // Settlement should succeed but payout should be accrued
        vm.expectEmit(true, true, false, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(maliciousToken), proposer, 25 ether);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(maliciousToken, proposer), 25 ether);
    }

    function testClaimSettlePayoutWithMaliciousToken() public {
        uint256 timestamp = _makeRequest(maliciousToken, 5 ether);
        _proposePrice(maliciousToken, timestamp, 100);

        // Blacklist proposer and settle
        maliciousToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        uint256 accruedAmount = oo.accruedSettlePayouts(maliciousToken, proposer);
        assertGt(accruedAmount, 0);

        // Remove blacklist and claim
        maliciousToken.setBlacklisted(proposer, false);

        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.ClaimedSettlePayout(address(maliciousToken), proposer, proposer, accruedAmount);
        vm.prank(proposer);
        oo.claimSettlePayout(maliciousToken, proposer);

        // Check that payout was claimed
        assertEq(oo.accruedSettlePayouts(maliciousToken, proposer), 0);
    }

    // -------------------- Multiple Currencies and Recipients Tests --------------------

    function testMultipleCurrenciesAccruedPayouts() public {
        // Test with blacklist token
        uint256 timestamp1 = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp1, 100);
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp1, ANCILLARY);

        // Test with reverting token
        uint256 timestamp2 = _makeRequest(revertingToken, 3 ether);
        _proposePrice(revertingToken, timestamp2, 200);
        revertingToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp2, ANCILLARY);

        // Check both accrued payouts
        assertGt(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
        assertGt(oo.accruedSettlePayouts(revertingToken, proposer), 0);

        // Claim both
        blacklistToken.setBlacklisted(proposer, false);
        revertingToken.setBlacklisted(proposer, false);

        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);
        vm.prank(proposer);
        oo.claimSettlePayout(revertingToken, proposer);

        // Check both are claimed
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
        assertEq(oo.accruedSettlePayouts(revertingToken, proposer), 0);
    }

    function testMultipleRecipientsAccruedPayouts() public {
        // First request - proposer gets blacklisted
        uint256 timestamp1 = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp1, 100);
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp1, ANCILLARY);

        // Second request - disputer gets blacklisted
        // Unblacklist proposer first
        blacklistToken.setBlacklisted(proposer, false);
        uint256 timestamp2 = _makeRequest(blacklistToken, 3 ether);
        _proposePrice(blacklistToken, timestamp2, 200);
        _disputePrice(blacklistToken, timestamp2);

        // Set oracle price for disputed settlement
        bytes memory stampedAncillary2 = oo.stampAncillaryData(ANCILLARY, requester);
        oracle.setPrice(IDENTIFIER, timestamp2, stampedAncillary2, 300);

        blacklistToken.setBlacklisted(disputer, true);
        vm.warp(block.timestamp + 1 days);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp2, ANCILLARY);

        // Check both accrued payouts
        assertGt(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
        assertGt(oo.accruedSettlePayouts(blacklistToken, disputer), 0);

        // Claim both
        blacklistToken.setBlacklisted(proposer, false);
        blacklistToken.setBlacklisted(disputer, false);

        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);
        vm.prank(disputer);
        oo.claimSettlePayout(blacklistToken, disputer);

        // Check both are claimed
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
        assertEq(oo.accruedSettlePayouts(blacklistToken, disputer), 0);
    }

    // -------------------- Edge Cases and Error Tests --------------------

    function testClaimSettlePayoutWithZeroAmount() public {
        // Try to claim when no payout is accrued
        vm.expectRevert(OptimisticOracleV2Interface.NoSettlePayoutToClaim.selector);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);
    }

    function testClaimSettlePayoutWithNonExistentCurrency() public {
        // Create a new token that's not whitelisted
        ERC20Mock newToken = new ERC20Mock();

        // Try to claim payout for non-existent currency
        vm.expectRevert(OptimisticOracleV2Interface.NoSettlePayoutToClaim.selector);
        vm.prank(proposer);
        oo.claimSettlePayout(newToken, proposer);
    }

    function testAccumulatingMultipleSettlements() public {
        // First settlement
        uint256 timestamp1 = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp1, 100);
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp1, ANCILLARY);

        uint256 firstAccrued = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertGt(firstAccrued, 0);

        // Second settlement (before claiming first)
        // Unblacklist proposer for the second request
        blacklistToken.setBlacklisted(proposer, false);
        uint256 timestamp2 = _makeRequest(blacklistToken, 3 ether);
        _proposePrice(blacklistToken, timestamp2, 200);
        // Blacklist proposer again before settlement
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp2, ANCILLARY);

        uint256 secondAccrued = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertGt(secondAccrued, firstAccrued);

        // Claim all accumulated
        blacklistToken.setBlacklisted(proposer, false);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);

        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
    }

    function testSettlePayoutAccruedEvent() public {
        uint256 timestamp = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);

        // Expect the SettlePayoutAccrued event
        vm.expectEmit(true, true, false, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(blacklistToken), proposer, 25 ether);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);
    }

    function testClaimedSettlePayoutEvent() public {
        uint256 timestamp = _makeRequest(blacklistToken, 5 ether);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);

        // Remove blacklist and claim
        blacklistToken.setBlacklisted(proposer, false);

        // Expect the ClaimedSettlePayout event
        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.ClaimedSettlePayout(address(blacklistToken), proposer, proposer, accruedAmount);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);
    }

    // -------------------- Integration Tests --------------------

    function testFullWorkflowWithBlacklistRecovery() public {
        // 1. Make request and propose
        uint256 timestamp = _makeRequest(blacklistToken, 10 ether);
        _proposePrice(blacklistToken, timestamp, 100);

        // 2. Blacklist proposer before settlement
        blacklistToken.setBlacklisted(proposer, true);

        // 3. Settle (should accrue payout)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertGt(accruedAmount, 0);

        // 4. Verify proposer can't receive tokens directly
        uint256 proposerBalance = blacklistToken.balanceOf(proposer);
        assertEq(proposerBalance, 1000 ether - 20 ether); // Only bond was deducted

        // 5. Remove blacklist and claim
        blacklistToken.setBlacklisted(proposer, false);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);

        // 6. Verify final balance
        uint256 finalBalance = blacklistToken.balanceOf(proposer);
        assertEq(finalBalance, 1000 ether - 20 ether + accruedAmount);
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
    }

    function testSettlePayoutWithDifferentBondAmounts() public {
        uint256 timestamp = _makeRequest(blacklistToken, 5 ether);

        // Set custom bond
        vm.prank(requester);
        oo.setBond(IDENTIFIER, timestamp, ANCILLARY, 15 ether);

        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY);

        // Check accrued payout includes custom bond + final fee + reward
        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertEq(accruedAmount, 15 ether + 10 ether + 5 ether); // bond + finalFee + reward
    }
}
