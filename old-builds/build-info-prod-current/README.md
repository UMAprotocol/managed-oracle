# Current production storage-layout reference

`df0e71094fbc248e.json` is a contract-focused reconstruction of the source and storage layout for the
implementation currently used by the Polygon ManagedOptimisticOracleV2 proxy:

- implementation: `0x7d660195eD02AC61A42408780233F06dDd6A2E42`
- source commit: `5fffebba9e3fecee6d6850dc4cc53f37647a6659`
- Solidity: 0.8.30
- EVM: Prague
- optimizer: enabled, 200 runs
- via IR: false
- file SHA-256: `91a49705c7f94b5fdd849aacd07e3efc0a77b8d7cdb7f94db9face918ad8529d`

The reconstructed runtime is 24,323 bytes and matches the live executable runtime after accounting for the
UUPS self-address immutable; only the final IPFS metadata hash differs. The production checks pin the raw live
runtime code hash independently. This file is retained as the immutable OpenZeppelin storage-layout reference.
The target build uses the compiler settings pinned in the root `foundry.toml`; the two builds do not need
identical optimizer settings for storage-layout validation.
