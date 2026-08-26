// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OOReporter} from "src/OOReporter.sol";
import {IOOReporter, RequestData, RerequestTrigger, RerequestType} from "src/interfaces/IOOReporter.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockOptimisticOracleV2} from "test/mocks/MockOptimisticOracleV2.sol";

interface Vm {
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(address emitter) external;
    function warp(uint256 newTimestamp) external;
}

contract SimpleProxy {
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    constructor(address implementation, bytes memory data) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, implementation)
        }

        if (data.length > 0) {
            (bool success, bytes memory result) = implementation.delegatecall(data);
            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }

    fallback() external payable {
        _fallback();
    }

    receive() external payable {
        _fallback();
    }

    function _fallback() private {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            let implementation := sload(slot)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract OOReporterTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event RequestRulesUpdated(
        bytes32 indexed requestId, uint256 indexed timestamp, address indexed updater, bytes updatedRules
    );
    event RequestRewardUpdated(
        bytes32 indexed requestId,
        uint256 indexed requestTimestamp,
        address indexed updater,
        address rewardCurrency,
        uint256 oldReward,
        uint256 newReward
    );
    event RequestResolved(bytes32 indexed requestId, uint256 indexed requestTimestamp, int256 outcome);
    event RequestRerequestAllowed(
        bytes32 indexed requestId, uint256 indexed requestTimestamp, RerequestTrigger indexed trigger
    );
    event AutomaticRerequestFailed(
        bytes32 indexed requestId, uint256 indexed requestTimestamp, RerequestType indexed rerequestType
    );
    event RequestRerequested(
        bytes32 indexed requestId,
        uint256 indexed requestTimestamp,
        address indexed rerequester,
        RerequestType rerequestType,
        uint256 previousRequestTimestamp,
        address rewardCurrency,
        uint256 reward,
        uint256 proposalBond,
        uint64 liveness,
        uint256 manualRerequestsRemaining
    );
    event RequestRerequestBudgetSet(bytes32 indexed requestId, uint256 manualRerequestsRemaining);
    event DefaultRerequestBudgetSet(uint256 defaultRerequestBudget);
    event AutomaticRerequestsEnabledSet(bool enabled);

    bytes32 internal constant REQUEST_ID = keccak256("request-id");
    bytes32 internal constant SECOND_REQUEST_ID = keccak256("second-request-id");
    bytes32 internal constant BINARY_IDENTIFIER = "YES_OR_NO_QUERY";
    bytes32 internal constant NUMERICAL_IDENTIFIER = "NUMERICAL";
    uint256 internal constant REWARD = 2_000_000;
    uint256 internal constant REREQUEST_REWARD = 3_000_000;
    uint256 internal constant PROPOSAL_BOND = 500_000_000;
    uint256 internal constant MANUAL_PROPOSAL_BOND = 700_000_000;
    uint64 internal constant LIVENESS = 7200;
    uint64 internal constant MANUAL_LIVENESS = 3 hours;
    uint256 internal constant DEFAULT_REREQUEST_BUDGET = 10;
    uint64 internal constant MINIMUM_LIVENESS = 0;
    uint64 internal constant MAXIMUM_LIVENESS = 2 days;
    uint64 internal constant STRICT_MINIMUM_LIVENESS = 1 hours;
    uint64 internal constant STRICT_MAXIMUM_LIVENESS = 2 days;

    OOReporter internal reporter;
    MockOptimisticOracleV2 internal optimisticOracle;
    MockERC20 internal usdc;

    address internal owner = address(0x1001);
    address internal requester = address(0x1002);
    address internal secondRequester = address(0x1003);
    address internal oracleInitializer = address(0x1004);
    address internal unauthorized = address(0x1005);

    function setUp() external {
        optimisticOracle = new MockOptimisticOracleV2();
        usdc = new MockERC20();

        OOReporter implementation = new OOReporter();
        bytes memory initData = abi.encodeCall(
            IOOReporter.initialize,
            (owner, address(optimisticOracle), address(usdc), oracleInitializer, requester, DEFAULT_REREQUEST_BUDGET)
        );
        reporter = OOReporter(address(new SimpleProxy(address(implementation), initData)));
    }

    function test_transferOwnershipRequiresPendingOwnerAcceptance() external {
        vm.prank(owner);
        reporter.transferOwnership(unauthorized);

        assertEq(reporter.owner(), owner, "owner should remain until acceptance");
        assertEq(reporter.pendingOwner(), unauthorized, "incorrect pending owner");

        vm.prank(owner);
        reporter.transferOwnership(secondRequester);

        assertEq(reporter.owner(), owner, "owner should remain after replacing nominee");
        assertEq(reporter.pendingOwner(), secondRequester, "replacement pending owner mismatch");

        vm.prank(secondRequester);
        reporter.acceptOwnership();

        assertEq(reporter.owner(), secondRequester, "accepted owner mismatch");
        assertEq(reporter.pendingOwner(), address(0), "pending owner should clear");
    }

    function test_renounceOwnershipIsDisabled() external {
        vm.prank(owner);
        vm.expectRevert(OOReporter.OwnershipRenunciationDisabled.selector);
        reporter.renounceOwnership();

        assertEq(reporter.owner(), owner, "owner should remain");
    }

    function test_registerRequestStoresRequestWithoutInitializerSuffix() external {
        bytes memory requestRules = _requestRules("primary");

        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        assertTrue(request.registered, "request should be registered");
        assertFalse(request.initialized, "request should not be initialized");
        assertFalse(request.resolved, "request should not be resolved");
        assertEq(request.requester, requester, "requester mismatch");
        assertEq(request.priceIdentifier, BINARY_IDENTIFIER, "identifier mismatch");
        assertEq(request.requestRules, requestRules, "request rules should be stored");
        assertEq(request.minimumLiveness, MINIMUM_LIVENESS, "minimum liveness mismatch");
        assertEq(request.maximumLiveness, MAXIMUM_LIVENESS, "maximum liveness mismatch");
    }

    function test_registerRequestRejectsDuplicateRequestId() external {
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, _requestRules("primary"));

        vm.prank(requester);
        vm.expectRevert(IOOReporter.RequestAlreadyRegistered.selector);
        reporter.registerRequest(
            REQUEST_ID, NUMERICAL_IDENTIFIER, _requestRules("different"), MINIMUM_LIVENESS, MAXIMUM_LIVENESS
        );
    }

    function test_duplicateReporterTuplesResolveIndependently() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);
        _registerRequest(SECOND_REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);
        RequestData memory firstRequest = reporter.getRequest(REQUEST_ID);

        vm.warp(block.timestamp + 1);
        vm.prank(oracleInitializer);
        reporter.initializeRequest(SECOND_REQUEST_ID, 0, 0, LIVENESS);
        RequestData memory secondRequest = reporter.getRequest(SECOND_REQUEST_ID);

        assertEq(
            reporter.getRequestId(BINARY_IDENTIFIER, firstRequest.requestTimestamp, requestRules),
            REQUEST_ID,
            "first request lookup mismatch"
        );
        assertEq(
            reporter.getRequestId(BINARY_IDENTIFIER, secondRequest.requestTimestamp, requestRules),
            SECOND_REQUEST_ID,
            "second request lookup mismatch"
        );

        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, secondRequest.requestTimestamp, requestRules, 0);
        assertFalse(reporter.isRequestResolved(REQUEST_ID), "first request should remain unresolved");
        assertTrue(reporter.isRequestResolved(SECOND_REQUEST_ID), "second request should resolve");

        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, firstRequest.requestTimestamp, requestRules, 1 ether
        );
        assertEq(reporter.getRequestResolution(REQUEST_ID), 1 ether, "first request outcome mismatch");
        assertEq(reporter.getRequestResolution(SECOND_REQUEST_ID), 0, "second request outcome mismatch");
    }

    function test_duplicateReporterTuplesCannotInitializeAtSameTimestamp() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);
        _registerRequest(SECOND_REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);

        vm.prank(oracleInitializer);
        vm.expectRevert(abi.encodeWithSelector(IOOReporter.OracleRequestAlreadyRegistered.selector, REQUEST_ID));
        reporter.initializeRequest(SECOND_REQUEST_ID, 0, 0, LIVENESS);

        assertFalse(reporter.getRequest(SECOND_REQUEST_ID).initialized, "second request should remain uninitialized");
    }

    function test_registerRequestAcceptsOORequestRulesLimit() external {
        assertEq(reporter.MAX_REQUEST_RULES(), 8139, "OO request rules limit mismatch");

        bytes memory requestRules = new bytes(reporter.MAX_REQUEST_RULES());

        vm.prank(requester);
        reporter.registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        assertTrue(request.registered, "request should be registered");
        assertEq(request.requestRules.length, reporter.MAX_REQUEST_RULES(), "request rules length mismatch");
    }

    function test_registerRequestRejectsUnapprovedRequesterAndInvalidRequestRules() external {
        bytes memory requestRules = _requestRules("primary");

        vm.prank(unauthorized);
        vm.expectRevert(IOOReporter.CallerNotRequester.selector);
        reporter.registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);

        vm.prank(requester);
        vm.expectRevert(IOOReporter.InvalidRequestRules.selector);
        reporter.registerRequest(REQUEST_ID, BINARY_IDENTIFIER, "", MINIMUM_LIVENESS, MAXIMUM_LIVENESS);

        bytes memory oversizedRequestRules = new bytes(reporter.MAX_REQUEST_RULES() + 1);
        vm.prank(requester);
        vm.expectRevert(IOOReporter.InvalidRequestRules.selector);
        reporter.registerRequest(
            REQUEST_ID, BINARY_IDENTIFIER, oversizedRequestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS
        );

        vm.prank(requester);
        vm.expectRevert(IOOReporter.InvalidRequestKey.selector);
        reporter.registerRequest(bytes32(0), BINARY_IDENTIFIER, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);

        vm.prank(requester);
        vm.expectRevert(IOOReporter.InvalidRequestKey.selector);
        reporter.registerRequest(REQUEST_ID, bytes32(0), requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function test_registerRequestRejectsInvalidLivenessRange() external {
        bytes memory requestRules = _requestRules("primary");

        vm.prank(requester);
        vm.expectRevert(
            abi.encodeWithSelector(IOOReporter.InvalidLivenessRange.selector, MAXIMUM_LIVENESS, MINIMUM_LIVENESS)
        );
        reporter.registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules, MAXIMUM_LIVENESS, MINIMUM_LIVENESS);
    }

    function test_registerRequestRejectsRangesOutsideManagedLivenessBounds() external {
        bytes memory requestRules = _requestRules("primary");
        uint256 oracleMinimumLiveness = optimisticOracle.minimumDisputeWindow();
        uint256 oracleMaximumLiveness = reporter.MAXIMUM_CUSTOM_LIVENESS();
        uint64 oracleMaximumLivenessAsUint64 = uint64(oracleMaximumLiveness);

        vm.prank(requester);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOOReporter.LivenessRangeOutsideManagedBounds.selector,
                oracleMaximumLivenessAsUint64,
                oracleMaximumLivenessAsUint64,
                oracleMinimumLiveness,
                oracleMaximumLiveness
            )
        );
        reporter.registerRequest(
            REQUEST_ID, BINARY_IDENTIFIER, requestRules, oracleMaximumLivenessAsUint64, oracleMaximumLivenessAsUint64
        );

        uint64 belowOracleMinimum = uint64(oracleMinimumLiveness - 1);
        vm.prank(requester);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOOReporter.LivenessRangeOutsideManagedBounds.selector,
                MINIMUM_LIVENESS,
                belowOracleMinimum,
                oracleMinimumLiveness,
                oracleMaximumLiveness
            )
        );
        reporter.registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules, MINIMUM_LIVENESS, belowOracleMinimum);
    }

    function test_initializeRequestAcceptsLivenessWithinPartiallyOverlappingRange() external {
        bytes memory requestRules = _requestRules("primary");
        uint64 oracleMinimumLiveness = uint64(optimisticOracle.minimumDisputeWindow());
        uint64 oracleMaximumLiveness = uint64(reporter.MAXIMUM_CUSTOM_LIVENESS());

        vm.prank(requester);
        reporter.registerRequest(
            REQUEST_ID, BINARY_IDENTIFIER, requestRules, oracleMinimumLiveness - 1, oracleMaximumLiveness
        );

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, oracleMinimumLiveness);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        assertEq(request.liveness, oracleMinimumLiveness, "selected liveness mismatch");

        bytes32 requestKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, block.timestamp, requestRules);
        assertEq(
            optimisticOracle.getMockRequest(requestKey).customLiveness, oracleMinimumLiveness, "OO liveness mismatch"
        );
    }

    function test_initializeRequestSeedsDefaultBudgetAndCreatesManagedOORequest() external {
        bytes memory requestRules = _requestRules("numerical");
        _registerRequest(REQUEST_ID, NUMERICAL_IDENTIFIER, requestRules);
        usdc.mint(address(reporter), REWARD);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, REWARD, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        assertEq(
            reporter.getRequestId(NUMERICAL_IDENTIFIER, request.requestTimestamp, requestRules),
            REQUEST_ID,
            "oracle request lookup mismatch"
        );
        assertTrue(request.initialized, "request should be initialized");
        assertEq(request.oracleInitializer, oracleInitializer, "initializer mismatch");
        assertEq(request.requestTimestamp, block.timestamp, "timestamp mismatch");
        assertEq(request.reward, REWARD, "reward mismatch");
        assertEq(request.proposalBond, PROPOSAL_BOND, "bond mismatch");
        assertEq(request.liveness, LIVENESS, "liveness mismatch");
        assertEq(request.minimumLiveness, MINIMUM_LIVENESS, "minimum liveness mismatch");
        assertEq(request.maximumLiveness, MAXIMUM_LIVENESS, "maximum liveness mismatch");
        assertEq(
            request.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET, "re-request budget should seed from default"
        );
        assertFalse(request.automaticDisputeRerequestUsed, "automatic dispute re-request should start unused");
        assertTrue(reporter.automaticRerequestsEnabled(), "automatic re-requests should initialize enabled");

        bytes32 requestKey =
            optimisticOracle.requestKey(address(reporter), NUMERICAL_IDENTIFIER, block.timestamp, requestRules);
        MockOptimisticOracleV2.MockRequest memory ooRequest = optimisticOracle.getMockRequest(requestKey);
        assertTrue(ooRequest.requested, "OO request should exist");
        assertTrue(ooRequest.eventBased, "request should be event based");
        assertFalse(ooRequest.callbackOnPriceProposed, "proposed callback should be disabled");
        assertTrue(ooRequest.callbackOnPriceDisputed, "disputed callback should be enabled");
        assertTrue(ooRequest.callbackOnPriceSettled, "settled callback should be enabled");
        assertEq(address(ooRequest.currency), address(usdc), "currency mismatch");
        assertEq(ooRequest.reward, REWARD, "OO reward mismatch");
        assertEq(ooRequest.bond, PROPOSAL_BOND, "OO bond mismatch");
        assertEq(ooRequest.customLiveness, LIVENESS, "OO liveness mismatch");

        bytes32 binaryKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, block.timestamp, requestRules);
        assertFalse(optimisticOracle.getMockRequest(binaryKey).requested, "binary request should not be created");
    }

    function test_initializeRequestRejectsMissingUnauthorizedAndDuplicate() external {
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, _requestRules("primary"));

        vm.prank(unauthorized);
        vm.expectRevert(IOOReporter.CallerNotOracleInitializer.selector);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestNotRegistered.selector);
        reporter.initializeRequest(SECOND_REQUEST_ID, 0, 0, LIVENESS);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestAlreadyInitialized.selector);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);
    }

    function test_initializeRequestRejectsZeroLiveness() external {
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, _requestRules("primary"));

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestLivenessCannotBeZero.selector);
        reporter.initializeRequest(REQUEST_ID, 0, 0, 0);
    }

    function test_initializeRequestRejectsLivenessBelowRegisteredMinimum() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequestWithLivenessRange(
            REQUEST_ID, BINARY_IDENTIFIER, requestRules, STRICT_MINIMUM_LIVENESS, STRICT_MAXIMUM_LIVENESS
        );

        vm.prank(oracleInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOOReporter.RequestLivenessOutOfRange.selector,
                STRICT_MINIMUM_LIVENESS - 1,
                STRICT_MINIMUM_LIVENESS,
                STRICT_MAXIMUM_LIVENESS
            )
        );
        reporter.initializeRequest(REQUEST_ID, 0, 0, STRICT_MINIMUM_LIVENESS - 1);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, STRICT_MINIMUM_LIVENESS);
    }

    function test_initializeRequestAcceptsCurrentOracleMinimumAboveRegisteredMaximum() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequestWithLivenessRange(
            REQUEST_ID, BINARY_IDENTIFIER, requestRules, STRICT_MINIMUM_LIVENESS, STRICT_MAXIMUM_LIVENESS
        );

        uint64 currentOracleMinimum = STRICT_MAXIMUM_LIVENESS + 1;
        optimisticOracle.setMinimumDisputeWindow(currentOracleMinimum);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, currentOracleMinimum);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        assertEq(request.liveness, currentOracleMinimum, "selected liveness mismatch");
        assertEq(request.maximumLiveness, STRICT_MAXIMUM_LIVENESS, "target maximum should remain stored");

        bytes32 requestKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, block.timestamp, requestRules);
        assertEq(
            optimisticOracle.getMockRequest(requestKey).customLiveness, currentOracleMinimum, "OO liveness mismatch"
        );
    }

    function test_initializeRequestPreservesManagedOOLivenessBounds() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        optimisticOracle.setMinimumDisputeWindow(uint256(LIVENESS) + 1);

        vm.prank(oracleInitializer);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "liveness below minimum"));
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);

        uint64 maximumCustomLiveness = uint64(reporter.MAXIMUM_CUSTOM_LIVENESS());
        vm.prank(oracleInitializer);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "liveness too long"));
        reporter.initializeRequest(REQUEST_ID, 0, 0, maximumCustomLiveness);
    }

    function test_setRequestRewardRejectsUnauthorizedAndInvalidLifecycle() external {
        bytes memory requestRules = _requestRules("primary");

        vm.prank(unauthorized);
        vm.expectRevert(IOOReporter.CallerNotOracleInitializer.selector);
        reporter.setRequestReward(REQUEST_ID, 0);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestNotRegistered.selector);
        reporter.setRequestReward(REQUEST_ID, 0);

        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestNotInitialized.selector);
        reporter.setRequestReward(REQUEST_ID, 0);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, 1 ether);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestAlreadyResolved.selector);
        reporter.setRequestReward(REQUEST_ID, 0);
    }

    function test_setRequestRewardUpdatesOracleCacheFundingAllowanceAndEvent() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);
        usdc.mint(address(reporter), REREQUEST_REWARD);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, REWARD, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        bytes32 requestKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        vm.prank(address(reporter));
        usdc.approve(address(optimisticOracle), 0);
        optimisticOracle.expectReporterRewardDuringSetReward(REQUEST_ID, REREQUEST_REWARD);

        vm.expectEmit(address(reporter));
        emit RequestRewardUpdated(
            REQUEST_ID, request.requestTimestamp, oracleInitializer, address(usdc), REWARD, REREQUEST_REWARD
        );
        vm.prank(oracleInitializer);
        reporter.setRequestReward(REQUEST_ID, REREQUEST_REWARD);

        RequestData memory increased = reporter.getRequest(REQUEST_ID);
        assertEq(increased.reward, REREQUEST_REWARD, "cached increased reward mismatch");
        assertEq(
            optimisticOracle.getMockRequest(requestKey).reward, REREQUEST_REWARD, "oracle increased reward mismatch"
        );
        assertEq(increased.oracleInitializer, oracleInitializer, "stored initializer should not change");
        assertEq(usdc.balanceOf(address(reporter)), 0, "increase should pull only the delta");
        assertEq(usdc.balanceOf(address(optimisticOracle)), REREQUEST_REWARD, "oracle increase balance mismatch");
        assertEq(
            usdc.allowance(address(reporter), address(optimisticOracle)),
            type(uint256).max,
            "increase should restore max allowance"
        );

        vm.prank(oracleInitializer);
        reporter.setRequestReward(REQUEST_ID, REWARD);

        assertEq(reporter.getRequest(REQUEST_ID).reward, REWARD, "cached decreased reward mismatch");
        assertEq(optimisticOracle.getMockRequest(requestKey).reward, REWARD, "oracle decreased reward mismatch");
        assertEq(usdc.balanceOf(address(reporter)), REREQUEST_REWARD - REWARD, "decrease refund mismatch");

        vm.prank(oracleInitializer);
        reporter.setRequestReward(REQUEST_ID, 0);

        assertEq(reporter.getRequest(REQUEST_ID).reward, 0, "cached zero reward mismatch");
        assertEq(optimisticOracle.getMockRequest(requestKey).reward, 0, "oracle zero reward mismatch");
        assertEq(usdc.balanceOf(address(reporter)), REREQUEST_REWARD, "zero reward refund mismatch");
        assertEq(usdc.balanceOf(address(optimisticOracle)), 0, "oracle should hold no reward");
    }

    function test_setRequestRewardRejectsInsufficientDeltaBalance() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);
        usdc.mint(address(reporter), REWARD);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, REWARD, PROPOSAL_BOND, LIVENESS);

        vm.prank(oracleInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOOReporter.InsufficientRewardBalance.selector, address(usdc), 0, REREQUEST_REWARD - REWARD
            )
        );
        reporter.setRequestReward(REQUEST_ID, REREQUEST_REWARD);

        assertEq(reporter.getRequest(REQUEST_ID).reward, REWARD, "failed update should preserve cached reward");
    }

    function test_setRequestRewardUsesOracleRewardWhenCacheIsStale() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);
        usdc.mint(address(reporter), REWARD);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, REWARD, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        uint256 managedReward = REWARD / 2;
        optimisticOracle.setRewardFor(
            address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, managedReward
        );
        usdc.mint(address(reporter), REREQUEST_REWARD - REWARD);

        vm.prank(address(reporter));
        usdc.approve(address(optimisticOracle), 0);

        vm.expectEmit(address(reporter));
        emit RequestRewardUpdated(
            REQUEST_ID, request.requestTimestamp, oracleInitializer, address(usdc), managedReward, REREQUEST_REWARD
        );
        vm.prank(oracleInitializer);
        reporter.setRequestReward(REQUEST_ID, REREQUEST_REWARD);

        assertEq(reporter.getRequest(REQUEST_ID).reward, REREQUEST_REWARD, "cache should resync to new reward");
        assertEq(usdc.balanceOf(address(reporter)), 0, "increase should use oracle reward as delta baseline");
    }

    function test_setRequestRewardRevertsAfterProposalWithoutChangingCache() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        optimisticOracle.markProposed(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);
        usdc.mint(address(reporter), REWARD);

        vm.prank(oracleInitializer);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "already proposed"));
        reporter.setRequestReward(REQUEST_ID, REWARD);

        assertEq(reporter.getRequest(REQUEST_ID).reward, 0, "failed update should preserve cached reward");
    }

    function test_updateRequestRulesForwardsToOptimisticOracle() external {
        bytes memory requestRules = _requestRules("primary");
        bytes memory firstUpdatedRules = bytes("first rules update");
        bytes memory secondUpdatedRules = bytes("second rules update");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.expectEmit(address(reporter));
        emit RequestRulesUpdated(REQUEST_ID, block.timestamp, requester, firstUpdatedRules);

        vm.prank(requester);
        reporter.updateRequestRules(REQUEST_ID, firstUpdatedRules);

        vm.warp(block.timestamp + 10);
        vm.prank(requester);
        reporter.updateRequestRules(REQUEST_ID, secondUpdatedRules);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        assertEq(request.requester, requester, "stored requester mismatch");

        // The reporter does not store rules updates; it forwards them to the Managed OO keyed by its own address as
        // the requester, the price identifier, and the original request rules.
        MockOptimisticOracleV2.ForwardedRulesUpdate[] memory forwarded =
            optimisticOracle.getForwardedRulesUpdates(address(reporter), BINARY_IDENTIFIER, requestRules);
        assertEq(forwarded.length, 2, "forwarded update count mismatch");
        assertEq(forwarded[0].updatedRules, firstUpdatedRules, "first forwarded rules mismatch");
        assertEq(forwarded[1].updatedRules, secondUpdatedRules, "second forwarded rules mismatch");
        assertEq(forwarded[1].timestamp, block.timestamp, "latest forwarded timestamp mismatch");
    }

    function test_updateRequestRulesRejectsUnknownAndWrongRequester() external {
        bytes memory requestRules = _requestRules("primary");

        vm.prank(requester);
        vm.expectRevert(IOOReporter.RequestNotRegistered.selector);
        reporter.updateRequestRules(REQUEST_ID, bytes("rules update"));

        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(unauthorized);
        vm.expectRevert(IOOReporter.CallerNotRequester.selector);
        reporter.updateRequestRules(REQUEST_ID, bytes("rules update"));

        vm.prank(owner);
        reporter.setRequesterEnabled(secondRequester, true);

        vm.prank(secondRequester);
        vm.expectRevert(IOOReporter.CallerNotRequestRegistrar.selector);
        reporter.updateRequestRules(REQUEST_ID, bytes("rules update"));
    }

    function test_updateRequestRulesRejectsResolvedRequest() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(requester);
        reporter.updateRequestRules(REQUEST_ID, bytes("pre-settlement rules update"));

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, 1 ether);

        vm.prank(requester);
        vm.expectRevert(IOOReporter.RequestAlreadyResolved.selector);
        reporter.updateRequestRules(REQUEST_ID, bytes("post-settlement rules update"));
    }

    function test_readersRevertForUnknownAndUnresolvedRequests() external {
        vm.expectRevert(IOOReporter.RequestNotRegistered.selector);
        reporter.isRequestResolved(REQUEST_ID);

        vm.expectRevert(IOOReporter.RequestNotRegistered.selector);
        reporter.getRequestResolution(REQUEST_ID);

        vm.expectRevert(IOOReporter.RequestNotRegistered.selector);
        reporter.getRequestId(BINARY_IDENTIFIER, block.timestamp, _requestRules("missing"));

        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, _requestRules("primary"));

        vm.expectRevert(IOOReporter.RequestResolutionUnavailable.selector);
        reporter.getRequestResolution(REQUEST_ID);
    }

    function test_priceSettledStoresRawBinaryPrices() external {
        _assertSettlementStores(keccak256("binary-no"), BINARY_IDENTIFIER, _requestRules("binary-no"), 0);
        _assertSettlementStores(
            keccak256("binary-unknown"), BINARY_IDENTIFIER, _requestRules("binary-unknown"), 0.5 ether
        );
        _assertSettlementStores(keccak256("binary-yes"), BINARY_IDENTIFIER, _requestRules("binary-yes"), 1 ether);
    }

    function test_priceSettledStoresRawNumericalPricesWithoutReporterValidation() external {
        _assertSettlementStores(keccak256("numerical-zero"), NUMERICAL_IDENTIFIER, _requestRules("numerical-zero"), 0);
        _assertSettlementStores(
            keccak256("numerical-one"), NUMERICAL_IDENTIFIER, _requestRules("numerical-one"), 1 ether
        );
        _assertSettlementStores(
            keccak256("numerical-invalid-for-pm"),
            NUMERICAL_IDENTIFIER,
            _requestRules("numerical-invalid-for-pm"),
            42 ether
        );
    }

    function test_priceDisputedAutomaticallyRerequestsOnceWithoutConsumingBudget() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);

        vm.expectEmit(address(reporter));
        emit RequestRerequested(
            REQUEST_ID,
            block.timestamp,
            address(reporter),
            RerequestType.AutomaticDispute,
            request.requestTimestamp,
            address(usdc),
            0,
            PROPOSAL_BOND,
            LIVENESS,
            DEFAULT_REREQUEST_BUDGET
        );

        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory afterAuto = reporter.getRequest(REQUEST_ID);
        assertFalse(afterAuto.rerequestAllowed, "automatic re-request should not leave gate open");
        assertFalse(afterAuto.resolved, "dispute should not resolve the request");
        assertTrue(afterAuto.automaticDisputeRerequestUsed, "automatic dispute re-request should be marked used");
        assertEq(afterAuto.requestTimestamp, block.timestamp, "automatic dispute should advance timestamp");
        assertEq(afterAuto.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET, "dispute should not consume budget");
    }

    function test_priceDisputedRerequestsWithEffectiveOracleRewardAfterManagerChange() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);
        usdc.mint(address(reporter), REWARD);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, REWARD, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        uint256 managedReward = REWARD / 2;
        optimisticOracle.setRewardFor(
            address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, managedReward
        );
        assertEq(reporter.getRequest(REQUEST_ID).reward, REWARD, "manager change should leave reporter cache stale");

        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory rerequested = reporter.getRequest(REQUEST_ID);
        bytes32 replacementKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, block.timestamp, requestRules);
        assertEq(rerequested.reward, managedReward, "dispute refund should refresh cached reward");
        assertEq(
            optimisticOracle.getMockRequest(replacementKey).reward,
            managedReward,
            "automatic re-request should use effective reward"
        );
        assertEq(
            usdc.balanceOf(address(reporter)),
            REWARD - managedReward,
            "automatic re-request should leave prior manager refund"
        );
    }

    function test_executeAutomaticRerequestRejectsNonSelfCaller() external {
        vm.expectRevert(IOOReporter.CallerNotSelf.selector);
        reporter.executeAutomaticRerequest(REQUEST_ID, RerequestType.AutomaticDispute);
    }

    function test_priceDisputedAllowsManualRecoveryAboveRegisteredMaximumAfterConfigurationDrift() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequestWithLivenessRange(
            REQUEST_ID, BINARY_IDENTIFIER, requestRules, STRICT_MINIMUM_LIVENESS, LIVENESS
        );

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        uint64 currentOracleMinimum = LIVENESS + 1;
        optimisticOracle.setMinimumDisputeWindow(currentOracleMinimum);

        vm.expectEmit(address(reporter));
        emit AutomaticRerequestFailed(REQUEST_ID, request.requestTimestamp, RerequestType.AutomaticDispute);

        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory allowedRequest = reporter.getRequest(REQUEST_ID);
        assertTrue(allowedRequest.rerequestAllowed, "failed automatic re-request should open manual gate");
        assertFalse(
            allowedRequest.automaticDisputeRerequestUsed,
            "failed automatic re-request should not consume automatic slot"
        );

        bytes32 replacementKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, block.timestamp, requestRules);
        MockOptimisticOracleV2.MockRequest memory replacementRequest = optimisticOracle.getMockRequest(replacementKey);
        assertFalse(replacementRequest.requested, "failed automatic re-request should roll back replacement request");

        vm.prank(oracleInitializer);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, currentOracleMinimum);

        RequestData memory recoveredRequest = reporter.getRequest(REQUEST_ID);
        assertFalse(recoveredRequest.rerequestAllowed, "manual recovery should close gate");
        assertEq(recoveredRequest.liveness, currentOracleMinimum, "manual recovery liveness mismatch");
        assertEq(
            optimisticOracle.getMockRequest(replacementKey).customLiveness,
            currentOracleMinimum,
            "replacement OO liveness mismatch"
        );
    }

    function test_priceDisputedOpensManualGateAfterAutomaticDisputeUsed() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory afterAuto = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);

        vm.expectEmit(address(reporter));
        emit RequestRerequestAllowed(REQUEST_ID, afterAuto.requestTimestamp, RerequestTrigger.Dispute);

        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, afterAuto.requestTimestamp, requestRules);

        RequestData memory allowedRequest = reporter.getRequest(REQUEST_ID);
        assertTrue(allowedRequest.rerequestAllowed, "second dispute should open the manual gate");
        assertTrue(allowedRequest.automaticDisputeRerequestUsed, "automatic dispute re-request should stay used");
        assertEq(
            allowedRequest.requestTimestamp, afterAuto.requestTimestamp, "manual gate should not advance timestamp"
        );
        assertEq(allowedRequest.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET, "gate should not consume budget");
    }

    function test_priceDisputedOpensManualGateWhenAutomaticRerequestTimestampNotAdvanced() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);

        vm.expectEmit(address(reporter));
        emit RequestRerequestAllowed(REQUEST_ID, request.requestTimestamp, RerequestTrigger.Dispute);

        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory allowedRequest = reporter.getRequest(REQUEST_ID);
        assertTrue(allowedRequest.rerequestAllowed, "same-block dispute should open manual gate");
        assertFalse(
            allowedRequest.automaticDisputeRerequestUsed, "blocked automatic dispute should not consume automatic slot"
        );
        assertEq(
            allowedRequest.requestTimestamp,
            request.requestTimestamp,
            "blocked automatic dispute should not advance timestamp"
        );
    }

    function test_priceDisputedOpensManualGateWhenRefundDeferred() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        usdc.mint(address(reporter), REWARD);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, REWARD, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.setDeferNextDisputeRefund(true);

        vm.expectEmit(address(reporter));
        emit RequestRerequestAllowed(REQUEST_ID, request.requestTimestamp, RerequestTrigger.Dispute);

        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory allowedRequest = reporter.getRequest(REQUEST_ID);
        assertTrue(allowedRequest.rerequestAllowed, "deferred refund should open manual gate");
        assertFalse(allowedRequest.automaticDisputeRerequestUsed, "deferred refund should not consume automatic slot");
        assertEq(
            allowedRequest.requestTimestamp, request.requestTimestamp, "deferred refund should not advance timestamp"
        );
        assertEq(
            optimisticOracle.deferredPayouts(usdc, address(reporter)), REWARD, "refund should be deferred to reporter"
        );
    }

    function test_priceDisputedUsesCurrentAutomationSettingAfterDisabledFirstDispute() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);

        vm.expectEmit(address(reporter));
        emit RequestRerequestAllowed(REQUEST_ID, request.requestTimestamp, RerequestTrigger.Dispute);

        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory afterDisabledDispute = reporter.getRequest(REQUEST_ID);
        assertTrue(afterDisabledDispute.rerequestAllowed, "disabled first dispute should open manual gate");
        assertFalse(
            afterDisabledDispute.automaticDisputeRerequestUsed,
            "disabled first dispute should not consume automatic slot"
        );
        assertEq(
            afterDisabledDispute.requestTimestamp,
            request.requestTimestamp,
            "disabled first dispute should not advance timestamp"
        );

        vm.warp(block.timestamp + 1);
        vm.prank(oracleInitializer);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory afterManual = reporter.getRequest(REQUEST_ID);

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(true);
        vm.warp(block.timestamp + 1);

        vm.expectEmit(address(reporter));
        emit RequestRerequested(
            REQUEST_ID,
            block.timestamp,
            address(reporter),
            RerequestType.AutomaticDispute,
            afterManual.requestTimestamp,
            address(usdc),
            0,
            PROPOSAL_BOND,
            LIVENESS,
            DEFAULT_REREQUEST_BUDGET - 1
        );

        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, afterManual.requestTimestamp, requestRules);

        RequestData memory afterAuto = reporter.getRequest(REQUEST_ID);
        assertFalse(afterAuto.rerequestAllowed, "enabled later dispute should auto re-request");
        assertTrue(afterAuto.automaticDisputeRerequestUsed, "enabled later dispute should consume automatic slot");
        assertEq(afterAuto.requestTimestamp, block.timestamp, "enabled later dispute should advance timestamp");
        assertEq(
            afterAuto.manualRerequestsRemaining,
            DEFAULT_REREQUEST_BUDGET - 1,
            "automatic re-request should not consume budget"
        );
    }

    function test_priceSettledP4ResetsBudgetAndAutomaticallyRerequests() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        // Spend one manual re-request so we can prove P4 refills the manual budget to the default.
        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);
        vm.prank(oracleInitializer);
        reporter.rerequest(REQUEST_ID, 0, MANUAL_PROPOSAL_BOND, MANUAL_LIVENESS);

        RequestData memory afterManual = reporter.getRequest(REQUEST_ID);
        assertEq(afterManual.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET - 1, "budget should decrement once");

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(true);
        vm.warp(block.timestamp + 1);

        vm.expectEmit(address(reporter));
        emit RequestRerequestBudgetSet(REQUEST_ID, DEFAULT_REREQUEST_BUDGET);
        vm.expectEmit(address(reporter));
        emit RequestRerequested(
            REQUEST_ID,
            block.timestamp,
            address(reporter),
            RerequestType.AutomaticInvalidSettlement,
            afterManual.requestTimestamp,
            address(usdc),
            0,
            MANUAL_PROPOSAL_BOND,
            MANUAL_LIVENESS,
            DEFAULT_REREQUEST_BUDGET
        );

        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, afterManual.requestTimestamp, requestRules, reporter.P4_PRICE()
        );

        RequestData memory afterP4 = reporter.getRequest(REQUEST_ID);
        assertFalse(afterP4.resolved, "P4 should not resolve request");
        assertFalse(reporter.isRequestResolved(REQUEST_ID), "P4 should not resolve request");
        assertFalse(afterP4.rerequestAllowed, "automatic P4 re-request should not leave gate open");
        assertEq(
            afterP4.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET, "P4 should refill the budget to the default"
        );
        assertEq(afterP4.requestTimestamp, block.timestamp, "P4 should auto re-request");
        assertEq(afterP4.proposalBond, MANUAL_PROPOSAL_BOND, "P4 should preserve latest manual bond");
        assertEq(afterP4.liveness, MANUAL_LIVENESS, "P4 should preserve latest manual liveness");

        vm.expectRevert(IOOReporter.RequestResolutionUnavailable.selector);
        reporter.getRequestResolution(REQUEST_ID);
    }

    function test_priceSettledP4OpensManualGateWhenAutomaticRerequestReverts() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.setMinimumDisputeWindow(uint256(LIVENESS) + 1);

        vm.expectEmit(address(reporter));
        emit AutomaticRerequestFailed(REQUEST_ID, request.requestTimestamp, RerequestType.AutomaticInvalidSettlement);

        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, reporter.P4_PRICE()
        );

        RequestData memory afterP4 = reporter.getRequest(REQUEST_ID);
        assertTrue(afterP4.rerequestAllowed, "failed automatic P4 re-request should open manual gate");

        bytes32 activeRequestKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);
        MockOptimisticOracleV2.MockRequest memory activeRequest = optimisticOracle.getMockRequest(activeRequestKey);
        assertTrue(activeRequest.settled, "P4 settlement should persist when automatic re-request fails");

        bytes32 replacementKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, block.timestamp, requestRules);
        MockOptimisticOracleV2.MockRequest memory replacementRequest = optimisticOracle.getMockRequest(replacementKey);
        assertFalse(replacementRequest.requested, "failed automatic P4 re-request should roll back replacement request");
    }

    function test_priceSettledP4OpensManualGateWhenAutomaticRerequestsDisabled() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);

        vm.expectEmit(address(reporter));
        emit RequestRerequestAllowed(REQUEST_ID, request.requestTimestamp, RerequestTrigger.InvalidSettlement);

        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, reporter.P4_PRICE()
        );

        RequestData memory afterP4 = reporter.getRequest(REQUEST_ID);
        assertTrue(afterP4.rerequestAllowed, "disabled P4 automation should open manual gate");
        assertEq(
            afterP4.requestTimestamp, request.requestTimestamp, "disabled P4 automation should not advance timestamp"
        );
        assertEq(
            afterP4.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET, "P4 should leave default budget available"
        );
    }

    function test_priceSettledP4OpensManualGateWhenAutomaticRerequestTimestampNotAdvanced() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);

        vm.expectEmit(address(reporter));
        emit RequestRerequestAllowed(REQUEST_ID, request.requestTimestamp, RerequestTrigger.InvalidSettlement);

        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, reporter.P4_PRICE()
        );

        RequestData memory afterP4 = reporter.getRequest(REQUEST_ID);
        assertTrue(afterP4.rerequestAllowed, "same-block P4 should open manual gate");
        assertFalse(afterP4.resolved, "P4 should not resolve request");
        assertEq(afterP4.requestTimestamp, request.requestTimestamp, "same-block P4 should not advance timestamp");
        assertEq(
            afterP4.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET, "P4 should leave default budget available"
        );
    }

    function test_priceSettledP4UsesCurrentAutomationSettingAfterBeingDisabled() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);
        vm.warp(block.timestamp + 1);

        vm.expectEmit(address(reporter));
        emit RequestRerequestAllowed(REQUEST_ID, request.requestTimestamp, RerequestTrigger.InvalidSettlement);

        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, reporter.P4_PRICE()
        );

        RequestData memory afterP4 = reporter.getRequest(REQUEST_ID);
        assertTrue(afterP4.rerequestAllowed, "disabled P4 callback should open manual gate");
        assertFalse(afterP4.resolved, "P4 should not resolve request");
        assertEq(
            afterP4.requestTimestamp, request.requestTimestamp, "disabled P4 callback should not advance timestamp"
        );
        assertEq(
            afterP4.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET, "disabled P4 should leave budget available"
        );
    }

    function test_rerequestConsumesBudgetAndCreatesReplacementRequest() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        RequestData memory afterAuto = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, afterAuto.requestTimestamp, requestRules);

        usdc.mint(address(reporter), REREQUEST_REWARD);

        vm.expectEmit(address(reporter));
        emit RequestRerequested(
            REQUEST_ID,
            block.timestamp,
            oracleInitializer,
            RerequestType.Manual,
            afterAuto.requestTimestamp,
            address(usdc),
            REREQUEST_REWARD,
            MANUAL_PROPOSAL_BOND,
            MANUAL_LIVENESS,
            DEFAULT_REREQUEST_BUDGET - 1
        );

        vm.prank(oracleInitializer);
        reporter.rerequest(REQUEST_ID, REREQUEST_REWARD, MANUAL_PROPOSAL_BOND, MANUAL_LIVENESS);

        RequestData memory rerequested = reporter.getRequest(REQUEST_ID);
        assertEq(rerequested.requestTimestamp, block.timestamp, "re-request timestamp mismatch");
        assertEq(rerequested.reward, REREQUEST_REWARD, "re-request reward mismatch");
        assertEq(rerequested.proposalBond, MANUAL_PROPOSAL_BOND, "re-request bond mismatch");
        assertEq(rerequested.liveness, MANUAL_LIVENESS, "re-request liveness mismatch");
        assertEq(rerequested.manualRerequestsRemaining, DEFAULT_REREQUEST_BUDGET - 1, "budget should decrement");
        assertFalse(rerequested.rerequestAllowed, "gate should close after re-request");

        bytes32 requestKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, block.timestamp, requestRules);
        MockOptimisticOracleV2.MockRequest memory ooRequest = optimisticOracle.getMockRequest(requestKey);
        assertTrue(ooRequest.requested, "replacement request should exist");
        assertEq(ooRequest.bond, MANUAL_PROPOSAL_BOND, "replacement request bond mismatch");
        assertEq(ooRequest.customLiveness, MANUAL_LIVENESS, "replacement request liveness mismatch");
    }

    function test_rerequestRevertsWhenGateClosedOrUnauthorized() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestRerequestNotAllowed.selector);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        vm.prank(owner);
        vm.expectRevert(IOOReporter.CallerNotOracleInitializer.selector);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        vm.prank(unauthorized);
        vm.expectRevert(IOOReporter.CallerNotOracleInitializer.selector);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);
    }

    function test_rerequestRejectsManualLivenessBelowRegisteredMinimum() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequestWithLivenessRange(
            REQUEST_ID, BINARY_IDENTIFIER, requestRules, STRICT_MINIMUM_LIVENESS, STRICT_MAXIMUM_LIVENESS
        );

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, STRICT_MINIMUM_LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);

        vm.prank(oracleInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOOReporter.RequestLivenessOutOfRange.selector,
                STRICT_MINIMUM_LIVENESS - 1,
                STRICT_MINIMUM_LIVENESS,
                STRICT_MAXIMUM_LIVENESS
            )
        );
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, STRICT_MINIMUM_LIVENESS - 1);
    }

    function test_rerequestBudgetExhaustsAndOwnerCanTopUp() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        // Seed a small budget so it can be exhausted in a couple of re-requests.
        vm.prank(owner);
        reporter.setDefaultRerequestBudget(2);
        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        // Consume the full budget, reopening the gate before each re-request.
        _disputeAndRerequest(requestRules);
        _disputeAndRerequest(requestRules);

        // Budget exhausted: gate is open again, but the re-request must revert.
        RequestData memory exhausted = reporter.getRequest(REQUEST_ID);
        assertEq(exhausted.manualRerequestsRemaining, 0, "budget should be exhausted");
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, exhausted.requestTimestamp, requestRules);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestRerequestBudgetExhausted.selector);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        // Owner cannot top a request up beyond the contract-level default budget.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOOReporter.RequestRerequestBudgetAboveDefault.selector, 3, 2));
        reporter.setRequestRerequestBudget(REQUEST_ID, 3);

        // Owner tops the budget back up to the default ceiling and re-requests succeed again.
        vm.expectEmit(address(reporter));
        emit RequestRerequestBudgetSet(REQUEST_ID, 2);
        vm.prank(owner);
        reporter.setRequestRerequestBudget(REQUEST_ID, 2);

        vm.prank(oracleInitializer);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        assertEq(reporter.getRequest(REQUEST_ID).manualRerequestsRemaining, 1, "budget should reflect top-up minus one");
    }

    function test_setRequestRerequestBudgetRejectsUnauthorizedUnchangedAndResolved() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        // Cannot set budget before initialization.
        vm.prank(owner);
        vm.expectRevert(IOOReporter.RequestNotInitialized.selector);
        reporter.setRequestRerequestBudget(REQUEST_ID, 5);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), unauthorized));
        reporter.setRequestRerequestBudget(REQUEST_ID, 5);

        vm.prank(owner);
        vm.expectRevert(IOOReporter.RequestRerequestBudgetUnchanged.selector);
        reporter.setRequestRerequestBudget(REQUEST_ID, DEFAULT_REREQUEST_BUDGET);

        // Owner cannot top a request up beyond the contract-level default budget.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOOReporter.RequestRerequestBudgetAboveDefault.selector,
                DEFAULT_REREQUEST_BUDGET + 1,
                DEFAULT_REREQUEST_BUDGET
            )
        );
        reporter.setRequestRerequestBudget(REQUEST_ID, DEFAULT_REREQUEST_BUDGET + 1);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, 1 ether);

        vm.prank(owner);
        vm.expectRevert(IOOReporter.RequestAlreadyResolved.selector);
        reporter.setRequestRerequestBudget(REQUEST_ID, 5);
    }

    function test_setDefaultRerequestBudgetUpdatesFutureInitializations() external {
        vm.expectEmit(address(reporter));
        emit DefaultRerequestBudgetSet(4);
        vm.prank(owner);
        reporter.setDefaultRerequestBudget(4);
        assertEq(reporter.defaultRerequestBudget(), 4, "default budget should update");

        vm.prank(owner);
        vm.expectRevert(IOOReporter.DefaultRerequestBudgetUnchanged.selector);
        reporter.setDefaultRerequestBudget(4);

        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, _requestRules("primary"));
        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        assertEq(reporter.getRequest(REQUEST_ID).manualRerequestsRemaining, 4, "request should seed new default budget");
    }

    function test_setAutomaticRerequestsEnabledUpdatesAndRejectsInvalidChanges() external {
        assertTrue(reporter.automaticRerequestsEnabled(), "automatic re-requests should start enabled");

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), unauthorized));
        reporter.setAutomaticRerequestsEnabled(false);

        vm.prank(owner);
        vm.expectRevert(IOOReporter.AutomaticRerequestsEnabledUnchanged.selector);
        reporter.setAutomaticRerequestsEnabled(true);

        vm.expectEmit(address(reporter));
        emit AutomaticRerequestsEnabledSet(false);
        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);
        assertFalse(reporter.automaticRerequestsEnabled(), "automatic re-requests should disable");

        vm.expectEmit(address(reporter));
        emit AutomaticRerequestsEnabledSet(true);
        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(true);
        assertTrue(reporter.automaticRerequestsEnabled(), "automatic re-requests should re-enable");
    }

    function test_priceSettledRejectsUnauthorizedCallerAndIgnoresUnknownTuples() external {
        vm.prank(unauthorized);
        vm.expectRevert(IOOReporter.CallerNotOptimisticOracle.selector);
        reporter.priceSettled(BINARY_IDENTIFIER, block.timestamp, _requestRules("primary"), 1 ether);

        vm.prank(address(optimisticOracle));
        reporter.priceSettled(BINARY_IDENTIFIER, block.timestamp, _requestRules("unknown"), 1 ether);
    }

    function test_staleCallbacksDoNotMutateAfterRerequest() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory firstRequest = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);

        // The first dispute automatically creates a replacement request and advances the active timestamp.
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, firstRequest.requestTimestamp, requestRules);

        RequestData memory activeRequest = reporter.getRequest(REQUEST_ID);
        assertEq(activeRequest.requestTimestamp, block.timestamp, "active timestamp should advance");
        assertFalse(activeRequest.resolved, "active request should remain unresolved");

        // A late settlement for the stale (replaced) request must not mutate the active request.
        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, firstRequest.requestTimestamp, requestRules, 1 ether
        );

        RequestData memory updatedRequest = reporter.getRequest(REQUEST_ID);
        assertFalse(reporter.isRequestResolved(REQUEST_ID), "stale settlement should not resolve");
        assertEq(updatedRequest.requestTimestamp, activeRequest.requestTimestamp, "active timestamp changed");
    }

    function test_resolvedRequestsCannotBeRerequestedOrBudgetSet() external {
        bytes memory requestRules = _requestRules("primary");
        _registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, 1 ether);

        vm.prank(oracleInitializer);
        vm.expectRevert(IOOReporter.RequestAlreadyResolved.selector);
        reporter.rerequest(REQUEST_ID, REREQUEST_REWARD, PROPOSAL_BOND, LIVENESS);

        vm.prank(owner);
        vm.expectRevert(IOOReporter.RequestAlreadyResolved.selector);
        reporter.setRequestRerequestBudget(REQUEST_ID, 5);
    }

    function _disputeAndRerequest(bytes memory requestRules) internal {
        RequestData memory request = reporter.getRequest(REQUEST_ID);
        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);
        vm.prank(oracleInitializer);
        reporter.rerequest(REQUEST_ID, 0, PROPOSAL_BOND, LIVENESS);
    }

    function _registerRequest(bytes32 requestId, bytes32 priceIdentifier, bytes memory requestRules) internal {
        _registerRequestWithLivenessRange(requestId, priceIdentifier, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function _registerRequestWithLivenessRange(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes memory requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) internal {
        vm.prank(requester);
        reporter.registerRequest(requestId, priceIdentifier, requestRules, minimumLiveness, maximumLiveness);
    }

    function _assertSettlementStores(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes memory requestRules,
        int256 price
    ) internal {
        _registerRequest(requestId, priceIdentifier, requestRules);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(requestId, 0, 0, LIVENESS);

        RequestData memory request = reporter.getRequest(requestId);
        vm.expectEmit(address(reporter));
        emit RequestResolved(requestId, request.requestTimestamp, price);

        optimisticOracle.settle(address(reporter), priceIdentifier, request.requestTimestamp, requestRules, price);

        assertTrue(reporter.isRequestResolved(requestId), "request should be resolved");
        assertEq(reporter.getRequestResolution(requestId), price, "stored price mismatch");
    }

    function _requestRules(string memory salt) internal pure returns (bytes memory) {
        return abi.encodePacked("q: title: PM v2 request ", salt, ", res_data: p1: 0, p2: 1, p3: 0.5");
    }

    function assertTrue(bool condition, string memory message) internal pure {
        if (!condition) revert(message);
    }

    function assertFalse(bool condition, string memory message) internal pure {
        if (condition) revert(message);
    }

    function assertEq(address actual, address expected, string memory message) internal pure {
        if (actual != expected) revert(message);
    }

    function assertEq(bool actual, bool expected, string memory message) internal pure {
        if (actual != expected) revert(message);
    }

    function assertEq(bytes32 actual, bytes32 expected, string memory message) internal pure {
        if (actual != expected) revert(message);
    }

    function assertEq(uint256 actual, uint256 expected, string memory message) internal pure {
        if (actual != expected) revert(message);
    }

    function assertEq(int256 actual, int256 expected, string memory message) internal pure {
        if (actual != expected) revert(message);
    }

    function assertEq(bytes memory actual, bytes memory expected, string memory message) internal pure {
        if (keccak256(actual) != keccak256(expected)) revert(message);
    }
}
