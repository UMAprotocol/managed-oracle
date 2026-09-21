// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OOReporter} from "src/reporters/OOReporter.sol";
import {IOOReporter} from "src/reporters/interfaces/IOOReporter.sol";
import {PolymarketOOReporter} from "src/reporters/integrations/PolymarketOOReporter.sol";
import {UpgradeOOReporter} from "script/reporters/UpgradeOOReporter.s.sol";
import {MockERC20} from "test/reporters/mocks/MockERC20.sol";
import {MockOptimisticOracleV2} from "test/reporters/mocks/MockOptimisticOracleV2.sol";
import {AddressWhitelist} from "src/common/implementation/AddressWhitelist.sol";

contract UpgradeScriptOracle is MockOptimisticOracleV2 {
    address public immutable requesterWhitelist;

    constructor(address whitelist) {
        requesterWhitelist = whitelist;
    }
}

contract UpgradeOOReporterHarness is UpgradeOOReporter {
    function validateRegistration(OOReporter reporter, Vm.EthGetLogs memory requestLog, address requester)
        external
        view
        returns (bytes32)
    {
        return _validateRegisteredRequest(reporter, requestLog, requester, 0);
    }

    function snapshot(OOReporter reporter, Config memory config, bytes32[] memory requestIds)
        external
        view
        returns (ReporterState memory)
    {
        return _snapshotReporterState(reporter, config, requestIds);
    }

    function validatePostUpgrade(
        OOReporter reporter,
        Config memory config,
        ReporterState memory expectedState,
        bytes32[] memory requestIds,
        address implementation
    ) external view {
        _validatePostUpgrade(reporter, config, expectedState, requestIds, implementation);
    }
}

contract UpgradeOOReporterScriptTest is Test {
    OOReporter public ooReporter;

    function test_registrationValidationAcceptsAliasesAcrossUpgradeAndRejectsMismatchedLogs() public {
        AddressWhitelist whitelist = new AddressWhitelist();
        UpgradeScriptOracle oracle = new UpgradeScriptOracle(address(whitelist));
        MockERC20 currency = new MockERC20();
        OOReporter reporter = OOReporter(
            address(
                new ERC1967Proxy(
                    address(new PolymarketOOReporter()),
                    abi.encodeCall(
                        IOOReporter.initialize,
                        (address(this), address(oracle), address(currency), address(this), address(this), 5)
                    )
                )
            )
        );
        ooReporter = reporter;
        whitelist.addToWhitelist(address(reporter));
        UpgradeOOReporterHarness script = new UpgradeOOReporterHarness();
        bytes32 canonicalId = keccak256("canonical");
        bytes32 aliasId = keccak256("alias");
        bytes32 identifier = "YES_OR_NO_QUERY";
        bytes memory rules = bytes("shared rules");

        vm.recordLogs();
        reporter.registerRequest(canonicalId, identifier, rules, 0, 2 days);
        reporter.registerRequest(aliasId, identifier, rules, 0, 2 days);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(reporter.getRequestId(identifier, rules), canonicalId);

        UpgradeOOReporter.Config memory config;
        config.proxy = address(reporter);
        config.expectedCurrentOptimisticOracle = address(oracle);
        config.expectedMooRequesterWhitelist = address(whitelist);
        config.expectedRequester = address(this);
        config.expectedOracleInitializer = address(this);
        bytes32[] memory requestIds = new bytes32[](2);
        requestIds[0] = canonicalId;
        requestIds[1] = aliasId;
        UpgradeOOReporter.ReporterState memory stateBefore = script.snapshot(reporter, config, requestIds);
        address finalImplementation = address(new PolymarketOOReporter());

        for (uint256 pass; pass < 2; ++pass) {
            if (pass == 1) {
                reporter.upgradeToAndCall(finalImplementation, "");
                script.validatePostUpgrade(reporter, config, stateBefore, requestIds, finalImplementation);
            }
            for (uint256 i; i < logs.length; ++i) {
                Vm.EthGetLogs memory requestLog;
                requestLog.emitter = logs[i].emitter;
                requestLog.topics = logs[i].topics;
                requestLog.data = logs[i].data;
                assertEq(
                    script.validateRegistration(reporter, requestLog, address(this)), i == 0 ? canonicalId : aliasId
                );

                requestLog.data = abi.encode(bytes("different rules"), uint64(0), uint64(2 days));
                vm.expectRevert(
                    abi.encodeWithSelector(
                        UpgradeOOReporter.RegisteredRequestStateMismatch.selector, requestLog.topics[1]
                    )
                );
                script.validateRegistration(reporter, requestLog, address(this));
            }
        }

        reporter.initializeRequest(aliasId, 0, 0, 2 hours);
        vm.expectRevert(abi.encodeWithSelector(UpgradeOOReporter.RequestStateChanged.selector, canonicalId));
        script.validatePostUpgrade(reporter, config, stateBefore, requestIds, finalImplementation);
    }
}
