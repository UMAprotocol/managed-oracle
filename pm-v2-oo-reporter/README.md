# PM v2 OOReporter

UMA-owned Managed Optimistic Oracle requester and raw outcome source for prediction market request IDs.

This package is intended to pair with a market-side requester module. The market-side module registers request IDs here,
then either pulls raw UMA outcomes from `OOReporter` or receives an automatic `report(requestId)` callback from
`PolymarketOOReporter`. Payout translation and finalization remain market-side responsibilities.

## Boundary

The market-side module calls:

```solidity
function registerRequest(
    bytes32 requestId,
    bytes32 priceIdentifier,
    bytes calldata requestRules,
    uint64 minimumLiveness,
    uint64 maximumLiveness
) external;

function updateRequestRules(bytes32 requestId, bytes calldata updatedRules) external;

function isRequestResolved(bytes32 requestId) external view returns (bool);

function getRequestResolution(bytes32 requestId) external view returns (int256);
```

`OOReporter` uses `requestId` as the external key. It does not compute, return, expose, or require market-specific question IDs, and it does not accept or store a market initializer. Tuple-based lookups use the original `(priceIdentifier, requestRules)` supplied during registration.

## Deployment Model

Each `OOReporter` deployment exposes one owner-managed request namespace. Enabled requester addresses are expected to
coordinate on request identity within that namespace; the contract does not isolate identical UMA request identities
per requester.

`PolymarketOOReporter` extends the base reporter with an automatic callback to the module that registered the request.
Deploy the base `OOReporter` for pull-only integrations and the Polymarket variant when every enabled requester
implements `IOOReporterModule.report(bytes32)`.

The reporter reserves each `(priceIdentifier, requestRules)` tuple globally across enabled requesters in the
deployment. This prevents two request IDs from pointing at the same UMA request identity. Independent integrations that
need the exact same UMA request identity should use separate reporter deployments; integrations with similar rules can
domain-separate request rules so their UMA request identities differ.

## Responsibilities

`OOReporter` owns:

- requester/module allowlisting;
- UMA oracle initializer allowlisting;
- Managed OO request creation;
- reward, bond, request-specific liveness minimums and target maximums, automatic re-request controls, and manual
  re-request budget controls;
- forwarding request rules updates to the Managed OO for active requests;
- raw UMA settlement storage.

`PolymarketOOReporter` additionally attempts to notify the registering module after storing a final outcome.

The prediction market integration owns:

- deriving the UMA price identifier from the request shape;
- scalar/vector payout translation;
- market-side finalization and admin recovery.

## Request Lifecycle

An enabled requester first calls `registerRequest(...)` with its external `requestId`, UMA price identifier, raw request
rules, and liveness range. Registration requires an internally consistent range that overlaps the Managed OO bounds at
that time. The minimum remains an onchain floor, while the maximum is stored, returned, and emitted as an offchain
initialization target rather than an onchain ceiling. The reporter reserves the `(priceIdentifier, requestRules)` tuple
globally within the deployment so two request IDs cannot point at the same UMA request identity.

An enabled UMA oracle initializer later calls `initializeRequest(requestId, reward, proposalBond, liveness)`. The selected
liveness must be non-zero and at or above the registered minimum, but it may exceed the registered target maximum. The
Managed OO independently enforces its current `minimumDisputeWindow` and technical maximum. Each initialized request
receives the current `defaultRerequestBudget` as its manual re-request budget.

Automatic re-requests are enabled by default and can be disabled or re-enabled by the owner with
`setAutomaticRerequestsEnabled(...)`. The current setting is evaluated when a dispute or P4 settlement callback arrives,
not when the request was initialized or last re-requested. When enabled, the first dispute callback for a request
attempts one replacement without consuming manual re-request budget. Failed attempts and later dispute callbacks open
the manual re-request gate without reverting the dispute. If Managed OO configuration drift invalidates the active
liveness, an automatic replacement can fail and an enabled oracle initializer can recover manually with a valid
liveness above the registered target maximum.

P4 settlements intentionally reset the active request's manual budget to the current default. When automatic re-requests
are enabled, P4 settlements also attempt a replacement without consuming manual budget. Disabled or failed attempts open
the manual re-request gate without reverting the settlement.

An enabled oracle initializer can call `rerequest(requestId, reward, proposalBond, liveness)` while the manual gate is
open and manual budget remains. Manual re-requests can update the active reward, proposal bond, and liveness for the
replacement request. Automatic re-requests reuse the active reward, proposal bond, and liveness. The owner can update
the default budget for future initializations and P4 refreshes with `setDefaultRerequestBudget(...)`, and can adjust an
active unresolved request's current manual budget with `setRequestRerequestBudget(...)`.

Lifecycle events that refer to a specific Managed OO request consistently lead with the external `requestId` and then
the active OO `requestTimestamp` before actor or outcome fields. This keeps initialization, re-request,
re-request-gate, rules-update, and resolution logs easy to correlate after a request has been replaced.

## Bond And Liveness Events

`BondUpdated` and `CustomLivenessUpdated` expose requester-controlled changes to the concrete Managed OO request. Each
request starts with a bond equal to its `finalFee` and custom liveness equal to `0`, so the first update event for each
setting reports that default as its old value.

To reconstruct the effective bond and liveness at proposal time, consumers must combine those events with
`CustomBondSet` and `CustomLivenessSet`. These request-manager overrides take precedence when `proposePriceFor(...)`
applies the proposal settings, even if the requester changed the concrete request afterward.

## Reward Updates And Pre-Proposal Pauses

Any enabled oracle initializer can call `setRequestReward(requestId, newReward)` while the active Managed OO request is
still waiting for a proposal. The caller does not need to be the initializer that created the active request. Increasing
the reward pulls only the delta from the reporter's reward balance; decreasing it, including setting it to zero, refunds
the delta to the reporter or credits a deferred payout if the token transfer fails. The reporter updates its cached
reward before calling Managed OO so callbacks observe the new amount. If the oracle rejects the change, the transaction
reverts the cache update as well; successful changes are reused by later automatic re-requests.

Because enabled initializers can spend the reporter's reward balance, initializer infrastructure should enforce an
operational maximum reward and the reporter should hold only the working balance needed for requests rather than a
treasury balance.

The Managed OO request manager can also update an active reward directly. An increase is funded by the request-manager
caller rather than pulled from the reporter, while a decrease is always refunded or deferred to the original requester
(the reporter). This prevents the request manager from using the reporter's token allowance to pull arbitrary funds.
Managed OO is authoritative after a direct manager update: `getRequest(requestId).reward` can retain its previous value
until `setRequestReward` reads the live oracle reward or a dispute callback synchronizes the refunded reward. The dispute
path updates the cache before attempting an automatic re-request.

Setting a reward to zero does not cancel the request or stop proposals. To pause an abandoned or malformed request before
proposal, the request manager must set its effective proposer whitelist to a real, enabled `AddressWhitelist` with no
members. The reward can then be set to zero to recover its escrow. These calls can be batched through Managed OO
multicall, with the whitelist change first to reduce the proposal race window; no separate cancellation state is
created.

To restore a paused request, an oracle initializer first restores the reward through `setRequestReward` while the empty
whitelist still blocks proposals. The request manager then restores the prior whitelist or sets the custom whitelist to
`address(0)` to return to the default. A `DisabledAddressWhitelist` is permissionless and therefore does not pause a
request, while `address(0)` restores the default whitelist rather than disabling proposals. If the earlier refund was
deferred, the owner must claim it before that balance can fund restoration.

Reward changes are valid only before a proposal. A proposer can still win transaction ordering if its proposal lands
before the pause transaction. Custom proposer whitelists are keyed without the request timestamp and therefore persist
across re-requests for the same requester, identifier, and request rules until explicitly restored.

## Trusted Resolver Dependency

`OOReporter` stores final outcomes only after Managed OO settles the active request and calls `priceSettled(...)` with a
non-P4 price. A P4 settlement attempts a re-request or opens the manual gate instead of finalizing.
Managed OO settlement is intentionally performed by trusted UMA resolver bots rather than permissionless callers. This
lets UMA use short liveness for routine proposals while resolver infrastructure can escalate uncertain requests to
human review before settlement.

If no trusted resolver settles the active request, `isRequestResolved(requestId)` remains false and
`getRequestResolution(requestId)` reverts. Downstream integrations should monitor this resolver dependency and keep any
timeout or administrative recovery path in the market-side module that translates raw UMA outcomes and finalizes markets.

## Oracle Reward Allowance

The reporter pays request rewards from its own reward-currency balance. When its Managed OO allowance is below a
request's reward, `_requestPrice` tops the allowance up to `type(uint256).max` instead of approving per request. This
unbounded approval is intentional: it saves an approval on every subsequent request and re-request, and Managed OO only
pulls each request's committed reward.

The standing allowance keeps the oracle authorized over the reporter's entire reward balance, which is accepted under
the reporter's trust model: the Managed OO address is fixed at initialization (the reporter has no oracle setter), and
it is UMA-governed infrastructure in the same trust domain as this UMA-owned reporter. To bound the impact of an oracle
compromise, operators should fund the reporter with a working reward float rather than a treasury balance.

## Automatic Polymarket Reporting

After storing a non-P4 final outcome, `PolymarketOOReporter` calls `report(requestId)` on the module that registered the
request. The reporter commits its resolved state before making this external call, so the module can read the outcome
during `report`.

The callback is wrapped in `try/catch`. If the call returns without reverting, the reporter emits
`ReportCallbackSucceeded(requestId, reporterModule)`. If the module reverts, Managed OO settlement still succeeds and
the reporter emits `ReportCallbackFailed(requestId, reporterModule)`. The module's permissionless `report(requestId)`
entry point can then be retried separately. P4 settlements, stale callbacks, unknown requests, and already-resolved
requests do not trigger reporting.

The reporter never calls market-side `finalize()`. Any reporting liveness, threshold, payout translation, and
finalization logic remains enforced by the Polymarket V2 contracts.

## Rules Updates

Only the requester that registered a `requestId` can update rules for that request. The reporter does not store update
history itself; it forwards the update to the Managed OO via
`updateRequestRules(priceIdentifier, requestRules, updatedRules)`, which records append-only history keyed by its managed
request id and emits its own `RequestRulesUpdated` event.

Rules updates do not replace the original registered rules or create a new `(priceIdentifier, updatedRules)` reporter
lookup alias. Consumers should use `requestId` as the stable reporter identity and read canonical update history from the
Managed OO using the reporter address plus the original `(priceIdentifier, requestRules)` tuple.

The reporter additionally emits a `RequestRulesUpdated` event carrying the requester-facing `requestId` and updater
address for self-contained logs.

For a registered request, updates can be forwarded before or after Managed OO initialization. The reporter rejects rules
updates after the request has resolved.

## Foundry Dependency Import

Install this repository as a normal Foundry dependency:

```bash
forge install UMAprotocol/managed-oracle
```

With the standard dependency remapping:

```toml
managed-oracle/pm-v2-oo-reporter/=lib/managed-oracle/pm-v2-oo-reporter/src/
```

Consumers can import the reporter from:

```solidity
import {OOReporter} from "managed-oracle/pm-v2-oo-reporter/OOReporter.sol";
import {PolymarketOOReporter} from "managed-oracle/pm-v2-oo-reporter/PolymarketOOReporter.sol";
import {IOOReporter} from "managed-oracle/pm-v2-oo-reporter/interfaces/IOOReporter.sol";
import {IOOReporterModule} from "managed-oracle/pm-v2-oo-reporter/interfaces/IOOReporterModule.sol";
```

Importing only `IOOReporter` does not require OpenZeppelin remappings.

Consumers that compile `OOReporter.sol` must provide compatible remappings for `@openzeppelin/contracts/` and `@openzeppelin/contracts-upgradeable/`; this package does so in `pm-v2-oo-reporter/foundry.toml` via its package-local `lib/openzeppelin-contracts-upgradeable` submodule.

## Deployment

`script/DeployOOReporter.s.sol` deploys the implementation and an initialized ERC1967 proxy. Run it from this package
directory.

The script accepts these environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `MNEMONIC` | Yes | Mnemonic for the deployer wallet (uses derivation index 0). |
| `INITIAL_OWNER` | No | Reporter owner; defaults to the deployer. |
| `OPTIMISTIC_ORACLE` | No on Polygon | Managed Optimistic Oracle V2 address; defaults to the Polygon deployment. Required on other networks. |
| `REWARD_CURRENCY` | No on Polygon | ERC20 reward currency; defaults to bridged USDC.e on Polygon. Required on other networks. |
| `INITIAL_ORACLE_INITIALIZER` | No | Initial enabled oracle initializer; omitted or zero leaves the allowlist empty. |
| `INITIAL_REQUESTER` | No | Initial enabled requester; omitted or zero leaves the allowlist empty. |
| `INITIAL_DEFAULT_REREQUEST_BUDGET` | No | Initial default manual re-request budget; defaults to `5`. |

On Polygon, the default Optimistic Oracle is Managed Optimistic Oracle V2 at
`0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1`, and the default reward currency is bridged USDC.e at
`0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`. Setting either address to the zero address uses the same network default.

### Deploy And Verify On Etherscan

Etherscan is the default verification target. Set an
[Etherscan API key](https://docs.etherscan.io/contract-verification/verify-with-foundry), then deploy with Foundry's
verification flags. If the first downstream integration address is known at deployment time, set it as
`INITIAL_REQUESTER`; otherwise omit that variable and enable the integration after deployment.

```bash
cd pm-v2-oo-reporter

export MNEMONIC="your mnemonic phrase"
export DOWNSTREAM_REQUESTER="first downstream integration address"

INITIAL_REQUESTER="$DOWNSTREAM_REQUESTER" \
forge script script/DeployOOReporter.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Foundry submits both the `OOReporter` implementation and the `ERC1967Proxy` from the broadcast sequence.

### Complete The Authorization Setup

Two independent authorization edges must be configured before a downstream integration can use the reporter:

1. The `OOReporter` proxy must be accepted as a requester by Managed Optimistic Oracle V2. The reporter itself is
   `msg.sender` when it creates or updates Managed OO requests.
2. The downstream integration, such as a Polymarket oracle module, must be enabled as a requester on the `OOReporter`
   proxy so it can register and update reporter requests.

Always configure the proxy address, not the implementation address.

#### Add OOReporter To The Managed OO Requester Whitelist

Read the active requester whitelist from the configured Managed OO and check whether it is enabled and whether it
already accepts the reporter:

```bash
PROXY_ADDRESS="deployed OOReporter proxy address"
OPTIMISTIC_ORACLE="configured Managed Optimistic Oracle V2 address"

MOO_REQUESTER_WHITELIST=$(cast call "$OPTIMISTIC_ORACLE" \
  "requesterWhitelist()(address)" \
  --rpc-url "$RPC_URL")

cast call "$MOO_REQUESTER_WHITELIST" \
  "isWhitelistEnabled()(bool)" \
  --rpc-url "$RPC_URL"

cast call "$MOO_REQUESTER_WHITELIST" \
  "isOnWhitelist(address)(bool)" \
  "$PROXY_ADDRESS" \
  --rpc-url "$RPC_URL"
```

If the whitelist is enabled and `isOnWhitelist` returns `false`, identify the owner of the standard Managed OO
requester whitelist:

```bash
cast call "$MOO_REQUESTER_WHITELIST" \
  "owner()(address)" \
  --rpc-url "$RPC_URL"
```

That owner must execute:

```bash
cast send "$MOO_REQUESTER_WHITELIST" \
  "addToWhitelist(address)" \
  "$PROXY_ADDRESS" \
  --rpc-url "$RPC_URL" \
  --mnemonic "$MNEMONIC"
```

If the whitelist owner is a multisig or governance contract, submit the same `addToWhitelist(address)` call through
that owner instead. No transaction is required when `isOnWhitelist` already returns `true`, including deployments that
use a disabled requester whitelist.

#### Enable A Downstream OOReporter Requester

Passing `INITIAL_REQUESTER` to the deployment script enables one downstream requester atomically during proxy
initialization. Confirm its status with:

```bash
cast call "$PROXY_ADDRESS" \
  "isRequester(address)(bool)" \
  "$DOWNSTREAM_REQUESTER" \
  --rpc-url "$RPC_URL"
```

If it was not set during deployment, or another downstream integration must be added later, the `OOReporter` owner must
execute:

```bash
cast send "$PROXY_ADDRESS" \
  "setRequesterEnabled(address,bool)" \
  "$DOWNSTREAM_REQUESTER" \
  true \
  --rpc-url "$RPC_URL" \
  --mnemonic "$MNEMONIC"
```

When `INITIAL_OWNER` differs from the deployer or is a multisig, this call must be sent by that configured owner.
`INITIAL_REQUESTER` is distinct from `INITIAL_ORACLE_INITIALIZER`: a requester registers and updates reporter requests,
while an oracle initializer creates the corresponding Managed OO requests.

If the deployment was broadcast without `--verify`, recover the exact addresses and proxy initialization calldata from
the broadcast artifact and verify both contracts separately:

```bash
CHAIN_ID=137
BROADCAST_PATH="broadcast/DeployOOReporter.s.sol/${CHAIN_ID}/run-latest.json"

IMPLEMENTATION_ADDRESS=$(jq -r \
  '.transactions[] | select(.contractName == "OOReporter") | .contractAddress' \
  "$BROADCAST_PATH")
PROXY_ADDRESS=$(jq -r \
  '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' \
  "$BROADCAST_PATH")
INIT_DATA=$(jq -r \
  '.transactions[] | select(.contractName == "ERC1967Proxy") | .arguments[1]' \
  "$BROADCAST_PATH")
PROXY_CONSTRUCTOR_ARGS=$(cast abi-encode \
  "constructor(address,bytes)" \
  "$IMPLEMENTATION_ADDRESS" \
  "$INIT_DATA")

forge verify-contract "$IMPLEMENTATION_ADDRESS" \
  src/OOReporter.sol:OOReporter \
  --chain "$CHAIN_ID" \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch

forge verify-contract "$PROXY_ADDRESS" \
  lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --chain "$CHAIN_ID" \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args "$PROXY_CONSTRUCTOR_ARGS" \
  --watch
```

Both contracts must be verified: the implementation provides the application source and ABI, while the proxy provides
the deployed entrypoint and ERC1967 implementation linkage.

### Tenderly Virtual TestNet

Use the same deployment or post-deployment verification flow, with only these changes:

- Set `RPC_URL` to the Tenderly Virtual TestNet RPC URL.
- Set `TENDERLY_VERIFIER_URL="${RPC_URL%/}/verify"`; the suffix must be exactly `/verify`.
- Replace `--verifier etherscan` with `--verifier custom`.
- Replace `--etherscan-api-key "$ETHERSCAN_API_KEY"` with
  `--verifier-url "$TENDERLY_VERIFIER_URL"`.
- Omit `--chain "$CHAIN_ID"` from post-deployment `forge verify-contract` calls.

The Virtual TestNet RPC URL authenticates the verifier, so no separate Tenderly access key is required. Tenderly also
requires the implementation and proxy to be verified separately for proxy-aware ABI decoding. See Tenderly's
[deployment verification](https://docs.tenderly.co/virtual-environments/develop/deploy-contracts) and
[proxy verification](https://docs.tenderly.co/virtual-environments/develop/verify-proxy-contracts) documentation.

## Build And Test

From the managed-oracle repository root:

```bash
cd pm-v2-oo-reporter && forge test
```

The package enables the Solidity optimizer with 200 runs so both reporter implementations remain comfortably below
the EIP-170 deployed bytecode limit.
