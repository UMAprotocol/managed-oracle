// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";

struct CoreDeployment {
    string repository;
    string artifact;
    string sourcePath;
    string sourceBlob;
    string deploymentRecordRevision;
    string sourceRevision;
    string abiRevision;
    string proxyType;
    address proxy;
    address implementation;
    address proxyAdmin;
    address upgradeAuthority;
    uint256 proxyDeploymentBlock;
    uint256 implementationDeploymentBlock;
    uint256 implementationActivationBlock;
    bytes32 proxyCodehash;
    bytes32 implementationCodehash;
}

struct ExternalDeployment {
    string artifact;
    string deploymentType;
    address contractAddress;
    uint256 deploymentBlock;
    bytes32 codehash;
}

struct SourceRevisions {
    string managedOracle;
    string managedOracleDeploymentTooling;
    string ooReporterDeploymentTooling;
    string polymarket;
    string polymarketDeploymentConfig;
}

struct EnvironmentRoles {
    address aggregatorOwner;
    address moduleOwner;
    address reporterOwner;
    address reporterPendingOwner;
    address managedOracleDefaultAdmin;
    uint256 managedOracleDefaultAdminDelay;
    address managedOraclePendingDefaultAdmin;
    uint256 managedOraclePendingDefaultAdminSchedule;
    address requesterWhitelistOwner;
    address defaultProposerWhitelistOwner;
    address[] requiredAggregatorAdmins;
    address[] requiredAggregatorOperators;
    address[] requiredModuleAdmins;
    address[] requiredModuleOperators;
    address[] requiredOracleInitializersAndProposers;
    address[] requiredManagedOracleConfigAdmins;
    address[] requiredManagedOracleRequestManagers;
    address[] requiredManagedOracleResolverAdmins;
    address[] requiredManagedOracleResolvers;
    address disputerAndArbitratorModule;
}

struct EnvironmentCapabilities {
    bool snapshotStateVerified;
    bool automaticReporterCallback;
    bool reporterTwoStepOwnership;
    bool fullLifecycleSimulation;
}

struct EnvironmentManifest {
    uint256 schemaVersion;
    string environment;
    string purpose;
    uint256 chainId;
    string rpcEnvironmentVariable;
    string explorer;
    string explorerEnvironmentVariable;
    uint256 snapshotBlock;
    string snapshotBlockRpc;
    bytes32 snapshotBlockHash;
    SourceRevisions sources;
    string testAbiBundle;
    bytes32 testAbiBundleHash;
    CoreDeployment aggregator;
    CoreDeployment reporterModule;
    CoreDeployment reporter;
    CoreDeployment managedOracle;
    CoreDeployment binaryModule;
    ExternalDeployment rewardCurrency;
    ExternalDeployment requesterWhitelist;
    ExternalDeployment defaultProposerWhitelist;
    EnvironmentRoles roles;
    EnvironmentCapabilities capabilities;
    string[] knownBlockers;
}

library EnvironmentManifestLib {
    using stdJson for string;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function load(string memory relativePath) internal view returns (EnvironmentManifest memory manifest) {
        string memory json = raw(relativePath);

        manifest.schemaVersion = json.readUint(".schemaVersion");
        manifest.environment = json.readString(".environment");
        manifest.purpose = json.readString(".purpose");
        manifest.chainId = json.readUint(".chainId");
        manifest.rpcEnvironmentVariable = json.readString(".rpcEnvironmentVariable");
        manifest.explorer = json.readString(".explorer.name");
        manifest.explorerEnvironmentVariable = json.readString(".explorer.baseUrlEnvironmentVariable");
        manifest.snapshotBlock = json.readUint(".snapshot.blockNumber");
        manifest.snapshotBlockRpc = json.readString(".snapshot.rpcBlockNumber");
        manifest.snapshotBlockHash = json.readBytes32(".snapshot.blockHash");

        manifest.sources = SourceRevisions({
            managedOracle: json.readString(".sources.managedOracle"),
            managedOracleDeploymentTooling: json.readString(".sources.managedOracleDeploymentTooling"),
            ooReporterDeploymentTooling: json.readString(".sources.ooReporterDeploymentTooling"),
            polymarket: json.readString(".sources.polymarket"),
            polymarketDeploymentConfig: json.readString(".sources.polymarketDeploymentConfig")
        });
        manifest.testAbiBundle = json.readString(".testAbiBundle.path");
        manifest.testAbiBundleHash = json.readBytes32(".testAbiBundle.keccak256");

        manifest.aggregator = _deployment(json, ".contracts.aggregator");
        manifest.reporterModule = _deployment(json, ".contracts.reporterModule");
        manifest.reporter = _deployment(json, ".contracts.reporter");
        manifest.managedOracle = _deployment(json, ".contracts.managedOracle");
        manifest.binaryModule = _deployment(json, ".contracts.binaryModule");
        manifest.rewardCurrency = _externalDeployment(json, ".contracts.rewardCurrency");
        manifest.requesterWhitelist = _externalDeployment(json, ".contracts.requesterWhitelist");
        manifest.defaultProposerWhitelist = _externalDeployment(json, ".contracts.defaultProposerWhitelist");

        manifest.roles = EnvironmentRoles({
            aggregatorOwner: json.readAddress(".roles.aggregatorOwner"),
            moduleOwner: json.readAddress(".roles.moduleOwner"),
            reporterOwner: json.readAddress(".roles.reporterOwner"),
            reporterPendingOwner: json.readAddress(".roles.reporterPendingOwner"),
            managedOracleDefaultAdmin: json.readAddress(".roles.managedOracleDefaultAdmin"),
            managedOracleDefaultAdminDelay: json.readUint(".roles.managedOracleDefaultAdminDelay"),
            managedOraclePendingDefaultAdmin: json.readAddress(".roles.managedOraclePendingDefaultAdmin"),
            managedOraclePendingDefaultAdminSchedule: json.readUint(".roles.managedOraclePendingDefaultAdminSchedule"),
            requesterWhitelistOwner: json.readAddress(".roles.requesterWhitelistOwner"),
            defaultProposerWhitelistOwner: json.readAddress(".roles.defaultProposerWhitelistOwner"),
            requiredAggregatorAdmins: json.readAddressArray(".roles.requiredAggregatorAdmins"),
            requiredAggregatorOperators: json.readAddressArray(".roles.requiredAggregatorOperators"),
            requiredModuleAdmins: json.readAddressArray(".roles.requiredModuleAdmins"),
            requiredModuleOperators: json.readAddressArray(".roles.requiredModuleOperators"),
            requiredOracleInitializersAndProposers: json.readAddressArray(".roles.requiredOracleInitializersAndProposers"),
            requiredManagedOracleConfigAdmins: json.readAddressArray(".roles.requiredManagedOracleConfigAdmins"),
            requiredManagedOracleRequestManagers: json.readAddressArray(".roles.requiredManagedOracleRequestManagers"),
            requiredManagedOracleResolverAdmins: json.readAddressArray(".roles.requiredManagedOracleResolverAdmins"),
            requiredManagedOracleResolvers: json.readAddressArray(".roles.requiredManagedOracleResolvers"),
            disputerAndArbitratorModule: json.readAddress(".roles.disputerAndArbitratorModule")
        });

        manifest.capabilities = EnvironmentCapabilities({
            snapshotStateVerified: json.readBool(".capabilities.snapshotStateVerified"),
            automaticReporterCallback: json.readBool(".capabilities.automaticReporterCallback"),
            reporterTwoStepOwnership: json.readBool(".capabilities.reporterTwoStepOwnership"),
            fullLifecycleSimulation: json.readBool(".capabilities.fullLifecycleSimulation")
        });
        manifest.knownBlockers = json.readStringArray(".knownBlockers");
    }

    function raw(string memory relativePath) internal view returns (string memory) {
        return VM.readFile(string.concat(VM.projectRoot(), "/", relativePath));
    }

    function _deployment(string memory json, string memory key)
        private
        pure
        returns (CoreDeployment memory deployment)
    {
        deployment.repository = json.readString(string.concat(key, ".repository"));
        deployment.artifact = json.readString(string.concat(key, ".artifact"));
        deployment.sourcePath = json.readString(string.concat(key, ".sourcePath"));
        deployment.sourceBlob = json.readString(string.concat(key, ".sourceBlob"));
        deployment.deploymentRecordRevision = json.readString(string.concat(key, ".deploymentRecordRevision"));
        deployment.sourceRevision = json.readString(string.concat(key, ".sourceRevision"));
        deployment.abiRevision = json.readString(string.concat(key, ".abiRevision"));
        deployment.proxyType = json.readString(string.concat(key, ".proxyType"));
        deployment.proxy = json.readAddress(string.concat(key, ".proxy"));
        deployment.implementation = json.readAddress(string.concat(key, ".implementation"));
        deployment.proxyAdmin = json.readAddress(string.concat(key, ".proxyAdmin"));
        deployment.upgradeAuthority = json.readAddress(string.concat(key, ".upgradeAuthority"));
        deployment.proxyDeploymentBlock = json.readUint(string.concat(key, ".proxyDeploymentBlock"));
        deployment.implementationDeploymentBlock = json.readUint(string.concat(key, ".implementationDeploymentBlock"));
        deployment.implementationActivationBlock = json.readUint(string.concat(key, ".implementationActivationBlock"));
        deployment.proxyCodehash = json.readBytes32(string.concat(key, ".proxyCodehash"));
        deployment.implementationCodehash = json.readBytes32(string.concat(key, ".implementationCodehash"));
    }

    function _externalDeployment(string memory json, string memory key)
        private
        pure
        returns (ExternalDeployment memory deployment)
    {
        deployment.artifact = json.readString(string.concat(key, ".artifact"));
        deployment.deploymentType = json.readString(string.concat(key, ".deploymentType"));
        deployment.contractAddress = json.readAddress(string.concat(key, ".address"));
        deployment.deploymentBlock = json.readUint(string.concat(key, ".deploymentBlock"));
        deployment.codehash = json.readBytes32(string.concat(key, ".codehash"));
    }
}
