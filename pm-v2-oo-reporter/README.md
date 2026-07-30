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

## Reward Updates And Pre-Proposal Pauses

Any enabled oracle initializer can call `setRequestReward(requestId, newReward)` while the active Managed OO request is
still waiting for a proposal. The caller does not need to be the initializer that created the active request. Increasing
the reward pulls only the delta from the reporter's reward balance; decreasing it, including setting it to zero, refunds
the delta to the reporter or credits a deferred payout if the token transfer fails. The reporter updates its cached
reward only after Managed OO accepts the change, so later automatic re-requests reuse the updated amount.

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

## Build And Test

From the managed-oracle repository root:

```bash
cd pm-v2-oo-reporter && forge test --match-path test/OOReporter.t.sol
```
