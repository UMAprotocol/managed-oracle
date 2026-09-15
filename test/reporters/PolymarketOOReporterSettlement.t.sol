// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ManagedOptimisticOracleV2} from "src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {OptimisticOracleV2Interface} from "src/optimistic-oracle-v2/interfaces/OptimisticOracleV2Interface.sol";
import {AddressWhitelist} from "src/common/implementation/AddressWhitelist.sol";
import {PolymarketOOReporter} from "src/reporters/integrations/PolymarketOOReporter.sol";
import {IOOReporter} from "src/reporters/interfaces/IOOReporter.sol";
import {OracleInterfaces} from "@uma/contracts/data-verification-mechanism/implementation/Constants.sol";
import {MockFinder} from "test/mocks/MockFinder.sol";
import {MockStore} from "test/mocks/MockStore.sol";
import {MockIdentifierWhitelist} from "test/mocks/MockIdentifierWhitelist.sol";

contract GasExhaustingReporterModule {
    IOOReporter public reporter;
    bytes32 public failingId;
    mapping(bytes32 => bool) public reported;

    function configure(IOOReporter reporter_, bytes32 failingId_) external {
        reporter = reporter_;
        failingId = failingId_;
    }

    function report(bytes32 requestId) external {
        require(reporter.isRequestResolved(requestId), "unresolved");
        require(reporter.getRequestResolution(requestId) == 1 ether, "wrong outcome");
        reported[requestId] = true;
        if (requestId == failingId) {
            // Exceptional halt consumes the full forwarded allowance and rolls back this callback's writes.
            assembly {
                invalid()
            }
        }
    }
}

contract PolymarketOOReporterSettlementTest is Test {
    bytes32 private constant IDENTIFIER = "YES_OR_NO_QUERY";
    uint64 private constant LIVENESS = 2 hours;
    uint256 private constant SETTLEMENT_GAS = 8_000_000;
    uint256 private constant BOND = 1 ether;
    bytes private rules;
    address private resolver = address(0x1001);
    address private proposer = address(0x1002);
    ManagedOptimisticOracleV2 private oracle;
    PolymarketOOReporter private reporter;
    GasExhaustingReporterModule private module;
    ERC20Mock private currency;
    address private oracleImplementation;
    address private reporterImplementation;
    uint256 private requestTimestamp;

    function setUp() public {
        bytes memory maximumRules = new bytes(8139);
        for (uint256 i; i < maximumRules.length; ++i) {
            maximumRules[i] = 0x61;
        }
        rules = maximumRules;
        MockFinder finder = new MockFinder();
        MockStore store = new MockStore();
        MockIdentifierWhitelist identifiers = new MockIdentifierWhitelist();
        AddressWhitelist collateral = new AddressWhitelist();
        AddressWhitelist requesters = new AddressWhitelist();
        AddressWhitelist proposers = new AddressWhitelist();
        currency = new ERC20Mock();
        collateral.addToWhitelist(address(currency));
        identifiers.addSupportedIdentifier(IDENTIFIER);
        proposers.addToWhitelist(proposer);
        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateral));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(identifiers));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));

        ManagedOptimisticOracleV2.CurrencyBondRange[] memory ranges =
            new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
        ranges[0] = ManagedOptimisticOracleV2.CurrencyBondRange(
            IERC20(address(currency)), ManagedOptimisticOracleV2.BondRange(uint128(BOND), uint128(BOND))
        );
        oracleImplementation = address(new ManagedOptimisticOracleV2());
        oracle = ManagedOptimisticOracleV2(
            address(
                new ERC1967Proxy(
                    oracleImplementation,
                    abi.encodeCall(
                        ManagedOptimisticOracleV2.initialize,
                        (
                            LIVENESS,
                            address(finder),
                            address(proposers),
                            address(requesters),
                            ranges,
                            address(this),
                            address(this)
                        )
                    )
                )
            )
        );
        oracle.initializeV2(5 minutes, address(this));
        oracle.addResolver(resolver);

        module = new GasExhaustingReporterModule();
        reporterImplementation = address(new PolymarketOOReporter());
        reporter = PolymarketOOReporter(
            address(
                new ERC1967Proxy(
                    reporterImplementation,
                    abi.encodeCall(
                        IOOReporter.initialize,
                        (address(this), address(oracle), address(currency), address(this), address(module), 1)
                    )
                )
            )
        );
        module.configure(IOOReporter(address(reporter)), bytes32(0));
        requesters.addToWhitelist(address(reporter));
        for (uint256 i = 1; i <= 10; ++i) {
            vm.prank(address(module));
            reporter.registerRequest(bytes32(i), IDENTIFIER, rules, 0, LIVENESS);
        }
        reporter.initializeRequest(bytes32(uint256(1)), 0, BOND, LIVENESS);
        requestTimestamp = reporter.getRequest(bytes32(uint256(1))).requestTimestamp;
        currency.mint(proposer, BOND);
        vm.startPrank(proposer);
        currency.approve(address(oracle), BOND);
        oracle.proposePrice(address(reporter), IDENTIFIER, requestTimestamp, rules, 1 ether);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + LIVENESS + 1);
    }

    function test_realSettlementSurvivesGasExhaustionAtEveryPosition() public {
        for (uint256 failedId = 1; failedId <= 10; ++failedId) {
            uint256 snapshot = vm.snapshotState();
            module.configure(IOOReporter(address(reporter)), bytes32(failedId));
            bytes memory data = abi.encodeCall(
                ManagedOptimisticOracleV2.settle, (address(reporter), IDENTIFIER, requestTimestamp, rules)
            );
            vm.cool(address(oracle));
            vm.cool(oracleImplementation);
            vm.cool(address(reporter));
            vm.cool(reporterImplementation);
            vm.cool(address(module));
            vm.cool(address(currency));
            vm.recordLogs();
            vm.prank(resolver);
            (bool success, bytes memory result) = address(oracle).call{gas: SETTLEMENT_GAS}(data);
            assertTrue(success, "real settlement reverted");
            assertEq(abi.decode(result, (uint256)), BOND, "wrong settlement return value");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 resolutions;
            uint256 successes;
            uint256 failures;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(reporter)) continue;
                if (logs[i].topics[0] == keccak256("RequestResolved(bytes32,uint256,int256)")) {
                    ++resolutions;
                    assertEq(logs[i].topics[1], bytes32(resolutions));
                    assertEq(uint256(logs[i].topics[2]), requestTimestamp);
                    assertEq(abi.decode(logs[i].data, (int256)), 1 ether);
                } else if (logs[i].topics[0] == keccak256("ReportCallbackSucceeded(bytes32,address)")) {
                    ++successes;
                } else if (logs[i].topics[0] == keccak256("ReportCallbackFailed(bytes32,address)")) {
                    ++failures;
                }
            }
            assertEq(resolutions, 10, "missing resolution events");
            assertEq(successes, failedId - 1, "earlier callbacks rolled back");
            assertEq(failures, 11 - failedId, "missing failed or skipped callbacks");
            OptimisticOracleV2Interface.Request memory settled =
                oracle.getRequest(address(reporter), IDENTIFIER, requestTimestamp, rules);
            assertTrue(settled.settled, "oracle state rolled back");
            assertEq(settled.resolvedPrice, 1 ether);
            assertEq(currency.balanceOf(proposer), BOND, "settlement payout rolled back");
            module.configure(IOOReporter(address(reporter)), bytes32(0));
            for (uint256 i = 1; i <= 10; ++i) {
                assertTrue(reporter.isRequestResolved(bytes32(i)));
                assertEq(module.reported(bytes32(i)), i < failedId, "incorrect callback persistence");
                if (i >= failedId) {
                    vm.prank(address(0xBEEF));
                    module.report(bytes32(i));
                    assertTrue(module.reported(bytes32(i)), "permissionless recovery failed");
                }
            }
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }
}
