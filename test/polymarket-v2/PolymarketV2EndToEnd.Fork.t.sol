// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EnvironmentManifest, EnvironmentManifestLib} from "./EnvironmentManifest.sol";
import {
    IBinaryModuleLike,
    IManagedOptimisticOracleLike,
    IOOReporterModuleLike,
    IPolymarketAggregator,
    IPolymarketOOReporterLike
} from "./PolymarketV2Interfaces.sol";

contract PolymarketV2EndToEndForkTest is Test {
    string private constant MANIFEST_PATH = "test/polymarket-v2/environments/vnet.json";
    string private constant FIXTURE_DOMAIN = "uma-fro-111-polymarket-v2-e2e-binary-v1";
    bytes32 private constant EXPECTED_REQUEST_ID = 0x018804eed8e0a0aaae200582e434c0b4f5000000000000000000000000000000;
    bytes32 private constant YES_OR_NO_QUERY = bytes32("YES_OR_NO_QUERY");
    int256 private constant YES_PRICE = 1e18;
    uint256 private constant RESULT_DENOMINATOR = 1_000_000;
    uint256 private constant EXPECTED_TOTAL_BOND = 500_000_000;
    uint64 private constant ORACLE_LIVENESS = 5 minutes;
    uint32 private constant AGGREGATOR_LIVENESS = 1 hours;
    bytes4 private constant UNAUTHORIZED_SELECTOR = bytes4(keccak256("Unauthorized()"));

    bytes32 private constant REQUEST_PRICE_EVENT =
        keccak256("RequestPrice(address,bytes32,uint256,bytes,address,uint256,uint256)");
    bytes32 private constant PROPOSE_PRICE_EVENT =
        keccak256("ProposePrice(address,address,bytes32,uint256,bytes,int256,uint256,address)");
    bytes32 private constant SETTLE_EVENT =
        keccak256("Settle(address,address,address,bytes32,uint256,bytes,int256,uint256)");
    bytes32 private constant REQUEST_REGISTERED_EVENT =
        keccak256("RequestRegistered(bytes32,address,bytes32,bytes,uint64,uint64)");
    bytes32 private constant REQUEST_INITIALIZED_EVENT =
        keccak256("RequestInitialized(bytes32,uint256,address,bytes32,bytes,address,uint256,uint256,uint64,uint256)");
    bytes32 private constant REQUEST_RESOLVED_EVENT = keccak256("RequestResolved(bytes32,uint256,int256)");
    bytes32 private constant REPORT_CALLBACK_SUCCEEDED_EVENT = keccak256("ReportCallbackSucceeded(bytes32,address)");
    bytes32 private constant OO_REPORTER_REQUEST_CREATED_EVENT = keccak256("OOReporterRequestCreated(bytes32,bytes32)");
    bytes32 private constant OO_REPORTER_RESULT_REPORTED_EVENT =
        keccak256("OOReporterResultReported(bytes32,int256,bytes32)");
    bytes32 private constant AGGREGATOR_REQUEST_INITIALIZED_EVENT =
        keccak256("RequestInitialized(bytes29,address,uint256,uint256,uint16,uint8,address,uint32,address)");
    bytes32 private constant AGGREGATOR_RESULT_REPORTED_EVENT =
        keccak256("ResultReported(bytes32,address,bytes32,uint256)");
    bytes32 private constant OUTCOME_PROPOSED_EVENT = keccak256("OutcomeProposed(bytes32,bytes32,uint256[])");
    bytes32 private constant AGGREGATOR_REQUEST_RESOLVED_EVENT = keccak256("RequestResolved(bytes32,bytes32,address)");

    EnvironmentManifest private manifest;
    bool private forkEnabled;

    function setUp() public {
        manifest = EnvironmentManifestLib.load(MANIFEST_PATH);
        string memory rpcUrl = vm.envOr(manifest.rpcEnvironmentVariable, string(""));
        if (bytes(rpcUrl).length == 0) return;

        _assertSnapshotHash(rpcUrl);
        vm.createSelectFork(rpcUrl, manifest.snapshotBlock);
        forkEnabled = true;
    }

    function test_happyPathRunsEntirelyInsideLocalFork() public {
        if (!_requireFork()) return;

        bytes32 requestId = _requestId();
        bytes memory requestRules = _requestRules();
        IPolymarketAggregator aggregator = IPolymarketAggregator(manifest.aggregator.proxy);
        IOOReporterModuleLike reporterModule = IOOReporterModuleLike(manifest.reporterModule.proxy);
        IPolymarketOOReporterLike reporter = IPolymarketOOReporterLike(manifest.reporter.proxy);
        IManagedOptimisticOracleLike managedOracle = IManagedOptimisticOracleLike(manifest.managedOracle.proxy);

        assertEq(requestId, EXPECTED_REQUEST_ID, "fixture ID scheme changed");
        assertEq(block.number, manifest.snapshotBlock);
        assertFalse(reporterModule.requestInitialized(bytes31(requestId)), "fixture already registered");
        (IPolymarketAggregator.ResolutionStatus initialStatus,,,) = aggregator.getRequestState(requestId);
        assertEq(uint8(initialStatus), uint8(IPolymarketAggregator.ResolutionStatus.None));
        assertEq(IBinaryModuleLike(manifest.binaryModule.proxy).getResult(bytes31(requestId)).length, 0);

        vm.recordLogs();

        vm.prank(manifest.roles.requiredAggregatorOperators[0]);
        aggregator.initializeRequest(_initParams(requestId, requestRules));

        IPolymarketOOReporterLike.RequestData memory reporterRequest = reporter.getRequest(requestId);
        assertTrue(reporterModule.requestInitialized(bytes31(requestId)));
        assertTrue(reporterRequest.registered);
        assertFalse(reporterRequest.initialized);
        assertEq(reporterRequest.requester, address(reporterModule));
        assertEq(reporterRequest.priceIdentifier, YES_OR_NO_QUERY);
        assertEq(reporterRequest.requestRules, requestRules);
        assertEq(reporterRequest.minimumLiveness, ORACLE_LIVENESS);
        assertEq(reporterRequest.maximumLiveness, 2 hours);
        assertTrue(aggregator.isReporterModule(bytes29(requestId), address(reporterModule)));
        assertTrue(aggregator.isDisputerModule(bytes29(requestId), manifest.roles.disputerAndArbitratorModule));
        (uint8 marketType, uint16 outcomeCount) = aggregator.getRequestShape(requestId);
        assertEq(marketType, uint8(IPolymarketAggregator.MarketType.BINARY));
        assertEq(outcomeCount, 1);

        vm.prank(manifest.roles.requiredOracleInitializersAndProposers[0]);
        reporter.initializeRequest(requestId, 0, 0, ORACLE_LIVENESS);

        reporterRequest = reporter.getRequest(requestId);
        assertTrue(reporterRequest.initialized);
        assertEq(reporterRequest.oracleInitializer, manifest.roles.requiredOracleInitializersAndProposers[0]);
        assertEq(reporterRequest.liveness, ORACLE_LIVENESS);

        IManagedOptimisticOracleLike.Request memory oracleRequest = managedOracle.getRequest(
            address(reporter), YES_OR_NO_QUERY, reporterRequest.requestTimestamp, requestRules
        );
        assertTrue(oracleRequest.requestSettings.eventBased);
        assertTrue(oracleRequest.requestSettings.callbackOnPriceSettled);
        assertEq(oracleRequest.requestSettings.customLiveness, ORACLE_LIVENESS);

        uint256 totalBond = oracleRequest.requestSettings.bond + oracleRequest.finalFee;
        assertEq(totalBond, EXPECTED_TOTAL_BOND);
        address proposer = manifest.roles.requiredOracleInitializersAndProposers[0];
        deal(address(oracleRequest.currency), proposer, totalBond, true);

        vm.startPrank(proposer);
        oracleRequest.currency.approve(address(managedOracle), totalBond);
        uint256 postedBond = managedOracle.proposePriceFor(
            proposer, address(reporter), YES_OR_NO_QUERY, reporterRequest.requestTimestamp, requestRules, YES_PRICE
        );
        vm.stopPrank();
        assertEq(postedBond, totalBond);

        oracleRequest = managedOracle.getRequest(
            address(reporter), YES_OR_NO_QUERY, reporterRequest.requestTimestamp, requestRules
        );
        assertEq(oracleRequest.proposer, proposer);
        assertEq(oracleRequest.proposedPrice, YES_PRICE);
        assertGt(oracleRequest.expirationTime, block.timestamp);
        uint256 proposalExpiration = oracleRequest.expirationTime;

        vm.warp(oracleRequest.expirationTime);
        vm.prank(manifest.roles.requiredManagedOracleResolvers[0]);
        uint256 payout =
            managedOracle.settle(address(reporter), YES_OR_NO_QUERY, reporterRequest.requestTimestamp, requestRules);
        assertEq(payout, totalBond);

        assertTrue(reporter.isRequestResolved(requestId));
        assertEq(reporter.getRequestResolution(requestId), YES_PRICE);

        uint256[] memory expectedProposal = new uint256[](1);
        expectedProposal[0] = RESULT_DENOMINATOR;
        bytes32 expectedProposalHash = keccak256(abi.encode(expectedProposal));

        (IPolymarketAggregator.ResolutionStatus proposedStatus, bytes32 proposedResultHash, uint256 disputeWindowEnd,) =
            aggregator.getRequestState(requestId);
        assertEq(uint8(proposedStatus), uint8(IPolymarketAggregator.ResolutionStatus.Active));
        assertEq(proposedResultHash, expectedProposalHash);
        assertGt(disputeWindowEnd, block.timestamp);

        vm.warp(disputeWindowEnd);
        reporterModule.finalize(requestId);

        (IPolymarketAggregator.ResolutionStatus finalStatus, bytes32 finalResultHash,,) =
            aggregator.getRequestState(requestId);
        assertEq(uint8(finalStatus), uint8(IPolymarketAggregator.ResolutionStatus.Resolved));
        assertEq(finalResultHash, expectedProposalHash);

        uint256[] memory binaryResult = IBinaryModuleLike(manifest.binaryModule.proxy).getResult(bytes31(requestId));
        assertEq(binaryResult.length, 2);
        assertEq(binaryResult[0], RESULT_DENOMINATOR);
        assertEq(binaryResult[1], 0);

        _assertLifecycleEvents(
            vm.getRecordedLogs(),
            requestId,
            requestRules,
            reporterRequest,
            oracleRequest.finalFee,
            proposalExpiration,
            totalBond,
            expectedProposal,
            expectedProposalHash
        );
    }

    function test_unauthorizedAccountCannotInitializeAggregatorRequest() public {
        if (!_requireFork()) return;

        vm.expectRevert(UNAUTHORIZED_SELECTOR);
        vm.prank(address(0xBEEF));
        IPolymarketAggregator(manifest.aggregator.proxy).initializeRequest(_initParams(_requestId(), _requestRules()));
    }

    function _initParams(bytes32 requestId, bytes memory requestRules)
        private
        view
        returns (IPolymarketAggregator.InitParams memory params)
    {
        IOOReporterModuleLike.RequestRegistration[] memory registrations =
            new IOOReporterModuleLike.RequestRegistration[](1);
        registrations[0] = IOOReporterModuleLike.RequestRegistration({
            requestId: requestId, requestRules: requestRules, minimumLiveness: ORACLE_LIVENESS, maximumLiveness: 2 hours
        });

        IPolymarketAggregator.ModuleConfig[] memory reporters = new IPolymarketAggregator.ModuleConfig[](1);
        reporters[0] = IPolymarketAggregator.ModuleConfig({
            module: manifest.reporterModule.proxy, initData: abi.encode(registrations)
        });

        IPolymarketAggregator.ModuleConfig[] memory disputers = new IPolymarketAggregator.ModuleConfig[](1);
        disputers[0] = IPolymarketAggregator.ModuleConfig({
            module: manifest.roles.disputerAndArbitratorModule, initData: bytes("")
        });

        params = IPolymarketAggregator.InitParams({
            eventId: bytes29(requestId),
            marketType: IPolymarketAggregator.MarketType.BINARY,
            targetContract: manifest.binaryModule.proxy,
            resultLength: 1,
            reporterModules: reporters,
            reporterThreshold: 1,
            disputerModules: disputers,
            disputerThreshold: 1,
            arbitratorModule: manifest.roles.disputerAndArbitratorModule,
            arbitratorInitData: bytes(""),
            livenessWindow: AGGREGATOR_LIVENESS,
            finalizer: manifest.reporterModule.proxy
        });
    }

    function _requestId() private pure returns (bytes32) {
        bytes32 baseHash = keccak256(abi.encode(uint256(1), bytes(FIXTURE_DOMAIN)));
        uint256 low128 = uint256(uint128(uint256(baseHash)));
        return bytes32((uint256(1) << 248) | (low128 << 120));
    }

    function _requestRules() private pure returns (bytes memory) {
        return bytes("FRO-111 deterministic local-fork lifecycle: resolve YES for the fixture scenario.");
    }

    function _requireFork() private returns (bool) {
        if (forkEnabled) return true;
        vm.skip(true, string.concat("set ", manifest.rpcEnvironmentVariable, " to run this local fork simulation"));
        return false;
    }

    function _assertLifecycleEvents(
        Vm.Log[] memory logs,
        bytes32 requestId,
        bytes memory requestRules,
        IPolymarketOOReporterLike.RequestData memory reporterRequest,
        uint256 finalFee,
        uint256 proposalExpiration,
        uint256 totalBond,
        uint256[] memory expectedProposal,
        bytes32 expectedProposalHash
    ) private view {
        _assertManagedOracleEvents(logs, requestRules, reporterRequest, finalFee, proposalExpiration, totalBond);
        _assertReporterEvents(logs, requestId, requestRules, reporterRequest);
        _assertPolymarketEvents(logs, requestId, expectedProposal, expectedProposalHash);
    }

    function _assertManagedOracleEvents(
        Vm.Log[] memory logs,
        bytes memory requestRules,
        IPolymarketOOReporterLike.RequestData memory reporterRequest,
        uint256 finalFee,
        uint256 proposalExpiration,
        uint256 totalBond
    ) private view {
        address proposer = manifest.roles.requiredOracleInitializersAndProposers[0];

        {
            Vm.Log memory requestPrice =
                _event(logs, manifest.managedOracle.proxy, REQUEST_PRICE_EVENT, bytes32(0), "Managed OO RequestPrice");
            assertEq(_topicAddress(requestPrice.topics[1]), manifest.reporter.proxy);
            (
                bytes32 identifier,
                uint256 timestamp,
                bytes memory ancillaryData,
                address currency,
                uint256 reward,
                uint256 emittedFinalFee
            ) = abi.decode(requestPrice.data, (bytes32, uint256, bytes, address, uint256, uint256));
            assertEq(identifier, YES_OR_NO_QUERY);
            assertEq(timestamp, reporterRequest.requestTimestamp);
            assertEq(ancillaryData, requestRules);
            assertEq(currency, manifest.rewardCurrency.contractAddress);
            assertEq(reward, reporterRequest.reward);
            assertEq(emittedFinalFee, finalFee);
        }

        {
            Vm.Log memory proposePrice =
                _event(logs, manifest.managedOracle.proxy, PROPOSE_PRICE_EVENT, bytes32(0), "Managed OO ProposePrice");
            assertEq(_topicAddress(proposePrice.topics[1]), manifest.reporter.proxy);
            assertEq(_topicAddress(proposePrice.topics[2]), proposer);
            (
                bytes32 identifier,
                uint256 timestamp,
                bytes memory ancillaryData,
                int256 proposedPrice,
                uint256 expirationTimestamp,
                address currency
            ) = abi.decode(proposePrice.data, (bytes32, uint256, bytes, int256, uint256, address));
            assertEq(identifier, YES_OR_NO_QUERY);
            assertEq(timestamp, reporterRequest.requestTimestamp);
            assertEq(ancillaryData, requestRules);
            assertEq(proposedPrice, YES_PRICE);
            assertEq(expirationTimestamp, proposalExpiration);
            assertEq(currency, manifest.rewardCurrency.contractAddress);
        }

        {
            Vm.Log memory settle =
                _event(logs, manifest.managedOracle.proxy, SETTLE_EVENT, bytes32(0), "Managed OO Settle");
            assertEq(_topicAddress(settle.topics[1]), manifest.reporter.proxy);
            assertEq(_topicAddress(settle.topics[2]), proposer);
            assertEq(_topicAddress(settle.topics[3]), address(0));
            (bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, int256 price, uint256 payout) =
                abi.decode(settle.data, (bytes32, uint256, bytes, int256, uint256));
            assertEq(identifier, YES_OR_NO_QUERY);
            assertEq(timestamp, reporterRequest.requestTimestamp);
            assertEq(ancillaryData, requestRules);
            assertEq(price, YES_PRICE);
            assertEq(payout, totalBond);
        }
    }

    function _assertReporterEvents(
        Vm.Log[] memory logs,
        bytes32 requestId,
        bytes memory requestRules,
        IPolymarketOOReporterLike.RequestData memory reporterRequest
    ) private view {
        {
            Vm.Log memory registered = _event(
                logs, manifest.reporter.proxy, REQUEST_REGISTERED_EVENT, requestId, "reporter RequestRegistered"
            );
            assertEq(_topicAddress(registered.topics[2]), manifest.reporterModule.proxy);
            assertEq(registered.topics[3], YES_OR_NO_QUERY);
            (bytes memory rules, uint64 minimumLiveness, uint64 maximumLiveness) =
                abi.decode(registered.data, (bytes, uint64, uint64));
            assertEq(rules, requestRules);
            assertEq(minimumLiveness, ORACLE_LIVENESS);
            assertEq(maximumLiveness, 2 hours);
        }

        {
            Vm.Log memory initialized = _event(
                logs, manifest.reporter.proxy, REQUEST_INITIALIZED_EVENT, requestId, "reporter RequestInitialized"
            );
            assertEq(uint256(initialized.topics[2]), reporterRequest.requestTimestamp);
            assertEq(_topicAddress(initialized.topics[3]), manifest.roles.requiredOracleInitializersAndProposers[0]);
            (
                bytes32 identifier,
                bytes memory rules,
                address currency,
                uint256 reward,
                uint256 proposalBond,
                uint64 liveness,
                uint256 manualRerequestsRemaining
            ) = abi.decode(initialized.data, (bytes32, bytes, address, uint256, uint256, uint64, uint256));
            assertEq(identifier, YES_OR_NO_QUERY);
            assertEq(rules, requestRules);
            assertEq(currency, manifest.rewardCurrency.contractAddress);
            assertEq(reward, reporterRequest.reward);
            assertEq(proposalBond, reporterRequest.proposalBond);
            assertEq(liveness, ORACLE_LIVENESS);
            assertEq(manualRerequestsRemaining, reporterRequest.manualRerequestsRemaining);
        }

        {
            Vm.Log memory resolved =
                _event(logs, manifest.reporter.proxy, REQUEST_RESOLVED_EVENT, requestId, "reporter RequestResolved");
            assertEq(uint256(resolved.topics[2]), reporterRequest.requestTimestamp);
            assertEq(abi.decode(resolved.data, (int256)), YES_PRICE);
        }

        Vm.Log memory callback = _event(
            logs,
            manifest.reporter.proxy,
            REPORT_CALLBACK_SUCCEEDED_EVENT,
            requestId,
            "reporter ReportCallbackSucceeded"
        );
        assertEq(_topicAddress(callback.topics[2]), manifest.reporterModule.proxy);
    }

    function _assertPolymarketEvents(
        Vm.Log[] memory logs,
        bytes32 requestId,
        uint256[] memory expectedProposal,
        bytes32 expectedProposalHash
    ) private view {
        {
            Vm.Log memory requestCreated = _event(
                logs,
                manifest.reporterModule.proxy,
                OO_REPORTER_REQUEST_CREATED_EVENT,
                requestId,
                "module OOReporterRequestCreated"
            );
            assertEq(abi.decode(requestCreated.data, (bytes32)), YES_OR_NO_QUERY);
        }

        {
            Vm.Log memory initialized = _event(
                logs,
                manifest.aggregator.proxy,
                AGGREGATOR_REQUEST_INITIALIZED_EVENT,
                bytes32(bytes29(requestId)),
                "aggregator RequestInitialized"
            );
            (
                address targetContract,
                uint256 reporterThreshold,
                uint256 disputerThreshold,
                uint16 resultLength,
                uint8 marketType,
                address arbitratorModule,
                uint32 livenessWindow,
                address finalizer
            ) = abi.decode(initialized.data, (address, uint256, uint256, uint16, uint8, address, uint32, address));
            assertEq(targetContract, manifest.binaryModule.proxy);
            assertEq(reporterThreshold, 1);
            assertEq(disputerThreshold, 1);
            assertEq(resultLength, 1);
            assertEq(marketType, uint8(IPolymarketAggregator.MarketType.BINARY));
            assertEq(arbitratorModule, manifest.roles.disputerAndArbitratorModule);
            assertEq(livenessWindow, AGGREGATOR_LIVENESS);
            assertEq(finalizer, manifest.reporterModule.proxy);
        }

        {
            Vm.Log memory reported = _event(
                logs,
                manifest.reporterModule.proxy,
                OO_REPORTER_RESULT_REPORTED_EVENT,
                requestId,
                "module OOReporterResultReported"
            );
            (int256 price, bytes32 resultHash) = abi.decode(reported.data, (int256, bytes32));
            assertEq(price, YES_PRICE);
            assertEq(resultHash, expectedProposalHash);
        }

        {
            Vm.Log memory resultReported = _event(
                logs,
                manifest.aggregator.proxy,
                AGGREGATOR_RESULT_REPORTED_EVENT,
                requestId,
                "aggregator ResultReported"
            );
            assertEq(_topicAddress(resultReported.topics[2]), manifest.reporterModule.proxy);
            (bytes32 resultHash, uint256 votes) = abi.decode(resultReported.data, (bytes32, uint256));
            assertEq(resultHash, expectedProposalHash);
            assertEq(votes, 1);
        }

        {
            Vm.Log memory proposed = _event(
                logs, manifest.aggregator.proxy, OUTCOME_PROPOSED_EVENT, requestId, "aggregator OutcomeProposed"
            );
            (bytes32 resultHash, uint256[] memory result) = abi.decode(proposed.data, (bytes32, uint256[]));
            assertEq(resultHash, expectedProposalHash);
            assertEq(result, expectedProposal);
        }

        {
            Vm.Log memory resolved = _event(
                logs,
                manifest.aggregator.proxy,
                AGGREGATOR_REQUEST_RESOLVED_EVENT,
                requestId,
                "aggregator RequestResolved"
            );
            assertEq(_topicAddress(resolved.topics[2]), manifest.aggregator.proxy);
            assertEq(abi.decode(resolved.data, (bytes32)), expectedProposalHash);
        }
    }

    function _assertSnapshotHash(string memory rpcUrl) private {
        vm.createSelectFork(rpcUrl, manifest.snapshotBlock + 1);
        assertEq(blockhash(manifest.snapshotBlock), manifest.snapshotBlockHash, "snapshot hash mismatch");
    }

    function _event(
        Vm.Log[] memory logs,
        address emitter,
        bytes32 signature,
        bytes32 indexedRequestId,
        string memory label
    ) private pure returns (Vm.Log memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics.length == 0 || logs[i].topics[0] != signature) continue;
            if (indexedRequestId != bytes32(0)) {
                if (logs[i].topics.length < 2 || logs[i].topics[1] != indexedRequestId) continue;
            }
            return logs[i];
        }
        revert(string.concat("missing event: ", label));
    }

    function _topicAddress(bytes32 topic) private pure returns (address) {
        return address(uint160(uint256(topic)));
    }
}
