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

contract UpgradeOOReporterHarness is UpgradeOOReporter {
    function validateRegistration(OOReporter reporter, Vm.EthGetLogs memory requestLog, address requester)
        external
        view
        returns (bytes32)
    {
        return _validateRegisteredRequest(reporter, requestLog, requester, 0);
    }
}

contract UpgradeOOReporterScriptTest is Test {
    function test_registrationValidationAcceptsAliasesAcrossUpgradeAndRejectsMismatchedLogs() public {
        MockOptimisticOracleV2 oracle = new MockOptimisticOracleV2();
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

        for (uint256 pass; pass < 2; ++pass) {
            if (pass == 1) reporter.upgradeToAndCall(address(new PolymarketOOReporter()), "");
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
    }
}
