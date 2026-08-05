// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {
    CoreDeployment,
    EnvironmentManifest,
    EnvironmentManifestLib,
    ExternalDeployment
} from "./EnvironmentManifest.sol";
import {
    IAddressWhitelistLike,
    IBinaryModuleLike,
    IERC1822ProxiableLike,
    IManagedOptimisticOracleLike,
    IOOReporterModuleLike,
    IOwnableLike,
    IPolymarketAggregator,
    IPolymarketOOReporterLike
} from "./PolymarketV2Interfaces.sol";

abstract contract PolymarketV2WiringForkBase is Test {
    uint256 private constant ADMIN_ROLE = 1 << 0;
    uint256 private constant OPERATOR_ROLE = 1 << 1;
    uint256 private constant BINARY_RESOLVER_ROLE = 1 << 4;
    bytes32 private constant MANAGED_ORACLE_CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");
    bytes32 private constant MANAGED_ORACLE_REQUEST_MANAGER_ROLE = keccak256("REQUEST_MANAGER_ROLE");
    bytes32 private constant MANAGED_ORACLE_RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 private constant MANAGED_ORACLE_RESOLVER_ADMIN_ROLE = keccak256("RESOLVER_ADMIN_ROLE");
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes4 private constant UNAUTHORIZED_SELECTOR = bytes4(keccak256("Unauthorized()"));
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    EnvironmentManifest internal manifest;
    string internal rpcUrl;
    bool internal forkEnabled;
    bool internal pinnedSnapshot;

    function setUp() public virtual {
        manifest = EnvironmentManifestLib.load(_manifestPath());
        rpcUrl = vm.envOr(manifest.rpcEnvironmentVariable, string(""));
        if (bytes(rpcUrl).length == 0) return;

        if (_useLatestState()) {
            vm.createSelectFork(rpcUrl);
        } else {
            _assertSnapshotHash();
            vm.createSelectFork(rpcUrl, manifest.snapshotBlock);
            pinnedSnapshot = true;
        }
        forkEnabled = true;
    }

    function test_wiringAndRolesMatchManifest() public {
        if (!_requireFork()) return;

        assertEq(block.chainid, manifest.chainId);
        if (pinnedSnapshot) assertEq(block.number, manifest.snapshotBlock);

        _assertDeployment(manifest.aggregator);
        _assertDeployment(manifest.reporterModule);
        _assertDeployment(manifest.reporter);
        _assertDeployment(manifest.managedOracle);
        _assertDeployment(manifest.binaryModule);
        _assertExternalDeployment(manifest.rewardCurrency);
        _assertExternalDeployment(manifest.requesterWhitelist);
        _assertExternalDeployment(manifest.defaultProposerWhitelist);

        IPolymarketAggregator aggregator = IPolymarketAggregator(manifest.aggregator.proxy);
        IOOReporterModuleLike reporterModule = IOOReporterModuleLike(manifest.reporterModule.proxy);
        IPolymarketOOReporterLike reporter = IPolymarketOOReporterLike(manifest.reporter.proxy);
        IManagedOptimisticOracleLike managedOracle = IManagedOptimisticOracleLike(manifest.managedOracle.proxy);

        assertEq(reporterModule.aggregator(), address(aggregator));
        assertEq(reporterModule.ooReporter(), address(reporter));
        assertEq(reporter.optimisticOracle(), address(managedOracle));
        assertEq(reporter.rewardCurrency(), manifest.rewardCurrency.contractAddress);
        assertTrue(reporter.isRequester(address(reporterModule)));
        assertEq(managedOracle.requesterWhitelist(), manifest.requesterWhitelist.contractAddress);
        assertEq(managedOracle.defaultProposerWhitelist(), manifest.defaultProposerWhitelist.contractAddress);
        assertTrue(IAddressWhitelistLike(manifest.requesterWhitelist.contractAddress).isOnWhitelist(address(reporter)));
        assertEq(
            IOwnableLike(manifest.requesterWhitelist.contractAddress).owner(), manifest.roles.requesterWhitelistOwner
        );
        assertEq(
            IOwnableLike(manifest.defaultProposerWhitelist.contractAddress).owner(),
            manifest.roles.defaultProposerWhitelistOwner
        );

        assertEq(aggregator.owner(), manifest.roles.aggregatorOwner);
        assertEq(reporterModule.owner(), manifest.roles.moduleOwner);
        assertEq(reporter.owner(), manifest.roles.reporterOwner);
        if (manifest.capabilities.reporterTwoStepOwnership) {
            assertEq(reporter.pendingOwner(), manifest.roles.reporterPendingOwner);
        }
        assertEq(managedOracle.defaultAdmin(), manifest.roles.managedOracleDefaultAdmin);
        assertEq(uint256(managedOracle.defaultAdminDelay()), manifest.roles.managedOracleDefaultAdminDelay);
        (address pendingDefaultAdmin, uint48 pendingSchedule) = managedOracle.pendingDefaultAdmin();
        assertEq(pendingDefaultAdmin, manifest.roles.managedOraclePendingDefaultAdmin);
        assertEq(uint256(pendingSchedule), manifest.roles.managedOraclePendingDefaultAdminSchedule);
        assertEq(manifest.aggregator.upgradeAuthority, manifest.roles.aggregatorOwner);
        assertEq(manifest.reporterModule.upgradeAuthority, manifest.roles.moduleOwner);
        assertEq(manifest.reporter.upgradeAuthority, manifest.roles.reporterOwner);
        assertEq(manifest.managedOracle.upgradeAuthority, manifest.roles.managedOracleDefaultAdmin);
        assertTrue(
            IBinaryModuleLike(manifest.binaryModule.proxy).hasAllRoles(address(aggregator), BINARY_RESOLVER_ROLE),
            "aggregator must resolve the binary target"
        );

        for (uint256 i; i < manifest.roles.requiredAggregatorAdmins.length; ++i) {
            assertTrue(aggregator.hasAllRoles(manifest.roles.requiredAggregatorAdmins[i], ADMIN_ROLE));
        }
        for (uint256 i; i < manifest.roles.requiredAggregatorOperators.length; ++i) {
            assertTrue(aggregator.hasAllRoles(manifest.roles.requiredAggregatorOperators[i], OPERATOR_ROLE));
        }
        for (uint256 i; i < manifest.roles.requiredModuleAdmins.length; ++i) {
            assertTrue(reporterModule.hasAllRoles(manifest.roles.requiredModuleAdmins[i], ADMIN_ROLE));
        }
        for (uint256 i; i < manifest.roles.requiredModuleOperators.length; ++i) {
            assertTrue(reporterModule.hasAllRoles(manifest.roles.requiredModuleOperators[i], OPERATOR_ROLE));
        }
        for (uint256 i; i < manifest.roles.requiredOracleInitializersAndProposers.length; ++i) {
            address account = manifest.roles.requiredOracleInitializersAndProposers[i];
            assertTrue(reporter.isOracleInitializer(account));
            assertTrue(IAddressWhitelistLike(managedOracle.defaultProposerWhitelist()).isOnWhitelist(account));
        }
        for (uint256 i; i < manifest.roles.requiredManagedOracleConfigAdmins.length; ++i) {
            assertTrue(
                managedOracle.hasRole(
                    MANAGED_ORACLE_CONFIG_ADMIN_ROLE, manifest.roles.requiredManagedOracleConfigAdmins[i]
                )
            );
        }
        for (uint256 i; i < manifest.roles.requiredManagedOracleRequestManagers.length; ++i) {
            assertTrue(
                managedOracle.hasRole(
                    MANAGED_ORACLE_REQUEST_MANAGER_ROLE, manifest.roles.requiredManagedOracleRequestManagers[i]
                )
            );
        }
        for (uint256 i; i < manifest.roles.requiredManagedOracleResolverAdmins.length; ++i) {
            assertTrue(
                managedOracle.hasRole(
                    MANAGED_ORACLE_RESOLVER_ADMIN_ROLE, manifest.roles.requiredManagedOracleResolverAdmins[i]
                )
            );
        }
        for (uint256 i; i < manifest.roles.requiredManagedOracleResolvers.length; ++i) {
            assertTrue(
                managedOracle.hasRole(MANAGED_ORACLE_RESOLVER_ROLE, manifest.roles.requiredManagedOracleResolvers[i])
            );
        }

        assertEq(managedOracle.getRoleAdmin(MANAGED_ORACLE_CONFIG_ADMIN_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(managedOracle.getRoleAdmin(MANAGED_ORACLE_REQUEST_MANAGER_ROLE), MANAGED_ORACLE_CONFIG_ADMIN_ROLE);
        assertEq(managedOracle.getRoleAdmin(MANAGED_ORACLE_RESOLVER_ROLE), MANAGED_ORACLE_RESOLVER_ADMIN_ROLE);
        assertEq(managedOracle.getRoleAdmin(MANAGED_ORACLE_RESOLVER_ADMIN_ROLE), MANAGED_ORACLE_RESOLVER_ADMIN_ROLE);
    }

    function test_deploymentAndActivationBlocksMatchManifest() public {
        if (!_requireFork()) return;
        if (!pinnedSnapshot) {
            vm.skip(true, "latest-state mode cannot verify historical deployment blocks");
            return;
        }

        _assertDeploymentHistory(manifest.aggregator);
        _assertDeploymentHistory(manifest.reporterModule);
        _assertDeploymentHistory(manifest.reporter);
        _assertDeploymentHistory(manifest.managedOracle);
        _assertDeploymentHistory(manifest.binaryModule);
        _assertFirstCodeBlock(
            manifest.rewardCurrency.contractAddress,
            manifest.rewardCurrency.deploymentBlock,
            "reward currency deployment block mismatch"
        );
        _assertFirstCodeBlock(
            manifest.requesterWhitelist.contractAddress,
            manifest.requesterWhitelist.deploymentBlock,
            "requester whitelist deployment block mismatch"
        );
        _assertFirstCodeBlock(
            manifest.defaultProposerWhitelist.contractAddress,
            manifest.defaultProposerWhitelist.deploymentBlock,
            "default proposer whitelist deployment block mismatch"
        );
    }

    function test_unauthorizedAggregatorInitializationIsRejected() public {
        if (!_requireFork()) return;

        IPolymarketAggregator.ModuleConfig[] memory modules = new IPolymarketAggregator.ModuleConfig[](0);
        IPolymarketAggregator.InitParams memory params = IPolymarketAggregator.InitParams({
            eventId: bytes29(0),
            marketType: IPolymarketAggregator.MarketType.BINARY,
            targetContract: manifest.binaryModule.proxy,
            resultLength: 1,
            reporterModules: modules,
            reporterThreshold: 1,
            disputerModules: modules,
            disputerThreshold: 1,
            arbitratorModule: manifest.roles.disputerAndArbitratorModule,
            arbitratorInitData: bytes(""),
            livenessWindow: 1 hours,
            finalizer: manifest.reporterModule.proxy
        });

        vm.expectRevert(UNAUTHORIZED_SELECTOR);
        vm.prank(address(0xBEEF));
        IPolymarketAggregator(manifest.aggregator.proxy).initializeRequest(params);
    }

    function _requireFork() internal returns (bool) {
        if (forkEnabled) return true;
        vm.skip(true, string.concat("set ", manifest.rpcEnvironmentVariable, " to run this read-only fork test"));
        return false;
    }

    function _assertDeployment(CoreDeployment memory deployment) private view {
        assertTrue(bytes(deployment.repository).length > 0, "missing deployment repository");
        assertTrue(bytes(deployment.artifact).length > 0, "missing deployment artifact");
        assertTrue(bytes(deployment.sourcePath).length > 0, "missing deployment source path");
        assertEq(bytes(deployment.sourceBlob).length, 40, "invalid deployment source blob");
        if (bytes(deployment.deploymentRecordRevision).length > 0) {
            assertEq(bytes(deployment.deploymentRecordRevision).length, 40, "invalid deployment record revision");
        }
        assertEq(bytes(deployment.sourceRevision).length, 40, "invalid deployment source revision");
        assertEq(bytes(deployment.abiRevision).length, 40, "invalid ABI revision");
        assertTrue(bytes(deployment.proxyType).length > 0, "missing proxy type");
        assertTrue(deployment.proxy.code.length > 0, "proxy has no code");
        assertTrue(deployment.implementation.code.length > 0, "implementation has no code");
        assertEq(deployment.proxy.codehash, deployment.proxyCodehash, "proxy codehash mismatch");
        assertEq(
            deployment.implementation.codehash, deployment.implementationCodehash, "implementation codehash mismatch"
        );
        assertEq(
            address(uint160(uint256(vm.load(deployment.proxy, ERC1967_IMPLEMENTATION_SLOT)))),
            deployment.implementation,
            "implementation slot mismatch"
        );
        assertEq(address(uint160(uint256(vm.load(deployment.proxy, ERC1967_ADMIN_SLOT)))), deployment.proxyAdmin);
        assertEq(deployment.proxyAdmin, address(0), "UUPS proxy must not have a transparent proxy admin");
        assertEq(IERC1822ProxiableLike(deployment.implementation).proxiableUUID(), ERC1967_IMPLEMENTATION_SLOT);
    }

    function _assertExternalDeployment(ExternalDeployment memory deployment) private view {
        assertTrue(bytes(deployment.artifact).length > 0, "missing external artifact");
        assertTrue(bytes(deployment.deploymentType).length > 0, "missing external deployment type");
        assertTrue(deployment.contractAddress.code.length > 0, "external dependency has no code");
        assertEq(deployment.contractAddress.codehash, deployment.codehash, "external dependency codehash mismatch");
    }

    function _assertSnapshotHash() private {
        vm.createSelectFork(rpcUrl, manifest.snapshotBlock + 1);
        assertEq(blockhash(manifest.snapshotBlock), manifest.snapshotBlockHash, "snapshot hash mismatch");
    }

    function _assertDeploymentHistory(CoreDeployment memory deployment) private {
        _assertFirstCodeBlock(deployment.proxy, deployment.proxyDeploymentBlock, "proxy deployment block mismatch");
        _assertFirstCodeBlock(
            deployment.implementation,
            deployment.implementationDeploymentBlock,
            "implementation deployment block mismatch"
        );

        bytes32 beforeActivation = _implementationAt(deployment.proxy, deployment.implementationActivationBlock - 1);
        bytes32 atActivation = _implementationAt(deployment.proxy, deployment.implementationActivationBlock);
        assertTrue(
            address(uint160(uint256(beforeActivation))) != deployment.implementation,
            "implementation active before manifest block"
        );
        assertEq(
            address(uint160(uint256(atActivation))),
            deployment.implementation,
            "implementation activation block mismatch"
        );
    }

    function _assertFirstCodeBlock(address target, uint256 deploymentBlock, string memory message) private {
        bytes memory beforeDeployment = vm.rpc(
            rpcUrl,
            "eth_getCode",
            string.concat("[\"", vm.toString(target), "\",\"", _rpcQuantity(deploymentBlock - 1), "\"]")
        );
        bytes memory atDeployment = vm.rpc(
            rpcUrl,
            "eth_getCode",
            string.concat("[\"", vm.toString(target), "\",\"", _rpcQuantity(deploymentBlock), "\"]")
        );
        assertEq(beforeDeployment.length, 0, message);
        assertGt(atDeployment.length, 0, message);
    }

    function _implementationAt(address proxy, uint256 blockNumber) private returns (bytes32) {
        bytes memory value = vm.rpc(
            rpcUrl,
            "eth_getStorageAt",
            string.concat(
                "[\"",
                vm.toString(proxy),
                "\",\"",
                vm.toString(ERC1967_IMPLEMENTATION_SLOT),
                "\",\"",
                _rpcQuantity(blockNumber),
                "\"]"
            )
        );
        return abi.decode(value, (bytes32));
    }

    function _rpcQuantity(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0x0";

        bytes16 symbols = "0123456789abcdef";
        uint256 length;
        for (uint256 copy = value; copy != 0; copy >>= 4) {
            ++length;
        }

        bytes memory result = new bytes(length + 2);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = length + 1; i > 1; --i) {
            result[i] = symbols[value & 0xf];
            value >>= 4;
        }
        return string(result);
    }

    function _manifestPath() internal pure virtual returns (string memory);

    function _useLatestState() internal view virtual returns (bool) {
        return false;
    }
}

contract PolymarketV2VNetWiringForkTest is PolymarketV2WiringForkBase {
    function _manifestPath() internal pure override returns (string memory) {
        return "test/polymarket-v2/environments/vnet.json";
    }
}

contract PolymarketV2AmoyWiringForkTest is PolymarketV2WiringForkBase {
    function _manifestPath() internal pure override returns (string memory) {
        return "test/polymarket-v2/environments/amoy.json";
    }

    function _useLatestState() internal view override returns (bool) {
        return vm.envOr("FRO111_AMOY_USE_LATEST", false);
    }
}
