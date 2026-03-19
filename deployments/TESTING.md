# Integration Testing - Base Sepolia Deployment

## Deployed Contracts

- **Network**: Base Sepolia (Chain ID: 84532)
- **ACTPKernel**: `0x469CBADbACFFE096270594F0a31f0EEC53753411`
- **EscrowVault**: `0x57f888261b629bB380dfb983f5DA6c70Ff2D49E5`
- **MockUSDC**: `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb`

## E2E Test Results

| Date | Test | Tx Hash | Result |
|------|------|---------|--------|
| 2026-02-10 | Testnet init (register + mint, gasless) | [`0x6e51c8f8...`](https://sepolia.basescan.org/tx/0x6e51c8f8739a6de8e387257f6fead8cf139644bea487e261cdbd595bd6c55d7c) | PASS |
| 2026-02-06 | ERC-8004 agentId integration | [`0xbb21f36d...`](https://sepolia.basescan.org/tx/0xbb21f36d574cc228b486d33f20e18e7ef0df09bf14a99d19d2ad91019bf5b9b9) | PASS |

**Details (2026-02-10)**:
- Smart Wallet deployed + AgentRegistered + 1000 USDC minted in ONE gasless UserOp
- Block: `37491140`
- Smart Wallet: `0xb5990B86a8913389A8f12B5AcEe086502bD10610`
- Root cause fix: Sepolia ACTPKernel (pre-v2) lacks `requesterNonces` — DualNonceManager now handles gracefully

**Details (2026-02-06)**:
- Transaction ID: `0x5596a895918e9d28e8f93abd6466de1d290e080294fc6b0dedd511dbaa9ef0b7`
- agentId: `12345` (0x3039 hex) verified in TransactionCreated event data
- Block: `37306522`
- Amount: 0.10 USDC (100000 wei)
- State reached: COMMITTED

---

## Prerequisites

1. **Install SDK dependencies**:
   ```bash
   cd "sdk-js"
   npm install
   ```

2. **Set up test wallet** with Base Sepolia ETH:
   - Get testnet ETH from: https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet
   - Or bridge from Sepolia: https://bridge.base.org/deposit

3. **Create `.env` file** in SDK directory:
   ```bash
   cd "sdk-js"
   cat > .env << 'EOF'
   # Test wallet private key (DO NOT use real funds!)
   PRIVATE_KEY=0x...your-test-wallet-private-key...

   # Base Sepolia RPC
   BASE_SEPOLIA_RPC=https://sepolia.base.org

   # Deployed contract addresses (already in networks.ts)
   ACTP_KERNEL=0x469CBADbACFFE096270594F0a31f0EEC53753411
   ESCROW_VAULT=0x57f888261b629bB380dfb983f5DA6c70Ff2D49E5
   MOCK_USDC=0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb

   # Deployed contract addresses (already in networks.ts)
   EOF
   ```

---

## Quick Sanity Test

### 1. Check Contract Deployment

```bash
# Check if ACTPKernel is deployed
cast code 0x469CBADbACFFE096270594F0a31f0EEC53753411 --rpc-url https://sepolia.base.org

# Should return bytecode (not 0x)
# If returns "0x" → Contract not deployed or wrong address
```

### 2. Check Contract State

```bash
# Read public variables from ACTPKernel
cast call 0x469CBADbACFFE096270594F0a31f0EEC53753411 "admin()(address)" --rpc-url https://sepolia.base.org

cast call 0x469CBADbACFFE096270594F0a31f0EEC53753411 "paused()(bool)" --rpc-url https://sepolia.base.org

cast call 0x469CBADbACFFE096270594F0a31f0EEC53753411 "platformFeeBps()(uint16)" --rpc-url https://sepolia.base.org
```

### 3. Check EscrowVault Link

```bash
# Check if EscrowVault knows about Kernel
cast call 0x57f888261b629bB380dfb983f5DA6c70Ff2D49E5 "kernel()(address)" --rpc-url https://sepolia.base.org

# Should return ACTPKernel address: 0x469CBADbACFFE096270594F0a31f0EEC53753411
```

### 4. Check MockUSDC

```bash
# Get USDC name
cast call 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb "name()(string)" --rpc-url https://sepolia.base.org

# Get USDC decimals
cast call 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb "decimals()(uint8)" --rpc-url https://sepolia.base.org
```

---

## SDK Integration Tests

### Build SDK First

```bash
cd "sdk-js"
npm run build
```

### Run Integration Tests

```bash
# Run all integration tests against deployed contracts
npm run test:integration

# Or run specific test file
npm test -- test/integration/createTransaction.test.ts
```

---

## Manual End-to-End Test

Create a test script to verify the full workflow:

```typescript
// test-deployment.ts
import { ethers } from 'ethers';
import { ACTPClient } from './src/ACTPClient';

async function testDeployment() {
  // Connect to Base Sepolia
  const provider = new ethers.providers.JsonRpcProvider('https://sepolia.base.org');
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

  console.log('🔗 Testing Base Sepolia deployment...');
  console.log('📍 Wallet:', wallet.address);

  // Initialize ACTP Client
  const client = await ACTPClient.create({
    network: 'base-sepolia',
    signer: wallet
  });

  console.log('✅ SDK connected to deployed contracts');

  // Check balances
  const ethBalance = await wallet.getBalance();
  console.log('💰 ETH Balance:', ethers.utils.formatEther(ethBalance), 'ETH');

  // Get MockUSDC contract
  const usdc = new ethers.Contract(
    '0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb',
    ['function balanceOf(address) view returns (uint256)', 'function mint(address,uint256)'],
    wallet
  );

  const usdcBalance = await usdc.balanceOf(wallet.address);
  console.log('💵 USDC Balance:', ethers.utils.formatUnits(usdcBalance, 6), 'USDC');

  // Mint some USDC if balance is low
  if (usdcBalance.lt(ethers.utils.parseUnits('100', 6))) {
    console.log('🪙 Minting test USDC...');
    const mintTx = await usdc.mint(wallet.address, ethers.utils.parseUnits('1000', 6));
    await mintTx.wait();
    console.log('✅ Minted 1000 USDC');
  }

  // Add your integration tests here:
  // - Transaction creation
  // - Escrow linking
  // - State transitions

  console.log('✅ All tests passed!');
}

testDeployment().catch(console.error);
```

Run:
```bash
npx ts-node test-deployment.ts
```

---

## Expected Results

### ✅ Success Criteria

1. **Contracts respond to calls** (not reverted)
2. **SDK can connect** to deployed addresses
3. **State reads work** (admin, paused, platformFeeBps)
4. **EscrowVault linked** to ACTPKernel
5. **MockUSDC mintable** and transferable

### ❌ Common Issues

**Issue**: "call revert exception"
- **Fix**: Contract not deployed at address, check deployment

**Issue**: "insufficient funds for gas"
- **Fix**: Get Base Sepolia ETH from faucet

**Issue**: "execution reverted"
- **Fix**: Check if contracts are paused or have access control issues

---

## Next Steps After Testing

1. ✅ Verify contracts on Basescan (see VERIFY.md)
2. ✅ Run full integration test suite
3. ✅ Test happy path: Create → Commit → Deliver → Settle
4. ✅ Test dispute path: Dispute → Resolve
5. ✅ Test cancellation path
6. ✅ Document any issues found

---

## Monitoring & Debugging

**View transactions on Basescan**:
- ACTPKernel: https://sepolia.basescan.org/address/0x469CBADbACFFE096270594F0a31f0EEC53753411
- EscrowVault: https://sepolia.basescan.org/address/0x57f888261b629bB380dfb983f5DA6c70Ff2D49E5

**Monitor events**:
```bash
# Watch for TransactionCreated events
cast logs --address 0x469CBADbACFFE096270594F0a31f0EEC53753411 \
  --rpc-url https://sepolia.base.org \
  'TransactionCreated(bytes32,address,address,uint256,bytes32,uint256,uint256,uint256)'
```

---

## Paymaster Allowlist Sanity Check

Gas sponsorship (ERC-4337 paymaster) only works for calls to whitelisted contracts.
After deploying or redeploying any contract, **add it to both paymaster allowlists**:

1. **Coinbase CDP**: [dashboard.developer.coinbase.com](https://dashboard.developer.coinbase.com) → Paymaster Policies
2. **Pimlico**: [dashboard.pimlico.io](https://dashboard.pimlico.io) → Sponsorship Policies

### Required Contracts (both Sepolia + Mainnet)

| Contract | Base Sepolia | Base Mainnet |
|----------|-------------|-------------|
| ACTPKernel | `0x469CBADbACFFE096270594F0a31f0EEC53753411` | `0x132B9eB321dBB57c828B083844287171BDC92d29` |
| EscrowVault | `0x57f888261b629bB380dfb983f5DA6c70Ff2D49E5` | `0x6aAF45882c4b0dD34130ecC790bb5Ec6be7fFb99` |
| USDC (MockUSDC on testnet) | `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| AgentRegistry | `0xDd6D66924B43419F484aE981F174b803487AF25A` | `0x6fB222CF3DDdf37Bcb248EE7BBBA42Fb41901de8` |
| X402Relay | `0x4DCD02b276Dbeab57c265B72435e90507b6Ac81A` | `0x81DFb954A3D58FEc24Fc9c946aC2C71a911609F8` |
| ArchiveTreasury | `0xACB672de092beaAE2cd286dD61Cb2352AF7159F1` | `0x0516C411C0E8d75D17A768022819a0a4FB3cA2f2` |

**Total: 12 addresses (6 contracts × 2 chains)**

### Quick Verification

If `actp register` or `actp init -m testnet` fails with:
```
"called address not in allowlist: 0x..."
```
→ The address in the error is NOT on the paymaster allowlist. Add it.

### Symptom → Fix

| Error | Missing from allowlist |
|-------|----------------------|
| `not in allowlist: 0x6fB2...` | AgentRegistry (mainnet) |
| `not in allowlist: 0xDd6D...` | AgentRegistry (sepolia) |
| `not in allowlist: 0x81DF...` | X402Relay (mainnet) |
| `not in allowlist: 0x4DCD...` | X402Relay (sepolia) |
| `require(false)` on ACTPKernel | Check if Kernel itself is on allowlist |

---

## Support

If tests fail or contracts behave unexpectedly:
1. Check Basescan for transaction details
2. Verify contracts are not paused
3. Ensure wallet has sufficient ETH for gas
4. Check that escrow vault is approved by kernel
5. **Check paymaster allowlist** (see section above)
