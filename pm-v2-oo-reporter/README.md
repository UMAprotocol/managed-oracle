# PM v2 OOReporter

UMA-owned Managed Optimistic Oracle requester and raw outcome source for prediction market request IDs.

This package is intended to pair with a market-side requester module. The market-side module registers request IDs here, then later pulls raw UMA outcomes for market-owned payout translation and finalization.

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

The reporter reserves each `(priceIdentifier, requestRules)` tuple globally across enabled requesters in the
deployment. This prevents two request IDs from pointing at the same UMA request identity. Independent integrations that
need the exact same UMA request identity should use separate reporter deployments; integrations with similar rules can
domain-separate request rules so their UMA request identities differ.

## Responsibilities

`OOReporter` owns:

- requester/module allowlisting;
- UMA oracle initializer allowlisting;
- Managed OO request creation;
- reward, bond, request-specific liveness bounds, automatic re-request controls, and manual re-request budget controls;
- forwarding request rules updates to the Managed OO for active requests;
- raw UMA settlement storage.

The prediction market integration owns:

- deriving the UMA price identifier from the request shape;
- scalar/vector payout translation;
- market-side finalization and admin recovery.

## Request Lifecycle

An enabled requester first calls `registerRequest(...)` with its external `requestId`, UMA price identifier, raw request
rules, and allowed liveness range. The reporter reserves the `(priceIdentifier, requestRules)` tuple globally within
the deployment so two request IDs cannot point at the same UMA request identity.

An enabled UMA oracle initializer later calls `initializeRequest(requestId, reward, proposalBond, liveness)`. The selected
liveness must be non-zero and inside the registered range. Each initialized request receives the current
`defaultRerequestBudget` as its manual re-request budget.

Automatic re-requests are enabled by default and can be disabled or re-enabled by the owner with
`setAutomaticRerequestsEnabled(...)`. The current setting is evaluated when a dispute or P4 settlement callback arrives,
not when the request was initialized or last re-requested. When enabled, the first dispute callback for a request
attempts one replacement without consuming manual re-request budget. Failed attempts and later dispute callbacks open
the manual re-request gate without reverting the dispute.

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

## Trusted Resolver Dependency

`OOReporter` stores final outcomes only after Managed OO settles the active request and calls `priceSettled(...)` with a
non-P4 price. A P4 settlement attempts a re-request or opens the manual gate instead of finalizing.
Managed OO settlement is intentionally performed by trusted UMA resolver bots rather than permissionless callers. This
lets UMA use short liveness for routine proposals while resolver infrastructure can escalate uncertain requests to
human review before settlement.

If no trusted resolver settles the active request, `isRequestResolved(requestId)` remains false and
`getRequestResolution(requestId)` reverts. Downstream integrations should monitor this resolver dependency and keep any
timeout or administrative recovery path in the market-side module that translates raw UMA outcomes and finalizes markets.

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
import {IOOReporter} from "managed-oracle/pm-v2-oo-reporter/interfaces/IOOReporter.sol";
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
verification flags:

```bash
cd pm-v2-oo-reporter

MNEMONIC="your mnemonic phrase" forge script script/DeployOOReporter.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --slow \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Foundry submits both the `OOReporter` implementation and the `ERC1967Proxy` from the broadcast sequence.

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
cd pm-v2-oo-reporter && forge test --match-path test/OOReporter.t.sol
```
