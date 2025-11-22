# H-1 Fix: Multisig Admin Migration Guide

## Executive Summary

**Vulnerability**: H-1: Admin = Single Point of Failure ⚠️ HIGH PRIORITY

**Risk**: Current admin is a single EOA (1-of-1). If private key is compromised:
- Attacker can pause protocol (instant DoS)
- Approve malicious escrow vaults (instant)
- Approve themselves as mediator (2 day wait)
- Steal 10% of all disputes
- Change fee recipient to steal all fees
- **Total potential loss: $100M+**

**Solution**: Deploy Gnosis Safe multisig (3-of-5 or 4-of-7) as admin. Single compromised key becomes useless - attacker needs 3+ signatures to execute any admin function.

**Status**:
- ✅ Tests completed (12 passing tests)
- ✅ Deployment script ready
- ⏳ Awaiting production deployment
- ⏳ Awaiting multisig signer onboarding

---

## Table of Contents

1. [Security Requirements](#security-requirements)
2. [Pre-Deployment Checklist](#pre-deployment-checklist)
3. [Step-by-Step Deployment Guide](#step-by-step-deployment-guide)
4. [Signer Onboarding](#signer-onboarding)
5. [Testing Procedures](#testing-procedures)
6. [Emergency Procedures](#emergency-procedures)
7. [Maintenance & Operations](#maintenance--operations)
8. [Appendix](#appendix)

---

## Security Requirements

### Multisig Configuration

**Threshold**: 3-of-5 signers (60% threshold)
- **Why 3-of-5**: Balance between security and operational speed
- **Alternative**: 4-of-7 (57% threshold) for higher security
- **Minimum**: Never use 2-of-3 (too risky - only 2 keys needed)
- **Maximum**: Never use 5-of-5 (too slow - key loss = protocol lockout)

### Signer Diversity Requirements

**Geographic Diversity**:
- At least 3 different countries
- At least 2 different time zones
- No more than 2 signers in same city

**Role Diversity**:
- 1x CEO (business decisions)
- 1x CTO (technical decisions)
- 1x Legal Counsel (compliance)
- 2x External Advisors (independent oversight)

**Access Diversity**:
- All signers use hardware wallets (Ledger or Trezor)
- No signers share same office/device
- No signers share same cloud backup
- No signers know each other's recovery phrases

**Communication Security**:
- Primary: Encrypted Signal group
- Backup: Encrypted email (PGP)
- Emergency: Phone call with code word verification
- Never communicate keys or signatures via Slack/Discord

---

## Pre-Deployment Checklist

### Phase 1: Infrastructure (Week 1)

- [ ] **Deploy Gnosis Safe on Base Sepolia (testnet)**
  - Network: Base Sepolia (Chain ID: 84532)
  - Safe version: Latest stable (v1.4.1+)
  - Threshold: 3-of-5
  - Signers: Test addresses (NOT production keys)

- [ ] **Verify Safe configuration**
  - Run: `cast call $SAFE "getOwners()(address[])" --rpc-url $BASE_SEPOLIA_RPC`
  - Verify: 5 owners returned
  - Run: `cast call $SAFE "getThreshold()(uint256)" --rpc-url $BASE_SEPOLIA_RPC`
  - Verify: Returns 3

- [ ] **Test admin transfer on testnet**
  - Run: `forge script script/DeployMultisig.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast`
  - Verify: `pendingAdmin` == Safe address
  - Wait: 2 days (or simulate with `vm.warp` in test)
  - Execute: `acceptAdmin()` via Safe UI
  - Verify: `admin` == Safe address

- [ ] **Test all admin functions via Safe UI**
  - Test pause/unpause
  - Test escrow vault approval
  - Test mediator approval
  - Test fee recipient update
  - Test pauser update
  - Test economic params schedule/execute/cancel

### Phase 2: Signer Onboarding (Week 2)

- [ ] **Hardware wallet procurement**
  - Order: 5x Ledger Nano X or Trezor Model T
  - Ship to: Each signer's secure location
  - Verify: Authentic devices (check hologram seals)

- [ ] **Signer onboarding sessions** (1 hour each)
  - Setup hardware wallet
  - Generate Ethereum account
  - Test signing on Base Sepolia testnet
  - Document public address (NOT private key)
  - Test Safe UI transaction signing

- [ ] **Signer documentation**
  - Each signer completes "Signer Responsibility Agreement"
  - Each signer documents backup location (sealed envelope)
  - Each signer tests recovery phrase backup/restore
  - Emergency contact info collected (phone, Signal, email)

- [ ] **Security training** (2 hours)
  - Phishing awareness
  - Hardware wallet security
  - Safe transaction verification
  - Emergency procedures
  - Social engineering tactics

### Phase 3: Production Deployment (Week 3)

- [ ] **Deploy Gnosis Safe on Base Mainnet**
  - Network: Base Mainnet (Chain ID: 8453)
  - Safe version: Same as testnet (verified working)
  - Threshold: 3-of-5
  - Signers: Production hardware wallet addresses

- [ ] **Verify Safe configuration**
  - Verify: 5 correct owner addresses
  - Verify: Threshold == 3
  - Fund Safe with ~0.01 ETH for gas

- [ ] **Legal review**
  - Legal counsel reviews all configuration
  - Legal counsel signs off on signer agreements
  - Legal counsel verifies compliance requirements

- [ ] **Schedule admin transfer**
  - Announce: 7 days advance notice to community
  - Tweet: Public announcement with Safe address
  - Discord: AMA session for questions
  - Docs: Update documentation with new admin address

- [ ] **Execute admin transfer**
  - Run: `forge script script/DeployMultisig.s.sol --rpc-url $BASE_MAINNET_RPC --broadcast --verify`
  - Verify: Transaction confirmed
  - Monitor: Etherscan for confirmation
  - Wait: 2 days (admin transfer timelock)

- [ ] **Multisig accepts admin**
  - Day 0+2: Multisig ready to accept
  - Create transaction via Safe UI: `ACTPKernel.acceptAdmin()`
  - Collect signatures: 3 of 5 signers approve
  - Execute transaction
  - Verify: `admin` == Safe address

- [ ] **Post-deployment verification**
  - Test: Pause/unpause via multisig
  - Test: Old admin cannot execute admin functions
  - Monitor: No unexpected transactions
  - Announce: Admin transfer complete

---

## Step-by-Step Deployment Guide

### Step 1: Deploy Gnosis Safe (15 minutes)

**Via Safe{Wallet} UI**: https://app.safe.global

1. **Connect wallet**
   - Use deployer wallet (current admin)
   - Connect via MetaMask/WalletConnect
   - Select network: Base Mainnet

2. **Create new Safe**
   - Click "Create New Safe"
   - Name: "AGIRAILS ACTP Admin Multisig"
   - Network: Base Mainnet (Chain ID 8453)

3. **Add signers** (5 total)
   ```
   Signer 1 (CEO):       0x... [Hardware Wallet Address]
   Signer 2 (CTO):       0x... [Hardware Wallet Address]
   Signer 3 (Legal):     0x... [Hardware Wallet Address]
   Signer 4 (Advisor 1): 0x... [Hardware Wallet Address]
   Signer 5 (Advisor 2): 0x... [Hardware Wallet Address]
   ```

4. **Set threshold**
   - Threshold: 3 out of 5
   - Verify: "Any transaction requires the confirmation of 3 out of 5 owners"

5. **Review and deploy**
   - Review all settings
   - Click "Create"
   - Confirm transaction (pay gas fee)
   - Wait for confirmation (~5 seconds on Base)

6. **Copy Safe address**
   - Example: `0x5AFe111111111111111111111111111111111111`
   - Save to secure location
   - Update `DeployMultisig.s.sol` with address

### Step 2: Verify Safe Configuration (5 minutes)

```bash
# Set variables
export SAFE_ADDRESS="0x5AFe111111111111111111111111111111111111"
export BASE_MAINNET_RPC="https://mainnet.base.org"

# Verify owners
cast call $SAFE_ADDRESS "getOwners()(address[])" --rpc-url $BASE_MAINNET_RPC

# Expected output:
# [
#   0x1111111111111111111111111111111111111111,
#   0x2222222222222222222222222222222222222222,
#   0x3333333333333333333333333333333333333333,
#   0x4444444444444444444444444444444444444444,
#   0x5555555555555555555555555555555555555555
# ]

# Verify threshold
cast call $SAFE_ADDRESS "getThreshold()(uint256)" --rpc-url $BASE_MAINNET_RPC

# Expected output: 3

# Fund Safe with gas (optional but recommended)
cast send $SAFE_ADDRESS --value 0.01ether --rpc-url $BASE_MAINNET_RPC --private-key $PRIVATE_KEY
```

### Step 3: Update Deployment Script (2 minutes)

Edit `script/DeployMultisig.s.sol`:

```solidity
// Update these constants:
address constant GNOSIS_SAFE_ADDRESS = 0x5AFe111111111111111111111111111111111111; // ⚠️ YOUR SAFE
address constant ACTP_KERNEL_ADDRESS = 0x...; // ⚠️ YOUR KERNEL

address constant SIGNER_1_CEO = 0x1111111111111111111111111111111111111111;
address constant SIGNER_2_CTO = 0x2222222222222222222222222222222222222222;
address constant SIGNER_3_LEGAL = 0x3333333333333333333333333333333333333333;
address constant SIGNER_4_ADVISOR_1 = 0x4444444444444444444444444444444444444444;
address constant SIGNER_5_ADVISOR_2 = 0x5555555555555555555555555555555555555555;

uint256 constant EXPECTED_THRESHOLD = 3;
```

### Step 4: Execute Admin Transfer (10 minutes)

```bash
# Set environment variables
export PRIVATE_KEY="0x..." # Current admin private key
export BASE_MAINNET_RPC="https://mainnet.base.org"
export ETHERSCAN_API_KEY="..." # For contract verification

# Run deployment script
forge script script/DeployMultisig.s.sol:DeployMultisig \
  --rpc-url $BASE_MAINNET_RPC \
  --broadcast \
  --verify \
  --slow

# Verify pending admin
cast call $ACTP_KERNEL_ADDRESS "pendingAdmin()(address)" --rpc-url $BASE_MAINNET_RPC

# Should return: $GNOSIS_SAFE_ADDRESS
```

### Step 5: Wait 2 Days (Admin Transfer Timelock)

**M-1 Fix**: 2-step admin transfer with 2-day timelock prevents instant admin takeover.

```bash
# Check current time
cast block latest --rpc-url $BASE_MAINNET_RPC | jq '.timestamp'

# Calculate acceptance time (current + 2 days)
# Acceptance allowed after: <current_timestamp + 172800>

# Set calendar reminder for Day 0 + 2 days
```

### Step 6: Multisig Accepts Admin (15 minutes)

**Via Safe{Wallet} UI**: https://app.safe.global

1. **Go to Safe** (after 2 days)
   - Select: Your Safe
   - Network: Base Mainnet

2. **Create new transaction**
   - Click "New Transaction"
   - Select "Contract Interaction"

3. **Enter contract details**
   - Contract Address: `$ACTP_KERNEL_ADDRESS`
   - ABI: Load from Etherscan or paste manually
   - Function: `acceptAdmin()`

4. **Create transaction**
   - Click "Create"
   - Review: No parameters needed
   - Verify: To address == ACTPKernel
   - Verify: Function == acceptAdmin()

5. **Collect signatures** (3 of 5)
   - Signer 1: Approves via hardware wallet
   - Signer 2: Approves via hardware wallet
   - Signer 3: Approves via hardware wallet
   - (3/5 threshold met)

6. **Execute transaction**
   - Click "Execute"
   - Pay gas fee from Safe balance
   - Wait for confirmation (~5 seconds)

7. **Verify success**
   ```bash
   cast call $ACTP_KERNEL_ADDRESS "admin()(address)" --rpc-url $BASE_MAINNET_RPC
   # Should return: $GNOSIS_SAFE_ADDRESS
   ```

### Step 7: Test Multisig Admin (30 minutes)

**Test 1: Pause/Unpause**
1. Create transaction: `ACTPKernel.pause()`
2. Collect 3 signatures
3. Execute
4. Verify: `paused()` returns `true`
5. Create transaction: `ACTPKernel.unpause()`
6. Collect 3 signatures
7. Execute
8. Verify: `paused()` returns `false`

**Test 2: Escrow Vault Approval**
1. Create transaction: `ACTPKernel.approveEscrowVault(address vault, bool approved)`
2. Parameters: `vault = 0x999...`, `approved = true`
3. Collect 3 signatures
4. Execute
5. Verify: `approvedEscrowVaults(0x999...)` returns `true`

**Test 3: Verify Old Admin Cannot Execute**
```bash
# Try to pause as old admin (should fail)
cast send $ACTP_KERNEL_ADDRESS "pause()" \
  --rpc-url $BASE_MAINNET_RPC \
  --private-key $OLD_ADMIN_KEY

# Expected: Revert with "Not admin" or "Not pauser"
```

---

## Signer Onboarding

### Hardware Wallet Setup (Per Signer)

**Equipment Checklist**:
- ✅ Ledger Nano X or Trezor Model T (brand new, sealed)
- ✅ USB cable (included with device)
- ✅ Computer with Ledger Live / Trezor Suite installed
- ✅ Pen and paper (for recovery phrase backup)
- ✅ Fireproof safe or bank vault (for backup storage)

**Setup Steps** (30 minutes):

1. **Unbox and verify**
   - Check hologram seals intact
   - Verify packaging not tampered
   - Visit manufacturer website to verify authenticity

2. **Initialize device**
   - Power on device
   - Choose "Set up as new device"
   - Choose PIN (8 digits, never reuse)
   - Write down recovery phrase (24 words)
   - Confirm recovery phrase (device will test you)

3. **Install Ethereum app**
   - Open Ledger Live / Trezor Suite
   - Install Ethereum app on device
   - Verify app version is latest stable

4. **Generate Ethereum account**
   - Open Ethereum app on device
   - Connect to computer
   - Ledger Live: Add Ethereum account
   - Copy Ethereum address (0x...)

5. **Backup recovery phrase**
   - Write on paper (NEVER digital)
   - Store in fireproof safe or bank vault
   - Test backup by restoring on 2nd device (optional)
   - Destroy any digital traces (photos, notes app, etc.)

6. **Test signing on Sepolia**
   - Get Sepolia ETH from faucet
   - Sign test transaction
   - Verify transaction on Etherscan
   - Confirm comfort with signing flow

### Signer Responsibility Agreement

**Each signer must acknowledge**:

1. **Security Responsibilities**:
   - I will store my hardware wallet in a secure location
   - I will store my recovery phrase in a fireproof safe or bank vault
   - I will NEVER share my recovery phrase with anyone (including other signers)
   - I will NEVER take a photo of my recovery phrase
   - I will NEVER store my recovery phrase digitally (cloud, notes app, etc.)
   - I will test my backup recovery at least once per year

2. **Operational Responsibilities**:
   - I will respond to multisig signature requests within 24 hours
   - I will verify all transaction details before signing
   - I will maintain availability via Signal, email, and phone
   - I will notify the team immediately if my key is compromised
   - I will participate in quarterly security reviews

3. **Compromise Protocol**:
   - If I suspect my key is compromised, I will immediately:
     - Notify CEO and CTO via Signal
     - Initiate signer rotation procedure
     - Document incident for security review
   - I understand compromised key ≠ protocol compromise (need 3 keys)

4. **Departure Protocol**:
   - If I leave the company or role, I will:
     - Notify team 30 days in advance
     - Participate in signer rotation
     - Destroy hardware wallet after rotation complete
     - Securely destroy recovery phrase backup

**Signature**: ___________________
**Date**: ___________________
**Witness (CEO)**: ___________________

---

## Testing Procedures

### Pre-Production Testing (Base Sepolia)

**Test 1: Admin Transfer**
```bash
# Deploy Safe on testnet
# Transfer admin to Safe
forge script script/DeployMultisig.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast

# Wait 2 days (or simulate with vm.warp in test)
# Accept admin via Safe UI
# Verify admin == Safe address
```

**Test 2: All Admin Functions**
```solidity
// Run comprehensive test suite
forge test --match-path test/H1_MultisigAdminTest.t.sol -vvv

// Verify all 12 tests pass:
// ✅ testH1Fix_AdminTransferToMultisig
// ✅ testH1Fix_SingleSignerCannotExecuteAdminFunctions
// ✅ testH1Fix_MultisigCanPauseUnpause
// ✅ testH1Fix_MultisigCanApproveEscrowVaults
// ✅ testH1Fix_MultisigCanApproveMediators
// ✅ testH1Fix_MultisigCanUpdatePauser
// ✅ testH1Fix_MultisigCanUpdateFeeRecipient
// ✅ testH1Fix_MultisigCanManageEconomicParams
// ✅ testH1Fix_MultisigCanRotateToNewMultisig
// ✅ testH1Fix_SignerDiversityPreventsCollusion
// ✅ testH1EconomicImpact_PreventedLoss
// ✅ testH1Vulnerability_SingleAdminFullControl
```

**Test 3: Signer Hardware Wallet Flow**
```bash
# Each signer tests on Sepolia:
# 1. Connect hardware wallet to Safe UI
# 2. Create test transaction (pause)
# 3. Sign transaction on device
# 4. Verify signature appears in Safe UI
# 5. Execute after collecting 3 signatures
```

### Production Smoke Tests (Day of Deployment)

**Immediately After Admin Transfer Accepted**:

```bash
# Test 1: Verify admin is multisig
cast call $KERNEL "admin()(address)" --rpc-url $BASE_MAINNET_RPC
# Expected: $GNOSIS_SAFE_ADDRESS

# Test 2: Verify old admin cannot execute
cast send $KERNEL "pause()" --private-key $OLD_ADMIN_KEY --rpc-url $BASE_MAINNET_RPC
# Expected: Revert with "Not pauser"

# Test 3: Verify multisig can pause (then unpause immediately)
# Via Safe UI:
# 1. Create transaction: pause()
# 2. Collect 3 signatures
# 3. Execute
# 4. Verify paused() == true
# 5. Create transaction: unpause()
# 6. Collect 3 signatures
# 7. Execute
# 8. Verify paused() == false

# Test 4: Verify all other contracts still work
# Create test transaction (small amount)
# Link escrow
# Complete transaction
# Verify funds flow correctly
```

---

## Emergency Procedures

### Emergency Contact Tree

```
Level 1 (Immediate Response - 0-1 hour):
├─ CEO:         +xxx-xxx-xxxx (Signal: @xxx)
├─ CTO:         +xxx-xxx-xxxx (Signal: @xxx)
└─ Legal:       +xxx-xxx-xxxx (Email: legal@agirails.io)

Level 2 (Escalation - 1-4 hours):
├─ Advisor 1:   +xxx-xxx-xxxx (Discord: @xxx)
├─ Advisor 2:   +xxx-xxx-xxxx (Twitter: @xxx)
└─ Security:    security@agirails.io

Level 3 (External Support - 4-24 hours):
├─ Gnosis Safe Support: support@safe.global
├─ Base Network Support: support@base.org
└─ Incident Response Firm: [TBD]
```

### Emergency Scenarios

#### Scenario 1: Single Signer Key Compromised

**Indicators**:
- Signer reports lost/stolen hardware wallet
- Signer suspects phishing attack
- Unauthorized transaction attempt detected

**Response** (Target: 2 hours):

1. **Immediate (0-15 minutes)**:
   - Signer notifies CEO and CTO via Signal
   - CEO initiates emergency call
   - Verify: Is compromised signer in active transaction?
   - Decision: Emergency pause needed?

2. **Assessment (15-30 minutes)**:
   - Review recent Safe transaction history
   - Check for suspicious pending transactions
   - Confirm: Only 1 key compromised (not 3+)
   - Conclusion: Protocol still secure (need 3 keys)

3. **Communication (30-60 minutes)**:
   - Notify all signers via Signal group
   - Notify community via Twitter (if public incident)
   - Document incident in security log
   - Prepare signer rotation plan

4. **Remediation (1-7 days)**:
   - Procure new hardware wallet for replacement signer
   - Onboard replacement signer (or existing signer's new device)
   - Execute signer rotation via Safe UI:
     ```
     1. addOwnerWithThreshold(newSigner, 3)  // Now 6 signers, threshold 3
     2. Wait 24 hours (monitoring period)
     3. removeOwner(compromisedSigner, 3)     // Back to 5 signers, threshold 3
     ```
   - Verify new configuration
   - Post-incident review

#### Scenario 2: Multiple Signer Keys Compromised (2 of 5)

**Indicators**:
- Two signers report compromise
- Coordinated social engineering attack detected
- Suspicious pending multisig transaction

**Response** (Target: 30 minutes):

1. **Immediate (0-5 minutes)**:
   - CEO declares "Code Red" via Signal
   - All signers check for pending transactions in Safe UI
   - If suspicious transaction pending: DO NOT SIGN
   - If 2/3 signatures already collected: EMERGENCY PAUSE

2. **Emergency Pause (5-15 minutes)**:
   - Remaining secure signers (3 of 5) execute emergency pause:
     ```
     ACTPKernel.pause()  // Requires 3 signatures
     ```
   - Pause blocks all state transitions (protocol frozen)
   - Funds remain safe in escrow (cannot be moved)

3. **Incident Response (15-60 minutes)**:
   - CEO contacts incident response firm
   - Forensic analysis of compromise vector
   - Review all pending/recent transactions
   - Determine: Was any malicious transaction executed?

4. **Recovery (1-4 hours)**:
   - If no malicious transactions executed:
     - Rotate both compromised signers
     - Test new configuration on testnet
     - Unpause protocol
   - If malicious transaction executed:
     - Assess damage
     - Execute dispute resolution
     - Community announcement
     - Post-mortem report

#### Scenario 3: Catastrophic (3+ Keys Compromised)

**Indicators**:
- Three or more signers report compromise
- Malicious transaction executed
- Funds movement detected

**Response** (Target: Immediate):

1. **Triage (0-5 minutes)**:
   - Determine: Which funds are at risk?
   - Check: Did attacker already execute transaction?
   - If yes: Damage control mode
   - If no: Prevention mode

2. **Damage Control (5-30 minutes)**:
   - If attacker paused protocol: Use pauser role to unpause (separate from admin)
   - If attacker approved malicious escrow: Cannot undo (escrow already approved)
   - If attacker approved malicious mediator: Wait 2 days (M-2 fix: mediator timelock)
   - If attacker changed fee recipient: Fees go to attacker (cannot recover past fees)

3. **Emergency Protocol (30-120 minutes)**:
   - Deploy new ACTPKernel V2 with new admin (new multisig)
   - Pause compromised V1 kernel (if attacker hasn't already)
   - Manually resolve all active V1 transactions:
     - Return funds to requesters
     - Pay providers for completed work
     - Document all resolutions
   - Migrate to V2 with new multisig
   - Post-mortem and community transparency

4. **Post-Incident (1-7 days)**:
   - Full security audit of incident
   - Legal review of losses and liabilities
   - Insurance claim (if applicable)
   - Community compensation plan (if needed)
   - Update security procedures
   - Re-audit with external firm

### Emergency Decision Matrix

| Keys Compromised | Risk Level | Action Required | Timeline |
|------------------|------------|-----------------|----------|
| 0 | 🟢 Low | Monitor | N/A |
| 1 | 🟡 Medium | Rotate signer | 1-7 days |
| 2 | 🟠 High | Emergency pause + rotate | 30 min - 4 hours |
| 3+ | 🔴 Critical | Emergency protocol + V2 deployment | Immediate - 2 hours |

---

## Maintenance & Operations

### Routine Operations

**Daily**:
- Monitor Safe transaction history
- Check for pending signature requests
- Respond to any signature requests within 24 hours

**Weekly**:
- Review Safe balance (ensure ~0.01 ETH for gas)
- Check Etherscan for any unexpected transactions
- Review any community questions about admin

**Monthly**:
- Security team reviews all admin transactions
- CEO reviews signer response times
- Document any operational issues

**Quarterly**:
- All signers test recovery phrase backup
- Security training refresh (phishing, social engineering)
- Review and update emergency procedures
- Test emergency contact tree (drill)

**Annually**:
- Consider proactive signer rotation (even if no compromise)
- Hardware wallet firmware updates
- Security audit of multisig operations
- Review threshold (still optimal at 3-of-5?)

### Signer Rotation Procedure

**When to Rotate**:
- Signer leaves company/role
- Signer key compromised or suspected compromised
- Proactive annual rotation (security best practice)
- Signer non-responsive (failed to sign within SLA)

**How to Rotate** (2-4 hours):

1. **Preparation**
   - Identify replacement signer
   - Onboard replacement signer (hardware wallet setup)
   - Test replacement signer on testnet
   - Schedule rotation window (low transaction period)

2. **Add New Signer**
   ```
   Via Safe UI:
   1. Settings → Owners
   2. Add new owner
   3. Address: <new_signer_address>
   4. Keep threshold: 3
   5. Collect 3 signatures
   6. Execute
   7. Verify: Safe now has 6 owners, threshold still 3
   ```

3. **Monitoring Period** (24-48 hours)
   - New signer tests signing (on testnet or small mainnet tx)
   - Verify new signer can access Safe UI
   - Verify new signer can sign transactions
   - Monitor for any issues

4. **Remove Old Signer**
   ```
   Via Safe UI:
   1. Settings → Owners
   2. Remove owner
   3. Address: <old_signer_address>
   4. Keep threshold: 3
   5. Collect 3 signatures (must include new signer)
   6. Execute
   7. Verify: Safe now has 5 owners, threshold 3
   ```

5. **Cleanup**
   - Old signer destroys hardware wallet (or wipes and repurposes)
   - Old signer destroys recovery phrase backup
   - Document rotation in security log
   - Update emergency contact tree

### Transaction Signing Best Practices

**Before Signing Any Transaction**:

1. **Verify Transaction Details**
   - To: Correct contract address (compare with docs)
   - Function: Correct function name
   - Parameters: Correct values (especially addresses)
   - Value: 0 ETH (unless intentionally funding)

2. **Verify in Safe UI**
   - Transaction hash matches
   - Other signers are legitimate (not phishing attempt)
   - No unexpected parameters

3. **Verify on Hardware Device**
   - Address on device matches Safe UI
   - Function on device matches Safe UI
   - Confirm on device only after verifying above

4. **Communication**
   - Always check Signal group before signing
   - CEO or CTO should explain transaction purpose
   - If unsure, ask questions (never sign blindly)
   - Document reason for signature in Safe UI (comment field)

**Red Flags (DO NOT SIGN)**:
- 🚩 Transaction not announced in Signal group
- 🚩 Transaction to unknown contract address
- 🚩 Transaction with large ETH value (unless expected)
- 🚩 Transaction during non-business hours (unless emergency)
- 🚩 Transaction rushed without explanation
- 🚩 Other signers are unknown addresses

---

## Appendix

### A. Useful Commands

**Check Safe Configuration**:
```bash
# Get all owners
cast call $SAFE "getOwners()(address[])" --rpc-url $RPC

# Get threshold
cast call $SAFE "getThreshold()(uint256)" --rpc-url $RPC

# Get Safe version
cast call $SAFE "VERSION()(string)" --rpc-url $RPC

# Get Safe balance
cast balance $SAFE --rpc-url $RPC
```

**Check Kernel Admin**:
```bash
# Get current admin
cast call $KERNEL "admin()(address)" --rpc-url $RPC

# Get pending admin
cast call $KERNEL "pendingAdmin()(address)" --rpc-url $RPC

# Get pauser
cast call $KERNEL "pauser()(address)" --rpc-url $RPC

# Check if paused
cast call $KERNEL "paused()(bool)" --rpc-url $RPC
```

**Monitor Transactions**:
```bash
# Get Safe transaction count
cast call $SAFE "nonce()(uint256)" --rpc-url $RPC

# Get transaction history (via API)
curl "https://safe-transaction-base.safe.global/api/v1/safes/$SAFE/transactions/"
```

### B. Contract Addresses

**Base Mainnet**:
```
ACTPKernel:    0x... [UPDATE AFTER DEPLOYMENT]
EscrowVault:   0x... [UPDATE AFTER DEPLOYMENT]
Gnosis Safe:   0x... [UPDATE AFTER DEPLOYMENT]
USDC:          0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

**Base Sepolia**:
```
ACTPKernel:    0x... [TESTNET]
EscrowVault:   0x... [TESTNET]
Gnosis Safe:   0x... [TESTNET]
MockUSDC:      0x... [TESTNET]
```

### C. References

**Documentation**:
- Gnosis Safe Docs: https://docs.safe.global
- Base Network Docs: https://docs.base.org
- ACTP Protocol Docs: [Internal]

**Support**:
- Gnosis Safe Discord: https://discord.gg/safe-global
- Base Developer Discord: https://discord.gg/base
- AGIRAILS Discord: [Internal]

**Security**:
- Report vulnerabilities: security@agirails.io
- Bug bounty: [TBD]
- Incident response: [TBD]

### D. Changelog

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2024-XX-XX | 1.0.0 | Initial multisig migration guide | Claude + Damir |
| TBD | 1.1.0 | Post-deployment updates | TBD |

---

## Approval Signatures

**CEO (Damir Mujic)**: ___________________  Date: ___________

**CTO (Justin Rooschuz)**: ___________________  Date: ___________

**Legal Counsel**: ___________________  Date: ___________

---

**Last Updated**: 2024-XX-XX
**Next Review**: Quarterly (every 3 months)
**Document Owner**: Security Team (security@agirails.io)
