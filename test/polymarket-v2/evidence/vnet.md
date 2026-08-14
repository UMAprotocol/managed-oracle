# Staging VNet validation evidence

- Validation date: 2026-08-05
- Chain ID: 137
- Pinned block: 88,102,756
- Pinned block hash: `0xe54e07757df3e49f3bfa531d525c63c7cef14c0219a6742845796461f4a5b6a2`
- Fixture request ID: `0x018804eed8e0a0aaae200582e434c0b4f5000000000000000000000000000000`
- Execution: deterministic Forge-local fork; no VNet transaction submitted

## Automated result

`PolymarketV2VNetWiringForkTest`: 3 passed.

- Exact snapshot hash, five proxy/implementation first-code blocks, five current implementation
  activation blocks, and first-code blocks for the reward token and both whitelists.
- Runtime hashes, UUPS/slots, owners, upgrade authorities, bindings, allowlists, role hierarchy,
  operational roles, and binary resolver permission.
- Unauthorized aggregator initialization rejected.

`PolymarketV2EndToEndForkTest`: 2 passed.

- Full registration → UMA initialization → proposal → settlement → automatic callback →
  Polymarket proposal/finalization → binary payout path.
- Independent unauthorized-initialization regression.

The final binary result was `[1_000_000, 0]`. Forge locally supplied the 500 USDC.e bond plus final
fee; no remote balance changed.

The BinaryModule's current implementation slot was restored by the VNet configuration at block
87,924,763 without an `Upgraded` event. The history check pins that exact state transition rather
than presenting it as a normal production upgrade.

## Event evidence

The E2E test captured and decoded Managed OO request/proposal/settlement, OOReporter
registration/initialization/resolution/callback, module request/result, and aggregator
initialization/vote/proposal/resolution events. It asserts their request IDs, actors, identifier,
rules, liveness, reward/bond, timestamps, prices, payout, result arrays/hashes, votes, and resolver.
The reusable field table is in `../README.md`.

There is no transaction hash by design: every state transition and log was produced inside the
local Forge EVM and discarded after the test.
