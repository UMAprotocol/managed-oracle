// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {
    CoreDeployment,
    EnvironmentManifest,
    EnvironmentManifestLib,
    ExternalDeployment
} from "./EnvironmentManifest.sol";

contract PolymarketV2ManifestTest is Test {
    string private constant VNET_MANIFEST = "test/polymarket-v2/environments/vnet.json";
    string private constant AMOY_MANIFEST = "test/polymarket-v2/environments/amoy.json";

    function test_manifestsAreVersionedAndContainNoRpcCredentials() public view {
        EnvironmentManifest memory vnet = EnvironmentManifestLib.load(VNET_MANIFEST);
        EnvironmentManifest memory amoy = EnvironmentManifestLib.load(AMOY_MANIFEST);

        assertEq(vnet.schemaVersion, 2);
        assertEq(amoy.schemaVersion, 2);
        assertEq(vnet.chainId, 137);
        assertEq(amoy.chainId, 80_002);
        assertEq(vnet.rpcEnvironmentVariable, "FRO111_VNET_RPC_URL");
        assertEq(amoy.rpcEnvironmentVariable, "FRO111_AMOY_RPC_URL");
        assertEq(vnet.explorerEnvironmentVariable, "FRO111_VNET_EXPLORER_URL");
        assertEq(amoy.explorerEnvironmentVariable, "FRO111_AMOY_EXPLORER_URL");
        assertTrue(vnet.capabilities.snapshotStateVerified);
        assertTrue(vnet.capabilities.automaticReporterCallback);
        assertTrue(vnet.capabilities.reporterTwoStepOwnership);
        assertTrue(vnet.capabilities.fullLifecycleSimulation);
        assertTrue(amoy.capabilities.snapshotStateVerified);
        assertFalse(amoy.capabilities.automaticReporterCallback);
        assertFalse(amoy.capabilities.reporterTwoStepOwnership);
        assertFalse(amoy.capabilities.fullLifecycleSimulation);
        assertEq(vnet.knownBlockers.length, 0);
        assertEq(amoy.knownBlockers.length, 3);

        _assertSourceRevision(vnet.sources.managedOracle);
        _assertSourceRevision(vnet.sources.managedOracleDeploymentTooling);
        _assertSourceRevision(vnet.sources.ooReporterDeploymentTooling);
        _assertSourceRevision(vnet.sources.polymarket);
        _assertSourceRevision(vnet.sources.polymarketDeploymentConfig);
        _assertSourceRevision(amoy.sources.managedOracle);
        _assertSourceRevision(amoy.sources.managedOracleDeploymentTooling);
        _assertSourceRevision(amoy.sources.ooReporterDeploymentTooling);
        _assertSourceRevision(amoy.sources.polymarket);
        _assertSourceRevision(amoy.sources.polymarketDeploymentConfig);
        assertEq(vnet.testAbiBundle, "test/polymarket-v2/PolymarketV2Interfaces.sol");
        assertEq(amoy.testAbiBundle, vnet.testAbiBundle);
        assertEq(keccak256(bytes(EnvironmentManifestLib.raw(vnet.testAbiBundle))), vnet.testAbiBundleHash);
        assertEq(amoy.testAbiBundleHash, vnet.testAbiBundleHash);

        _assertDeployment(vnet.aggregator);
        _assertDeployment(vnet.reporterModule);
        _assertDeployment(vnet.reporter);
        _assertDeployment(vnet.managedOracle);
        _assertDeployment(vnet.binaryModule);
        _assertDeployment(amoy.aggregator);
        _assertDeployment(amoy.reporterModule);
        _assertDeployment(amoy.reporter);
        _assertDeployment(amoy.managedOracle);
        _assertDeployment(amoy.binaryModule);
        _assertExternalDeployment(vnet.rewardCurrency);
        _assertExternalDeployment(vnet.requesterWhitelist);
        _assertExternalDeployment(vnet.defaultProposerWhitelist);
        _assertExternalDeployment(amoy.rewardCurrency);
        _assertExternalDeployment(amoy.requesterWhitelist);
        _assertExternalDeployment(amoy.defaultProposerWhitelist);

        assertEq(vnet.roles.requiredAggregatorAdmins.length, 1);
        assertEq(vnet.roles.requiredAggregatorOperators.length, 2);
        assertEq(vnet.roles.requiredModuleAdmins.length, 1);
        assertEq(vnet.roles.requiredModuleOperators.length, 1);
        assertEq(vnet.roles.requiredManagedOracleResolvers.length, 3);
        assertEq(amoy.roles.requiredAggregatorAdmins.length, 1);
        assertEq(amoy.roles.requiredAggregatorOperators.length, 2);
        assertEq(amoy.roles.requiredModuleAdmins.length, 1);
        assertEq(amoy.roles.requiredModuleOperators.length, 0);
        assertEq(amoy.roles.requiredManagedOracleResolvers.length, 1);

        _assertNoCredentialMaterial(EnvironmentManifestLib.raw(VNET_MANIFEST));
        _assertNoCredentialMaterial(EnvironmentManifestLib.raw(AMOY_MANIFEST));
    }

    function _assertSourceRevision(string memory revision) private pure {
        assertEq(bytes(revision).length, 40, "source revision must be a full git SHA");
    }

    function _assertDeployment(CoreDeployment memory deployment) private pure {
        assertTrue(bytes(deployment.repository).length > 0, "repository is required");
        assertTrue(bytes(deployment.artifact).length > 0, "artifact is required");
        assertTrue(bytes(deployment.sourcePath).length > 0, "source path is required");
        _assertSourceRevision(deployment.sourceBlob);
        assertTrue(bytes(deployment.proxyType).length > 0, "proxy type is required");
        if (bytes(deployment.deploymentRecordRevision).length > 0) {
            _assertSourceRevision(deployment.deploymentRecordRevision);
        }
        _assertSourceRevision(deployment.sourceRevision);
        _assertSourceRevision(deployment.abiRevision);
        assertTrue(deployment.proxy != address(0), "proxy is required");
        assertTrue(deployment.implementation != address(0), "implementation is required");
        assertTrue(deployment.upgradeAuthority != address(0), "upgrade authority is required");
        assertGt(deployment.proxyDeploymentBlock, 0);
        assertGt(deployment.implementationDeploymentBlock, 0);
        assertGe(deployment.implementationActivationBlock, deployment.implementationDeploymentBlock);
    }

    function _assertExternalDeployment(ExternalDeployment memory deployment) private pure {
        assertTrue(bytes(deployment.artifact).length > 0, "external artifact is required");
        assertTrue(bytes(deployment.deploymentType).length > 0, "external deployment type is required");
        assertTrue(deployment.contractAddress != address(0), "external address is required");
        assertGt(deployment.deploymentBlock, 0);
        assertTrue(deployment.codehash != bytes32(0), "external codehash is required");
    }

    function _assertNoCredentialMaterial(string memory manifest) private pure {
        bytes memory raw = bytes(manifest);
        assertFalse(_contains(raw, bytes("https://")), "manifest must not embed an RPC URL");
        assertFalse(_contains(raw, bytes("http://")), "manifest must not embed an RPC URL");
        assertFalse(_contains(raw, bytes("wss://")), "manifest must not embed a websocket URL");
        assertFalse(_contains(raw, bytes("privateKey")), "manifest must not embed a private key");
        assertFalse(_contains(raw, bytes("mnemonic")), "manifest must not embed a mnemonic");
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;

        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool matches = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
