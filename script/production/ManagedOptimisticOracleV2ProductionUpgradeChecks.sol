// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AddressWhitelistInterface} from "../../src/common/interfaces/AddressWhitelistInterface.sol";
import {ManagedOptimisticOracleV2} from "../../src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";

interface IOOReporterProductionWiring {
    function optimisticOracle() external view returns (address);
    function rewardCurrency() external view returns (address);
}

/// @notice Production constants and invariant checks shared by the deployment, Safe preparation, and verifier scripts.
abstract contract ManagedOptimisticOracleV2ProductionUpgradeChecks {
    struct StateSnapshot {
        bytes32 stateHash;
        uint256 nativeBalance;
        uint256 rewardCurrencyBalance;
    }

    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant POLYGON_CHAIN_ID = 137;
    address internal constant PROXY = 0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1;
    address internal constant SAFE = 0x7FB4492Ff58E4326a99D7d4F66aE1f47c8286Fc6;
    address internal constant CURRENT_IMPLEMENTATION = 0x7d660195eD02AC61A42408780233F06dDd6A2E42;

    address internal constant FINDER = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    address internal constant DEFAULT_PROPOSER_WHITELIST = 0x9F35885CE8f67a942D7B2f4Fbf937987DA08c463;
    address internal constant REQUESTER_WHITELIST = 0x0f79d0039956D58a7d5d006a6Dd64a35616Aa2c6;
    IERC20 internal constant USDC_E = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

    address internal constant CONFIG_ADMIN = 0x3dcE0a29139A851Da1dFCa56Af8e8a6440b4D952;
    address internal constant RESOLVER_ADMIN = 0x6ee4D971142afadEa1828445124D6137080B4146;
    address internal constant RESOLVER_1 = 0x33965F7D08F61A62B86C1Ab9Be5d82C42F4c3081;
    address internal constant RESOLVER_2 = 0x9725e8172A108f2BaD87ef31eA4Ea729e939d869;
    address internal constant EXISTING_PROPOSER = 0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D;
    address internal constant EXISTING_REQUESTER_1 = 0x65070BE91477460D8A7AeEb94ef92fe056C2f2A7;
    address internal constant EXISTING_REQUESTER_2 = 0x69c47De9D4D3Dad79590d61b9e05918E03775f24;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    bytes32 internal constant PROXY_CODEHASH = 0x77ffdff2dced37bc5d5cfea25d4b224824bd47f84ff720cb831e085db6a8f1e9;
    bytes32 internal constant CURRENT_IMPLEMENTATION_CODEHASH =
        0x35685e89c1d2c5ac7c45c9b1eea62d3a46799a87ea454aa3fdf360772c971cd2;
    bytes32 internal constant WHITELIST_CODEHASH = 0x2d4153189ac6f7e0e098061ca41a95234700c66792e3a77bcf12b2fc15ca9e6a;
    bytes32 internal constant TARGET_CREATION_CODEHASH =
        0xb376f529ccc58c4b64c7a3ccda3183362eb310b2fc3cb264481da847331b2bcd;
    bytes32 internal constant TARGET_NORMALIZED_RUNTIME_CODEHASH =
        0xe3759fddcb0d42fbc69a948adc235956a4fad52b343719932453e2a7b68d2867;

    uint256 internal constant CURRENT_IMPLEMENTATION_SIZE = 24_323;
    uint256 internal constant TARGET_IMPLEMENTATION_SIZE = 24_524;
    uint256 private constant TARGET_SELF_IMMUTABLE_OFFSET_1 = 5_158;
    uint256 private constant TARGET_SELF_IMMUTABLE_OFFSET_2 = 5_454;

    function _assertProductionState(
        address expectedImplementation,
        bool targetImplementation,
        address expectedReporter,
        address expectedRequestManager
    ) internal view {
        require(block.chainid == POLYGON_CHAIN_ID, "unexpected chain");
        require(PROXY.codehash == PROXY_CODEHASH, "proxy bytecode drift");
        require(_implementation() == expectedImplementation, "unexpected implementation");
        require(VM.load(PROXY, INITIALIZABLE_STORAGE_SLOT) == bytes32(uint256(2)), "proxy initializer version drift");

        if (targetImplementation) {
            _assertTargetImplementation(expectedImplementation);
        } else {
            require(expectedImplementation == CURRENT_IMPLEMENTATION, "unexpected current implementation");
            require(expectedImplementation.codehash == CURRENT_IMPLEMENTATION_CODEHASH, "current bytecode drift");
            require(expectedImplementation.code.length == CURRENT_IMPLEMENTATION_SIZE, "current bytecode size drift");
        }

        ManagedOptimisticOracleV2 managedOO = ManagedOptimisticOracleV2(PROXY);
        require(managedOO.owner() == SAFE, "owner drift");
        require(managedOO.defaultAdmin() == SAFE, "default admin drift");
        (address pendingAdmin, uint48 pendingSchedule) = managedOO.pendingDefaultAdmin();
        require(pendingAdmin == address(0) && pendingSchedule == 0, "pending admin transfer");
        require(managedOO.defaultAdminDelay() == 3 days, "admin delay drift");
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = managedOO.pendingDefaultAdminDelay();
        require(pendingDelay == 0 && pendingDelaySchedule == 0, "pending admin delay change");

        require(address(managedOO.finder()) == FINDER, "finder drift");
        require(managedOO.defaultLiveness() == 2 hours, "default liveness drift");
        require(address(managedOO.defaultProposerWhitelist()) == DEFAULT_PROPOSER_WHITELIST, "proposer whitelist drift");
        require(address(managedOO.requesterWhitelist()) == REQUESTER_WHITELIST, "requester whitelist drift");
        require(managedOO.minimumDisputeWindow() == 5 minutes, "minimum dispute window drift");
        (uint128 minimumBond, uint128 maximumBond) = managedOO.allowedBondRanges(USDC_E);
        require(minimumBond == 100e6 && maximumBond == 100_000e6, "bond range drift");

        _assertRoles(managedOO, expectedRequestManager);
        _assertWhitelistWiring(expectedReporter);
    }

    function _assertTargetImplementation(address implementation) internal view {
        require(implementation != address(0) && implementation.code.length != 0, "target not deployed");
        require(implementation.code.length == TARGET_IMPLEMENTATION_SIZE, "target bytecode size drift");
        require(
            _normalizedTargetRuntimeCodehash(implementation) == TARGET_NORMALIZED_RUNTIME_CODEHASH,
            "target bytecode drift"
        );
        require(
            ManagedOptimisticOracleV2(implementation).proxiableUUID() == ERC1967_IMPLEMENTATION_SLOT,
            "invalid UUPS UUID"
        );
        require(
            VM.load(implementation, INITIALIZABLE_STORAGE_SLOT) == bytes32(uint256(type(uint64).max)),
            "implementation is initializable"
        );
    }

    function _assertPostUpgradeGetters() internal view {
        ManagedOptimisticOracleV2 managedOO = ManagedOptimisticOracleV2(PROXY);
        require(managedOO.getRequestReward(address(1), bytes32(0), 0, bytes("")) == 0, "reward getter failed");
        require(managedOO.getRequestRulesUpdates(address(1), bytes32(0), bytes("")).length == 0, "rules getter failed");
    }

    function _snapshot(address expectedReporter, address expectedRequestManager)
        internal
        view
        returns (StateSnapshot memory snapshot)
    {
        ManagedOptimisticOracleV2 managedOO = ManagedOptimisticOracleV2(PROXY);
        snapshot.stateHash = keccak256(
            abi.encode(
                _adminStateHash(managedOO),
                _configurationStateHash(managedOO),
                _roleStateHash(managedOO, expectedRequestManager),
                _wiringStateHash(expectedReporter),
                VM.load(PROXY, INITIALIZABLE_STORAGE_SLOT)
            )
        );
        snapshot.nativeBalance = PROXY.balance;
        snapshot.rewardCurrencyBalance = USDC_E.balanceOf(PROXY);
    }

    function _assertSnapshotUnchanged(
        StateSnapshot memory beforeState,
        address expectedReporter,
        address expectedRequestManager
    ) internal view {
        StateSnapshot memory afterState = _snapshot(expectedReporter, expectedRequestManager);
        require(afterState.stateHash == beforeState.stateHash, "managed OO state changed");
        require(afterState.nativeBalance == beforeState.nativeBalance, "native balance changed");
        require(
            afterState.rewardCurrencyBalance == beforeState.rewardCurrencyBalance, "reward currency balance changed"
        );
    }

    function _assertExpectedBalances(uint256 expectedNativeBalance, uint256 expectedRewardCurrencyBalance)
        internal
        view
    {
        require(PROXY.balance == expectedNativeBalance, "unexpected native balance");
        require(USDC_E.balanceOf(PROXY) == expectedRewardCurrencyBalance, "unexpected reward currency balance");
    }

    function _assertRoles(ManagedOptimisticOracleV2 managedOO, address expectedRequestManager) private view {
        bytes32 defaultAdminRole = managedOO.DEFAULT_ADMIN_ROLE();
        bytes32 configAdminRole = managedOO.CONFIG_ADMIN_ROLE();
        bytes32 requestManagerRole = managedOO.REQUEST_MANAGER_ROLE();
        bytes32 resolverAdminRole = managedOO.RESOLVER_ADMIN_ROLE();
        bytes32 resolverRole = managedOO.RESOLVER_ROLE();

        require(defaultAdminRole == bytes32(0), "default role drift");
        require(managedOO.UPGRADE_ADMIN_ROLE() == defaultAdminRole, "upgrade role drift");
        require(managedOO.getRoleAdmin(defaultAdminRole) == defaultAdminRole, "default role admin drift");
        require(managedOO.getRoleAdmin(configAdminRole) == defaultAdminRole, "config role admin drift");
        require(managedOO.getRoleAdmin(requestManagerRole) == configAdminRole, "manager role admin drift");
        require(managedOO.getRoleAdmin(resolverAdminRole) == resolverAdminRole, "resolver admin role drift");
        require(managedOO.getRoleAdmin(resolverRole) == resolverAdminRole, "resolver role admin drift");

        require(managedOO.hasRole(defaultAdminRole, SAFE), "Safe lacks upgrade role");
        require(managedOO.hasRole(configAdminRole, CONFIG_ADMIN), "config admin missing");
        require(managedOO.hasRole(resolverAdminRole, RESOLVER_ADMIN), "resolver admin missing");
        require(managedOO.hasRole(resolverRole, RESOLVER_1), "resolver 1 missing");
        require(managedOO.hasRole(resolverRole, RESOLVER_2), "resolver 2 missing");
        if (expectedRequestManager != address(0)) {
            require(managedOO.hasRole(requestManagerRole, expectedRequestManager), "request manager missing");
        }
    }

    function _assertWhitelistWiring(address expectedReporter) private view {
        AddressWhitelistInterface proposerWhitelist = AddressWhitelistInterface(DEFAULT_PROPOSER_WHITELIST);
        AddressWhitelistInterface requesterWhitelist = AddressWhitelistInterface(REQUESTER_WHITELIST);
        require(DEFAULT_PROPOSER_WHITELIST.codehash == WHITELIST_CODEHASH, "proposer whitelist bytecode drift");
        require(REQUESTER_WHITELIST.codehash == WHITELIST_CODEHASH, "requester whitelist bytecode drift");
        require(Ownable(DEFAULT_PROPOSER_WHITELIST).owner() == RESOLVER_ADMIN, "proposer whitelist owner drift");
        require(Ownable(REQUESTER_WHITELIST).owner() == CONFIG_ADMIN, "requester whitelist owner drift");
        require(proposerWhitelist.isOnWhitelist(EXISTING_PROPOSER), "existing proposer missing");
        require(requesterWhitelist.isOnWhitelist(EXISTING_REQUESTER_1), "existing requester 1 missing");
        require(requesterWhitelist.isOnWhitelist(EXISTING_REQUESTER_2), "existing requester 2 missing");

        if (expectedReporter != address(0)) {
            require(expectedReporter.code.length != 0, "reporter not deployed");
            require(requesterWhitelist.isOnWhitelist(expectedReporter), "reporter not requester-whitelisted");
            require(
                IOOReporterProductionWiring(expectedReporter).optimisticOracle() == PROXY, "reporter oracle mismatch"
            );
            require(
                IOOReporterProductionWiring(expectedReporter).rewardCurrency() == address(USDC_E),
                "reporter reward currency mismatch"
            );
        }
    }

    function _adminStateHash(ManagedOptimisticOracleV2 managedOO) private view returns (bytes32) {
        (address pendingAdmin, uint48 pendingSchedule) = managedOO.pendingDefaultAdmin();
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = managedOO.pendingDefaultAdminDelay();
        return keccak256(
            abi.encode(
                managedOO.owner(),
                managedOO.defaultAdmin(),
                pendingAdmin,
                pendingSchedule,
                managedOO.defaultAdminDelay(),
                pendingDelay,
                pendingDelaySchedule
            )
        );
    }

    function _configurationStateHash(ManagedOptimisticOracleV2 managedOO) private view returns (bytes32) {
        (uint128 minimumBond, uint128 maximumBond) = managedOO.allowedBondRanges(USDC_E);
        return keccak256(
            abi.encode(
                address(managedOO.finder()),
                managedOO.defaultLiveness(),
                address(managedOO.defaultProposerWhitelist()),
                address(managedOO.requesterWhitelist()),
                managedOO.minimumDisputeWindow(),
                minimumBond,
                maximumBond
            )
        );
    }

    function _roleStateHash(ManagedOptimisticOracleV2 managedOO, address expectedRequestManager)
        private
        view
        returns (bytes32)
    {
        bytes32 defaultAdminRole = managedOO.DEFAULT_ADMIN_ROLE();
        bytes32 configAdminRole = managedOO.CONFIG_ADMIN_ROLE();
        bytes32 requestManagerRole = managedOO.REQUEST_MANAGER_ROLE();
        bytes32 resolverAdminRole = managedOO.RESOLVER_ADMIN_ROLE();
        bytes32 resolverRole = managedOO.RESOLVER_ROLE();
        return keccak256(
            abi.encode(
                managedOO.getRoleAdmin(defaultAdminRole),
                managedOO.getRoleAdmin(configAdminRole),
                managedOO.getRoleAdmin(requestManagerRole),
                managedOO.getRoleAdmin(resolverAdminRole),
                managedOO.getRoleAdmin(resolverRole),
                managedOO.hasRole(defaultAdminRole, SAFE),
                managedOO.hasRole(configAdminRole, CONFIG_ADMIN),
                managedOO.hasRole(resolverAdminRole, RESOLVER_ADMIN),
                managedOO.hasRole(resolverRole, RESOLVER_1),
                managedOO.hasRole(resolverRole, RESOLVER_2),
                expectedRequestManager == address(0)
                    ? false
                    : managedOO.hasRole(requestManagerRole, expectedRequestManager)
            )
        );
    }

    function _wiringStateHash(address expectedReporter) private view returns (bytes32) {
        AddressWhitelistInterface proposerWhitelist = AddressWhitelistInterface(DEFAULT_PROPOSER_WHITELIST);
        AddressWhitelistInterface requesterWhitelist = AddressWhitelistInterface(REQUESTER_WHITELIST);
        bytes32 reporterHash;
        if (expectedReporter != address(0)) {
            reporterHash = keccak256(
                abi.encode(
                    expectedReporter.codehash,
                    requesterWhitelist.isOnWhitelist(expectedReporter),
                    IOOReporterProductionWiring(expectedReporter).optimisticOracle(),
                    IOOReporterProductionWiring(expectedReporter).rewardCurrency()
                )
            );
        }
        return keccak256(
            abi.encode(
                DEFAULT_PROPOSER_WHITELIST.codehash,
                REQUESTER_WHITELIST.codehash,
                Ownable(DEFAULT_PROPOSER_WHITELIST).owner(),
                Ownable(REQUESTER_WHITELIST).owner(),
                proposerWhitelist.isOnWhitelist(EXISTING_PROPOSER),
                requesterWhitelist.isOnWhitelist(EXISTING_REQUESTER_1),
                requesterWhitelist.isOnWhitelist(EXISTING_REQUESTER_2),
                reporterHash
            )
        );
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(VM.load(PROXY, ERC1967_IMPLEMENTATION_SLOT))));
    }

    /// @dev UUPS embeds its own address in two immutable words. Zeroing those words makes the runtime comparable
    /// across deployment addresses while retaining an exact check over every other byte.
    function _normalizedTargetRuntimeCodehash(address implementation) private view returns (bytes32) {
        bytes memory runtimeCode = implementation.code;
        require(runtimeCode.length == TARGET_IMPLEMENTATION_SIZE, "unexpected target runtime length");
        bytes32 expectedSelf = bytes32(uint256(uint160(implementation)));
        bytes32 selfReference1;
        bytes32 selfReference2;
        assembly ("memory-safe") {
            selfReference1 := mload(add(add(runtimeCode, 0x20), TARGET_SELF_IMMUTABLE_OFFSET_1))
            selfReference2 := mload(add(add(runtimeCode, 0x20), TARGET_SELF_IMMUTABLE_OFFSET_2))
        }
        require(selfReference1 == expectedSelf && selfReference2 == expectedSelf, "target self immutable drift");
        assembly ("memory-safe") {
            mstore(add(add(runtimeCode, 0x20), TARGET_SELF_IMMUTABLE_OFFSET_1), 0)
            mstore(add(add(runtimeCode, 0x20), TARGET_SELF_IMMUTABLE_OFFSET_2), 0)
        }
        return keccak256(runtimeCode);
    }
}
