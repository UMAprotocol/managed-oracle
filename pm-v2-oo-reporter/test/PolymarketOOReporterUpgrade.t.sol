// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PolymarketOOReporter} from "src/PolymarketOOReporter.sol";
import {IOOReporter} from "src/interfaces/IOOReporter.sol";
import {LegacyOOReporter, LegacyRequestData} from "test/mocks/LegacyOOReporter.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockOptimisticOracleV2} from "test/mocks/MockOptimisticOracleV2.sol";

interface IUUPSUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeOwner {
    function execute(address target, bytes calldata data) external {
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}

contract UpgradeReporterModule {
    IOOReporter public reporter;
    uint256 public reportCount;
    bytes32 public lastRequestId;
    address public lastReporter;
    bool public observedResolved;
    int256 public observedOutcome;

    function setReporter(IOOReporter newReporter) external {
        reporter = newReporter;
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
        reportCount += 1;
        lastRequestId = requestId;
        lastReporter = msg.sender;
        observedResolved = reporter.isRequestResolved(requestId);
        observedOutcome = reporter.getRequestResolution(requestId);
    }
}

contract PolymarketOOReporterUpgradeTest is Test {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant RESOLVED_REQUEST_ID = keccak256("resolved-before-upgrade");
    bytes32 private constant PENDING_REQUEST_ID = keccak256("pending-during-upgrade");
    bytes32 private constant BINARY_IDENTIFIER = "YES_OR_NO_QUERY";
    uint64 private constant LIVENESS = 2 hours;
    uint64 private constant MAXIMUM_LIVENESS = 2 days;
    uint256 private constant DEFAULT_REREQUEST_BUDGET = 5;

    address private owner = address(0x1001);
    address private oracleInitializer = address(0x1002);
    address private unauthorized = address(0x1003);

    LegacyOOReporter private legacyReporter;
    UpgradeReporterModule private module;
    MockOptimisticOracleV2 private optimisticOracle;
    MockERC20 private usdc;

    function setUp() external {
        optimisticOracle = new MockOptimisticOracleV2();
        usdc = new MockERC20();
        module = new UpgradeReporterModule();

        LegacyOOReporter implementation = new LegacyOOReporter();
        bytes memory initData = abi.encodeCall(
            LegacyOOReporter.initialize,
            (
                owner,
                address(optimisticOracle),
                address(usdc),
                oracleInitializer,
                address(module),
                DEFAULT_REREQUEST_BUDGET
            )
        );
        legacyReporter = LegacyOOReporter(address(new ERC1967Proxy(address(implementation), initData)));
        module.setReporter(IOOReporter(address(legacyReporter)));
    }

    function test_upgradePreservesStateAndEnablesCallback() external {
        bytes memory resolvedRules = bytes("resolved before upgrade");
        _registerAndInitialize(RESOLVED_REQUEST_ID, resolvedRules);
        LegacyRequestData memory resolvedBefore = legacyReporter.getRequest(RESOLVED_REQUEST_ID);
        optimisticOracle.settle(
            address(legacyReporter), BINARY_IDENTIFIER, resolvedBefore.requestTimestamp, resolvedRules, 1 ether
        );
        resolvedBefore = legacyReporter.getRequest(RESOLVED_REQUEST_ID);
        assertTrue(resolvedBefore.resolved, "legacy request should resolve");
        assertEq(module.reportCount(), 0, "legacy implementation should not report");

        bytes memory pendingRules = bytes("pending during upgrade");
        _registerAndInitialize(PENDING_REQUEST_ID, pendingRules);
        LegacyRequestData memory pendingBefore = legacyReporter.getRequest(PENDING_REQUEST_ID);

        PolymarketOOReporter implementation = new PolymarketOOReporter();
        vm.prank(owner);
        IUUPSUpgrade(address(legacyReporter)).upgradeToAndCall(address(implementation), bytes(""));

        PolymarketOOReporter upgraded = PolymarketOOReporter(address(legacyReporter));
        assertEq(upgraded.owner(), owner, "owner changed");
        assertEq(upgraded.pendingOwner(), address(0), "pending owner should start empty");
        assertEq(address(upgraded.optimisticOracle()), address(optimisticOracle), "oracle changed");
        assertEq(address(upgraded.rewardCurrency()), address(usdc), "currency changed");
        assertEq(upgraded.defaultRerequestBudget(), DEFAULT_REREQUEST_BUDGET, "default budget changed");
        assertTrue(upgraded.automaticRerequestsEnabled(), "automatic rerequests changed");
        assertTrue(upgraded.isRequester(address(module)), "requester role changed");
        assertTrue(upgraded.isOracleInitializer(oracleInitializer), "initializer role changed");
        assertEq(
            keccak256(abi.encode(upgraded.getRequest(RESOLVED_REQUEST_ID))),
            keccak256(abi.encode(resolvedBefore)),
            "resolved request changed"
        );
        assertEq(
            keccak256(abi.encode(upgraded.getRequest(PENDING_REQUEST_ID))),
            keccak256(abi.encode(pendingBefore)),
            "pending request changed"
        );
        assertEq(
            upgraded.getRequestId(BINARY_IDENTIFIER, resolvedRules), RESOLVED_REQUEST_ID, "resolved lookup changed"
        );
        assertEq(upgraded.getRequestId(BINARY_IDENTIFIER, pendingRules), PENDING_REQUEST_ID, "pending lookup changed");

        optimisticOracle.settle(
            address(upgraded), BINARY_IDENTIFIER, pendingBefore.requestTimestamp, pendingRules, 1 ether
        );

        assertEq(module.reportCount(), 1, "callback not invoked");
        assertEq(module.lastRequestId(), PENDING_REQUEST_ID, "callback request id mismatch");
        assertEq(module.lastReporter(), address(upgraded), "callback reporter mismatch");
        assertTrue(module.observedResolved(), "callback observed unresolved request");
        assertEq(module.observedOutcome(), 1 ether, "callback outcome mismatch");
    }

    function test_upgradeRejectsNonOwner() external {
        PolymarketOOReporter implementation = new PolymarketOOReporter();
        bytes32 implementationBefore = vm.load(address(legacyReporter), IMPLEMENTATION_SLOT);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), unauthorized));
        IUUPSUpgrade(address(legacyReporter)).upgradeToAndCall(address(implementation), bytes(""));

        assertEq(vm.load(address(legacyReporter), IMPLEMENTATION_SLOT), implementationBefore, "implementation changed");
        assertEq(legacyReporter.owner(), owner, "owner changed");
    }

    function test_upgradeSupportsPredeployedImplementationAndContractOwner() external {
        UpgradeOwner upgradeOwner = new UpgradeOwner();
        vm.prank(owner);
        legacyReporter.transferOwnership(address(upgradeOwner));

        PolymarketOOReporter implementation = new PolymarketOOReporter();
        bytes memory upgradeCall = abi.encodeCall(IUUPSUpgrade.upgradeToAndCall, (address(implementation), bytes("")));
        upgradeOwner.execute(address(legacyReporter), upgradeCall);

        assertEq(
            address(uint160(uint256(vm.load(address(legacyReporter), IMPLEMENTATION_SLOT)))),
            address(implementation),
            "implementation mismatch"
        );
        assertEq(legacyReporter.owner(), address(upgradeOwner), "contract owner changed");
        assertEq(address(legacyReporter.optimisticOracle()), address(optimisticOracle), "oracle changed");
        assertEq(address(legacyReporter.rewardCurrency()), address(usdc), "currency changed");
    }

    function _registerAndInitialize(bytes32 requestId, bytes memory requestRules) private {
        module.registerRequest(requestId, BINARY_IDENTIFIER, requestRules, 0, MAXIMUM_LIVENESS);
        vm.prank(oracleInitializer);
        legacyReporter.initializeRequest(requestId, 0, 0, LIVENESS);
    }
}
