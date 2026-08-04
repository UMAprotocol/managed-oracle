// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PolymarketOOReporter} from "./PolymarketOOReporter.sol";
import {IOptimisticOracleV2} from "./interfaces/IOptimisticOracleV2.sol";
import {RequestData} from "./interfaces/IOOReporter.sol";

/// @title One-shot Polymarket OOReporter oracle migration
/// @notice Atomically migrates an existing reporter to a new Managed OO and removes this migration entry point.
/// @dev This implementation is only an atomic upgrade bridge. It writes the first field of the reporter's existing
///      ERC-7201 namespace, then installs the supplied final UUPS implementation in the same transaction.
contract PolymarketOOReporterOracleMigration is PolymarketOOReporter {
    using SafeERC20 for IERC20;

    error ActiveRequest(bytes32 requestId);
    error DeferredPayoutOutstanding(uint256 amount);
    error OptimisticOracleMismatch(address expected, address actual);
    error OptimisticOracleUnchanged();
    error TargetHasNoCode(address target);

    event OptimisticOracleMigrated(
        address indexed previousOptimisticOracle,
        address indexed newOptimisticOracle,
        address indexed finalImplementation
    );

    address public immutable EXPECTED_CURRENT_OPTIMISTIC_ORACLE;
    address public immutable NEW_OPTIMISTIC_ORACLE;
    address public immutable FINAL_IMPLEMENTATION;

    /// @dev Mirrors only the leading field of `OOReporterStorage`, leaving every subsequent value untouched.
    struct OracleMigrationStorage {
        IOptimisticOracleV2 optimisticOracle;
    }

    // Must remain identical to OOReporter.OO_REPORTER_STORAGE_LOCATION.
    bytes32 private constant OO_REPORTER_STORAGE_LOCATION =
        0xe597f8c3629f5ca2bbd4f416c338811ff317bd2d6db5ce34f2567207506cc400;

    constructor(address expectedCurrentOptimisticOracle, address newOptimisticOracle, address finalImplementation) {
        if (expectedCurrentOptimisticOracle.code.length == 0) {
            revert TargetHasNoCode(expectedCurrentOptimisticOracle);
        }
        if (newOptimisticOracle.code.length == 0) revert TargetHasNoCode(newOptimisticOracle);
        if (finalImplementation.code.length == 0) revert TargetHasNoCode(finalImplementation);
        if (expectedCurrentOptimisticOracle == newOptimisticOracle) revert OptimisticOracleUnchanged();

        EXPECTED_CURRENT_OPTIMISTIC_ORACLE = expectedCurrentOptimisticOracle;
        NEW_OPTIMISTIC_ORACLE = newOptimisticOracle;
        FINAL_IMPLEMENTATION = finalImplementation;
    }

    /// @notice Changes the reporter oracle and immediately installs the constructor-bound final implementation.
    /// @param registeredRequestIds Exhaustive registered request IDs; initialized entries must already be resolved.
    /// @dev The final upgrade uses the inherited UUPS path, which rechecks owner authorization and the final
    ///      implementation's proxiable UUID. It remains atomic with the storage migration. Reinstalling this bridge
    ///      cannot migrate the same proxy again because its immutable expected-current-oracle guard no longer matches.
    function migrateOptimisticOracleAndFinalize(bytes32[] calldata registeredRequestIds) external onlyProxy onlyOwner {
        OracleMigrationStorage storage $ = _getOracleMigrationStorage();
        address currentOracle = address($.optimisticOracle);
        if (currentOracle != EXPECTED_CURRENT_OPTIMISTIC_ORACLE) {
            revert OptimisticOracleMismatch(EXPECTED_CURRENT_OPTIMISTIC_ORACLE, currentOracle);
        }

        for (uint256 i = 0; i < registeredRequestIds.length; i++) {
            RequestData memory request = this.getRequest(registeredRequestIds[i]);
            if (request.initialized && !request.resolved) revert ActiveRequest(registeredRequestIds[i]);
        }

        IERC20 currency = rewardCurrency();
        uint256 deferredPayout = optimisticOracle().deferredPayouts(currency, address(this));
        if (deferredPayout != 0) revert DeferredPayoutOutstanding(deferredPayout);

        $.optimisticOracle = IOptimisticOracleV2(NEW_OPTIMISTIC_ORACLE);
        if (currency.allowance(address(this), currentOracle) != 0) {
            currency.forceApprove(currentOracle, 0);
        }

        emit OptimisticOracleMigrated(currentOracle, NEW_OPTIMISTIC_ORACLE, FINAL_IMPLEMENTATION);
        upgradeToAndCall(FINAL_IMPLEMENTATION, bytes(""));
    }

    function _getOracleMigrationStorage() private pure returns (OracleMigrationStorage storage $) {
        assembly {
            $.slot := OO_REPORTER_STORAGE_LOCATION
        }
    }
}
