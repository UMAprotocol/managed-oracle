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

# AddressWhitelist-specific variables
# WHITELIST_OWNER="0x1234567890123456789012345678901234567890"  # Optional, defaults to deployer

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

## AddressWhitelist Deployment

The `DeployAddressWhitelist.s.sol` script deploys the `AddressWhitelist` contract with configurable ownership.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `MNEMONIC` | Yes | The mnemonic phrase for the deployer wallet (uses 0 index address) |
| `WHITELIST_OWNER` | No | The address to set as owner. If not set, uses deployer address. If set to 0x0000000000000000000000000000000000000000, burns ownership. |

### Usage Examples

```bash
# Deploy with deployer as owner (WHITELIST_OWNER not set)
forge script script/DeployAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast

# Deploy and burn ownership to zero address
WHITELIST_OWNER=0x0000000000000000000000000000000000000000 forge script script/DeployAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast

# Deploy and transfer ownership to specific address
WHITELIST_OWNER=0x1234567890123456789012345678901234567890 forge script script/DeployAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast
```

### Features

- **Configurable ownership**: Supports setting custom owner or burning ownership
- **Automatic deployment**: Deploys the `AddressWhitelist` contract
- **Detailed logging**: Provides comprehensive deployment information and status updates

### Etherscan Verification

After deployment, verify the contract on Etherscan:

```bash
forge verify-contract <CONTRACT_ADDRESS> src/common/implementation/AddressWhitelist.sol:AddressWhitelist --chain-id <CHAIN_ID> --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

**Replace:**
- `<CONTRACT_ADDRESS>` with the deployed contract address
- `<CHAIN_ID>` with the network chain ID (1 for Ethereum mainnet, 11155111 for Sepolia, etc.)
- `<YOUR_ETHERSCAN_API_KEY>` with your Etherscan API key

### Contract Details

The `AddressWhitelist` contract:
- Inherits from `AddressWhitelistInterface`, `Ownable`, `Lockable`, and `ERC165`
- Supports adding/removing addresses from whitelist
- Includes ownership management capabilities

## AddressWhitelist Redeployment

The `RedeployAddressWhitelist.s.sol` script deploys a new `AddressWhitelist` contract that duplicates the configuration from a previously deployed contract.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `MNEMONIC` | Yes | The mnemonic phrase for the deployer wallet (uses 0 index address) |
| `PREVIOUS_ADDRESS_WHITELIST` | Yes | The address of the previous AddressWhitelist contract to duplicate |
| `DEPLOYER_MULTISIG` | No | The address of a Safe multisig to use for batching transactions (requires threshold=1) |
| `MULTISEND_ADDRESS` | No | The address of the MultiSend contract (defaults to MultiSendCallOnly v1.4.1) |

### Usage Examples

```bash
# Redeploy with configuration from previous contract
forge script script/RedeployAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast

# Redeploy using multisig for batching (MULTISEND_ADDRESS optional)
DEPLOYER_MULTISIG=0x1234567890123456789012345678901234567890 forge script script/RedeployAddressWhitelist.s.sol --rpc-url "YOUR_RPC_URL" --broadcast
```

### Features

- **Configuration duplication**: Copies all whitelisted addresses from the previous contract
- **Ownership preservation**: Transfers ownership to the same address if different from deployer
- **Ownership burning**: Burns ownership if the previous contract had no owner
- **Multisig support**: Optional Safe multisig integration for batching transactions atomically
- **Multisig validation**: Validates deployer is a signer and threshold is 1
- **Verification**: Includes verification that the whitelist was copied correctly
- **Detailed logging**: Provides comprehensive redeployment information and status updates

### What Gets Copied

- All whitelisted addresses from the previous contract
- Ownership configuration (same owner or burned ownership) - **both transfer and renounce operations are supported in batch mode**

### What Gets Reset

- Contract address (new deployment)
- Contract state (fresh contract instance)

### Multisig Requirements

When using `DEPLOYER_MULTISIG`, the script validates:

- **Threshold = 1**: The multisig must have a threshold of 1 for single signature execution
- **Deployer as signer**: The deployer address must be a signer of the multisig
**Supported multisig types**: Gnosis Safe (tested and verified)

**Note**: The script uses the MultiSend contract for batching. When using `DEPLOYER_MULTISIG`, the `MULTISEND_ADDRESS` environment variable is optional and defaults to the MultiSendCallOnly v1.4.1 contract address.

**Benefits of multisig batching**:
- **Atomic operations**: All whitelist additions happen in a single transaction
- **Gas efficiency**: Reduces gas costs for large whitelists
- **Better UX**: Single transaction instead of multiple individual transactions
- **Error handling**: If one addition fails, the entire batch is reverted
- **Safe integration**: Uses standard Safe multisig execTransaction with v=1 signature

### Etherscan Verification

After redeployment, verify the new contract on Etherscan:

```bash
forge verify-contract <NEW_CONTRACT_ADDRESS> src/common/implementation/AddressWhitelist.sol:AddressWhitelist --chain-id <CHAIN_ID> --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

**Replace:**
- `<NEW_CONTRACT_ADDRESS>` with the newly deployed contract address
- `<CHAIN_ID>` with the network chain ID (1 for Ethereum mainnet, 11155111 for Sepolia, etc.)
- `<YOUR_ETHERSCAN_API_KEY>` with your Etherscan API key

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
| `CUSTOM_CURRENCY` | No | Address of a custom currency bond range to initialize (defaults to none or USDC.e on Polygon) |
| `MINIMUM_BOND_AMOUNT` | No | Minimum bond amount for the custom currency (defaults to none or 100 USDC.e on Polygon) |
| `MAXIMUM_BOND_AMOUNT` | No | Maximum bond amount for the custom currency (defaults to none or 100,000 USDC.e on Polygon) |

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

After deployment, verify both the implementation and proxy contracts on Etherscan. For UUPS proxies, both contracts need to be verified:

#### 1. Verify Implementation Contract

```bash
forge verify-contract <IMPLEMENTATION_ADDRESS> src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2 --chain-id <CHAIN_ID> --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

#### 2. Verify Proxy Contract

```bash
forge verify-contract <PROXY_ADDRESS> lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --chain-id <CHAIN_ID> --etherscan-api-key <YOUR_ETHERSCAN_API_KEY> --constructor-args $(cast abi-encode "constructor(address,bytes)" <IMPLEMENTATION_ADDRESS> <INITIALIZATION_DATA>)
```

**Replace:**
- `<IMPLEMENTATION_ADDRESS>` with the deployed implementation contract address
- `<PROXY_ADDRESS>` with the deployed proxy contract address
- `<CHAIN_ID>` with the network chain ID (1 for Ethereum mainnet, 11155111 for Sepolia, etc.)
- `<YOUR_ETHERSCAN_API_KEY>` with your Etherscan API key
- `<IMPLEMENTATION_ADDRESS>` with the address of the implementation contract
- `<INITIALIZATION_DATA>` with the encoded initialization data for the proxy constructor

#### Example for Polygon (Chain ID 137)

Based on the latest deployment:
- Implementation: `0x3555e39a1264f5f8febc129ebbb909f3ea299936`
- Proxy: `0x2c0367a9db231ddebd88a94b4f6461a6e47c58b1`

```bash
# Verify implementation
forge verify-contract 0x3555e39a1264f5f8febc129ebbb909f3ea299936 src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol:ManagedOptimisticOracleV2 --chain-id 137 --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>

# Verify proxy (constructor args from deployment)
forge verify-contract 0x2c0367a9db231ddebd88a94b4f6461a6e47c58b1 lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --chain-id 137 --etherscan-api-key <YOUR_ETHERSCAN_API_KEY> --constructor-args $(cast abi-encode "constructor(address,bytes)" 0x3555e39A1264f5f8Febc129eBBb909F3Ea299936 0xcdb21cc60000000000000000000000000000000000000000000000000000000000001c2000000000000000000000000009aea4b2242abc8bb4bb78d537a67a245a7bec640000000000000000000000009f35885ce8f67a942d7b2f4fbf937987da08c4630000000000000000000000000f79d0039956d58a7d5d006a6dd64a35616aa2c600000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000e100000000000000000000000003dce0a29139a851da1dfca56af8e8a6440b4d9520000000000000000000000007fb4492ff58e4326a99d7d4f66ae1f47c8286fc600000000000000000000000000000000000000000000000000000000000000010000000000000000000000002791bca1f2de4661ed88a30c99a7a9449aa841740000000000000000000000000000000000000000000000000000000005f5e100000000000000000000000000000000000000000000000000000000174876e800)
```

**Note:** The initialization data can be extracted from the deployment broadcast file as the second element in the `arguments` array for the `ERC1967Proxy` deployment transaction.

### Contract Details

The `ManagedOptimisticOracleV2` contract:
- Inherits from `OptimisticOracleV2` and adds management capabilities
- Uses UUPS upgradeable pattern for future upgrades
- Supports role-based access control with config and upgrade admins
- Allows request managers to set custom bonds, liveness, and proposer whitelists
- Enforces maximum bonds and minimum liveness set by admins
- Requires whitelisted requesters and proposers 