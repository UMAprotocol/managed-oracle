// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ManagedOptimisticOracleV2} from "../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {OptimisticOracleV2Interface} from "../src/optimistic-oracle-v2/interfaces/OptimisticOracleV2Interface.sol";
import {AddressWhitelist} from "../src/common/implementation/AddressWhitelist.sol";

/**
 * @title Fork Scenario Tests for ManagedOptimisticOracleV2
 * @notice Tests real historical Polymarket price requests from Polygon mainnet at different states.
 * @dev These tests validate early resolver functionality against actual requests at the pinned fork block.
 *
 * IMPORTANT: This test is pinned to block 81683818 (Jan 15, 2026 14:33:28 UTC).
 * All test data comes from real Polymarket requests that exist at this block.
 *
 * Test data extracted using:
 * cast logs --from-block $((81683818 - 50000)) --to-block 81683818 \
 *   --address 0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1 \
 *   "RequestPrice(...)" --rpc-url "$NODE_URL_137"
 */
contract ManagedOptimisticOracleV2ForkScenariosTest is Test {
    ManagedOptimisticOracleV2 oracle;

    // Contract addresses on Polygon
    address constant PROXY_ADDRESS = 0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1;
    IERC20 constant USDC_E = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    uint256 constant FORK_BLOCK = 81683818;
    address constant UPGRADE_ADMIN = 0x7FB4492Ff58E4326a99D7d4F66aE1f47c8286Fc6;

    // All real requests from the same requester (Polymarket)
    address constant REQUESTER = 0x65070BE91477460D8A7AeEb94ef92fe056C2f2A7;
    bytes32 constant YES_OR_NO_QUERY = bytes32("YES_OR_NO_QUERY");

    // Test actors
    address resolver = address(0x1234);
    address disputer = address(0x5678);
    address requestManager = address(0x9999);

    // Request in REQUESTED state (Block 81683133)
    // "Jalen Johnson: Assists Over 8.5" - never received a proposal
    uint256 constant REQUESTED_TIMESTAMP = 1768486238;
    bytes requestedAncillary =
        hex"713a207469746c653a204a616c656e204a6f686e736f6e3a2041737369737473204f76657220382e352c206465736372697074696f6e3a20496e20746865207570636f6d696e67204e42412067616d652c207363686564756c656420666f72204a616e756172792031352061742031303a303020504d2045543a0a0a54686973206d61726b65742077696c6c207265736f6c766520746f202259657322206966204a616c656e204a6f686e736f6e207265636f726473206d6f7265207468616e20382e35206173736973747320647572696e67207468652067616d652e0a0a54686973206d61726b65742077696c6c207265736f6c766520746f20224e6f22206966204a616c656e204a6f686e736f6e207265636f72647320382e352061737369737473206f7220666577657220647572696e67207468652067616d652e0a0a54686520656e746972652067616d6520696e636c7564696e6720616c6c206f76657274696d6520706572696f64732077696c6c20626520636f6e736964657265642e0a0a4966207468652067616d6520697320706f7374706f6e65642c2074686973206d61726b65742077696c6c2072656d61696e206f70656e20756e74696c207468652067616d6520686173206265656e20636f6d706c657465642e204966207468652067616d652069732063616e63656c656420656e746972656c792c2077697468206e6f206d616b652d75702067616d652c2074686973206d61726b65742077696c6c207265736f6c76652035302d35302e0a0a49662074686520706c61796572206973206c697374656420617320696e616374697665206f72206f746865727769736520646f6573206e6f742074616b652074686520636f75727420617420616e7920706f696e742c20746865206d61726b65742077696c6c207265736f6c766520224e6f222e0a0a546865207265736f6c7574696f6e20736f757263652077696c6c20626520746865206f6666696369616c204e424120626f782073636f7265206173207075626c6973686564206f6e204e42412e636f6d2e206d61726b65745f69643a2031313930313238207265735f646174613a2070313a20302c2070323a20312c2070333a20302e352e20576865726520703120636f72726573706f6e647320746f204e6f2c20703220746f205965732c20703320746f20756e6b6e6f776e2f35302d35302e2055706461746573206d61646520627920746865207175657374696f6e2063726561746f7220766961207468652062756c6c6574696e20626f61726420617420307836353037304245393134373734363044384137416545623934656639326665303536433266324137206173206465736372696265642062792068747470733a2f2f706f6c79676f6e7363616e2e636f6d2f74782f3078613134663031623131356334393133363234666333663530386639363066346465613235323735386537336332386635663037663865313964376263613036362073686f756c6420626520636f6e736964657265642e2c696e697469616c697a65723a39313433306361643264333937353736363439393731376661306436366137386438313465356335";

    // Request in PROPOSED state (Block 81683812)
    // "DN SOOPers Challengers to win 2 games?" - has proposal, not expired
    uint256 constant PROPOSED_TIMESTAMP = 1767864653;
    address constant PROPOSER = 0x9A025dF44E9a5e0660E7603F649cd4b55C0128EC;
    uint256 constant PROPOSED_EXPIRATION_TIME = 1768494796; // Actual expiration time from V1 state at fork block
    bytes proposedAncillary =
        hex"713a207469746c653a20444e20534f4f50657273204368616c6c656e6765727320746f2077696e20322067616d65733f2c206465736372697074696f6e3a20496e20746865207570636f6d696e67206d61746368206265747765656e20444e20534f4f50657273204368616c6c656e6765727320616e6420424e4b20466561725820596f75746820696e20746865204c434b204368616c6c656e67657273204c6561677565204b69636b6f66662047726f75702053746167652c207363686564756c656420666f72204a616e756172792031352061742031323a3030616d2045543a0a0a496620444e20534f4f50657273204368616c6c656e676572732077696e732065786163746c7920322067616d657320696e2074686973207365726965732c2074686973206d61726b65742077696c6c207265736f6c766520746f2022596573222e0a0a4f74686572776973652c2069742077696c6c207265736f6c766520746f20224e6f222e0a0a496620746865206d6174636820697320706f7374706f6e65642c2074686973206d61726b65742077696c6c2072656d61696e206f70656e20756e74696c20746865206d6174636820686173206265656e20636f6d706c657465642e0a0a496620746865206d617463682069732063616e63656c656420656e746972656c792077697468206e6f206d616b652d7570206d617463682c2074686973206d61726b65742077696c6c207265736f6c76652035302d35302e206d61726b65745f69643a2031313335303032207265735f646174613a2070313a20302c2070323a20312c2070333a20302e352e20576865726520703120636f72726573706f6e647320746f204e6f2c20703220746f205965732c20703320746f20756e6b6e6f776e2f35302d35302e2055706461746573206d61646520627920746865207175657374696f6e2063726561746f7220766961207468652062756c6c6574696e20626f61726420617420307836353037304245393134373734363044384137416545623934656639326665303536433266324137206173206465736372696265642062792068747470733a2f2f706f6c79676f6e7363616e2e636f6d2f74782f3078613134663031623131356334393133363234666333663530386639363066346465613235323735386537336332386635663037663865313964376263613036362073686f756c6420626520636f6e736964657265642e2c696e697469616c697a65723a39313433306361643264333937353736363439393731376661306436366137386438313465356335";

    // Request in DISPUTED state (Block 81675648)
    // "Mobile Legends: Aurora Türkiye vs Team Spirit - Game 1" - disputed
    uint256 constant DISPUTED_TIMESTAMP = 1768323629;
    bytes disputedAncillary =
        hex"713a207469746c653a204d6f62696c65204c6567656e64732042616e672042616e673a204175726f72612054c3bc726b697965207673205465616d20537069726974202d2047616d6520312057696e6e65722c206465736372697074696f6e3a2054686973206d61726b65742072656665727320746f20746865204d6f62696c65204c6567656e64732042616e672042616e67206d61746368206265747765656e204175726f72612054c3bc726b69796520616e64205465616d2053706972697420696e2074686520576f726c64204368616d70696f6e73686970204d372047726f75702053746167652c207363686564756c656420666f72204a616e7561727920313520617420323a3030414d2045542e0a0a54686973206d61726b65742077696c6c207265736f6c766520746f20224175726f72612054c3bc726b69796522206966204175726f72612054c3bc726b6979652077696e2047616d65203120616761696e7374205465616d205370697269742e0a0a54686973206d61726b65742077696c6c207265736f6c766520746f20225465616d2053706972697422206966205465616d205370697269742077696e2047616d65203120616761696e7374204175726f72612054c3bc726b6979652e0a0a496620746865206d6174636820626567696e7320627574206973206e6f7420636f6d706c657465642c20616e642047616d65203120697320636f6e636c75646564207769746820612077696e6e65722064657465726d696e65642c2074686973206d61726b65742077696c6c207265736f6c7665206261736564206f6e2074686520636f6d706c657465642047616d6520312e200a0a49662047616d652031206973206e6f7420636f6d706c6574656420666f7220616e7920726561736f6e2c2074686973206d61726b65742077696c6c207265736f6c76652035302d35302e200a0a496620746865206d617463682069732063616e63656c656420286e6f7420706c6179656420617420616c6c29206f722069732064656c61796564206265796f6e64203720646179732066726f6d20746865207363686564756c6564206461746520776974686f757420706c617920626567696e6e696e672c2074686973206d61726b65742077696c6c207265736f6c76652035302d35302e200a0a546865207265736f6c7574696f6e20736f7572636520666f722074686973206d61726b65742077696c6c206265206f6666696369616c20696e666f726d6174696f6e2066726f6d2068747470733a2f2f6c6971756970656469612e6e65742f6d6f62696c656c6567656e64732f4d61696e5f506167652e206d61726b65745f69643a2031313736313230207265735f646174613a2070313a20302c2070323a20312c2070333a20302e352e20576865726520703120636f72726573706f6e647320746f205465616d205370697269742c20703220746f204175726f72612054c3bc726b6979652c20703320746f20756e6b6e6f776e2f35302d35302e2055706461746573206d61646520627920746865207175657374696f6e2063726561746f7220766961207468652062756c6c6574696e20626f61726420617420307836353037304245393134373734363044384137416545623934656639326665303536433266324137206173206465736372696265642062792068747470733a2f2f706f6c79676f6e7363616e2e636f6d2f74782f3078613134663031623131356334393133363234666333663530386639363066346465613235323735386537336332386635663037663865313964376263613036362073686f756c6420626520636f6e736964657265642e2c696e697469616c697a65723a39313433306361643264333937353736363439393731376661306436366137386438313465356335";

    function setUp() public {
        vm.createSelectFork(vm.envString("NODE_URL_137"), FORK_BLOCK);
        oracle = ManagedOptimisticOracleV2(PROXY_ADDRESS);

        // Upgrade to V2 and setup resolver for all tests
        _upgradeToV2AndSetupRoles();
    }

    /**
     * @notice Test real request in REQUESTED state with full early resolver workflow.
     * @dev This request never received a proposal before the fork block.
     * Tests: custom liveness change, proposal, and early resolver settlement.
     */
    function testRealRequestedState() public {
        // Verify initial state
        OptimisticOracleV2Interface.State state =
            oracle.getState(REQUESTER, YES_OR_NO_QUERY, REQUESTED_TIMESTAMP, requestedAncillary);
        assertEq(uint256(state), uint256(OptimisticOracleV2Interface.State.Requested), "Should be in Requested state");

        OptimisticOracleV2Interface.Request memory request =
            oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, REQUESTED_TIMESTAMP, requestedAncillary);
        assertFalse(request.settled, "Should not be settled");
        assertEq(request.proposer, address(0), "Should have no proposer");

        // Step 1: Request manager changes custom liveness to a shorter duration (10 minutes)
        vm.prank(requestManager);
        oracle.requestManagerSetCustomLiveness(REQUESTER, YES_OR_NO_QUERY, requestedAncillary, 10 minutes);

        // Deploy custom proposer whitelist and add proposer
        address proposerAddr = address(0xABCD);
        AddressWhitelist customWhitelist = new AddressWhitelist();
        customWhitelist.addToWhitelist(proposerAddr);

        // Step 2: Request manager sets custom proposer whitelist for this request
        vm.prank(requestManager);
        oracle.requestManagerSetProposerWhitelist(
            REQUESTER, YES_OR_NO_QUERY, requestedAncillary, address(customWhitelist)
        );

        // Verify custom whitelist was set and proposer is whitelisted
        request = oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, REQUESTED_TIMESTAMP, requestedAncillary);
        assertTrue(customWhitelist.isOnWhitelist(proposerAddr), "Proposer should be on custom whitelist");

        // Step 3: Proposer proposes a price (YES = 1e18)
        // Get the required bond amount from the request
        uint256 bondAmount = request.requestSettings.bond + request.finalFee;

        vm.startPrank(proposerAddr);
        deal(address(USDC_E), proposerAddr, bondAmount);
        USDC_E.approve(address(oracle), bondAmount);

        uint256 proposalTimestamp = block.timestamp;
        oracle.proposePrice(
            REQUESTER,
            YES_OR_NO_QUERY,
            REQUESTED_TIMESTAMP,
            requestedAncillary,
            1e18 // YES
        );
        vm.stopPrank();

        // Verify proposal was recorded and custom liveness was applied
        request = oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, REQUESTED_TIMESTAMP, requestedAncillary);
        assertEq(request.proposer, proposerAddr, "Should have proposer");
        assertEq(request.proposedPrice, 1e18, "Should have proposed price");
        assertEq(request.proposalTime, proposalTimestamp, "V2 requests track proposal time");
        assertEq(request.requestSettings.customLiveness, 10 minutes, "Custom liveness should be applied on proposal");

        state = oracle.getState(REQUESTER, YES_OR_NO_QUERY, REQUESTED_TIMESTAMP, requestedAncillary);
        assertEq(uint256(state), uint256(OptimisticOracleV2Interface.State.Proposed), "Should be in Proposed state");

        // Step 4: Warp to expiration time to allow resolver settlement
        // Verify expiration time is proposal time + custom liveness (10 minutes)
        uint256 expectedExpirationTime = proposalTimestamp + 10 minutes;
        assertEq(request.expirationTime, expectedExpirationTime, "Expiration should be proposal time + custom liveness");

        // Note: The early resolver can settle at expiration, with exclusive rights
        vm.warp(request.expirationTime);

        vm.prank(resolver);
        uint256 payout = oracle.settle(REQUESTER, YES_OR_NO_QUERY, REQUESTED_TIMESTAMP, requestedAncillary);

        assertTrue(payout > 0, "Payout should be non-zero");

        // Verify settled
        request = oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, REQUESTED_TIMESTAMP, requestedAncillary);
        assertTrue(request.settled, "Should be settled by early resolver");
        assertEq(request.resolvedPrice, 1e18, "Resolved price should match proposal");
    }

    /**
     * @notice Test real request in PROPOSED state at fork block.
     * @dev This request has a proposal but hasn't expired yet.
     * After V2 upgrade, resolver can settle it early after minimum dispute window.
     */
    function testRealProposedStateEarlySettlement() public {
        OptimisticOracleV2Interface.State state =
            oracle.getState(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertEq(uint256(state), uint256(OptimisticOracleV2Interface.State.Proposed), "Should be in Proposed state");

        OptimisticOracleV2Interface.Request memory request =
            oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertEq(request.proposer, PROPOSER, "Should have correct proposer");
        assertFalse(request.settled, "Should not be settled yet");

        // Warp past expiration time to allow settlement.
        vm.warp(request.expirationTime);

        // Now resolver can settle the expired V1 request
        vm.prank(resolver);
        uint256 payout = oracle.settle(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);

        assertTrue(payout > 0, "Payout should be non-zero");

        // Verify settled
        request = oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertTrue(request.settled, "Should be settled by resolver");
    }

    /**
     * @notice Test real request in DISPUTED state at fork block.
     * @dev This request was proposed and disputed. Validates dispute state recognition.
     * Disputed requests cannot be settled by resolver - they await DVM resolution.
     */
    function testRealDisputedState() public view {
        OptimisticOracleV2Interface.State state =
            oracle.getState(REQUESTER, YES_OR_NO_QUERY, DISPUTED_TIMESTAMP, disputedAncillary);
        assertEq(uint256(state), uint256(OptimisticOracleV2Interface.State.Disputed), "Should be in Disputed state");

        OptimisticOracleV2Interface.Request memory request =
            oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, DISPUTED_TIMESTAMP, disputedAncillary);
        assertEq(request.proposer, PROPOSER, "Should have correct proposer");
        assertEq(request.disputer, PROPOSER, "Should have correct disputer");
        assertFalse(request.settled, "Disputed requests await DVM resolution");
    }

    /**
     * @notice Test extended dispute window on real proposed request.
     * @dev After V2 upgrade, expired proposals can still be disputed.
     */
    function testRealProposedExtendedDisputeWindow() public {
        OptimisticOracleV2Interface.Request memory request =
            oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);

        // Warp past natural expiration
        vm.warp(request.expirationTime + 1);

        // Post-V2: disputes should still be allowed (extended window)
        vm.startPrank(disputer);
        // Get the actual bond requirement from the request
        uint256 bondAmount = request.requestSettings.bond * 2 + 250e6; // bond + finalFee, doubled for safety
        deal(address(USDC_E), disputer, bondAmount);
        USDC_E.approve(address(oracle), bondAmount);

        oracle.disputePrice(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        vm.stopPrank();

        // Should now be Disputed
        OptimisticOracleV2Interface.State state =
            oracle.getState(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertEq(
            uint256(state),
            uint256(OptimisticOracleV2Interface.State.Disputed),
            "Should be Disputed after extended window"
        );
    }

    /**
     * @notice Test that proposals in liveness during upgrade preserve their expiration and transition correctly.
     * @dev This test explicitly verifies that:
     * 1. Proposals that were in liveness (Proposed state) when V2 was deployed keep their original expiration timestamp
     * 2. After upgrade, they can only be settled by resolver (not permissionlessly)
     * 3. Resolver can settle them after their original expiration time
     *
     * This test uses a REAL Polymarket proposal that was in Proposed state at the fork block (before any V2 upgrade).
     * The setUp() has already performed the V2 upgrade, simulating the mainnet upgrade scenario.
     */
    function testForkProposalPreservesExpirationAndRequiresResolverSettlement() public {
        // This request was in PROPOSED state at fork block 81683818 (Jan 15, 2026), BEFORE V2 upgrade
        // The setUp() has already performed the V2 upgrade, so we're now in post-upgrade state

        // VERIFICATION 1: The pre-existing V1 proposal still has its exact expiration timestamp from before upgrade
        OptimisticOracleV2Interface.Request memory request =
            oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);

        assertEq(
            request.expirationTime,
            PROPOSED_EXPIRATION_TIME,
            "Expiration time must be preserved from V1 (proves storage compatibility)"
        );
        assertEq(request.proposer, PROPOSER, "Should have preserved proposer from V1");
        assertFalse(request.settled, "Should not be settled yet");

        // State should still be Proposed since we haven't reached expiration
        OptimisticOracleV2Interface.State stateBefore =
            oracle.getState(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertEq(uint256(stateBefore), uint256(OptimisticOracleV2Interface.State.Proposed), "Should be Proposed");

        // VERIFICATION 2: After the original expiration time, non-resolver CANNOT settle (permissionless settlement blocked)
        vm.warp(PROPOSED_EXPIRATION_TIME);

        // Important: Due to the extended dispute window feature in ManagedOptimisticOracleV2,
        // getState() will still return Proposed even after expiration (to allow continued disputes).
        // This is by design - _getStateForDispute overrides Expired → Proposed.
        OptimisticOracleV2Interface.State stateAfterExpiration =
            oracle.getState(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertEq(
            uint256(stateAfterExpiration),
            uint256(OptimisticOracleV2Interface.State.Proposed),
            "State should still appear as Proposed due to extended dispute window"
        );

        // Non-resolver cannot settle (permissionless settlement is blocked)
        address nonResolver = makeAddr("nonResolver");
        bytes32 resolverRole = oracle.RESOLVER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonResolver, resolverRole)
        );
        vm.prank(nonResolver);
        oracle.settle(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);

        // VERIFICATION 3: Resolver CAN settle after the original expiration time
        vm.prank(resolver);
        uint256 payout = oracle.settle(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);

        assertTrue(payout > 0, "Payout should be non-zero");

        // Verify final settled state
        OptimisticOracleV2Interface.Request memory settledRequest =
            oracle.getRequest(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertTrue(settledRequest.settled, "Should be settled by resolver");
        assertEq(settledRequest.resolvedPrice, request.proposedPrice, "Resolved price should match proposal");

        OptimisticOracleV2Interface.State finalState =
            oracle.getState(REQUESTER, YES_OR_NO_QUERY, PROPOSED_TIMESTAMP, proposedAncillary);
        assertEq(uint256(finalState), uint256(OptimisticOracleV2Interface.State.Settled), "Should be Settled");
    }

    /**
     * @notice Helper to upgrade to V2 and setup resolver roles.
     */
    function _upgradeToV2AndSetupRoles() internal {
        ManagedOptimisticOracleV2 v2Implementation = new ManagedOptimisticOracleV2();
        bytes32 configAdminRole = oracle.CONFIG_ADMIN_ROLE();
        bytes32 requestManagerRole = oracle.REQUEST_MANAGER_ROLE();

        // Build multicall data: initializeV2 (grants RESOLVER_ADMIN to UPGRADE_ADMIN) + addResolver + grant CONFIG_ADMIN + grant REQUEST_MANAGER
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSelector(ManagedOptimisticOracleV2.initializeV2.selector, 5 minutes, UPGRADE_ADMIN);
        calls[1] = abi.encodeWithSelector(ManagedOptimisticOracleV2.addResolver.selector, resolver);
        calls[2] = abi.encodeWithSelector(IAccessControl.grantRole.selector, configAdminRole, UPGRADE_ADMIN);
        calls[3] = abi.encodeWithSelector(IAccessControl.grantRole.selector, requestManagerRole, requestManager);

        bytes memory callData = abi.encodeWithSignature("multicall(bytes[])", calls);

        vm.prank(UPGRADE_ADMIN);
        oracle.upgradeToAndCall(address(v2Implementation), callData);

        assertTrue(
            IAccessControl(address(oracle)).hasRole(oracle.RESOLVER_ROLE(), resolver), "Resolver role should be granted"
        );
        assertTrue(
            IAccessControl(address(oracle)).hasRole(oracle.REQUEST_MANAGER_ROLE(), requestManager),
            "Request manager role should be granted"
        );
    }
}
