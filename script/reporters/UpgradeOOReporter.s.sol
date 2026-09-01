// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {OOReporter} from "src/reporters/OOReporter.sol";
import {PolymarketOOReporter} from "src/reporters/integrations/PolymarketOOReporter.sol";
import {RequestData} from "src/reporters/interfaces/IOOReporter.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IAddressWhitelist {
    function isOnWhitelist(address account) external view returns (bool);
}

interface IManagedOptimisticOracleConfiguration {
    function requesterWhitelist() external view returns (address);
}

interface IOOReporterModuleConfiguration {
    function ooReporter() external view returns (address);
}

/// @title Guarded OOReporter implementation upgrade
/// @notice Installs PolymarketOOReporter on an existing proxy without changing its Managed OO or reporter state.
/// @dev The script discovers every registered request from on-chain events, validates live configuration and wiring,
///      optionally deploys or reuses the final implementation, and prints owner calldata. `EXECUTE_UPGRADE=true` is
///      available when the external deployment signer is also the proxy owner. `VERIFY_ONLY=true` reruns the guarded
///      post-upgrade checks. No private key or mnemonic is read by the script.
contract UpgradeOOReporter is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 internal constant REQUEST_REGISTERED_TOPIC =
        keccak256("RequestRegistered(bytes32,address,bytes32,bytes,uint64,uint64)");
    bytes32 internal constant REQUESTER_ENABLED_TOPIC = keccak256("RequesterEnabledSet(address,bool)");
    bytes32 internal constant ORACLE_INITIALIZER_ENABLED_TOPIC = keccak256("OracleInitializerEnabledSet(address,bool)");
    bytes32 internal constant INITIALIZED_TOPIC = keccak256("Initialized(uint64)");

    error AddressHasNoCode(address target);
    error AddressMismatch(string field, address expected, address actual);
    error Bytes32Mismatch(string field, bytes32 expected, bytes32 actual);
    error ChainIdMismatch(uint256 expected, uint256 actual);
    error DuplicateRegisteredRequest(bytes32 requestId);
    error DeployerRequired();
    error ExpectedAddressNotEnabled(bytes32 eventTopic, address account);
    error InvalidDeploymentBlock(uint256 deploymentBlock, uint256 currentBlock);
    error InvalidEnabledAddressLog(bytes32 eventTopic, uint256 logIndex);
    error InvalidProxiableUUID(address implementation, bytes32 actual);
    error InvalidRegisteredRequestLog(uint256 logIndex);
    error InvalidLogBlockRange();
    error OwnerMismatch(address expected, address actual);
    error PostUpgradeStateMismatch();
    error RegisteredRequestStateMismatch(bytes32 requestId);
    error ReporterInitializationNotFound(uint256 deploymentBlock);
    error ReporterNotWhitelisted(address whitelist, address reporter);
    error RequestStateChanged(bytes32 requestId);
    error StateFingerprintMismatch(bytes32 expected, bytes32 actual);
    error StateFingerprintRequired();
    error TargetImplementationRequired();
    error TargetImplementationCodehashRequired();
    error DirectExecutionOwnerMismatch(address owner, address deployer);
    error UnexpectedEnabledAddress(bytes32 eventTopic, address account);

    struct Config {
        uint256 expectedChainId;
        uint256 reporterDeploymentBlock;
        uint256 maxLogBlockRange;
        address deployer;
        address expectedOwner;
        address proxy;
        bytes32 expectedProxyCodehash;
        address expectedCurrentImplementation;
        bytes32 expectedCurrentImplementationCodehash;
        bytes32 expectedFinalImplementationCreationCodehash;
        address finalImplementation;
        bytes32 expectedFinalImplementationCodehash;
        address expectedCurrentOptimisticOracle;
        bytes32 expectedCurrentOptimisticOracleCodehash;
        address expectedCurrentMooImplementation;
        bytes32 expectedCurrentMooImplementationCodehash;
        address expectedMooRequesterWhitelist;
        bytes32 expectedMooRequesterWhitelistCodehash;
        address expectedRewardCurrency;
        address expectedRequester;
        bytes32 expectedRequesterCodehash;
        address expectedRequesterImplementation;
        bytes32 expectedRequesterImplementationCodehash;
        address expectedOracleInitializer;
        bool executeUpgrade;
        bool verifyOnly;
        bytes32 expectedStateFingerprint;
    }

    struct ReporterState {
        address owner;
        address optimisticOracle;
        address rewardCurrency;
        uint256 defaultRerequestBudget;
        bool automaticRerequestsEnabled;
        bool requesterEnabled;
        bool oracleInitializerEnabled;
        bytes32 initializableStorage;
        bytes32[] requestHashes;
    }

    function run() external returns (address finalImplementation) {
        Config memory config = _loadConfig();
        if (block.chainid != config.expectedChainId) {
            revert ChainIdMismatch(config.expectedChainId, block.chainid);
        }
        if (config.maxLogBlockRange == 0) revert InvalidLogBlockRange();

        if (config.verifyOnly) return _verifyCompletedUpgrade(config);

        _validateDependencies(config);
        _validateCurrentImplementation(config);

        OOReporter reporter = OOReporter(config.proxy);
        _validateCurrentReporter(reporter, config);
        _validateReporterDeploymentBlock(config.proxy, config.reporterDeploymentBlock);

        bytes32[] memory registeredRequestIds = _loadAndValidateRegisteredRequests(
            reporter, config.proxy, config.reporterDeploymentBlock, config.expectedRequester, config.maxLogBlockRange
        );
        _validateExclusiveEnabledAddress(
            config.proxy,
            config.reporterDeploymentBlock,
            REQUESTER_ENABLED_TOPIC,
            config.expectedRequester,
            config.maxLogBlockRange
        );
        _validateExclusiveEnabledAddress(
            config.proxy,
            config.reporterDeploymentBlock,
            ORACLE_INITIALIZER_ENABLED_TOPIC,
            config.expectedOracleInitializer,
            config.maxLogBlockRange
        );
        ReporterState memory stateBefore = _snapshotReporterState(reporter, config, registeredRequestIds);
        bytes32 stateFingerprint = _stateFingerprint(stateBefore);

        _expectCodehash(
            "final reporter implementation creation code",
            config.expectedFinalImplementationCreationCodehash,
            keccak256(type(PolymarketOOReporter).creationCode)
        );

        console.log("Implementation deployer:", config.deployer);
        console.log("Reporter owner:", config.expectedOwner);
        console.log("Reporter proxy:", config.proxy);
        console.log("Current reporter implementation:", config.expectedCurrentImplementation);
        console.log("Preserved Managed OO:", config.expectedCurrentOptimisticOracle);
        console.log("Requester module:", config.expectedRequester);
        console.log("Registered requests discovered:", registeredRequestIds.length);

        finalImplementation = config.finalImplementation;
        if (finalImplementation == address(0)) {
            if (config.deployer == address(0)) revert DeployerRequired();
            vm.startBroadcast(config.deployer);
            finalImplementation = address(new PolymarketOOReporter());
            vm.stopBroadcast();
            _requireUUPSImplementation(finalImplementation);
            console.log("Deployed final implementation:", finalImplementation);
            console.logBytes32(finalImplementation.codehash);
        } else {
            _validateFinalImplementation(config, finalImplementation);
            console.log("Reusing final implementation:", finalImplementation);
        }

        bytes memory upgradeCall = abi.encodeCall(IUUPSUpgradeable.upgradeToAndCall, (finalImplementation, bytes("")));
        console.log("Upgrade target:", config.proxy);
        console.log("Upgrade value: 0");
        console.log("Upgrade calldata:");
        console.logBytes(upgradeCall);
        console.log("Pre-upgrade state fingerprint:");
        console.logBytes32(stateFingerprint);

        if (!config.executeUpgrade) {
            console.log("Upgrade not executed. Submit the calldata through the configured reporter owner.");
            return finalImplementation;
        }

        if (config.expectedOwner != config.deployer) {
            revert DirectExecutionOwnerMismatch(config.expectedOwner, config.deployer);
        }

        vm.startBroadcast(config.deployer);
        _callUpgrade(config.proxy, upgradeCall);
        vm.stopBroadcast();

        _validatePostUpgrade(reporter, config, stateBefore, registeredRequestIds, finalImplementation);

        console.log("\n=== Reporter implementation upgrade complete ===");
        console.log("Reporter proxy:", config.proxy);
        console.log("Final Polymarket implementation:", finalImplementation);
        console.log("Managed OO (unchanged):", address(reporter.optimisticOracle()));
        console.log("Owner:", reporter.owner());
    }

    function _verifyCompletedUpgrade(Config memory config) private returns (address finalImplementation) {
        finalImplementation = config.finalImplementation;
        if (finalImplementation == address(0)) revert TargetImplementationRequired();
        if (config.expectedStateFingerprint == bytes32(0)) revert StateFingerprintRequired();

        _validateDependencies(config);
        _validateFinalImplementation(config, finalImplementation);
        _expectAddress("final reporter implementation", finalImplementation, _getImplementation(config.proxy));

        OOReporter reporter = OOReporter(config.proxy);
        _validateCurrentReporter(reporter, config);
        _validateReporterDeploymentBlock(config.proxy, config.reporterDeploymentBlock);

        bytes32[] memory registeredRequestIds = _loadAndValidateRegisteredRequests(
            reporter, config.proxy, config.reporterDeploymentBlock, config.expectedRequester, config.maxLogBlockRange
        );
        _validateExclusiveEnabledAddress(
            config.proxy,
            config.reporterDeploymentBlock,
            REQUESTER_ENABLED_TOPIC,
            config.expectedRequester,
            config.maxLogBlockRange
        );
        _validateExclusiveEnabledAddress(
            config.proxy,
            config.reporterDeploymentBlock,
            ORACLE_INITIALIZER_ENABLED_TOPIC,
            config.expectedOracleInitializer,
            config.maxLogBlockRange
        );

        ReporterState memory state = _snapshotReporterState(reporter, config, registeredRequestIds);
        bytes32 actualStateFingerprint = _stateFingerprint(state);
        if (actualStateFingerprint != config.expectedStateFingerprint) {
            revert StateFingerprintMismatch(config.expectedStateFingerprint, actualStateFingerprint);
        }
        if (PolymarketOOReporter(address(reporter)).pendingOwner() != address(0)) {
            revert PostUpgradeStateMismatch();
        }
        _validateExternalWiring(config);

        console.log("Reporter upgrade verified:", config.proxy);
        console.log("Final implementation:", finalImplementation);
        console.log("State fingerprint:");
        console.logBytes32(actualStateFingerprint);
    }

    function _loadConfig() private view returns (Config memory config) {
        config.expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        config.reporterDeploymentBlock = vm.envUint("REPORTER_DEPLOYMENT_BLOCK");
        config.maxLogBlockRange = vm.envOr("MAX_LOG_BLOCK_RANGE", uint256(50_000));
        config.deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        config.expectedOwner = vm.envAddress("EXPECTED_OWNER");
        config.proxy = vm.envAddress("PROXY_ADDRESS");
        config.expectedProxyCodehash = vm.envBytes32("EXPECTED_PROXY_CODEHASH");
        config.expectedCurrentImplementation = vm.envOr("EXPECTED_CURRENT_IMPLEMENTATION", address(0));
        config.expectedCurrentImplementationCodehash = vm.envOr("EXPECTED_CURRENT_IMPLEMENTATION_CODEHASH", bytes32(0));
        config.expectedFinalImplementationCreationCodehash =
            vm.envBytes32("EXPECTED_FINAL_IMPLEMENTATION_CREATION_CODEHASH");
        config.finalImplementation = vm.envOr("FINAL_IMPLEMENTATION", address(0));
        config.expectedFinalImplementationCodehash = vm.envOr("EXPECTED_FINAL_IMPLEMENTATION_CODEHASH", bytes32(0));
        config.expectedCurrentOptimisticOracle = vm.envAddress("EXPECTED_CURRENT_OPTIMISTIC_ORACLE");
        config.expectedCurrentOptimisticOracleCodehash = vm.envBytes32("EXPECTED_CURRENT_OPTIMISTIC_ORACLE_CODEHASH");
        config.expectedCurrentMooImplementation = vm.envAddress("EXPECTED_CURRENT_MOO_IMPLEMENTATION");
        config.expectedCurrentMooImplementationCodehash = vm.envBytes32("EXPECTED_CURRENT_MOO_IMPLEMENTATION_CODEHASH");
        config.expectedMooRequesterWhitelist = vm.envAddress("EXPECTED_MOO_REQUESTER_WHITELIST");
        config.expectedMooRequesterWhitelistCodehash = vm.envBytes32("EXPECTED_MOO_REQUESTER_WHITELIST_CODEHASH");
        config.expectedRewardCurrency = vm.envAddress("EXPECTED_REWARD_CURRENCY");
        config.expectedRequester = vm.envAddress("EXPECTED_REQUESTER");
        config.expectedRequesterCodehash = vm.envBytes32("EXPECTED_REQUESTER_CODEHASH");
        config.expectedRequesterImplementation = vm.envAddress("EXPECTED_REQUESTER_IMPLEMENTATION");
        config.expectedRequesterImplementationCodehash = vm.envBytes32("EXPECTED_REQUESTER_IMPLEMENTATION_CODEHASH");
        config.expectedOracleInitializer = vm.envAddress("EXPECTED_ORACLE_INITIALIZER");
        config.executeUpgrade = vm.envOr("EXECUTE_UPGRADE", false);
        config.verifyOnly = vm.envOr("VERIFY_ONLY", false);
        config.expectedStateFingerprint = vm.envOr("EXPECTED_STATE_FINGERPRINT", bytes32(0));
    }

    function _validateDependencies(Config memory config) private view {
        _requireCode(config.proxy);
        _requireCode(config.expectedCurrentOptimisticOracle);
        _requireCode(config.expectedCurrentMooImplementation);
        _requireCode(config.expectedMooRequesterWhitelist);
        _requireCode(config.expectedRewardCurrency);
        _requireCode(config.expectedRequester);
        _requireCode(config.expectedRequesterImplementation);

        _expectCodehash("reporter proxy", config.expectedProxyCodehash, config.proxy.codehash);
        _expectCodehash(
            "current Managed OO proxy",
            config.expectedCurrentOptimisticOracleCodehash,
            config.expectedCurrentOptimisticOracle.codehash
        );
        _expectCodehash(
            "current Managed OO implementation",
            config.expectedCurrentMooImplementationCodehash,
            config.expectedCurrentMooImplementation.codehash
        );
        _expectCodehash(
            "Managed OO requester whitelist",
            config.expectedMooRequesterWhitelistCodehash,
            config.expectedMooRequesterWhitelist.codehash
        );
        _expectCodehash("requester module", config.expectedRequesterCodehash, config.expectedRequester.codehash);
        _expectCodehash(
            "requester module implementation",
            config.expectedRequesterImplementationCodehash,
            config.expectedRequesterImplementation.codehash
        );

        _expectAddress(
            "current Managed OO implementation",
            config.expectedCurrentMooImplementation,
            _getImplementation(config.expectedCurrentOptimisticOracle)
        );
        _expectAddress(
            "requester module implementation",
            config.expectedRequesterImplementation,
            _getImplementation(config.expectedRequester)
        );
    }

    function _validateCurrentImplementation(Config memory config) private view {
        _requireCode(config.expectedCurrentImplementation);
        _expectCodehash(
            "current reporter implementation",
            config.expectedCurrentImplementationCodehash,
            config.expectedCurrentImplementation.codehash
        );
        _expectAddress("current implementation", config.expectedCurrentImplementation, _getImplementation(config.proxy));
    }

    function _validateFinalImplementation(Config memory config, address finalImplementation) private view {
        if (config.expectedFinalImplementationCodehash == bytes32(0)) {
            revert TargetImplementationCodehashRequired();
        }
        _expectCodehash(
            "final reporter implementation creation code",
            config.expectedFinalImplementationCreationCodehash,
            keccak256(type(PolymarketOOReporter).creationCode)
        );
        _requireUUPSImplementation(finalImplementation);
        _expectCodehash(
            "final reporter implementation", config.expectedFinalImplementationCodehash, finalImplementation.codehash
        );
    }

    function _validateCurrentReporter(OOReporter reporter, Config memory config) private view {
        address actualOwner = reporter.owner();
        if (actualOwner != config.expectedOwner) revert OwnerMismatch(config.expectedOwner, actualOwner);

        _expectAddress(
            "current optimistic oracle", config.expectedCurrentOptimisticOracle, address(reporter.optimisticOracle())
        );
        _expectAddress("reward currency", config.expectedRewardCurrency, address(reporter.rewardCurrency()));
        if (!reporter.isRequester(config.expectedRequester)) revert PostUpgradeStateMismatch();
        if (!reporter.isOracleInitializer(config.expectedOracleInitializer)) revert PostUpgradeStateMismatch();

        _validateExternalWiring(config);
    }

    function _validateExternalWiring(Config memory config) private view {
        _expectAddress(
            "requester module reporter",
            config.proxy,
            IOOReporterModuleConfiguration(config.expectedRequester).ooReporter()
        );

        address requesterWhitelist =
            IManagedOptimisticOracleConfiguration(config.expectedCurrentOptimisticOracle).requesterWhitelist();
        _expectAddress("Managed OO requester whitelist", config.expectedMooRequesterWhitelist, requesterWhitelist);

        IAddressWhitelist whitelist = IAddressWhitelist(requesterWhitelist);
        if (!whitelist.isOnWhitelist(config.proxy)) revert ReporterNotWhitelisted(requesterWhitelist, config.proxy);
    }

    function _loadAndValidateRegisteredRequests(
        OOReporter reporter,
        address proxy,
        uint256 deploymentBlock,
        address expectedRequester,
        uint256 maxLogBlockRange
    ) private returns (bytes32[] memory requestIds) {
        if (deploymentBlock > block.number) {
            revert InvalidDeploymentBlock(deploymentBlock, block.number);
        }

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = REQUEST_REGISTERED_TOPIC;
        Vm.EthGetLogs[] memory logs = _loadLogs(deploymentBlock, block.number, proxy, topics, maxLogBlockRange);
        requestIds = new bytes32[](logs.length);

        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 requestId = _validateRegisteredRequest(reporter, logs[i], expectedRequester, i);
            for (uint256 j = 0; j < i; j++) {
                if (requestIds[j] == requestId) revert DuplicateRegisteredRequest(requestId);
            }
            requestIds[i] = requestId;
        }
    }

    function _validateRegisteredRequest(
        OOReporter reporter,
        Vm.EthGetLogs memory requestLog,
        address expectedRequester,
        uint256 logIndex
    ) private view returns (bytes32 requestId) {
        if (requestLog.removed || requestLog.topics.length != 4 || requestLog.topics[0] != REQUEST_REGISTERED_TOPIC) {
            revert InvalidRegisteredRequestLog(logIndex);
        }

        requestId = requestLog.topics[1];
        address requester = address(uint160(uint256(requestLog.topics[2])));
        bytes32 priceIdentifier = requestLog.topics[3];
        (bytes memory requestRules, uint64 minimumLiveness, uint64 maximumLiveness) =
            abi.decode(requestLog.data, (bytes, uint64, uint64));
        RequestData memory request = reporter.getRequest(requestId);

        if (
            !request.registered || requester != expectedRequester || request.requester != requester
                || request.priceIdentifier != priceIdentifier || keccak256(request.requestRules) != keccak256(requestRules)
                || request.minimumLiveness != minimumLiveness || request.maximumLiveness != maximumLiveness
                || reporter.getRequestId(priceIdentifier, requestRules) != requestId
        ) revert RegisteredRequestStateMismatch(requestId);
    }

    function _validateReporterDeploymentBlock(address proxy, uint256 deploymentBlock) private {
        if (deploymentBlock > block.number) revert InvalidDeploymentBlock(deploymentBlock, block.number);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = INITIALIZED_TOPIC;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(deploymentBlock, deploymentBlock, proxy, topics);
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                !logs[i].removed && logs[i].topics.length == 1 && logs[i].topics[0] == INITIALIZED_TOPIC
                    && abi.decode(logs[i].data, (uint64)) == 1
            ) return;
        }
        revert ReporterInitializationNotFound(deploymentBlock);
    }

    function _validateExclusiveEnabledAddress(
        address proxy,
        uint256 deploymentBlock,
        bytes32 eventTopic,
        address expectedAccount,
        uint256 maxLogBlockRange
    ) private {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = eventTopic;
        Vm.EthGetLogs[] memory logs = _loadLogs(deploymentBlock, block.number, proxy, topics, maxLogBlockRange);
        address[] memory accounts = new address[](logs.length);
        bool[] memory enabled = new bool[](logs.length);
        uint256 accountCount;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].removed || logs[i].topics.length != 2 || logs[i].topics[0] != eventTopic) {
                revert InvalidEnabledAddressLog(eventTopic, i);
            }

            address account = address(uint160(uint256(logs[i].topics[1])));
            uint256 index;
            while (index < accountCount && accounts[index] != account) {
                index++;
            }
            if (index == accountCount) {
                accounts[index] = account;
                accountCount++;
            }
            enabled[index] = abi.decode(logs[i].data, (bool));
        }

        bool expectedAccountEnabled;
        for (uint256 i = 0; i < accountCount; i++) {
            if (!enabled[i]) continue;
            if (accounts[i] != expectedAccount) revert UnexpectedEnabledAddress(eventTopic, accounts[i]);
            expectedAccountEnabled = true;
        }
        if (!expectedAccountEnabled) revert ExpectedAddressNotEnabled(eventTopic, expectedAccount);
    }

    function _loadLogs(
        uint256 fromBlock,
        uint256 toBlock,
        address emitter,
        bytes32[] memory topics,
        uint256 maxBlockRange
    ) private returns (Vm.EthGetLogs[] memory logs) {
        logs = new Vm.EthGetLogs[](0);
        while (fromBlock <= toBlock) {
            uint256 remainingBlocks = toBlock - fromBlock + 1;
            uint256 batchSize = remainingBlocks < maxBlockRange ? remainingBlocks : maxBlockRange;
            uint256 batchEnd = fromBlock + batchSize - 1;
            Vm.EthGetLogs[] memory batch = vm.eth_getLogs(fromBlock, batchEnd, emitter, topics);
            Vm.EthGetLogs[] memory combined = new Vm.EthGetLogs[](logs.length + batch.length);
            for (uint256 i = 0; i < logs.length; i++) {
                combined[i] = logs[i];
            }
            for (uint256 i = 0; i < batch.length; i++) {
                combined[logs.length + i] = batch[i];
            }
            logs = combined;
            fromBlock = batchEnd + 1;
        }
    }

    function _snapshotReporterState(OOReporter reporter, Config memory config, bytes32[] memory requestIds)
        private
        view
        returns (ReporterState memory state)
    {
        state.owner = reporter.owner();
        state.optimisticOracle = address(reporter.optimisticOracle());
        state.rewardCurrency = address(reporter.rewardCurrency());
        state.defaultRerequestBudget = reporter.defaultRerequestBudget();
        state.automaticRerequestsEnabled = reporter.automaticRerequestsEnabled();
        state.requesterEnabled = reporter.isRequester(config.expectedRequester);
        state.oracleInitializerEnabled = reporter.isOracleInitializer(config.expectedOracleInitializer);
        state.initializableStorage = vm.load(address(reporter), INITIALIZABLE_STORAGE_SLOT);
        state.requestHashes = new bytes32[](requestIds.length);
        for (uint256 i = 0; i < requestIds.length; i++) {
            state.requestHashes[i] = keccak256(abi.encode(reporter.getRequest(requestIds[i])));
        }
    }

    function _stateFingerprint(ReporterState memory state) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                state.owner,
                state.optimisticOracle,
                state.rewardCurrency,
                state.defaultRerequestBudget,
                state.automaticRerequestsEnabled,
                state.requesterEnabled,
                state.oracleInitializerEnabled,
                state.initializableStorage,
                state.requestHashes
            )
        );
    }

    function _validatePostUpgrade(
        OOReporter reporter,
        Config memory config,
        ReporterState memory expectedState,
        bytes32[] memory requestIds,
        address finalImplementation
    ) private view {
        _expectAddress("final reporter implementation", finalImplementation, _getImplementation(address(reporter)));
        _expectAddress(
            "current Managed OO implementation",
            config.expectedCurrentMooImplementation,
            _getImplementation(config.expectedCurrentOptimisticOracle)
        );

        if (
            reporter.owner() != expectedState.owner
                || address(reporter.optimisticOracle()) != expectedState.optimisticOracle
                || address(reporter.rewardCurrency()) != expectedState.rewardCurrency
                || reporter.defaultRerequestBudget() != expectedState.defaultRerequestBudget
                || reporter.automaticRerequestsEnabled() != expectedState.automaticRerequestsEnabled
                || reporter.isRequester(config.expectedRequester) != expectedState.requesterEnabled
                || reporter.isOracleInitializer(config.expectedOracleInitializer) != expectedState.oracleInitializerEnabled
                || vm.load(address(reporter), INITIALIZABLE_STORAGE_SLOT) != expectedState.initializableStorage
                || PolymarketOOReporter(address(reporter)).pendingOwner() != address(0)
        ) revert PostUpgradeStateMismatch();

        for (uint256 i = 0; i < requestIds.length; i++) {
            RequestData memory request = reporter.getRequest(requestIds[i]);
            if (
                keccak256(abi.encode(request)) != expectedState.requestHashes[i]
                    || reporter.getRequestId(request.priceIdentifier, request.requestRules) != requestIds[i]
            ) revert RequestStateChanged(requestIds[i]);
        }

        _validateExternalWiring(config);
    }

    function _requireUUPSImplementation(address implementation) private view {
        _requireCode(implementation);
        bytes32 actual = PolymarketOOReporter(implementation).proxiableUUID();
        if (actual != IMPLEMENTATION_SLOT) revert InvalidProxiableUUID(implementation, actual);
    }

    function _getImplementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert AddressHasNoCode(target);
    }

    function _expectAddress(string memory field, address expected, address actual) private pure {
        if (actual != expected) revert AddressMismatch(field, expected, actual);
    }

    function _expectCodehash(string memory field, bytes32 expected, bytes32 actual) private pure {
        if (actual != expected) revert Bytes32Mismatch(field, expected, actual);
    }

    function _callUpgrade(address proxy, bytes memory upgradeCall) private {
        (bool success, bytes memory returnData) = proxy.call(upgradeCall);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
