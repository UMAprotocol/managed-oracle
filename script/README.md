# Deployment Scripts

This directory contains Foundry deployment scripts for the managed-oracle contracts.

## Setup

1. **Create `.env` file** in the project root:
```bash
cp env.example .env
vi .env
```

2. **Configure your variables** in the `.env` file:
```bash
MNEMONIC="your mnemonic phrase here"
IS_ENFORCED="true"  # Optional
NEW_OWNER="0x1234567890123456789012345678901234567890"  # Optional
```

3. **Deploy** using the command line:
```bash
forge script script/DeployDisableableAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast
```

## DisableableAddressWhitelist Deployment

The `DeployDisableableAddressWhitelist.s.sol` script deploys the `DisableableAddressWhitelist` contract with optional configuration.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `MNEMONIC` | Yes | The mnemonic phrase for the deployer wallet (uses 0 index address) |
| `IS_ENFORCED` | No | If set to "true", enables whitelist enforcement (default: false) |
| `NEW_OWNER` | No | If set, transfers ownership to this address |

### Usage Examples

```bash
forge script script/DeployDisableableAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast
```

### Features

- **Automatic deployment**: Deploys the `DisableableAddressWhitelist` contract
- **Configurable enforcement**: Optionally enables whitelist enforcement via `IS_ENFORCED`
- **Ownership transfer**: Optionally transfers ownership to a new address via `NEW_OWNER`
- **Detailed logging**: Provides comprehensive deployment information and status updates

### Etherscan Verification

After deployment, verify the contract on Etherscan:

```bash
forge verify-contract <CONTRACT_ADDRESS> src/common/implementation/DisableableAddressWhitelist.sol:DisableableAddressWhitelist --chain-id <CHAIN_ID> --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

**Replace:**
- `<CONTRACT_ADDRESS>` with the deployed contract address
- `<CHAIN_ID>` with the network chain ID (1 for Ethereum mainnet, 11155111 for Sepolia, etc.)
- `<YOUR_ETHERSCAN_API_KEY>` with your Etherscan API key
```

### Contract Details

The `DisableableAddressWhitelist` contract:
- Inherits from `AddressWhitelist` and `DisableableAddressWhitelistInterface`
- Allows toggling whitelist enforcement on/off
- When enforcement is disabled, all addresses are considered whitelisted
- When enforcement is enabled, only explicitly whitelisted addresses are allowed
- Supports ownership management for administrative functions 