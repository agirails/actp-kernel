# Integration Testing - Base Sepolia Deployment

> **Current as of**: 2026-05-19. Addresses below reflect the 2026-05-19
> redeploy (per-tx penalty rate lock, permissionless auto-settle, milestone-
> fully-drained settle, X402Relay dust guard). Bump this stamp whenever
> the Sepolia stack is redeployed; cross-check against
> `deployments/base-sepolia.json` which is the machine-readable source of
> truth.

## Deployed Contracts (current — 2026-05-19 redeploy)

- **Network**: Base Sepolia (Chain ID: 84532)
- **ACTPKernel**: `0x9d25A874f046185d9237Cd4954C88D2B74B0021b`
- **EscrowVault**: `0x7dF07327090efcA73DCBa70414aA3131Fc6d2efB`
- **AgentRegistry**: `0xD91F9aBfBf60b4a2Fd5317ab0cDF3F44faB5D656`
- **ArchiveTreasury**: `0x2eE4f7bE289fc9EFC2F9f2D6E53e50abDF23A3eb`
- **X402Relay** (deprecated, SDK 3.3.0+ direct-routes): `0x110b25bb3d45c40dfcf34bb451aa7069b2a1cb3b`
- **AGIRAILSIdentityRegistry**: `0xce9749c768b425fab0daa0331047d1340ec99a88`
- **MockUSDC**: `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb`

### Previous (pre-2026-04-15 redeploy, storage-layout incompatible)

- ACTPKernel: `0x0ba0b17554601b30F5406e74d2208f567C12CcFE` (DEPRECATED)
- EscrowVault: `0xedC62264301A119207f1f89C6bDE4Fd7a7A4CeB4` (DEPRECATED)

These older addresses are listed here only for historical reference;
new integrations must use the current addresses above.

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
   ACTP_KERNEL=0x9d25A874f046185d9237Cd4954C88D2B74B0021b
   ESCROW_VAULT=0x7dF07327090efcA73DCBa70414aA3131Fc6d2efB
   MOCK_USDC=0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb

   # Deployed contract addresses (already in networks.ts)
   EOF
   ```

---

## Quick Sanity Test

### 1. Check Contract Deployment

```bash
# Check if ACTPKernel is deployed
cast code 0x9d25A874f046185d9237Cd4954C88D2B74B0021b --rpc-url https://sepolia.base.org

# Should return bytecode (not 0x)
# If returns "0x" → Contract not deployed or wrong address
```

### 2. Check Contract State

```bash
# Read public variables from ACTPKernel
cast call 0x9d25A874f046185d9237Cd4954C88D2B74B0021b "admin()(address)" --rpc-url https://sepolia.base.org

cast call 0x9d25A874f046185d9237Cd4954C88D2B74B0021b "paused()(bool)" --rpc-url https://sepolia.base.org

cast call 0x9d25A874f046185d9237Cd4954C88D2B74B0021b "platformFeeBps()(uint16)" --rpc-url https://sepolia.base.org
```

### 3. Check EscrowVault Link

```bash
# Check if EscrowVault knows about Kernel
cast call 0x7dF07327090efcA73DCBa70414aA3131Fc6d2efB "kernel()(address)" --rpc-url https://sepolia.base.org

# Should return ACTPKernel address: 0x9d25A874f046185d9237Cd4954C88D2B74B0021b
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
- ACTPKernel: https://sepolia.basescan.org/address/0x9d25A874f046185d9237Cd4954C88D2B74B0021b
- EscrowVault: https://sepolia.basescan.org/address/0x7dF07327090efcA73DCBa70414aA3131Fc6d2efB

**Monitor events**:
```bash
# Watch for TransactionCreated events
cast logs --address 0x9d25A874f046185d9237Cd4954C88D2B74B0021b \
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
| ACTPKernel | `0x9d25A874f046185d9237Cd4954C88D2B74B0021b` | `0x048c811352e8a3fECd5b0Ec4AA2c2b94083CC842` |
| EscrowVault | `0x7dF07327090efcA73DCBa70414aA3131Fc6d2efB` | `0x262D5912A9612F0c66dA5d13B4E678D50ebC44b5` |
| USDC (MockUSDC on testnet) | `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| AgentRegistry | `0xDd6D66924B43419F484aE981F174b803487AF25A` | `0x64Cb18bfb3CC1aCb1370a3B01613391D3561a009` |
| X402Relay | `0x4DCD02b276Dbeab57c265B72435e90507b6Ac81A` | `(mainnet: X402Relay deprecated, not deployed — see Sepolia for legacy address)` |
| ArchiveTreasury | `0xACB672de092beaAE2cd286dD61Cb2352AF7159F1` | `0x6159A80Ce8362aBB2307FbaB4Ed4D3F4A4231Acc` |

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
