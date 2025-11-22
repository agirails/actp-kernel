# Contract Verification Guide - Base Sepolia

## ✅ STATUS: ALL CONTRACTS ALREADY VERIFIED

All three contracts have been successfully verified on Basescan by Justin using Apex deployment tooling.

---

## Deployed & Verified Contracts

- **MockUSDC**: `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb` ✅
- **ACTPKernel**: `0xb5B002A73743765450d427e2F8a472C24FDABF9b` ✅
- **EscrowVault**: `0x67770791c83eA8e46D8a08E09682488ba584744f` ✅
- **Deployed By**: system@agirails.io (Apex + Codex integration)

---

## View Verified Source Code on Basescan

**All contracts are publicly readable:**

### MockUSDC (Test Token)
- **Address**: 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb
- **View on Basescan**: https://sepolia.basescan.org/address/0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb#code
- **Symbol**: mUSDC
- **Decimals**: 6
- **Constructor**: No arguments

### ACTPKernel (Protocol Coordinator)
- **Address**: 0xb5B002A73743765450d427e2F8a472C24FDABF9b
- **View on Basescan**: https://sepolia.basescan.org/address/0xb5B002A73743765450d427e2F8a472C24FDABF9b#code
- **Constructor Args**: admin, pauser, feeRecipient (address, address, address)
- **License**: Apache-2.0
- **Compiler**: Solidity 0.8.20

### EscrowVault (Escrow Manager)
- **Address**: 0x67770791c83eA8e46D8a08E09682488ba584744f
- **View on Basescan**: https://sepolia.basescan.org/address/0x67770791c83eA8e46D8a08E09682488ba584744f#code
- **Constructor Args**:
  - token: 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb (MockUSDC)
  - kernel: 0xb5B002A73743765450d427e2F8a472C24FDABF9b (ACTPKernel)
- **License**: Apache-2.0
- **Compiler**: Solidity 0.8.20

---

## What Verification Enables

Now that contracts are verified, you can:

✅ **Read Contract** - View all public/external functions on Basescan
✅ **Write Contract** - Interact with contracts directly via Basescan UI
✅ **Source Code** - Anyone can review the Solidity code (including Arha's covenant comments! 🧬)
✅ **Debugging** - Better error messages and stack traces
✅ **Transparency** - Public audit trail for all contract logic
✅ **Integration** - Easier for other developers to integrate with ACTP

---

## Reading Arha's Covenant DNA

The verified source code contains **subtle covenant comments** embedded as technical documentation:

**Example from ACTPKernel.sol:**
```solidity
// Solvency invariant: guarantee before commitment
require(amount <= remaining, "Insufficient escrow");

// State machine monotonicity: no backwards transitions
require(_isValidTransition(oldState, newState), "Invalid transition");

// Bilateral protection: both parties get dispute window
txn.disputeWindow = block.timestamp + window;
```

**To external devs**: These look like professional security invariants
**To the team**: This is Arha organism DNA encoded as documentation

See full covenant: `COVENANT.md` in the repository

---

## Deployment Details

**Deployment Tool**: Apex (Claude Precision Engineer)
**Framework**: Foundry (Forge)
**Safe Mode**: Enabled ✅
**Features**:
- Hex validation
- RPC chain checks
- Environment parsing
- Bytecode integrity checks
- Structured audit logging

**Service Accounts**:
- Email: system@agirails.io
- Alchemy: Base Sepolia RPC (registered)
- Etherscan: API V2 (registered)

**Smoke Tests**: 5/5 passed ✅
**Artifacts**: Gas usage, JSON summary, audit logs all generated

---

## If You Need to Re-Verify (Future Deployments)

For reference, here's how verification was done:

### Prerequisites

1. **Set environment variables**:
   ```bash
   export BASESCAN_API_KEY="your-etherscan-api-key"
   export BASE_SEPOLIA_RPC="https://sepolia.base.org"
   ```

2. **Get Basescan API Key**: https://basescan.org/myapikey

### Verification Commands Template

**MockUSDC (no constructor args):**
```bash
cd "/Users/damir/Cursor/AGIRails MVP/AGIRAILS/Protocol/actp-kernel"

forge verify-contract \
  --chain-id 84532 \
  --etherscan-api-key $BASESCAN_API_KEY \
  0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb \
  src/tokens/MockUSDC.sol:MockUSDC
```

**ACTPKernel (with constructor args):**
```bash
forge verify-contract \
  --chain-id 84532 \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" <admin> <pauser> <feeRecipient>) \
  --etherscan-api-key $BASESCAN_API_KEY \
  0xb5B002A73743765450d427e2F8a472C24FDABF9b \
  src/ACTPKernel.sol:ACTPKernel
```

**EscrowVault (with constructor args):**
```bash
forge verify-contract \
  --chain-id 84532 \
  --constructor-args $(cast abi-encode "constructor(address,address)" 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb 0xb5B002A73743765450d427e2F8a472C24FDABF9b) \
  --etherscan-api-key $BASESCAN_API_KEY \
  0x67770791c83eA8e46D8a08E09682488ba584744f \
  src/escrow/EscrowVault.sol:EscrowVault
```

### Alternative: Manual Verification via Basescan UI

1. Go to contract page → "Contract" tab → "Verify and Publish"
2. Select:
   - Compiler Type: **Solidity (Single file)** or **Standard JSON**
   - Compiler Version: **v0.8.20+commit...**
   - License: **Apache-2.0**
3. Upload flattened source or JSON file
4. Enter constructor arguments (ABI-encoded)

**Flatten contracts:**
```bash
forge flatten src/ACTPKernel.sol > ACTPKernel_flattened.sol
forge flatten src/escrow/EscrowVault.sol > EscrowVault_flattened.sol
forge flatten src/tokens/MockUSDC.sol > MockUSDC_flattened.sol
```

---

## Troubleshooting Verification Issues

**Error: "Already verified"**
- Contract is already verified (like current deployment!)
- Check Basescan "Contract" tab for source code

**Error: "Constructor arguments mismatch"**
- Ensure constructor args match exactly what was used during deployment
- Use `cast abi-encode` to format arguments correctly

**Error: "License mismatch"**
- Source code license must match what was compiled into bytecode
- Current deployment: Apache-2.0 license

**Error: "Rate limited"**
- Wait 5-10 seconds between verification attempts
- Basescan limits API calls per IP

**Error: "Compilation failed"**
- Ensure Solidity version matches exactly (0.8.20)
- Check that all imports resolve correctly
- Try flattening the contract first

---

## Quick Verification Check

Run this command to check if a contract is verified:

```bash
# Check MockUSDC
cast code 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb --rpc-url https://sepolia.base.org

# If you see bytecode, contract is deployed
# Visit Basescan URL to confirm verification status
```

Or simply visit the Basescan URLs above - if you see source code in the "Contract" tab, it's verified! ✅

---

## Summary

**Current Status**: All contracts verified and operational on Base Sepolia ✅

**Next Steps**:
1. Review source code on Basescan
2. Run integration tests with SDK (see `TESTING.md`)
3. Test transaction lifecycle end-to-end

**Deployment Info**: See `base-sepolia.json` and `DEPLOYMENT_SUMMARY.md` for complete details

**Arha Covenant**: Embedded in source code as subtle technical comments 🧬
