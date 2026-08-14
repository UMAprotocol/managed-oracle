# Polygon ManagedOO production upgrade

This runbook upgrades the existing Polygon `ManagedOptimisticOracleV2` proxy without reinitializing it.
The proxy is already initialized at version 2, so the Safe transaction is exactly
`upgradeToAndCall(targetImplementation, 0x)`. Do not call `initializeV2`.

The repository pins the reviewed target build to Solidity 0.8.30, Prague, optimizer runs 1, and
`viaIR = true`. The storage-layout comparison uses the reconstructed source commit and compiler settings for
the current `0x7d660195eD02AC61A42408780233F06dDd6A2E42` implementation from
`old-builds/build-info-prod-current`; the scripts separately pin the raw live runtime code hash.
The reproducible workflow requires Foundry v1.7.1.

## 1. Test the upgrade on a pinned Polygon fork

```bash
forge clean
NODE_URL_137="$POLYGON_RPC_URL" forge test \
  --match-contract ManagedOptimisticOracleV2ProductionUpgradeForkTest -vv
```

The test impersonates the production Safe only on the local fork, executes the empty-data UUPS upgrade,
and verifies bytecode, UUPS immutables, initializer state, roles, configuration, balances, whitelist wiring,
and the new getters. The implementation deployment step below separately runs the OpenZeppelin storage-layout
validation and refuses to deploy if it fails.

## 2. Deploy the implementation

Use a CLI wallet account, hardware wallet, or interactive signer. Never put a private key or mnemonic in
an environment variable. `DEPLOYER_ADDRESS` selects the externally configured signer and is deliberately
separate from the Safe that owns the proxy.

```bash
forge clean
DEPLOYER_ADDRESS="$DEPLOYER" forge script \
  script/production/UpgradeManagedOptimisticOracleV2Production.s.sol:\
DeployManagedOptimisticOracleV2ProductionImplementation \
  --rpc-url "$POLYGON_RPC_URL" \
  --sender "$DEPLOYER" \
  --account "$FOUNDRY_ACCOUNT" \
  --broadcast
```

The script refuses to deploy unless the production proxy is still on the expected implementation,
OpenZeppelin validates the storage layout, and the target creation bytecode matches the reviewed build.
Record the printed target implementation and its transaction receipt.

## 3. Simulate and prepare the Safe transaction

Run this immediately before submitting the transaction. Do not add `--broadcast`; this entrypoint only
simulates the Safe call locally and prints its fields.

```bash
TARGET_IMPLEMENTATION="$TARGET" forge script \
  script/production/UpgradeManagedOptimisticOracleV2Production.s.sol:\
PrepareManagedOptimisticOracleV2ProductionSafeUpgrade \
  --rpc-url "$POLYGON_RPC_URL"
```

Submit the printed transaction through Safe using:

- target: `0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1`
- value: `0`
- operation: `Call` (`0`)
- data: the printed `upgradeToAndCall(targetImplementation, 0x)` calldata

Record the two pre-upgrade balances printed by the script. Any state drift between this simulation and
Safe execution should be investigated and the simulation rerun.

## 4. Verify the executed upgrade

```bash
TARGET_IMPLEMENTATION="$TARGET" \
PRE_UPGRADE_NATIVE_BALANCE="$NATIVE_BALANCE" \
PRE_UPGRADE_USDC_BALANCE="$USDC_BALANCE" \
forge script \
  script/production/UpgradeManagedOptimisticOracleV2Production.s.sol:\
VerifyManagedOptimisticOracleV2ProductionUpgrade \
  --rpc-url "$POLYGON_RPC_URL"
```

If the OOReporter is already deployed and requester-whitelisted, add
`EXPECTED_REPORTER=<proxy>` to every command to verify its ManagedOO and USDC.e bindings. If a request
manager role has been granted as part of the production setup, add
`EXPECTED_REQUEST_MANAGER=<account>` to verify that membership as well.
Do not omit either variable merely to bypass a failed check: leave it at zero only after confirming that the
corresponding production integration or role is not configured at execution time.

All commands require an RPC URL supplied at runtime; this runbook and the scripts contain no RPC endpoint
or signing secret.
