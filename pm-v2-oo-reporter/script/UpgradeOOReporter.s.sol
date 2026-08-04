// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {OOReporter} from "../src/OOReporter.sol";
import {PolymarketOOReporter} from "../src/PolymarketOOReporter.sol";
import {RequestData} from "../src/interfaces/IOOReporter.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IAddressWhitelist {
    function isOnWhitelist(address account) external view returns (bool);

    function isWhitelistEnabled() external view returns (bool);
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
///      deploys the final implementation, and invokes `upgradeToAndCall` with empty calldata. Use an external signer
///      with `--sender <DEPLOYER_ADDRESS> --interactive`; no private key or mnemonic is read here.
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
    error ExpectedAddressNotEnabled(bytes32 eventTopic, address account);
    error InvalidDeploymentBlock(uint256 deploymentBlock, uint256 currentBlock);
    error InvalidEnabledAddressLog(bytes32 eventTopic, uint256 logIndex);
    error InvalidProxiableUUID(address implementation, bytes32 actual);
    error InvalidRegisteredRequestLog(uint256 logIndex);
    error OwnerMismatch(address expected, address actual);
    error PostUpgradeStateMismatch();
    error RegisteredRequestStateMismatch(bytes32 requestId);
    error ReporterInitializationNotFound(uint256 deploymentBlock);
    error ReporterNotWhitelisted(address whitelist, address reporter);
    error RequestStateChanged(bytes32 requestId);
    error UnexpectedEnabledAddress(bytes32 eventTopic, address account);
    error WhitelistDisabled(address whitelist);

    struct Config {
        uint256 expectedChainId;
        uint256 reporterDeploymentBlock;
        address deployer;
        address proxy;
        bytes32 expectedProxyCodehash;
        address expectedCurrentImplementation;
        bytes32 expectedCurrentImplementationCodehash;
        bytes32 expectedFinalImplementationCreationCodehash;
        address expectedCurrentOptimisticOracle;
        bytes32 expectedCurrentOptimisticOracleCodehash;
        address expectedCurrentMooImplementation;
        bytes32 expectedCurrentMooImplementationCodehash;
        address expectedMooRequesterWhitelist;
        bytes32 expectedMooRequesterWhitelistCodehash;
        address expectedRewardCurrency;
        address expectedRequester;
        bytes32 expectedRequesterCodehash;
        address expectedOracleInitializer;
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

        _validateCodeAndImplementations(config);

        OOReporter reporter = OOReporter(config.proxy);
        _validateCurrentReporter(reporter, config);
        _validateReporterDeploymentBlock(config.proxy, config.reporterDeploymentBlock);

        bytes32[] memory registeredRequestIds = _loadAndValidateRegisteredRequests(
            reporter, config.proxy, config.reporterDeploymentBlock, config.expectedRequester
        );
        _validateExclusiveEnabledAddress(
            config.proxy, config.reporterDeploymentBlock, REQUESTER_ENABLED_TOPIC, config.expectedRequester
        );
        _validateExclusiveEnabledAddress(
            config.proxy,
            config.reporterDeploymentBlock,
            ORACLE_INITIALIZER_ENABLED_TOPIC,
            config.expectedOracleInitializer
        );
        ReporterState memory stateBefore = _snapshotReporterState(reporter, config, registeredRequestIds);

        _expectCodehash(
            "final reporter implementation creation code",
            config.expectedFinalImplementationCreationCodehash,
            keccak256(type(PolymarketOOReporter).creationCode)
        );

        console.log("Deployer and owner:", config.deployer);
        console.log("Reporter proxy:", config.proxy);
        console.log("Current reporter implementation:", config.expectedCurrentImplementation);
        console.log("Preserved Managed OO:", config.expectedCurrentOptimisticOracle);
        console.log("Requester module:", config.expectedRequester);
        console.log("Registered requests discovered:", registeredRequestIds.length);

        vm.startBroadcast(config.deployer);
        PolymarketOOReporter finalReporterImplementation = new PolymarketOOReporter();
        vm.stopBroadcast();

        finalImplementation = address(finalReporterImplementation);
        _requireUUPSImplementation(finalImplementation);

        bytes memory upgradeCall = abi.encodeCall(IUUPSUpgradeable.upgradeToAndCall, (finalImplementation, bytes("")));

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

    function _loadConfig() private view returns (Config memory config) {
        config.expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        config.reporterDeploymentBlock = vm.envUint("REPORTER_DEPLOYMENT_BLOCK");
        config.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        config.proxy = vm.envAddress("PROXY_ADDRESS");
        config.expectedProxyCodehash = vm.envBytes32("EXPECTED_PROXY_CODEHASH");
        config.expectedCurrentImplementation = vm.envAddress("EXPECTED_CURRENT_IMPLEMENTATION");
        config.expectedCurrentImplementationCodehash = vm.envBytes32("EXPECTED_CURRENT_IMPLEMENTATION_CODEHASH");
        config.expectedFinalImplementationCreationCodehash =
            vm.envBytes32("EXPECTED_FINAL_IMPLEMENTATION_CREATION_CODEHASH");
        config.expectedCurrentOptimisticOracle = vm.envAddress("EXPECTED_CURRENT_OPTIMISTIC_ORACLE");
        config.expectedCurrentOptimisticOracleCodehash = vm.envBytes32("EXPECTED_CURRENT_OPTIMISTIC_ORACLE_CODEHASH");
        config.expectedCurrentMooImplementation = vm.envAddress("EXPECTED_CURRENT_MOO_IMPLEMENTATION");
        config.expectedCurrentMooImplementationCodehash = vm.envBytes32("EXPECTED_CURRENT_MOO_IMPLEMENTATION_CODEHASH");
        config.expectedMooRequesterWhitelist = vm.envAddress("EXPECTED_MOO_REQUESTER_WHITELIST");
        config.expectedMooRequesterWhitelistCodehash = vm.envBytes32("EXPECTED_MOO_REQUESTER_WHITELIST_CODEHASH");
        config.expectedRewardCurrency = vm.envAddress("EXPECTED_REWARD_CURRENCY");
        config.expectedRequester = vm.envAddress("EXPECTED_REQUESTER");
        config.expectedRequesterCodehash = vm.envBytes32("EXPECTED_REQUESTER_CODEHASH");
        config.expectedOracleInitializer = vm.envAddress("EXPECTED_ORACLE_INITIALIZER");
    }

    function _validateCodeAndImplementations(Config memory config) private view {
        _requireCode(config.proxy);
        _requireCode(config.expectedCurrentImplementation);
        _requireCode(config.expectedCurrentOptimisticOracle);
        _requireCode(config.expectedCurrentMooImplementation);
        _requireCode(config.expectedMooRequesterWhitelist);
        _requireCode(config.expectedRewardCurrency);
        _requireCode(config.expectedRequester);

        _expectCodehash("reporter proxy", config.expectedProxyCodehash, config.proxy.codehash);
        _expectCodehash(
            "current reporter implementation",
            config.expectedCurrentImplementationCodehash,
            config.expectedCurrentImplementation.codehash
        );
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

        _expectAddress("current implementation", config.expectedCurrentImplementation, _getImplementation(config.proxy));
        _expectAddress(
            "current Managed OO implementation",
            config.expectedCurrentMooImplementation,
            _getImplementation(config.expectedCurrentOptimisticOracle)
        );
    }

    function _validateCurrentReporter(OOReporter reporter, Config memory config) private view {
        address actualOwner = reporter.owner();
        if (actualOwner != config.deployer) revert OwnerMismatch(config.deployer, actualOwner);

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
        if (!whitelist.isWhitelistEnabled()) revert WhitelistDisabled(requesterWhitelist);
        if (!whitelist.isOnWhitelist(config.proxy)) revert ReporterNotWhitelisted(requesterWhitelist, config.proxy);
    }

    function _loadAndValidateRegisteredRequests(
        OOReporter reporter,
        address proxy,
        uint256 deploymentBlock,
        address expectedRequester
    ) private returns (bytes32[] memory requestIds) {
        if (deploymentBlock > block.number) {
            revert InvalidDeploymentBlock(deploymentBlock, block.number);
        }

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = REQUEST_REGISTERED_TOPIC;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(deploymentBlock, block.number, proxy, topics);
        requestIds = new bytes32[](logs.length);

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].removed || logs[i].topics.length != 4 || logs[i].topics[0] != REQUEST_REGISTERED_TOPIC) {
                revert InvalidRegisteredRequestLog(i);
            }

            bytes32 requestId = logs[i].topics[1];
            for (uint256 j = 0; j < i; j++) {
                if (requestIds[j] == requestId) revert DuplicateRegisteredRequest(requestId);
            }
            requestIds[i] = requestId;

            address requester = address(uint160(uint256(logs[i].topics[2])));
            bytes32 priceIdentifier = logs[i].topics[3];
            (bytes memory requestRules, uint64 minimumLiveness, uint64 maximumLiveness) =
                abi.decode(logs[i].data, (bytes, uint64, uint64));
            RequestData memory request = reporter.getRequest(requestId);

            if (
                !request.registered || requester != expectedRequester || request.requester != requester
                    || request.priceIdentifier != priceIdentifier
                    || keccak256(request.requestRules) != keccak256(requestRules)
                    || request.minimumLiveness != minimumLiveness || request.maximumLiveness != maximumLiveness
                    || reporter.getRequestId(priceIdentifier, requestRules) != requestId
            ) revert RegisteredRequestStateMismatch(requestId);
        }
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
        address expectedAccount
    ) private {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = eventTopic;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(deploymentBlock, block.number, proxy, topics);
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
                || reporter.isOracleInitializer(config.expectedOracleInitializer)
                    != expectedState.oracleInitializerEnabled
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
