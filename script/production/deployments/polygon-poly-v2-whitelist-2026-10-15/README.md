# Polygon Polymarket V2 custom whitelist

Deployed and configured on 2026-10-15 on Polygon (chain ID 137).
This is a request-specific proposer whitelist for the initializer's atomic
AccessManager path. It does not replace the ManagedOO default whitelist.

| Contract | Address |
|---|---|
| Custom AddressWhitelist | `0x0044C7b41206A4EB4183C1b37D6Ba65261173c42` |
| Owner and only member: SignedProposer proxy | `0x632dA7EcAD445C090DaFe1B03c24c113bD0edD13` |
| SignedProposer implementation at verification | `0x1307Ce44A51AF6D84AD2e346D7655f1B7D20D856` |
| AccessManager | `0xfa6f0Ff6c719001Cba691Ff12CeaA9c49aCDCb66` |
| ManagedOptimisticOracleV2 | `0x2C0367a9DB231dDeBd88a94b4f6461a6e47C58B1` |
| OOReporter proxy | `0x53703Dd6129d723066b6362510E5aE2fECd48218` |

## Executed transactions

All three receipts succeeded. Ownership transfer is immediate; no acceptance
transaction is required. The deployer was
`0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D`.

| Operation | Nonce | Block | Transaction |
|---|---|---|---|
| Deploy AddressWhitelist | 14944 | 95570673 | [Receipt](https://polygonscan.com/tx/0x7b8b4a1c5f5ff149cf84af9d1323892ff82d9d5202a67eee862a1b3cc13870b4) |
| Add SignedProposer proxy | 14945 | 95570755 | [Receipt](https://polygonscan.com/tx/0x5658e6d4e666d14d6afe29e6e156a9ed4d6f1fc82e8af8760ae9d929d2fa302f) |
| Transfer ownership to proxy | 14946 | 95570769 | [Receipt](https://polygonscan.com/tx/0x9ad99421fdcc1126ef7a2bf69f6d9a81199d4d5cb81f24167bc15e1e7bf7377d) |

[deployment.json](deployment.json) records receipt block hashes and logs,
configuration calldata, source revisions, compiler settings and verified state.
At block `95573288` (`0xfa7f5ccfc98241b34e95586909c3606e6a7473a1bf142f1938de59541598dd9c`),
`owner()` and `getWhitelist()` returned the proxy above and a one-element list,
respectively; `isWhitelistEnabled()` returned `true`. Thus the implementation
address is not a member. The deployed runtime exactly matched the pinned build,
including metadata; its Keccak-256 is `0x086f94e78f61895eb3b08f67be1b92989ff5b7e233abdaca63e7217ce2f2a7e7`.

## Build and implementation provenance

The whitelist was compiled from managed-oracle commit
`886c23b88e7210dc3eac16f03a900ac36811862d`, contract
`src/common/implementation/AddressWhitelist.sol:AddressWhitelist`, with no
constructor arguments. Solidity 0.8.30, Prague, optimizer runs 1 and viaIR were
used with the dependency revisions recorded in `deployment.json`. Compiler
remappings are recorded in `deployment.json`; changing remappings can change metadata hashes.

[verified-code-pins.json](verified-code-pins.json) records the AccessManager
runtime pin and the effective SignedProposer implementation runtime pin.
[bytecode-reproduction.json](bytecode-reproduction.json) includes the exact
compiler settings and immutable offsets; [reviewed-source-provenance.json](reviewed-source-provenance.json)
contains source hashes and matching revisions. The two `*-standard-input.json`
files retain the verified source closures and compiler inputs. Compile them
with Solidity `0.8.30+commit.73712a01` using standard JSON, requesting deployed
bytecode and immutable references; for SignedProposer, fill the two documented
`__self` locations with the implementation address before comparing the entire
runtime, including metadata, with `eth_getCode` at the recorded block.

AccessManager matches canonical OpenZeppelin Contracts v5.6.1; it is outside
the UMA-specific OOReporter/SignedProposer diff audit. SignedProposer matches
release `24a5930ba82bb9a91fb3251d8d7ff243b5d95a7a` and the reviewed PR79 fixes.
The [audit](https://audits.openzeppelin.com/risk-labs/uma-26-retainer-01-ooreporter-consolidation-and-signedproposer-batching)
resolved N-03/N-04; L-05 remains acknowledged under the trusted relayer model.
These checks establish deployment provenance, not a new integration audit.

## Initializer handoff

The compatible initializer in [MCP-OTB PR2540](https://github.com/UMAprotocol/mcp-otb/pull/2540)
assigns this custom whitelist and initializes each request through
AccessManager in one transaction. The existing initializer HSM is
`0x2964a637fEaeA99edf573087E8C3C0C1917D553C`; the permissions batch maps role 11 to the
ManagedOO whitelist selector and role 12 to OOReporter initialization.
The configured proposer API relayer is
`0xE6018D3913ff69ce30C467144442ba3E57cE3743`.

Before activation, verify that the Safe authorization of AccessManager in
OOReporter and the selector-role batch have executed, recheck the effective
implementation and pins, release the compatible initializer, and stop/drain
old direct initialization transactions before recording the inclusive
`HISTORICAL_DIRECT_MAX_BLOCK`. The deployment receipts here do not establish
that those separate governance or runtime steps have completed. This record
neither assigns the whitelist to existing requests nor activates the worker.
