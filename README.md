## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Local Foundry Version (Pinned)

This repo pins Foundry to `1.3.6` via `.tool-versions`. The simplest way to use it per-repo is `mise`.

### Install mise (script)

```shell
$ curl https://mise.run | sh
```

### Install the pinned Foundry toolchain

```shell
$ ~/.local/bin/mise install
```

### Activate mise in your shell

```shell
$ echo 'eval "$(~/.local/bin/mise activate --shims bash)"' >> ~/.bashrc
$ source ~/.bashrc
```

If you prefer not to modify your shell config, run commands through `mise`:

```shell
$ ~/.local/bin/mise exec -- forge -V
$ ~/.local/bin/mise exec -- forge fmt
```

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
