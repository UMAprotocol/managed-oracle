// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OOReporter} from "../src/OOReporter.sol";
import {PolymarketOOReporter} from "../src/PolymarketOOReporter.sol";
import {PolymarketOOReporterOracleMigration} from "../src/PolymarketOOReporterOracleMigration.sol";
import {IOptimisticOracleV2} from "../src/interfaces/IOptimisticOracleV2.sol";
import {RequestData} from "../src/interfaces/IOOReporter.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IAddressWhitelist {
    function isOnWhitelist(address account) external view returns (bool);

    function isWhitelistEnabled() external view returns (bool);
}

interface IManagedOptimisticOracleMigrationTarget {
    function defaultLiveness() external view returns (uint256);

    function finder() external view returns (address);

    function defaultProposerWhitelist() external view returns (address);

    function requesterWhitelist() external view returns (address);

    function minimumDisputeWindow() external view returns (uint256);

    function allowedBondRanges(IERC20 currency) external view returns (uint128 minimumBond, uint128 maximumBond);

    function CONFIG_ADMIN_ROLE() external view returns (bytes32);

    function RESOLVER_ROLE() external view returns (bytes32);

    function RESOLVER_ADMIN_ROLE() external view returns (bytes32);

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title Atomic OOReporter implementation and Managed OO migration
/// @notice Installs the final Polymarket reporter and moves future requests to a fully configured replacement Managed OO.
/// @dev The script discovers every registered request from on-chain events, refuses unresolved initialized requests,
///      deploys a constructor-bound temporary bridge and final implementation, then atomically migrates and removes the
///      bridge. The reporter must remain operationally frozen between the preflight simulation and broadcast.
///      Use an external signer with `--sender <DEPLOYER_ADDRESS> --interactive`; no private key or mnemonic is read here.
contract UpgradeOOReporter is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 internal constant REQUEST_REGISTERED_TOPIC =
        keccak256("RequestRegistered(bytes32,address,bytes32,bytes,uint64,uint64)");
    bytes32 internal constant ORACLE_INITIALIZER_ENABLED_TOPIC = keccak256("OracleInitializerEnabledSet(address,bool)");
    bytes32 internal constant INITIALIZED_TOPIC = keccak256("Initialized(uint64)");

    error ActiveRequest(bytes32 requestId);
    error AddressHasNoCode(address target);
    error AddressMismatch(string field, address expected, address actual);
    error Bytes32Mismatch(string field, bytes32 expected, bytes32 actual);
    error ChainIdMismatch(uint256 expected, uint256 actual);
    error DeferredPayoutOutstanding(uint256 amount);
    error InvalidDeploymentBlock(uint256 deploymentBlock, uint256 currentBlock);
    error InvalidOracleInitializerLog(uint256 logIndex);
    error InvalidRegisteredRequestLog(uint256 logIndex);
    error InvalidProxiableUUID(address implementation, bytes32 actual);
    error MissingRole(bytes32 role, address account);
    error NoExpectedResolvers();
    error OwnerMismatch(address expected, address actual);
    error PostUpgradeStateMismatch();
    error RequestLivenessIncompatible(bytes32 requestId, uint64 maximumLiveness, uint256 minimumDisputeWindow);
    error RequestStateChanged(bytes32 requestId);
    error UintMismatch(string field, uint256 expected, uint256 actual);
    error UnexpectedEnabledOracleInitializer(address oracleInitializer);
    error UnexpectedRole(bytes32 role, address account);
    error WhitelistDisabled(address whitelist);
    error ReporterNotWhitelisted(address whitelist, address reporter);
    error ReporterInitializationNotFound(uint256 deploymentBlock);

    struct Config {
        uint256 expectedChainId;
        uint256 reporterDeploymentBlock;
        address deployer;
        address proxy;
        bytes32 expectedProxyCodehash;
        address expectedCurrentImplementation;
        bytes32 expectedCurrentImplementationCodehash;
        address expectedCurrentOptimisticOracle;
        bytes32 expectedCurrentOptimisticOracleCodehash;
        address newOptimisticOracle;
        bytes32 expectedNewMooProxyCodehash;
        address expectedNewMooImplementation;
        bytes32 expectedNewMooImplementationCodehash;
        address expectedRewardCurrency;
        address expectedRequester;
        address expectedOracleInitializer;
        address expectedNewFinder;
        address expectedNewDefaultProposerWhitelist;
        address expectedNewRequesterWhitelist;
        uint256 expectedNewDefaultLiveness;
        uint256 expectedNewMinimumDisputeWindow;
        uint256 expectedNewMinimumBond;
        uint256 expectedNewMaximumBond;
        address expectedNewConfigAdmin;
        address expectedNewUpgradeAdmin;
        address expectedNewResolverAdmin;
        address[] expectedNewResolvers;
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

    function run() external returns (address migrationImplementation, address finalImplementation) {
        Config memory config = _loadConfig();
        if (block.chainid != config.expectedChainId) {
            revert ChainIdMismatch(config.expectedChainId, block.chainid);
        }

        _requireCode(config.proxy);
        _requireCode(config.expectedCurrentImplementation);
        _requireCode(config.expectedCurrentOptimisticOracle);
        _requireCode(config.newOptimisticOracle);
        _requireCode(config.expectedNewMooImplementation);
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
        _expectCodehash("new Managed OO proxy", config.expectedNewMooProxyCodehash, config.newOptimisticOracle.codehash);
        _expectCodehash(
            "new Managed OO implementation",
            config.expectedNewMooImplementationCodehash,
            config.expectedNewMooImplementation.codehash
        );

        _expectAddress("current implementation", config.expectedCurrentImplementation, _getImplementation(config.proxy));

        OOReporter reporter = OOReporter(config.proxy);
        _validateCurrentReporter(reporter, config);
        _validateNewManagedOracle(config);

        _validateReporterDeploymentBlock(config.proxy, config.reporterDeploymentBlock);
        bytes32[] memory registeredRequestIds = _loadRegisteredRequestIds(config.proxy, config.reporterDeploymentBlock);
        _validateExclusiveOracleInitializer(
            config.proxy, config.reporterDeploymentBlock, config.expectedOracleInitializer
        );
        _validateRequests(reporter, registeredRequestIds, config.expectedNewMinimumDisputeWindow);
        ReporterState memory stateBefore = _snapshotReporterState(reporter, config, registeredRequestIds);

        uint256 deferredPayout = IOptimisticOracleV2(config.expectedCurrentOptimisticOracle)
            .deferredPayouts(IERC20(config.expectedRewardCurrency), config.proxy);
        if (deferredPayout != 0) revert DeferredPayoutOutstanding(deferredPayout);

        console.log("Deployer:", config.deployer);
        console.log("Reporter proxy:", config.proxy);
        console.log("Current Managed OO:", config.expectedCurrentOptimisticOracle);
        console.log("New Managed OO:", config.newOptimisticOracle);
        console.log("Registered requests discovered:", registeredRequestIds.length);

        vm.startBroadcast(config.deployer);
        PolymarketOOReporter finalReporterImplementation = new PolymarketOOReporter();
        PolymarketOOReporterOracleMigration migration = new PolymarketOOReporterOracleMigration(
            config.expectedCurrentOptimisticOracle, config.newOptimisticOracle, address(finalReporterImplementation)
        );
        vm.stopBroadcast();

        migrationImplementation = address(migration);
        finalImplementation = address(finalReporterImplementation);
        _requireUUPSImplementation(migrationImplementation);
        _requireUUPSImplementation(finalImplementation);

        bytes memory migrationCall = abi.encodeCall(
            PolymarketOOReporterOracleMigration.migrateOptimisticOracleAndFinalize, (registeredRequestIds)
        );
        bytes memory upgradeCall =
            abi.encodeCall(IUUPSUpgradeable.upgradeToAndCall, (migrationImplementation, migrationCall));

        vm.startBroadcast(config.deployer);
        _callUpgrade(config.proxy, upgradeCall);
        vm.stopBroadcast();

        _validatePostUpgrade(reporter, config, stateBefore, registeredRequestIds, finalImplementation);

        console.log("\n=== Atomic migration complete ===");
        console.log("Reporter proxy:", config.proxy);
        console.log("Temporary migration implementation:", migrationImplementation);
        console.log("Final Polymarket implementation:", finalImplementation);
        console.log("Managed OO:", address(reporter.optimisticOracle()));
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
        config.expectedCurrentOptimisticOracle = vm.envAddress("EXPECTED_CURRENT_OPTIMISTIC_ORACLE");
        config.expectedCurrentOptimisticOracleCodehash = vm.envBytes32("EXPECTED_CURRENT_OPTIMISTIC_ORACLE_CODEHASH");
        config.newOptimisticOracle = vm.envAddress("NEW_OPTIMISTIC_ORACLE");
        config.expectedNewMooProxyCodehash = vm.envBytes32("EXPECTED_NEW_MOO_PROXY_CODEHASH");
        config.expectedNewMooImplementation = vm.envAddress("EXPECTED_NEW_MOO_IMPLEMENTATION");
        config.expectedNewMooImplementationCodehash = vm.envBytes32("EXPECTED_NEW_MOO_IMPLEMENTATION_CODEHASH");
        config.expectedRewardCurrency = vm.envAddress("EXPECTED_REWARD_CURRENCY");
        config.expectedRequester = vm.envAddress("EXPECTED_REQUESTER");
        config.expectedOracleInitializer = vm.envAddress("EXPECTED_ORACLE_INITIALIZER");
        config.expectedNewFinder = vm.envAddress("EXPECTED_NEW_FINDER");
        config.expectedNewDefaultProposerWhitelist = vm.envAddress("EXPECTED_NEW_DEFAULT_PROPOSER_WHITELIST");
        config.expectedNewRequesterWhitelist = vm.envAddress("EXPECTED_NEW_REQUESTER_WHITELIST");
        config.expectedNewDefaultLiveness = vm.envUint("EXPECTED_NEW_DEFAULT_LIVENESS");
        config.expectedNewMinimumDisputeWindow = vm.envUint("EXPECTED_NEW_MINIMUM_DISPUTE_WINDOW");
        config.expectedNewMinimumBond = vm.envUint("EXPECTED_NEW_MINIMUM_BOND");
        config.expectedNewMaximumBond = vm.envUint("EXPECTED_NEW_MAXIMUM_BOND");
        config.expectedNewConfigAdmin = vm.envAddress("EXPECTED_NEW_CONFIG_ADMIN");
        config.expectedNewUpgradeAdmin = vm.envAddress("EXPECTED_NEW_UPGRADE_ADMIN");
        config.expectedNewResolverAdmin = vm.envAddress("EXPECTED_NEW_RESOLVER_ADMIN");
        config.expectedNewResolvers = vm.envAddress("EXPECTED_NEW_RESOLVERS", ",");
        if (config.expectedNewResolvers.length == 0) revert NoExpectedResolvers();
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
    }

    function _validateNewManagedOracle(Config memory config) private view {
        _expectAddress(
            "new MOO implementation",
            config.expectedNewMooImplementation,
            _getImplementation(config.newOptimisticOracle)
        );

        IManagedOptimisticOracleMigrationTarget oracle =
            IManagedOptimisticOracleMigrationTarget(config.newOptimisticOracle);
        _expectAddress("new MOO finder", config.expectedNewFinder, oracle.finder());
        _expectAddress(
            "new MOO proposer whitelist", config.expectedNewDefaultProposerWhitelist, oracle.defaultProposerWhitelist()
        );
        _expectAddress("new MOO requester whitelist", config.expectedNewRequesterWhitelist, oracle.requesterWhitelist());
        _expectUint("new MOO default liveness", config.expectedNewDefaultLiveness, oracle.defaultLiveness());
        _expectUint(
            "new MOO minimum dispute window", config.expectedNewMinimumDisputeWindow, oracle.minimumDisputeWindow()
        );

        (uint128 minimumBond, uint128 maximumBond) = oracle.allowedBondRanges(IERC20(config.expectedRewardCurrency));
        _expectUint("new MOO minimum bond", config.expectedNewMinimumBond, minimumBond);
        _expectUint("new MOO maximum bond", config.expectedNewMaximumBond, maximumBond);

        IAddressWhitelist proposerWhitelist = IAddressWhitelist(config.expectedNewDefaultProposerWhitelist);
        IAddressWhitelist requesterWhitelist = IAddressWhitelist(config.expectedNewRequesterWhitelist);
        _requireCode(address(proposerWhitelist));
        _requireCode(address(requesterWhitelist));
        if (!proposerWhitelist.isWhitelistEnabled()) revert WhitelistDisabled(address(proposerWhitelist));
        if (!requesterWhitelist.isWhitelistEnabled()) revert WhitelistDisabled(address(requesterWhitelist));
        if (!requesterWhitelist.isOnWhitelist(config.proxy)) {
            revert ReporterNotWhitelisted(address(requesterWhitelist), config.proxy);
        }

        _requireRole(oracle, oracle.CONFIG_ADMIN_ROLE(), config.expectedNewConfigAdmin);
        _requireRole(oracle, oracle.DEFAULT_ADMIN_ROLE(), config.expectedNewUpgradeAdmin);
        bytes32 resolverAdminRole = oracle.RESOLVER_ADMIN_ROLE();
        _requireRole(oracle, resolverAdminRole, config.expectedNewResolverAdmin);
        if (
            config.expectedNewUpgradeAdmin != config.expectedNewResolverAdmin
                && oracle.hasRole(resolverAdminRole, config.expectedNewUpgradeAdmin)
        ) revert UnexpectedRole(resolverAdminRole, config.expectedNewUpgradeAdmin);
        bytes32 resolverRole = oracle.RESOLVER_ROLE();
        for (uint256 i = 0; i < config.expectedNewResolvers.length; i++) {
            _requireRole(oracle, resolverRole, config.expectedNewResolvers[i]);
        }
    }

    function _loadRegisteredRequestIds(address proxy, uint256 deploymentBlock)
        private
        returns (bytes32[] memory requestIds)
    {
        if (deploymentBlock > block.number) revert InvalidDeploymentBlock(deploymentBlock, block.number);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = REQUEST_REGISTERED_TOPIC;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(deploymentBlock, block.number, proxy, topics);
        requestIds = new bytes32[](logs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].removed || logs[i].topics.length != 4 || logs[i].topics[0] != REQUEST_REGISTERED_TOPIC) {
                revert InvalidRegisteredRequestLog(i);
            }
            requestIds[i] = logs[i].topics[1];
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

    function _validateRequests(OOReporter reporter, bytes32[] memory requestIds, uint256 newMinimumDisputeWindow)
        private
        view
    {
        for (uint256 i = 0; i < requestIds.length; i++) {
            RequestData memory request = reporter.getRequest(requestIds[i]);
            if (request.initialized && !request.resolved) revert ActiveRequest(requestIds[i]);
            if (!request.initialized && request.maximumLiveness < newMinimumDisputeWindow) {
                revert RequestLivenessIncompatible(requestIds[i], request.maximumLiveness, newMinimumDisputeWindow);
            }
        }
    }

    function _validateExclusiveOracleInitializer(address proxy, uint256 deploymentBlock, address expectedInitializer)
        private
    {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ORACLE_INITIALIZER_ENABLED_TOPIC;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(deploymentBlock, block.number, proxy, topics);
        address[] memory initializers = new address[](logs.length);
        bool[] memory enabled = new bool[](logs.length);
        uint256 initializerCount;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].removed || logs[i].topics.length != 2 || logs[i].topics[0] != ORACLE_INITIALIZER_ENABLED_TOPIC) revert InvalidOracleInitializerLog(i);

            address initializer = address(uint160(uint256(logs[i].topics[1])));
            uint256 index;
            while (index < initializerCount && initializers[index] != initializer) {
                index++;
            }
            if (index == initializerCount) {
                initializers[index] = initializer;
                initializerCount++;
            }
            enabled[index] = abi.decode(logs[i].data, (bool));
        }

        bool expectedInitializerEnabled;
        for (uint256 i = 0; i < initializerCount; i++) {
            if (!enabled[i]) continue;
            if (initializers[i] != expectedInitializer) {
                revert UnexpectedEnabledOracleInitializer(initializers[i]);
            }
            expectedInitializerEnabled = true;
        }
        if (!expectedInitializerEnabled) revert PostUpgradeStateMismatch();
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

        if (
            reporter.owner() != expectedState.owner
                || address(reporter.optimisticOracle()) != config.newOptimisticOracle
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
            if (keccak256(abi.encode(reporter.getRequest(requestIds[i]))) != expectedState.requestHashes[i]) {
                revert RequestStateChanged(requestIds[i]);
            }
        }

        uint256 oldAllowance =
            IERC20(config.expectedRewardCurrency).allowance(address(reporter), config.expectedCurrentOptimisticOracle);
        if (oldAllowance != 0) revert UintMismatch("old MOO allowance", 0, oldAllowance);
        uint256 deferredPayout = IOptimisticOracleV2(config.expectedCurrentOptimisticOracle)
            .deferredPayouts(IERC20(config.expectedRewardCurrency), address(reporter));
        if (deferredPayout != 0) revert DeferredPayoutOutstanding(deferredPayout);
    }

    function _requireRole(IManagedOptimisticOracleMigrationTarget oracle, bytes32 role, address account) private view {
        if (!oracle.hasRole(role, account)) revert MissingRole(role, account);
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

    function _expectUint(string memory field, uint256 expected, uint256 actual) private pure {
        if (actual != expected) revert UintMismatch(field, expected, actual);
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
