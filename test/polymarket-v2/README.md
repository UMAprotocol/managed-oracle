# Polymarket v2 end-to-end contract environment

This fixture validates the deployed Polymarket v2 oracle stack against versioned VNet and Amoy
manifests. The VNet test covers the full path from Polymarket request registration through Managed
OO settlement, the automatic OOReporter callback, aggregator finalization, and the binary payout.

## Safety guarantee

The tests use `vm.createSelectFork` to pull remote state into Forge's local EVM. Every call,
impersonation, balance change, deployment, and timestamp change after that happens only in the
local test process and is discarded when the process exits.

This workflow must not contain `cast send`, `--broadcast`, a private key, a signer, Tenderly
impersonation methods, or any `eth_send*` RPC method. It intentionally produces no remote
transaction hash. `vm.prank`, `deal`, and `vm.warp` are Forge-local operations, not RPC writes.

## Environment configuration

Bootstrap a clean checkout first:

```sh
git submodule update --init --recursive
git clone https://github.com/Polymarket/polymarket-v2.git ../polymarket-v2
export FRO111_POLYMARKET_REPO="$(cd ../polymarket-v2 && pwd)"
bash test/polymarket-v2/check-provenance.sh
```

An existing full Polymarket checkout can be used instead of cloning another copy. The provenance
check resolves every declared commit, deployment-record commit, source path, and Git source blob in
its owning repository. It fails before RPC testing if any source/ABI association is stale or
incorrect.

Then copy the variable names from `env.example` into the shell and populate them locally. The RPCs
must support historical reads at the manifest blocks. Explorer variables are optional reference
keys; the tests do not contact an explorer.

| Environment | RPC variable | Explorer variable | Purpose |
| --- | --- | --- | --- |
| Staging VNet | `FRO111_VNET_RPC_URL` | `FRO111_VNET_EXPLORER_URL` | Exact post-audit lifecycle replay |
| Amoy | `FRO111_AMOY_RPC_URL` | `FRO111_AMOY_EXPLORER_URL` | Exact wiring, history, roles, and authorization subset |

No endpoint, token, service credential, or private key is stored in the manifests.

## Versioned inventory and provenance

Each integration-owned deployment (aggregator, reporter module, reporter, Managed OO, and binary
module) records:

- proxy and implementation addresses, raw runtime code hashes, first-code blocks, and the current
  implementation activation block;
- proxy family, ERC-1967 admin slot expectation, and effective UUPS upgrade authority;
- canonical source artifact plus full source and ABI revisions;
- immutable Git source-blob ID and the deployment-record/tooling revision when one exists;
- the chain, snapshot height and hash, dependencies, ownership, allowlists, required operational
  role holders, capabilities, and unresolved blockers.

The external reward token and both UMA whitelists are also pinned by address, first-code block,
runtime code hash, and deployment topology. Their minimal ABI surfaces are part of the pinned local
test interface bundle; their external source/build provenance is not claimed by this fixture.

The onchain code hash and block data are authoritative. Source and ABI revisions identify the
corresponding source surface; they are not presented as a compiler proof when the original build
artifact was not retained. `testAbiBundle.keccak256` pins the exact local interface bundle exercised
by these tests. The Amoy Managed OO source mapping is explicitly marked as inferred because its
original broadcast/build artifact was not versioned.

The VNet BinaryModule slot was restored to the recorded Polygon implementation at block 87,924,763
without an `Upgraded` log, as part of the fork's configured state. The manifest therefore records
that exact slot-transition block as the current implementation activation point; block 85,313,858
remains the implementation's first deployment and initial proxy activation.

## Commands

Validate both manifests without an RPC:

```sh
forge test --match-contract PolymarketV2ManifestTest -vv
```

Validate the exact VNet snapshot, deployment history, proxy topology, wiring, roles, and negative
authorization case:

```sh
forge test --match-contract PolymarketV2VNetWiringForkTest -vv
```

Run the full VNet lifecycle in the local EVM:

```sh
forge test --match-contract PolymarketV2EndToEndForkTest -vv
```

Validate the equivalent supported subset against the exact Amoy snapshot:

```sh
forge test --match-contract PolymarketV2AmoyWiringForkTest -vv
```

If an Amoy endpoint serves only current state, current wiring can still be checked explicitly:

```sh
FRO111_AMOY_USE_LATEST=true \
  forge test --match-contract PolymarketV2AmoyWiringForkTest -vv
```

Latest-state mode deliberately skips historical deployment/activation checks and is not accepted
as an exact replay. The existing Polygon fork CI job does not set either FRO-111 RPC variable, so
these tests skip cleanly instead of accidentally using Polygon mainnet.

## Automated checks

The exact wiring suites fail on any mismatch in:

- chain ID, snapshot number, or snapshot hash; the hash is read with `blockhash` from a local fork
  at the following block;
- first proxy/implementation code blocks and implementation activation blocks, using read-only
  `eth_getCode` and `eth_getStorageAt` calls;
- runtime code hashes, ERC-1967 implementation/admin slots, and ERC-1822 UUIDs;
- owners, pending transfers, upgrade authorities, three-day Managed OO default-admin delay, and
  role-admin hierarchy; VNet's reporter is two-step-owned while the older Amoy reporter is not;
- aggregator/module admins and operators; Managed OO config, request-manager, resolver-admin, and
  resolver roles;
- module → reporter → Managed OO bindings, requester and proposer allowlists, and binary-module
  resolver permission;
- rejection of aggregator initialization from an unrelated address.

The role arrays are the operational principals required by this integration. The Staging VNet
also contains ephemeral test aggregator operators created by other scenarios; they are not used as
deployment authorities or lifecycle actors here.

## VNet lifecycle

The fixed fixture derives a canonical binary request ID from
`uma-fro-111-polymarket-v2-e2e-binary-v1` and proves it is unused at the pinned snapshot. The test
then performs the following only in Forge's local EVM:

1. An active aggregator operator initializes the binary request and registers the live
   `OOReporterModule` through its initializer payload.
2. The UMA initializer creates an event-based Managed OO request with the configured identifier,
   rules, and liveness bounds.
3. Forge locally funds the proposer with exactly the bond plus final fee and grants a local token
   allowance.
4. The proposer submits `YES`; local time advances; an active resolver settles the request.
5. `PolymarketOOReporter` stores the outcome and automatically calls the reporter module, which
   translates and submits the result to the aggregator.
6. Local time advances through the aggregator window; the module finalizes; the binary module
   stores `[1_000_000, 0]`.

The test also asserts `requestInitialized`, reporter/disputer module membership, request shape,
identifier, rules, minimum/maximum/custom liveness, proposal bond, payout, result hash, vote count,
and final binary result.

## Lifecycle event evidence

`PolymarketV2EndToEndForkTest` captures and decodes the local EVM logs rather than checking only
event signatures. These fields are asserted and form the initial indexer contract:

| Contract | Events | Asserted fields |
| --- | --- | --- |
| Managed OO | `RequestPrice`, `ProposePrice`, `Settle` | requester, proposer/disputer, identifier, timestamp, rules, currency, reward/final fee, price, expiration, payout |
| OOReporter | `RequestRegistered`, `RequestInitialized`, `RequestResolved`, `ReportCallbackSucceeded` | request ID, requester, initializer, identifier, rules, liveness bounds, reward/bond, budget, outcome, callback module |
| OOReporterModule | `OOReporterRequestCreated`, `OOReporterResultReported` | request ID, identifier, price, translated result hash |
| OracleAggregator | `RequestInitialized`, `ResultReported`, `OutcomeProposed`, `RequestResolved` | event/request ID, target, thresholds, shape, modules, liveness, finalizer, result, hash, votes, resolver |

The evidence is deterministic local-fork evidence, not a remote transaction receipt. Rerunning at
the pinned block reproduces the same state transitions and decoded values without mutating the
VNet.

## Operational ownership and setup

The wiring test is the idempotent setup check: rerun it before any lifecycle work. All required
VNet roles and all supported Amoy roles currently pass.

| Capability | VNet authority/actor | Amoy authority/actor |
| --- | --- | --- |
| Aggregator/module UUPS upgrade | `0x47Eb...629C` owner | `0xfCBF...3D02` owner |
| Aggregator/module admin | `0x3dcE...D952` | `0xcA71...38A1` |
| Lifecycle aggregator operator | `0x1b41...f3f4` | `0xac99...5294`, `0x8c7c...a73c` |
| Module operator | `0xac99...5294` | Missing; admin `0xcA71...38A1` can grant it after a recipient is selected |
| Reporter UUPS/requester/initializer config | `0x9A8...b04D` owner | `0x9A8...b04D` owner |
| Requester whitelist changes | `0x3dcE...D952` | `0x9A8...b04D` |
| Default proposer whitelist changes | `0x6ee4...4146` | `0x9A8...b04D` |
| Managed OO upgrade/default admin | `0x9A8...b04D` | `0x9A8...b04D` |
| Managed OO config/request manager | `0x3dcE...D952` / `0x9A8...b04D` | `0x9A8...b04D` |
| Managed OO resolver admin/resolver | `0x6ee4...4146` / three manifest resolvers | `0x9A8...b04D` |

The only missing Amoy role is a module operator. After choosing the recipient, its calldata can be
prepared locally without sending it:

```sh
cast calldata "addOperator(address)" <selected-operator>
```

The module owner/admin must review and execute any eventual configuration transaction outside this
read-only workflow. Upgrading Amoy from base `OOReporter` to `PolymarketOOReporter` likewise requires
the reporter owner and a reviewed implementation; it is not performed here.

## Funding and gas

The VNet simulation needs no remote funding or gas. Forge's `deal` supplies exactly 500,000,000
reward-token base units (500 USDC.e at six decimals) for the bond plus final fee, and all approvals
remain local. A real testnet lifecycle would require native gas for each operator/proposer/resolver
and reward currency plus allowance for the proposer, but remote execution is deliberately outside
this fixture.

## Amoy scope and blockers

The exact Amoy snapshot passes deployment-history, topology, wiring, role, allowlist, and
unauthorized-initialization tests. It cannot run the automatic lifecycle because:

- the proxy points to base `OOReporter`, which has no automatic Polymarket callback;
- `OOReporterModule` has no selected operator for future module configuration;
- the current Managed OO deployment lacks a versioned original broadcast/build artifact, so its
  source mapping remains documented as an inference while the onchain code hash is authoritative.

## Replay, reset, and VNet recreation

Rerun the same Forge command to reset. Every test starts from the immutable snapshot and discards
all local writes; no cleanup transaction is needed or permitted.

If the VNet is recreated or any deployment changes, create a new manifest snapshot. Record the new
block and following block, verify the new hash, re-discover every first-code and activation block,
refresh all code hashes/roles/allowlists, choose an unused fixture ID, and rerun both wiring and E2E
tests. Do not silently repoint an existing manifest or replace an exact snapshot with latest state.
