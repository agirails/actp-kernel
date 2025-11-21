# ACTP-Kernel Security Model

## Trust Assumptions & Access Control

### H-1: Dispute Resolution Trust Model

**Status**: Known architectural decision
**Severity**: HIGH (requires trust in admin/pauser roles)
**Mitigation**: Multisig + operational procedures

#### Current Implementation

The ACTP-Kernel uses an **off-chain arbitration model** for dispute resolution:

```solidity
// Only admin or pauser can resolve disputes
if (fromState == State.DISPUTED && (toState == State.SETTLED || toState == State.CANCELLED)) {
    require(msg.sender == admin || msg.sender == pauser, "Resolver only");
}
```

**Implications**:
- Admin/pauser can distribute disputed funds arbitrarily
- No on-chain cryptographic proof of arbitration decision
- Users must trust the AGIRAILS dispute resolution process

#### Production Deployment Requirements

**REQUIRED FOR MAINNET**:

1. **3-of-5 Multisig for Admin Role**
   - Gnosis Safe contract on Base L2
   - Minimum 3 signatures required for any admin action
   - Signers: 2 founders + 3 trusted advisors/investors

2. **Separate Pauser Role** (already implemented)
   - Can pause contract in emergency
   - CANNOT resolve disputes or steal funds
   - Can be individual address for fast response

3. **Operational Procedures**
   - All disputes logged off-chain with evidence
   - Dispute resolution follows published arbitration rules
   - 7-day public review period before execution
   - Transparent decision documentation

#### Alternative: On-Chain Arbitration (Future V2)

**Option A: Kleros Integration**
- Decentralized jury-based arbitration
- Cryptographic evidence submission
- Game-theoretic security
- Timeline: Month 12-18

**Option B: Optimistic Dispute Resolution**
- Challenge period (7 days)
- Fraud proofs
- Economic security via bonds
- Timeline: Month 18-24

#### Security Score Impact

| Configuration | Trust Level | Security Score | Production Ready |
|---------------|-------------|----------------|------------------|
| Single admin | HIGH TRUST | 5/10 ❌ | NO |
| 2-of-3 multisig | MEDIUM TRUST | 7/10 ⚠️ | Testnet only |
| **3-of-5 multisig + procedures** | **LOW TRUST** | **8/10 ✅** | **YES** |
| On-chain arbitration (Kleros) | ZERO TRUST | 9/10 ✅ | Future V2 |

#### Audit Trail

All dispute resolutions MUST be logged:

```typescript
// Off-chain logging (required)
{
  transactionId: "0x...",
  disputedAt: 1234567890,
  resolvedAt: 1234567999,
  evidence: [
    {type: "ipfs", cid: "Qm..."},
    {type: "url", url: "https://..."}
  ],
  decision: {
    requesterAmount: "750000",
    providerAmount: "250000",
    mediatorAmount: "0",
    reasoning: "Provider delivered 75% of agreed scope..."
  },
  signatures: [
    {signer: "0xA...", signature: "0x..."},
    {signer: "0xB...", signature: "0x..."},
    {signer: "0xC...", signature: "0x..."}
  ]
}
```

#### Risk Mitigation Checklist

**Before Mainnet Deployment**:

- [ ] Deploy 3-of-5 Gnosis Safe multisig
- [ ] Transfer admin role to multisig
- [ ] Publish arbitration rules & procedures
- [ ] Set up dispute logging infrastructure
- [ ] Test multisig dispute resolution flow
- [ ] Document all signer identities publicly
- [ ] Establish emergency response procedures

**Operational**:

- [ ] Log all disputes to IPFS + centralized backup
- [ ] 7-day review period before resolution execution
- [ ] Monthly transparency reports
- [ ] Annual third-party audit of dispute logs

---

## Other Security Considerations

### Fixed Vulnerabilities

✅ **BLOCKER-1**: Escrow ID reuse attack - FIXED via `delete escrows[escrowId]` after completion
✅ **MEDIUM-5**: Mediator time-lock bypass - FIXED via `mediatorApprovedAt[mediator] == 0` check
✅ **HIGH-1**: State machine INITIATED→COMMITTED - FIXED via `linkEscrow` auto-transition
✅ **MEDIUM-2**: Vault verification - FIXED via `approvedEscrowVaults` check in all payout functions
✅ **MEDIUM-4**: MIN_DISPUTE_WINDOW - FIXED via 1-hour minimum enforcement
✅ **H-2**: Provider cancel flexibility - FIXED via requester-specific timing check
✅ **M-1**: Escrow lifecycle DoS - FIXED via `delete` after completion

### Known Limitations

1. **Dispute resolution requires trust** (see H-1 above)
2. **Gas costs 3x target** (~750k vs 250k target for happy path)
3. **Off-chain arbitration delay** (~7 days review period)

### Recommended External Audits

Before mainnet:
1. **Trail of Bits** or **ConsenSys Diligence** - $50-80K, 4-6 weeks
2. **Certora formal verification** - $30-50K, 2-3 weeks
3. **Public bug bounty** - $100K max payout, 2-4 weeks

Total estimated cost: **$180-230K**
Total timeline: **8-12 weeks**

---

**Last Updated**: 2025-01-17
**Version**: v0.9.0 (pre-mainnet)
**Security Contact**: security@agirails.io
