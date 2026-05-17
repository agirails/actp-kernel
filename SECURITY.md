# ACTP-Kernel Security Model

## Trust Assumptions & Access Control

### H-1: Dispute Resolution Trust Model

**Status**: Known architectural decision
**Severity**: HIGH (requires trust in the admin role)
**Mitigation**: Multisig + operational procedures

#### Current Implementation

The ACTP-Kernel uses an **off-chain arbitration model** for dispute resolution.
The resolver allowlist was tightened in commit `d9c6e8e` (Sepolia redeploy
2026-04-15) — pauser is now a pure pause-only operational key and is no
longer authorised to resolve disputes. Admin (multisig) is the sole
resolver:

```solidity
// Only admin can resolve disputes (pauser removed in d9c6e8e, 2026-04-15)
} else if (
    fromState == State.DISPUTED && (toState == State.SETTLED || toState == State.CANCELLED)
) {
    require(msg.sender == admin, "Resolver only");
}
```

**Implications**:
- Admin can distribute disputed funds arbitrarily
- No on-chain cryptographic proof of arbitration decision
- Users must trust the AGIRAILS dispute resolution process
- Pauser key, even if compromised, cannot resolve disputes or steal funds

#### Production Deployment Requirements

**REQUIRED FOR MAINNET**:

1. **Multisig for Admin Role**
   - Gnosis Safe contract on Base L2
   - Multiple signatures required for any admin action

2. **Separate Pauser Role** (already implemented)
   - Can pause contract in emergency
   - CANNOT resolve disputes or steal funds

3. **Operational Procedures**
   - All disputes logged off-chain with evidence
   - Dispute resolution follows published arbitration rules
   - Transparent decision documentation

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

---

## Other Security Considerations

### Fixed Vulnerabilities

**Prior rounds:**
✅ **BLOCKER-1**: Escrow ID reuse attack - FIXED via `delete escrows[escrowId]` after completion
✅ **MEDIUM-5**: Mediator time-lock bypass - FIXED via `mediatorApprovedAt[mediator] == 0` check
✅ **HIGH-1**: State machine INITIATED→COMMITTED - FIXED via `linkEscrow` auto-transition
✅ **MEDIUM-2**: Vault verification - FIXED via `approvedEscrowVaults` check in all payout functions
✅ **MEDIUM-4**: MIN_DISPUTE_WINDOW - FIXED via 1-hour minimum enforcement
✅ **H-2**: Provider cancel flexibility - FIXED via requester-specific timing check
✅ **M-1**: Escrow lifecycle DoS - FIXED via `delete` after completion

**April 2026 audit (CTO + CODEx verification):**
✅ **H-2**: X402Relay two-step admin transfer - already fixed (confirmed by CODEx)
✅ **L-5**: ACTPKernel MIN_FEE enforcement - already fixed (confirmed by CODEx)
✅ **M-1**: Emergency USDC recovery - `emergencyRecoverUSDC()` (admin + paused only)
✅ **M-2**: Empty-proof dispute default removed - explicit resolution proof required
✅ **M-3**: `releaseEscrow()` pause bypass documented via NatSpec (intentional design)
✅ **L-1**: NatSpec on `executeAgentRegistryUpdate()` permissionless design
✅ **L-2**: Zero-address guard in `IdentityRegistry._changeOwner()`
✅ **L-3**: `deregisterAgent()` with swap-and-pop + reputation preservation on re-register
✅ **L-4**: Purpose param on `ArchiveTreasury.withdrawForArchiving()`
✅ **CEI**: Bond zeroing before external call in `_distributeBond()`
✅ **DOS**: feeRecipient payout wrapped in try-catch to prevent settlement DOS

### Known Limitations

1. **Dispute resolution requires trust** (see H-1 above)
2. **Gas costs ~3x target** (~750k vs 250k target for happy path)
3. **Off-chain arbitration delay** (~7 days review period)
4. **M-4**: ArchiveTreasury uploader can withdraw up to $1K/day without on-chain proof-of-archiving (rate-limited, monitoring recommended)

---

**Last Updated**: 2026-05-17
**Version**: v0.9.1 (audit fixes applied, pre-professional-audit)
**Security Contact**: [agirails.io/contact](https://agirails.io/contact)
