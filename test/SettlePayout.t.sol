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

// Import shared mocks
import {MockStore} from "./mocks/MockStore.sol";
import {MockIdentifierWhitelist} from "./mocks/MockIdentifierWhitelist.sol";
import {MockFinder} from "./mocks/MockFinder.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {BlacklistERC20Mock} from "./mocks/BlacklistERC20Mock.sol";
import {RevertingReasonBlacklistERC20Mock} from "./mocks/RevertingReasonBlacklistERC20Mock.sol";
import {RevertingBlacklistERC20Mock} from "./mocks/RevertingBlacklistERC20Mock.sol";

contract SettlePayoutTest is Test {
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
    RevertingReasonBlacklistERC20Mock internal revertingReasonToken;
    RevertingBlacklistERC20Mock internal revertingToken;

    // Common constants
    bytes32 internal constant IDENTIFIER = keccak256("TEST_IDENTIFIER");
    bytes internal constant ANCILLARY_DATA = bytes("Test ancillary data");
    uint256 internal constant REWARD = 1 ether;
    uint256 internal constant FINAL_FEE = 10 ether;
    uint256 internal constant DEFAULT_BOND = FINAL_FEE;
    uint256 internal constant TOTAL_BOND = DEFAULT_BOND * 2;
    uint256 internal constant INITIAL_MINT = 100 ether;
    uint256 internal constant LIVENESS = 2 hours;

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
        revertingReasonToken = new RevertingReasonBlacklistERC20Mock();
        revertingToken = new RevertingBlacklistERC20Mock();

        // Configure whitelists
        collateralWhitelist.addToWhitelist(address(blacklistToken));
        collateralWhitelist.addToWhitelist(address(revertingReasonToken));
        collateralWhitelist.addToWhitelist(address(revertingToken));
        idWhitelist.addSupportedIdentifier(IDENTIFIER);

        // Register in Finder
        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateralWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(idWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.Oracle, address(oracle));

        // Set final fees
        store.setFinalFee(address(blacklistToken), FINAL_FEE);
        store.setFinalFee(address(revertingReasonToken), FINAL_FEE);
        store.setFinalFee(address(revertingToken), FINAL_FEE);

        // Deploy OptimisticOracleV2
        OptimisticOracleV2 impl = new OptimisticOracleV2();
        bytes memory initData =
            abi.encodeWithSelector(OptimisticOracleV2.initialize.selector, LIVENESS, address(finder), upgradeAdmin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        oo = OptimisticOracleV2(address(proxy));

        // Mint tokens to actors
        blacklistToken.mint(requester, INITIAL_MINT);
        blacklistToken.mint(proposer, INITIAL_MINT);
        blacklistToken.mint(disputer, INITIAL_MINT);
        blacklistToken.mint(otherAddress, INITIAL_MINT);

        revertingReasonToken.mint(requester, INITIAL_MINT);
        revertingReasonToken.mint(proposer, INITIAL_MINT);
        revertingReasonToken.mint(disputer, INITIAL_MINT);
        revertingReasonToken.mint(otherAddress, INITIAL_MINT);

        revertingToken.mint(requester, INITIAL_MINT);
        revertingToken.mint(proposer, INITIAL_MINT);
        revertingToken.mint(disputer, INITIAL_MINT);
        revertingToken.mint(otherAddress, INITIAL_MINT);

        // Approve tokens
        vm.startPrank(requester);
        blacklistToken.approve(address(oo), type(uint256).max);
        revertingReasonToken.approve(address(oo), type(uint256).max);
        revertingToken.approve(address(oo), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(proposer);
        blacklistToken.approve(address(oo), type(uint256).max);
        revertingReasonToken.approve(address(oo), type(uint256).max);
        revertingToken.approve(address(oo), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(disputer);
        blacklistToken.approve(address(oo), type(uint256).max);
        revertingReasonToken.approve(address(oo), type(uint256).max);
        revertingToken.approve(address(oo), type(uint256).max);
        vm.stopPrank();
    }

    function _makeRequest(IERC20 currency) internal returns (uint256 timestamp) {
        timestamp = block.timestamp;
        vm.prank(requester);
        oo.requestPrice(IDENTIFIER, timestamp, ANCILLARY_DATA, currency, REWARD);
    }

    function _proposePrice(IERC20 currency, uint256 timestamp, int256 price) internal {
        vm.prank(proposer);
        oo.proposePrice(requester, IDENTIFIER, timestamp, ANCILLARY_DATA, price);
    }

    function _disputePrice(IERC20 currency, uint256 timestamp) internal {
        vm.prank(disputer);
        oo.disputePrice(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);
    }

    // -------------------- Blacklist Token Tests (Returns false) --------------------

    function testExpiredSettlementWithBlacklistedProposer() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist the proposer before settlement
        blacklistToken.setBlacklisted(proposer, true);

        // Fast forward to expiration
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settlement should succeed but payout should be accrued
        uint256 proposerBalanceBefore = blacklistToken.balanceOf(proposer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(blacklistToken), proposer, expectedPayout);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - proposer should not receive tokens directly
        assertEq(blacklistToken.balanceOf(proposer), proposerBalanceBefore);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), expectedPayout);
    }

    function testDisputedSettlementWithBlacklistedWinner() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);
        _disputePrice(blacklistToken, timestamp);

        // Mock DVM resolution (disputer wins) - set a different price than proposed
        // Use the stamped ancillary data that the oracle will check
        bytes memory stampedAncillary = oo.stampAncillaryData(ANCILLARY_DATA, requester);
        oracle.setPrice(IDENTIFIER, timestamp, stampedAncillary, 200);

        // Blacklist the disputer before settlement
        blacklistToken.setBlacklisted(disputer, true);

        // Ensure the oracle has the price
        assertTrue(oracle.hasPrice(IDENTIFIER, timestamp, stampedAncillary));

        uint256 disputerBalanceBefore = blacklistToken.balanceOf(disputer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        uint256 expectedPayout = TOTAL_BOND + REWARD + DEFAULT_BOND / 2;
        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(blacklistToken), disputer, expectedPayout);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - disputer should not receive tokens directly
        assertEq(blacklistToken.balanceOf(disputer), disputerBalanceBefore);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(blacklistToken, disputer), expectedPayout);
    }

    function testClaimSettlePayoutToSameAddress() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertEq(accruedAmount, expectedPayout);

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
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertEq(accruedAmount, expectedPayout);

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

    // -------------------- Reverting Token Tests (Reverts on transfer with a reason) ------

    function testExpiredSettlementWithRevertingReasonToken() public {
        uint256 timestamp = _makeRequest(revertingReasonToken);
        _proposePrice(revertingReasonToken, timestamp, 100);

        // Blacklist the proposer before settlement
        revertingReasonToken.setBlacklisted(proposer, true);

        // Fast forward to expiration
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settlement should succeed but payout should be accrued
        uint256 expectedPayout = TOTAL_BOND + REWARD;
        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(revertingReasonToken), proposer, expectedPayout);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(revertingReasonToken, proposer), expectedPayout);
    }

    function testClaimSettlePayoutWithRevertingReasonToken() public {
        uint256 timestamp = _makeRequest(revertingReasonToken);
        _proposePrice(revertingReasonToken, timestamp, 100);

        // Blacklist proposer and settle
        revertingReasonToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        uint256 accruedAmount = oo.accruedSettlePayouts(revertingReasonToken, proposer);
        assertEq(accruedAmount, expectedPayout);

        // Remove blacklist and claim
        revertingReasonToken.setBlacklisted(proposer, false);

        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.ClaimedSettlePayout(
            address(revertingReasonToken), proposer, proposer, accruedAmount
        );
        vm.prank(proposer);
        oo.claimSettlePayout(revertingReasonToken, proposer);

        // Check that payout was claimed
        assertEq(oo.accruedSettlePayouts(revertingReasonToken, proposer), 0);
    }

    // -------------------- Reverting Token Tests (Reverts on transfer without a reason) ---

    function testExpiredSettlementWithRevertingToken() public {
        uint256 timestamp = _makeRequest(revertingToken);
        _proposePrice(revertingToken, timestamp, 100);

        // Blacklist the proposer before settlement
        revertingToken.setBlacklisted(proposer, true);

        // Fast forward to expiration
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settlement should succeed but payout should be accrued
        uint256 expectedPayout = TOTAL_BOND + REWARD;
        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(revertingToken), proposer, expectedPayout);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check accrued payout
        assertEq(oo.accruedSettlePayouts(revertingToken, proposer), expectedPayout);
    }

    function testClaimSettlePayoutWithRevertingToken() public {
        uint256 timestamp = _makeRequest(revertingToken);
        _proposePrice(revertingToken, timestamp, 100);

        // Blacklist proposer and settle
        revertingToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        uint256 accruedAmount = oo.accruedSettlePayouts(revertingToken, proposer);
        assertEq(accruedAmount, expectedPayout);

        // Remove blacklist and claim
        revertingToken.setBlacklisted(proposer, false);

        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.ClaimedSettlePayout(address(revertingToken), proposer, proposer, accruedAmount);
        vm.prank(proposer);
        oo.claimSettlePayout(revertingToken, proposer);

        // Check that payout was claimed
        assertEq(oo.accruedSettlePayouts(revertingToken, proposer), 0);
    }

    // -------------------- Multiple Currencies and Recipients Tests --------------------

    function testMultipleCurrenciesAccruedPayouts() public {
        // Test with blacklist token
        uint256 timestamp1 = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp1, 100);
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp1, ANCILLARY_DATA);

        // Test with reverting token
        uint256 timestamp2 = _makeRequest(revertingReasonToken);
        _proposePrice(revertingReasonToken, timestamp2, 200);
        revertingReasonToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp2, ANCILLARY_DATA);

        // Check both accrued payouts
        uint256 expectedPayout = TOTAL_BOND + REWARD;
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), expectedPayout);
        assertEq(oo.accruedSettlePayouts(revertingReasonToken, proposer), expectedPayout);

        // Claim both
        blacklistToken.setBlacklisted(proposer, false);
        revertingReasonToken.setBlacklisted(proposer, false);

        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);
        vm.prank(proposer);
        oo.claimSettlePayout(revertingReasonToken, proposer);

        // Check both are claimed
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
        assertEq(oo.accruedSettlePayouts(revertingReasonToken, proposer), 0);
    }

    function testMultipleRecipientsAccruedPayouts() public {
        // First request - proposer gets blacklisted
        uint256 timestamp1 = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp1, 100);
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp1, ANCILLARY_DATA);

        // Second request - disputer gets blacklisted
        // Unblacklist proposer first
        blacklistToken.setBlacklisted(proposer, false);
        uint256 timestamp2 = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp2, 200);
        _disputePrice(blacklistToken, timestamp2);

        // Set oracle price for disputed settlement
        bytes memory stampedAncillary2 = oo.stampAncillaryData(ANCILLARY_DATA, requester);
        oracle.setPrice(IDENTIFIER, timestamp2, stampedAncillary2, 300);

        blacklistToken.setBlacklisted(disputer, true);
        oo.settle(requester, IDENTIFIER, timestamp2, ANCILLARY_DATA);

        // Check both accrued payouts
        uint256 expectedProposerPayout = TOTAL_BOND + REWARD;
        uint256 expectedDisputerPayout = TOTAL_BOND + REWARD + DEFAULT_BOND / 2;
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), expectedProposerPayout);
        assertEq(oo.accruedSettlePayouts(blacklistToken, disputer), expectedDisputerPayout);

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

    // -------------------- Happy Path Tests (No Blacklist) --------------------

    function testExpiredSettlementHappyPath() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);

        // Fast forward to expiration
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settlement should succeed and payout should go directly to proposer
        uint256 proposerBalanceBefore = blacklistToken.balanceOf(proposer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - proposer should receive tokens directly
        assertEq(blacklistToken.balanceOf(proposer), proposerBalanceBefore + expectedPayout);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore - expectedPayout);

        // Check no accrued payout
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
    }

    function testDisputedSettlementHappyPathProposerWins() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);
        _disputePrice(blacklistToken, timestamp);

        // Mock DVM resolution (proposer wins) - set the same price as proposed
        bytes memory stampedAncillary = oo.stampAncillaryData(ANCILLARY_DATA, requester);
        oracle.setPrice(IDENTIFIER, timestamp, stampedAncillary, 100);

        // Ensure the oracle has the price
        assertTrue(oracle.hasPrice(IDENTIFIER, timestamp, stampedAncillary));

        uint256 proposerBalanceBefore = blacklistToken.balanceOf(proposer);
        uint256 disputerBalanceBefore = blacklistToken.balanceOf(disputer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        uint256 expectedPayout = TOTAL_BOND + REWARD + DEFAULT_BOND / 2; // proposer gets half of disputer's bond
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - proposer should receive tokens directly
        assertEq(blacklistToken.balanceOf(proposer), proposerBalanceBefore + expectedPayout);
        assertEq(blacklistToken.balanceOf(disputer), disputerBalanceBefore); // disputer gets nothing
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore - expectedPayout);

        // Check no accrued payouts
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
        assertEq(oo.accruedSettlePayouts(blacklistToken, disputer), 0);
    }

    function testDisputedSettlementHappyPathDisputerWins() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);
        _disputePrice(blacklistToken, timestamp);

        // Mock DVM resolution (disputer wins) - set a different price than proposed
        bytes memory stampedAncillary = oo.stampAncillaryData(ANCILLARY_DATA, requester);
        oracle.setPrice(IDENTIFIER, timestamp, stampedAncillary, 200);

        // Ensure the oracle has the price
        assertTrue(oracle.hasPrice(IDENTIFIER, timestamp, stampedAncillary));

        uint256 proposerBalanceBefore = blacklistToken.balanceOf(proposer);
        uint256 disputerBalanceBefore = blacklistToken.balanceOf(disputer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        uint256 expectedPayout = TOTAL_BOND + REWARD + DEFAULT_BOND / 2; // disputer gets half of proposer's bond
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - disputer should receive tokens directly
        assertEq(blacklistToken.balanceOf(proposer), proposerBalanceBefore); // proposer gets nothing
        assertEq(blacklistToken.balanceOf(disputer), disputerBalanceBefore + expectedPayout);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore - expectedPayout);

        // Check no accrued payouts
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
        assertEq(oo.accruedSettlePayouts(blacklistToken, disputer), 0);
    }

    function testHappyPathWithRevertingReasonToken() public {
        uint256 timestamp = _makeRequest(revertingReasonToken);
        _proposePrice(revertingReasonToken, timestamp, 100);

        // Fast forward to expiration
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settlement should succeed and payout should go directly to proposer
        uint256 proposerBalanceBefore = revertingReasonToken.balanceOf(proposer);
        uint256 contractBalanceBefore = revertingReasonToken.balanceOf(address(oo));

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - proposer should receive tokens directly
        assertEq(revertingReasonToken.balanceOf(proposer), proposerBalanceBefore + expectedPayout);
        assertEq(revertingReasonToken.balanceOf(address(oo)), contractBalanceBefore - expectedPayout);

        // Check no accrued payout
        assertEq(oo.accruedSettlePayouts(revertingReasonToken, proposer), 0);
    }

    function testHappyPathWithRevertingToken() public {
        uint256 timestamp = _makeRequest(revertingToken);
        _proposePrice(revertingToken, timestamp, 100);

        // Fast forward to expiration
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settlement should succeed and payout should go directly to proposer
        uint256 proposerBalanceBefore = revertingToken.balanceOf(proposer);
        uint256 contractBalanceBefore = revertingToken.balanceOf(address(oo));

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - proposer should receive tokens directly
        assertEq(revertingToken.balanceOf(proposer), proposerBalanceBefore + expectedPayout);
        assertEq(revertingToken.balanceOf(address(oo)), contractBalanceBefore - expectedPayout);

        // Check no accrued payout
        assertEq(oo.accruedSettlePayouts(revertingToken, proposer), 0);
    }

    function testHappyPathWithCustomBond() public {
        uint256 timestamp = _makeRequest(blacklistToken);

        // Set custom bond
        uint256 customBond = 15 ether;
        vm.prank(requester);
        oo.setBond(IDENTIFIER, timestamp, ANCILLARY_DATA, customBond);

        _proposePrice(blacklistToken, timestamp, 100);

        // Fast forward to expiration
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settlement should succeed and payout should go directly to proposer
        uint256 proposerBalanceBefore = blacklistToken.balanceOf(proposer);
        uint256 contractBalanceBefore = blacklistToken.balanceOf(address(oo));

        uint256 expectedPayout = customBond + FINAL_FEE + REWARD;
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check balances - proposer should receive tokens directly
        assertEq(blacklistToken.balanceOf(proposer), proposerBalanceBefore + expectedPayout);
        assertEq(blacklistToken.balanceOf(address(oo)), contractBalanceBefore - expectedPayout);

        // Check no accrued payout
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
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

    function testClaimSettlePayoutWithZeroRepaymentAddress() public {
        // First create some accrued payout
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Try to claim payout with zero address as repayment address
        vm.expectRevert(OptimisticOracleV2Interface.RepaymentAddressCannotBeZero.selector);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, address(0));
    }

    function testAccumulatingMultipleSettlements() public {
        // First settlement
        uint256 timestamp1 = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp1, 100);
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(requester);
        oo.settle(requester, IDENTIFIER, timestamp1, ANCILLARY_DATA);

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        uint256 firstAccrued = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertEq(firstAccrued, expectedPayout);

        // Second settlement (before claiming first)
        // Unblacklist proposer for the second request
        blacklistToken.setBlacklisted(proposer, false);
        uint256 timestamp2 = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp2, 200);
        // Blacklist proposer again before settlement
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp2, ANCILLARY_DATA);

        uint256 secondAccrued = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertEq(secondAccrued, firstAccrued + expectedPayout);

        // Claim all accumulated
        blacklistToken.setBlacklisted(proposer, false);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);

        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
    }

    function testSettlePayoutAccruedEvent() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);

        // Expect the SettlePayoutAccrued event
        uint256 expectedPayout = TOTAL_BOND + REWARD;
        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.SettlePayoutAccrued(address(blacklistToken), proposer, expectedPayout);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);
    }

    function testClaimedSettlePayoutEvent() public {
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

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
        uint256 timestamp = _makeRequest(blacklistToken);
        _proposePrice(blacklistToken, timestamp, 100);

        // 2. Blacklist proposer before settlement
        blacklistToken.setBlacklisted(proposer, true);

        // 3. Settle (should accrue payout)
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        uint256 expectedPayout = TOTAL_BOND + REWARD;
        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertEq(accruedAmount, expectedPayout);

        // 4. Verify proposer can't receive tokens directly
        uint256 proposerBalance = blacklistToken.balanceOf(proposer);
        assertEq(proposerBalance, INITIAL_MINT - TOTAL_BOND); // Only bond was deducted

        // 5. Remove blacklist and claim
        blacklistToken.setBlacklisted(proposer, false);
        vm.prank(proposer);
        oo.claimSettlePayout(blacklistToken, proposer);

        // 6. Verify final balance
        uint256 finalBalance = blacklistToken.balanceOf(proposer);
        assertEq(finalBalance, INITIAL_MINT + REWARD);
        assertEq(oo.accruedSettlePayouts(blacklistToken, proposer), 0);
    }

    function testSettlePayoutWithDifferentBondAmounts() public {
        uint256 timestamp = _makeRequest(blacklistToken);

        // Set custom bond
        uint256 customBond = 15 ether;
        vm.prank(requester);
        oo.setBond(IDENTIFIER, timestamp, ANCILLARY_DATA, customBond);

        _proposePrice(blacklistToken, timestamp, 100);

        // Blacklist proposer and settle
        blacklistToken.setBlacklisted(proposer, true);
        vm.warp(block.timestamp + LIVENESS + 1);
        oo.settle(requester, IDENTIFIER, timestamp, ANCILLARY_DATA);

        // Check accrued payout includes custom bond + final fee + reward
        uint256 expectedPayout = customBond + FINAL_FEE + REWARD;
        uint256 accruedAmount = oo.accruedSettlePayouts(blacklistToken, proposer);
        assertEq(accruedAmount, expectedPayout);
    }
}
