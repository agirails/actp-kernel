# Integration Testing - Base Sepolia Deployment

## Deployed Contracts

- **Network**: Base Sepolia (Chain ID: 84532)
- **ACTPKernel**: `0xb5B002A73743765450d427e2F8a472C24FDABF9b`
- **EscrowVault**: `0x67770791c83eA8e46D8a08E09682488ba584744f`
- **MockUSDC**: `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb`

---

## Prerequisites

1. **Install SDK dependencies**:
   ```bash
   cd "$PROJECT_ROOT/AGIRAILS/SDK and Runtime/sdk-js"
   npm install
   ```

2. **Set up test wallet** with Base Sepolia ETH:
   - Get testnet ETH from: https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet
   - Or bridge from Sepolia: https://bridge.base.org/deposit

3. **Create `.env` file** in SDK directory:
   ```bash
   cd "$PROJECT_ROOT/AGIRAILS/SDK and Runtime/sdk-js"
   cat > .env << 'EOF'
   # Test wallet private key (DO NOT use real funds!)
   PRIVATE_KEY=0x...your-test-wallet-private-key...

   # Base Sepolia RPC
   BASE_SEPOLIA_RPC=https://sepolia.base.org

   # Deployed contract addresses (already in networks.ts)
   ACTP_KERNEL=0xb5B002A73743765450d427e2F8a472C24FDABF9b
   ESCROW_VAULT=0x67770791c83eA8e46D8a08E09682488ba584744f
   MOCK_USDC=0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb
   EOF
   ```

---

## Quick Sanity Test

### 1. Check Contract Deployment

```bash
# Check if ACTPKernel is deployed
cast code 0xb5B002A73743765450d427e2F8a472C24FDABF9b --rpc-url https://sepolia.base.org

# Should return bytecode (not 0x)
# If returns "0x" → Contract not deployed or wrong address
```

### 2. Check Contract State

```bash
# Read public variables from ACTPKernel
cast call 0xb5B002A73743765450d427e2F8a472C24FDABF9b "admin()(address)" --rpc-url https://sepolia.base.org

cast call 0xb5B002A73743765450d427e2F8a472C24FDABF9b "paused()(bool)" --rpc-url https://sepolia.base.org

cast call 0xb5B002A73743765450d427e2F8a472C24FDABF9b "platformFeeBps()(uint16)" --rpc-url https://sepolia.base.org
```

### 3. Check EscrowVault Link

```bash
# Check if EscrowVault knows about Kernel
cast call 0x67770791c83eA8e46D8a08E09682488ba584744f "kernel()(address)" --rpc-url https://sepolia.base.org

# Should return ACTPKernel address: 0xb5B002A73743765450d427e2F8a472C24FDABF9b
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
cd "$PROJECT_ROOT/AGIRAILS/SDK and Runtime/sdk-js"
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
- ACTPKernel: https://sepolia.basescan.org/address/0xb5B002A73743765450d427e2F8a472C24FDABF9b
- EscrowVault: https://sepolia.basescan.org/address/0x67770791c83eA8e46D8a08E09682488ba584744f

**Monitor events**:
```bash
# Watch for TransactionCreated events
cast logs --address 0xb5B002A73743765450d427e2F8a472C24FDABF9b \
  --rpc-url https://sepolia.base.org \
  'TransactionCreated(bytes32,address,address,uint256,bytes32,uint256,uint256)'
```

---

## Support

If tests fail or contracts behave unexpectedly:
1. Check Basescan for transaction details
2. Verify contracts are not paused
3. Ensure wallet has sufficient ETH for gas
4. Check that escrow vault is approved by kernel
