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

`OOReporter` uses `requestId` as the external key. It does not compute, return, expose, or require market-specific question IDs, and it does not accept or store a market initializer.

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
- request rules update history for active requests;
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
automatically creates one replacement request without consuming manual re-request budget. Later dispute callbacks open
the manual re-request gate and emit `RequestRerequestAllowed`.

P4 settlements intentionally reset the active request's manual budget to the current default. When automatic re-requests
are enabled, P4 settlements also create a replacement request without consuming manual budget. When automatic
re-requests are disabled, P4 settlements open the manual re-request gate instead so UMA-controlled oracle initializers can
continue recovery.

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
non-P4 price. A P4 settlement re-requests instead of finalizing.
Managed OO settlement is intentionally performed by trusted UMA resolver bots rather than permissionless callers. This
lets UMA use short liveness for routine proposals while resolver infrastructure can escalate uncertain requests to
human review before settlement.

If no trusted resolver settles the active request, `isRequestResolved(requestId)` remains false and
`getRequestResolution(requestId)` reverts. Downstream integrations should monitor this resolver dependency and keep any
timeout or administrative recovery path in the market-side module that translates raw UMA outcomes and finalizes markets.

## Rules Updates

Only the requester that registered a `requestId` can update rules for that request. Rules updates are stored as:

```solidity
struct RequestRulesUpdate {
    uint256 timestamp;
    bytes updatedRules;
}
```

The rules update event includes the updater address for self-contained logs. Stored attribution is derivable from `getRequest(requestId).requester`.

Rules updates are rejected after the request has resolved.

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
