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
# Common variables (used by all scripts)
MNEMONIC="your mnemonic phrase here"

# ManagedOptimisticOracleV2-specific variables
FINDER_ADDRESS="0x1234567890123456789012345678901234567890"
DEFAULT_PROPOSER_WHITELIST="0x1234567890123456789012345678901234567890"
REQUESTER_WHITELIST="0x1234567890123456789012345678901234567890"
# CONFIG_ADMIN="0x1234567890123456789012345678901234567890"  # Optional, defaults to deployer
# UPGRADE_ADMIN="0x1234567890123456789012345678901234567890"  # Optional, defaults to deployer
# DEFAULT_LIVENESS="7200"  # Optional, defaults to 7200 (2 hours) if not provided
# MINIMUM_LIVENESS="3600"  # Optional, defaults to 3600 (1 hour) if not provided
# CUSTOM_CURRENCY="" # Optional, defaults to none or USDC.e on Polygon
# MINIMUM_BOND_AMOUNT="100000000" # Optional, defaults to 100 USDC.e on Polygon
# MAXIMUM_BOND_AMOUNT="100000000000" # Optional, defaults to 100,000 USDC.e on Polygon
```

## DisabledAddressWhitelist Deployment

The `DeployDisabledAddressWhitelist.s.sol` script deploys the `DisabledAddressWhitelist` contract with optional configuration.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `MNEMONIC` | Yes | The mnemonic phrase for the deployer wallet (uses 0 index address) |

### Usage Examples

```bash
forge script script/DeployDisabledAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast
```

### Features

- **Automatic deployment**: Deploys the `DisabledAddressWhitelist` contract
- **Detailed logging**: Provides comprehensive deployment information and status updates

### Etherscan Verification

After deployment, verify the contract on Etherscan:

```bash
forge verify-contract <CONTRACT_ADDRESS> src/common/implementation/DisabledAddressWhitelist.sol:DisabledAddressWhitelist --chain-id <CHAIN_ID> --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

**Replace:**
- `<CONTRACT_ADDRESS>` with the deployed contract address
- `<CHAIN_ID>` with the network chain ID (1 for Ethereum mainnet, 11155111 for Sepolia, etc.)
- `<YOUR_ETHERSCAN_API_KEY>` with your Etherscan API key

### Contract Details

The `DisabledAddressWhitelist` contract:
- Inherits from `AddressWhitelist` and `DisabledAddressWhitelistInterface`

## ManagedOptimisticOracleV2 Deployment

The `DeployManagedOptimisticOracleV2.s.sol` script deploys the `ManagedOptimisticOracleV2` contract with proxy using OpenZeppelin Upgrades library.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `MNEMONIC` | Yes | The mnemonic phrase for the deployer wallet (uses 0 index address) |
| `FINDER_ADDRESS` | No* | Address of the Finder contract. If not provided, uses network-specific defaults (see below) |
| `DEFAULT_PROPOSER_WHITELIST` | Yes | Address of the default proposer whitelist |
| `REQUESTER_WHITELIST` | Yes | Address of the requester whitelist |
| `CONFIG_ADMIN` | No | Address of the config admin (defaults to deployer if not provided) |
| `UPGRADE_ADMIN` | No | Address of the upgrade admin (defaults to deployer if not provided) |
| `DEFAULT_LIVENESS` | No | Default liveness period in seconds (defaults to 7200 if not provided) |
| `MINIMUM_LIVENESS` | No | Minimum liveness period in seconds (defaults to 3600 if not provided) |
| `CUSTOM_CURRENCY` | No | Address of the custom currency (defaults to none or USDC.e on Polygon) |
| `MINIMUM_BOND_AMOUNT` | No | Minimum raw bond amount (defaults to 100 USDC.e on Polygon) |
| `MAXIMUM_BOND_AMOUNT` | No | Maximum raw bond amount (defaults to 100,000 USDC.e on Polygon) |

### Default Finder Addresses

The following networks have default Finder addresses that will be used if `FINDER_ADDRESS` is not provided:

| Network | Chain ID | Default Finder Address |
|---------|----------|----------------------|
| Sepolia | 11155111 | `0xf4C48eDAd256326086AEfbd1A53e1896815F8f13` |
| Amoy | 80002 | `0x28077B47Cd03326De7838926A63699849DD4fa87` |
| Ethereum Mainnet | 1 | `0x40f941E48A552bF496B154Af6bf55725f18D77c3` |
| Polygon Mainnet | 137 | `0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64` |

### Usage Examples

```bash
forge script script/DeployManagedOptimisticOracleV2.s.sol --rpc-url "YOUR_RPC_URL" --broadcast
```

### Features

- **Proxy deployment**: Deploys implementation and proxy using OZ Upgrades
- **UUPS upgradeable**: Uses UUPS (Universal Upgradeable Proxy Standard) pattern
- **Comprehensive initialization**: Sets all required parameters during deployment
- **Detailed logging**: Provides comprehensive deployment information and status updates

### Etherscan Verification

After deployment, verify the proxy contract on Etherscan:

```bash
forge verify-contract <PROXY_ADDRESS> src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2 --chain-id <CHAIN_ID> --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

**Replace:**
- `<PROXY_ADDRESS>` with the deployed proxy contract address
- `<CHAIN_ID>` with the network chain ID (1 for Ethereum mainnet, 11155111 for Sepolia, etc.)
- `<YOUR_ETHERSCAN_API_KEY>` with your Etherscan API key

### Contract Details

The `ManagedOptimisticOracleV2` contract:
- Inherits from `OptimisticOracleV2` and adds management capabilities
- Uses UUPS upgradeable pattern for future upgrades
- Supports role-based access control with config and upgrade admins
- Allows request managers to set custom bonds, liveness, and proposer whitelists
- Enforces maximum bonds and minimum liveness set by admins
- Requires whitelisted requesters and proposers 