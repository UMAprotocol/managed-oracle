# Amoy validation evidence

- Validation date: 2026-08-05
- Chain ID: 80002
- Pinned block: 44,114,794
- Pinned block hash: `0x2cb26d0bccddd8e93324a4f7d49646422caabb098b1a7a5239bba1e1e8a72593`
- Execution: read-only RPC state plus Forge-local authorization call; no transaction submitted

## Automated result

`PolymarketV2AmoyWiringForkTest`: 3 passed against the exact snapshot using an archive-capable
endpoint.

- Snapshot hash, five proxy/implementation deployment and activation histories, plus first-code
  blocks for the reward token and both whitelists.
- Runtime hashes, UUPS/slots, owners, upgrade authorities, bindings, allowlists, role hierarchy,
  admins, two aggregator operators, and Managed OO roles.
- Unauthorized aggregator initialization rejected in the local fork.

## Supported scope and blockers

Amoy cannot run the automatic callback lifecycle because the reporter proxy points to base
`OOReporter`, not `PolymarketOOReporter`. `OOReporterModule` also has no operator selected; its admin
can grant one after the recipient is decided. Finally, the Managed OO deployment has no retained
versioned broadcast/build artifact, so the source mapping is identified as an inference while its
observed block, implementation slot, and code hash remain authoritative.

These blockers do not affect the exact wiring and authorization subset above.
