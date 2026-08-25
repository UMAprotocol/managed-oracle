// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {PolymarketOOReporter} from "src/PolymarketOOReporter.sol";
import {IOOReporter, RequestData} from "src/interfaces/IOOReporter.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockOptimisticOracleV2} from "test/mocks/MockOptimisticOracleV2.sol";

interface PolymarketReporterVm {
    function prank(address msgSender) external;
    function expectEmit(address emitter) external;
    function warp(uint256 newTimestamp) external;
}

contract PolymarketReporterProxy {
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    constructor(address implementation, bytes memory data) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, implementation)
        }

        (bool success, bytes memory result) = implementation.delegatecall(data);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    fallback() external payable {
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

contract MockPolymarketOOReporterModule {
    error ReportFailed();

    IOOReporter public reporter;
    bool public shouldRevert;
    uint256 public reportCount;
    bytes32 public lastRequestId;
    mapping(bytes32 requestId => bool reported) public reported;
    address public lastReporter;
    bool public observedResolved;
    int256 public observedOutcome;

    function setReporter(IOOReporter newReporter) external {
        reporter = newReporter;
    }

    function setShouldRevert(bool newShouldRevert) external {
        shouldRevert = newShouldRevert;
    }

    function registerRequest(
        bytes32 requestId,
        bytes32 priceIdentifier,
        bytes calldata requestRules,
        uint64 minimumLiveness,
        uint64 maximumLiveness
    ) external {
        reporter.registerRequest(requestId, priceIdentifier, requestRules, minimumLiveness, maximumLiveness);
    }

    function report(bytes32 requestId) external {
        if (shouldRevert) revert ReportFailed();

        reportCount += 1;
        lastRequestId = requestId;
        reported[requestId] = true;
        lastReporter = msg.sender;
        observedResolved = reporter.isRequestResolved(requestId);
        observedOutcome = reporter.getRequestResolution(requestId);
    }
}

contract PolymarketOOReporterTest {
    PolymarketReporterVm private constant vm =
        PolymarketReporterVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event RequestResolved(bytes32 indexed requestId, uint256 indexed requestTimestamp, int256 outcome);
    event ReportCallbackSucceeded(bytes32 indexed requestId, address indexed reporterModule);
    event ReportCallbackFailed(bytes32 indexed requestId, address indexed reporterModule);

    bytes32 private constant REQUEST_ID = keccak256("polymarket-request-id");
    bytes32 private constant SECOND_REQUEST_ID = keccak256("second-polymarket-request-id");
    bytes32 private constant BINARY_IDENTIFIER = "YES_OR_NO_QUERY";
    uint64 private constant LIVENESS = 2 hours;
    uint64 private constant MAXIMUM_LIVENESS = 2 days;
    uint256 private constant DEFAULT_REREQUEST_BUDGET = 1;

    address private owner = address(0x1001);
    address private oracleInitializer = address(0x1002);

    PolymarketOOReporter private reporter;
    MockPolymarketOOReporterModule private module;
    MockOptimisticOracleV2 private optimisticOracle;
    MockERC20 private usdc;

    function setUp() external {
        optimisticOracle = new MockOptimisticOracleV2();
        usdc = new MockERC20();
        module = new MockPolymarketOOReporterModule();

        PolymarketOOReporter implementation = new PolymarketOOReporter();
        bytes memory initData = abi.encodeCall(
            IOOReporter.initialize,
            (
                owner,
                address(optimisticOracle),
                address(usdc),
                oracleInitializer,
                address(module),
                DEFAULT_REREQUEST_BUDGET
            )
        );
        reporter = PolymarketOOReporter(address(new PolymarketReporterProxy(address(implementation), initData)));
        module.setReporter(IOOReporter(address(reporter)));
    }

    function test_settlementAutomaticallyReportsResolvedOutcome() external {
        bytes memory requestRules = _registerAndInitialize();
        RequestData memory request = reporter.getRequest(REQUEST_ID);

        vm.expectEmit(address(reporter));
        emit RequestResolved(REQUEST_ID, request.requestTimestamp, 1 ether);
        vm.expectEmit(address(reporter));
        emit ReportCallbackSucceeded(REQUEST_ID, address(module));

        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, 1 ether);

        _assertEq(module.reportCount(), 1, "report count mismatch");
        _assertEq(module.lastRequestId(), REQUEST_ID, "request id mismatch");
        _assertEq(module.lastReporter(), address(reporter), "report caller mismatch");
        _assertTrue(module.observedResolved(), "report should observe resolved state");
        _assertEq(module.observedOutcome(), 1 ether, "reported outcome mismatch");
    }

    function test_settlementAutomaticallyReportsAllDuplicateRequestIds() external {
        bytes memory requestRules = bytes("Will ETH reach 10k?");
        module.registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules, 0, MAXIMUM_LIVENESS);
        module.registerRequest(SECOND_REQUEST_ID, BINARY_IDENTIFIER, requestRules, 0, MAXIMUM_LIVENESS);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);
        vm.prank(oracleInitializer);
        reporter.initializeRequest(SECOND_REQUEST_ID, 0, 0, LIVENESS);

        RequestData memory request = reporter.getRequest(REQUEST_ID);
        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, 1 ether);

        _assertEq(module.reportCount(), 2, "report count mismatch");
        _assertTrue(module.reported(REQUEST_ID), "canonical request was not reported");
        _assertTrue(module.reported(SECOND_REQUEST_ID), "duplicate request was not reported");
        _assertTrue(reporter.isRequestResolved(SECOND_REQUEST_ID), "duplicate request should resolve");
        _assertEq(reporter.getRequestResolution(SECOND_REQUEST_ID), 1 ether, "duplicate outcome mismatch");
    }

    function test_reportFailureDoesNotRevertSettlementAndCanBeRetried() external {
        bytes memory requestRules = _registerAndInitialize();
        RequestData memory request = reporter.getRequest(REQUEST_ID);
        module.setShouldRevert(true);

        vm.expectEmit(address(reporter));
        emit RequestResolved(REQUEST_ID, request.requestTimestamp, 1 ether);
        vm.expectEmit(address(reporter));
        emit ReportCallbackFailed(REQUEST_ID, address(module));

        optimisticOracle.settle(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, 1 ether);

        _assertTrue(reporter.isRequestResolved(REQUEST_ID), "reporter should remain resolved");
        _assertEq(reporter.getRequestResolution(REQUEST_ID), 1 ether, "stored outcome mismatch");
        bytes32 requestKey =
            optimisticOracle.requestKey(address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules);
        _assertTrue(optimisticOracle.getMockRequest(requestKey).settled, "oracle settlement should persist");

        module.setShouldRevert(false);
        module.report(REQUEST_ID);
        _assertEq(module.reportCount(), 1, "permissionless retry should succeed");
    }

    function test_p4SettlementDoesNotReport() external {
        bytes memory requestRules = _registerAndInitialize();
        RequestData memory request = reporter.getRequest(REQUEST_ID);

        vm.prank(owner);
        reporter.setAutomaticRerequestsEnabled(false);
        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, request.requestTimestamp, requestRules, reporter.P4_PRICE()
        );

        _assertEq(module.reportCount(), 0, "P4 should not report");
        _assertFalse(reporter.isRequestResolved(REQUEST_ID), "P4 should not resolve reporter request");
        _assertTrue(reporter.getRequest(REQUEST_ID).rerequestAllowed, "P4 should open rerequest gate");
    }

    function test_staleSettlementDoesNotReport() external {
        bytes memory requestRules = _registerAndInitialize();
        RequestData memory initialRequest = reporter.getRequest(REQUEST_ID);

        vm.warp(block.timestamp + 1);
        optimisticOracle.disputePrice(
            address(reporter), BINARY_IDENTIFIER, initialRequest.requestTimestamp, requestRules
        );
        RequestData memory activeRequest = reporter.getRequest(REQUEST_ID);

        optimisticOracle.settle(
            address(reporter), BINARY_IDENTIFIER, initialRequest.requestTimestamp, requestRules, 1 ether
        );

        _assertEq(module.reportCount(), 0, "stale settlement should not report");
        _assertFalse(reporter.isRequestResolved(REQUEST_ID), "stale settlement should not resolve active request");
        _assertEq(
            reporter.getRequest(REQUEST_ID).requestTimestamp,
            activeRequest.requestTimestamp,
            "stale settlement should not replace active timestamp"
        );
    }

    function _registerAndInitialize() private returns (bytes memory requestRules) {
        requestRules = bytes("Will ETH reach 10k?");
        module.registerRequest(REQUEST_ID, BINARY_IDENTIFIER, requestRules, 0, MAXIMUM_LIVENESS);

        vm.prank(oracleInitializer);
        reporter.initializeRequest(REQUEST_ID, 0, 0, LIVENESS);
    }

    function _assertTrue(bool condition, string memory message) private pure {
        if (!condition) revert(message);
    }

    function _assertFalse(bool condition, string memory message) private pure {
        if (condition) revert(message);
    }

    function _assertEq(uint256 actual, uint256 expected, string memory message) private pure {
        if (actual != expected) revert(message);
    }

    function _assertEq(int256 actual, int256 expected, string memory message) private pure {
        if (actual != expected) revert(message);
    }

    function _assertEq(bytes32 actual, bytes32 expected, string memory message) private pure {
        if (actual != expected) revert(message);
    }

    function _assertEq(address actual, address expected, string memory message) private pure {
        if (actual != expected) revert(message);
    }
}
