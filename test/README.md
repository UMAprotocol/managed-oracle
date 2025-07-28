# ManagedOptimisticOracleV2 Test Suite

This directory contains comprehensive Foundry tests for the `ManagedOptimisticOracleV2` contract.

## Test Structure

### Main Test Files

1. **`ManagedOptimisticOracleV2.t.sol`** - Core unit tests covering all individual functions and edge cases
2. **`ManagedOptimisticOracleV2Integration.t.sol`** - Integration tests covering complex scenarios and state transitions

### Mock Contracts (`mocks/`)

- **`MockFinder.sol`** - Mock implementation of FinderInterface
- **`MockStore.sol`** - Mock implementation of StoreInterface  
- **`MockOracle.sol`** - Mock implementation of OracleAncillaryInterface
- **`MockIdentifierWhitelist.sol`** - Mock implementation of IdentifierWhitelistInterface
- **`MockCollateralWhitelist.sol`** - Mock implementation extending AddressWhitelist

## Test Coverage

### Core Functionality Tests

#### Initialization
- ✅ Contract initialization with all parameters
- ✅ Revert on double initialization
- ✅ Revert on zero whitelist addresses
- ✅ Proper setup of default values and admin roles

#### Access Control
- ✅ Admin can add/remove request managers
- ✅ Non-admin cannot add/remove request managers
- ✅ Request managers can modify requests
- ✅ Non-request managers cannot modify requests

#### Bond Management
- ✅ Admin can set maximum bonds for currencies
- ✅ Request managers can set custom bonds within limits
- ✅ Revert on bond exceeding maximum
- ✅ Revert on unsupported currency
- ✅ Zero bond handling

#### Liveness Management
- ✅ Admin can set minimum liveness
- ✅ Request managers can set custom liveness within bounds
- ✅ Revert on liveness below minimum
- ✅ Boundary value testing

#### Whitelist Management
- ✅ Admin can update default proposer whitelist
- ✅ Admin can update requester whitelist
- ✅ Request managers can set custom proposer whitelists
- ✅ Revert on zero address whitelists
- ✅ Whitelist enforcement status checking

#### Price Requests
- ✅ Whitelisted requesters can request prices
- ✅ Non-whitelisted requesters cannot request prices
- ✅ Proper bond calculation
- ✅ State transitions

#### Price Proposals
- ✅ Whitelisted proposers can propose prices
- ✅ Non-whitelisted proposers cannot propose prices
- ✅ Custom whitelist enforcement
- ✅ Disabled whitelist scenarios

### Integration Tests

#### Complete Workflows
- ✅ End-to-end price request flow
- ✅ Multiple currencies and request managers
- ✅ Complex whitelist enforcement scenarios
- ✅ State transition sequences

#### Advanced Scenarios
- ✅ Request manager permission management
- ✅ Edge cases and boundary conditions
- ✅ Complex multicall operations
- ✅ Contract upgrade scenarios
- ✅ Gas optimization and stress testing
- ✅ Error handling and recovery

## Running Tests

### Prerequisites
- Foundry installed
- All dependencies installed via `forge install`

### Basic Commands

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vvv

# Run specific test file
forge test --match-contract ManagedOptimisticOracleV2Test

# Run specific test function
forge test --match-test test_Initialize

# Run with gas reporting
forge test --gas-report

# Run with coverage
forge coverage
```

### Test Categories

```bash
# Run only unit tests
forge test --match-contract ManagedOptimisticOracleV2Test

# Run only integration tests  
forge test --match-contract ManagedOptimisticOracleV2IntegrationTest

# Run initialization tests
forge test --match-test test_Initialize

# Run access control tests
forge test --match-test "test_AddRequestManager|test_RemoveRequestManager"

# Run bond management tests
forge test --match-test "test_SetMaximumBond|test_RequestManagerSetBond"
```

## Test Constants

### Addresses
- `admin`: `0x1` - Contract admin
- `requestManager1/2`: `0x2/0x3` - Request managers
- `requester1/2`: `0x4/0x5` - Price requesters
- `proposer1/2`: `0x6/0x7` - Price proposers
- `disputer`: `0x8` - Price disputer

### Values
- `DEFAULT_LIVENESS`: 7200 seconds (2 hours)
- `MINIMUM_LIVENESS`: 3600 seconds (1 hour)
- `MAXIMUM_BOND1/2`: 1000e18/2000e18 tokens
- `FINAL_FEE`: 100e18 tokens
- `REWARD`: 50e18 tokens
- `PROPOSED_PRICE`: 1000

## Mock Contract Usage

### MockFinder
```solidity
// Set implementation addresses
finder.setImplementationAddress("Oracle", address(mockOracle));
finder.setImplementationAddress("Store", address(store));
```

### MockOracle
```solidity
// Set price availability
mockOracle.setHasPrice(identifier, timestamp, ancillaryData, true);

// Set specific price
mockOracle.setPrice(identifier, timestamp, ancillaryData, 1000);
```

### MockWhitelists
```solidity
// Add addresses to whitelists
defaultProposerWhitelist.addToWhitelist(proposer);
requesterWhitelist.addToWhitelist(requester);

// Disable enforcement
defaultProposerWhitelist.setWhitelistEnforcement(false);
```

## State Management

### Request States
- `0` - Invalid (never requested)
- `1` - Requested
- `2` - Proposed
- `3` - Expired
- `4` - Disputed
- `5` - Resolved
- `6` - Settled

### State Transitions
1. **Invalid → Requested**: `requestPrice()`
2. **Requested → Proposed**: `proposePriceFor()`
3. **Proposed → Expired**: Time passes beyond liveness
4. **Proposed → Disputed**: `disputePrice()`
5. **Disputed → Resolved**: Oracle provides price
6. **Expired/Resolved → Settled**: `settle()`

## Error Handling

### Common Error Messages
- `"Requester not whitelisted"` - Non-whitelisted requester
- `"Proposer not whitelisted"` - Non-whitelisted proposer
- `"Bond exceeds maximum bond"` - Bond too high
- `"Liveness is less than minimum"` - Liveness too low
- `"Whitelist cannot be zero address"` - Invalid whitelist
- `"Unsupported currency"` - Currency not in collateral whitelist

## Best Practices

### Test Organization
- Group related tests together
- Use descriptive test names
- Include both positive and negative test cases
- Test boundary conditions
- Verify state changes and events

### Mock Usage
- Keep mocks simple and focused
- Use realistic but minimal implementations
- Document mock behavior clearly
- Avoid complex logic in mocks

### Gas Testing
- Test gas usage for critical functions
- Monitor gas changes across updates
- Test with realistic data sizes
- Consider gas optimization scenarios

## Contributing

When adding new tests:

1. Follow the existing naming conventions
2. Add comprehensive documentation
3. Include both success and failure cases
4. Test edge cases and boundaries
5. Update this README if adding new test categories

## Troubleshooting

### Common Issues

**Test fails with "Initializable: contract is already initialized"**
- Ensure you're not calling initialize twice on the same proxy
- Use separate implementation contracts for different test scenarios

**Test fails with "Requester not whitelisted"**
- Check that the requester address is added to the requester whitelist
- Verify the whitelist is properly deployed and configured

**Test fails with "Bond exceeds maximum bond"**
- Ensure the bond amount is within the maximum bond limit for the currency
- Check that the currency is properly configured in the maximum bonds array

**Mock contract not working as expected**
- Verify the mock contract implements the correct interface
- Check that the mock is properly deployed and configured in the finder
- Ensure the mock functions return the expected values 