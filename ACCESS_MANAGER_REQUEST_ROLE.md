# AccessManager for Managed OO Request Operations

## Problem

The Managed OO needs a stable address holding `REQUEST_MANAGER_ROLE`, while operational keys must remain replaceable.

Granting the role directly to an EOA or HSM key creates operational risks:

- Rotating a compromised or expired key requires changing the Managed OO role holder.
- Automated operations depend on one privileged key.
- The key receives every permission associated with the role.
- Administrative and operational responsibilities are not separated.

## Proposed Solution

Use OpenZeppelin [`AccessManager`](https://docs.openzeppelin.com/contracts/5.x/access-control#access-management) as
the holder of `REQUEST_MANAGER_ROLE`.

```text
Admin multisig
    └── manages operator roles
            └── Operator EOA/HSM
                    └── AccessManager.execute(...)
                            └── Managed OO
```

The admin assigns a restricted operator role to backend EOAs or HSM keys. Operators call the Managed OO through
`AccessManager.execute`, so the Managed OO sees `AccessManager` as `msg.sender`.

The operator role is restricted to the four request-manager functions:

- `requestManagerSetReward`
- `requestManagerSetBond`
- `requestManagerSetCustomLiveness`
- `requestManagerSetProposerWhitelist`

## Why AccessManager Fits

- **Stable identity:** The Managed OO role remains assigned to one contract address.
- **Key rotation:** Operators can be added or revoked without changing the Managed OO role holder.
- **Least privilege:** Permissions are scoped by target contract and function selector.
- **Admin separation:** A multisig controls permissions without signing routine operations.
- **Batching:** Multiple authorized calls can be submitted through `AccessManager.multicall`.
- **No Managed OO changes:** The existing `AccessControl` checks continue to work.
- **Existing dependency:** OpenZeppelin `AccessManager` is already available in the repository.

## Proof of Concept

The current proof of concept verifies that:

- `AccessManager` can hold `REQUEST_MANAGER_ROLE`.
- An authorized EOA can execute request-manager operations through it.
- Unconfigured function selectors are rejected.
- Operator keys can be rotated.
- Multiple request updates can be batched.

The tests exercise liveness, bond, and proposer-whitelist updates end-to-end. The reward selector is configured but
still needs an end-to-end test because reward increases require `AccessManager` to hold and approve the relevant ERC20
token.

## DSProxy Comparison

DSProxy was considered, but its generic `execute` function uses `delegatecall`. DSGuard authorizes the outer proxy call
and cannot safely restrict the embedded target and calldata by itself.

Giving an operator access to the generic DSProxy execution function would therefore provide broader authority than
required. Making it safe would require an additional action contract or custom authorization layer.

`AccessManager` provides the required target-and-selector authorization directly, with less custom code and a smaller
security surface.
