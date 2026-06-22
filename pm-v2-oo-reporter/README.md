# PM v2 OOReporter

UMA-owned Managed Optimistic Oracle requester and raw outcome source for Polymarket v2 request IDs.

This package is intended to pair with the Polymarket v2 `OOReporterModule` shared separately at https://github.com/UMAprotocol/polymarket-v2/blob/oo-reporter-module/src/oracle/modules/OOReporterModule.sol. The Polymarket-side module registers request IDs here, then later pulls raw UMA outcomes for Polymarket-owned payout translation and aggregator finalization.

## Boundary

The PM v2 module calls:

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

`OOReporter` uses `requestId` as the external key. It does not compute, return, expose, or require a Polymarket `questionId`, and it does not accept or store `marketInitializer`.

## Responsibilities

`OOReporter` owns:

- requester/module allowlisting;
- UMA oracle initializer allowlisting;
- Managed OO request creation;
- reward, bond, request-specific liveness bounds, and re-request budget controls;
- request rules update history for active requests;
- raw UMA settlement storage.

Polymarket v2 owns:

- deriving the UMA price identifier from the request shape;
- scalar/vector payout translation;
- PM aggregator finalization and admin recovery.

## Request Lifecycle

An enabled requester first calls `registerRequest(...)` with its external `requestId`, UMA price identifier, raw request rules, and allowed liveness range. The reporter reserves the `(priceIdentifier, requestRules)` tuple globally so two request IDs cannot point at the same UMA request identity.

An enabled UMA oracle initializer later calls `initializeRequest(requestId, reward, proposalBond, liveness)`. The selected liveness must be non-zero and inside the registered range. Each initialized request receives the current `defaultRerequestBudget`.

Dispute callbacks and P4 settlements do not create replacement requests automatically. They open the re-request gate and emit `RequestRerequestAllowed`. An enabled UMA oracle initializer can then call `rerequest(requestId, reward)` while budget remains. A P4 settlement on the active request resets the remaining re-request budget to the current default before opening the gate.

The owner can update the default budget for future initializations with `setDefaultRerequestBudget(...)`, and can top up or reduce an active unresolved request with `setRequestRerequestBudget(...)`.

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

The implementation also imports OpenZeppelin v5 contracts and upgradeable contracts, so the consuming repository must provide compatible remappings for `@openzeppelin/contracts/` and `@openzeppelin/contracts-upgradeable/`.

## Build And Test

From the managed-oracle repository root:

```bash
cd pm-v2-oo-reporter && forge test --match-path test/OOReporter.t.sol
```
