// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {OOReporter} from "src/reporters/OOReporter.sol";
import {PolymarketOOReporter} from "src/reporters/integrations/PolymarketOOReporter.sol";
import {IOOReporter, RequestData} from "src/reporters/interfaces/IOOReporter.sol";
import {MockERC20} from "test/reporters/mocks/MockERC20.sol";
import {MockOptimisticOracleV2} from "test/reporters/mocks/MockOptimisticOracleV2.sol";

interface IUUPSUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeOwner {
    function acceptOwnership(OOReporter reporter) external {
        reporter.acceptOwnership();
    }

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

    OOReporter private baseReporter;
    UpgradeReporterModule private module;
    MockOptimisticOracleV2 private optimisticOracle;
    MockERC20 private usdc;

    function setUp() external {
        optimisticOracle = new MockOptimisticOracleV2();
        usdc = new MockERC20();
        module = new UpgradeReporterModule();

        OOReporter implementation = new OOReporter();
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
        baseReporter = OOReporter(address(new ERC1967Proxy(address(implementation), initData)));
        module.setReporter(IOOReporter(address(baseReporter)));
    }

    function test_upgradePreservesStateAndEnablesCallback() external {
        bytes memory resolvedRules = bytes("resolved before upgrade");
        _registerAndInitialize(RESOLVED_REQUEST_ID, resolvedRules);
        RequestData memory resolvedBefore = baseReporter.getRequest(RESOLVED_REQUEST_ID);
        optimisticOracle.settle(
            address(baseReporter), BINARY_IDENTIFIER, resolvedBefore.requestTimestamp, resolvedRules, 1 ether
        );
        resolvedBefore = baseReporter.getRequest(RESOLVED_REQUEST_ID);
        assertTrue(resolvedBefore.resolved, "base request should resolve");
        assertEq(module.reportCount(), 0, "base implementation should not report");

        bytes memory pendingRules = bytes("pending during upgrade");
        _registerAndInitialize(PENDING_REQUEST_ID, pendingRules);
        RequestData memory pendingBefore = baseReporter.getRequest(PENDING_REQUEST_ID);

        PolymarketOOReporter implementation = new PolymarketOOReporter();
        vm.prank(owner);
        IUUPSUpgrade(address(baseReporter)).upgradeToAndCall(address(implementation), bytes(""));

        PolymarketOOReporter upgraded = PolymarketOOReporter(address(baseReporter));
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
        bytes32 implementationBefore = vm.load(address(baseReporter), IMPLEMENTATION_SLOT);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), unauthorized));
        IUUPSUpgrade(address(baseReporter)).upgradeToAndCall(address(implementation), bytes(""));

        assertEq(vm.load(address(baseReporter), IMPLEMENTATION_SLOT), implementationBefore, "implementation changed");
        assertEq(baseReporter.owner(), owner, "owner changed");
    }

    function test_upgradeSupportsPredeployedImplementationAndContractOwner() external {
        UpgradeOwner upgradeOwner = new UpgradeOwner();
        vm.prank(owner);
        baseReporter.transferOwnership(address(upgradeOwner));
        upgradeOwner.acceptOwnership(baseReporter);

        PolymarketOOReporter implementation = new PolymarketOOReporter();
        bytes memory upgradeCall = abi.encodeCall(IUUPSUpgrade.upgradeToAndCall, (address(implementation), bytes("")));
        upgradeOwner.execute(address(baseReporter), upgradeCall);

        assertEq(
            address(uint160(uint256(vm.load(address(baseReporter), IMPLEMENTATION_SLOT)))),
            address(implementation),
            "implementation mismatch"
        );
        assertEq(baseReporter.owner(), address(upgradeOwner), "contract owner changed");
        assertEq(address(baseReporter.optimisticOracle()), address(optimisticOracle), "oracle changed");
        assertEq(address(baseReporter.rewardCurrency()), address(usdc), "currency changed");
    }

    function _registerAndInitialize(bytes32 requestId, bytes memory requestRules) private {
        module.registerRequest(requestId, BINARY_IDENTIFIER, requestRules, 0, MAXIMUM_LIVENESS);
        vm.prank(oracleInitializer);
        baseReporter.initializeRequest(requestId, 0, 0, LIVENESS);
    }
}
