# Protocol Invariants

**ACTP** - Agent Commerce Transaction Protocol

This document defines the ethical invariants encoded in the ACTP protocol implementation. These principles are not policy choices but structural requirements that ensure protocol integrity and bilateral fairness.

---

## 1. Solvency Invariant

**Principle:** Never commit funds that cannot be guaranteed.

**Implementation:**
- Escrow balance validation before state transitions (`linkEscrow()`)
- Locked funds tracking in EscrowVault
- Settlement calculations verified against available balance

**Code Pattern:**
```solidity
// Solvency invariant: guarantee before commitment
require(escrowBalance >= amount, "Insufficient escrow");
```

**Rationale:** A commitment without backing is a promise without substance. The protocol enforces reality-backed guarantees.

---

## 2. Transparency Invariant

**Principle:** All state changes must be observable.

**Implementation:**
- Events emitted for every state transition
- Transaction history queryable on-chain
- Escrow movements logged and verifiable

**Code Pattern:**
```solidity
// State changes must be observable
emit StateTransitioned(txId, oldState, newState, block.timestamp);
```

**Rationale:** Trust emerges from verifiability. Hidden state changes enable manipulation; observable changes enable trust.

---

## 3. Bilateral Protection Invariant

**Principle:** Equal safeguards for both requester and provider.

**Implementation:**
- Dispute windows enforced symmetrically
- Deadline protection for both parties
- Penalty mechanisms apply equally to false claims

**Code Pattern:**
```solidity
// Bilateral protection: both parties get dispute window
require(block.timestamp > tx.completedAt + disputeWindow, "Window active");
```

**Rationale:** Asymmetric power corrupts markets. The protocol enforces structural fairness independent of party strength.

---

## 4. Finality Invariant

**Principle:** State transitions are irreversible.

**Implementation:**
- One-way state machine (no backwards transitions)
- Settled transactions are immutable
- Cancelled transactions cannot be reopened

**Code Pattern:**
```solidity
// State machine monotonicity: no backwards transitions
require(uint8(newState) > uint8(currentState), "Invalid transition");
```

**Rationale:** Reversibility enables endless disputes. Finality enables closure and economic efficiency.

---

## 5. Access Control Invariant

**Principle:** Only authorized parties can trigger state changes.

**Implementation:**
- Requester-only functions: `createTransaction`, `linkEscrow`, `releaseEscrow`
- Provider-only functions: `transitionState(DELIVERED)`, `anchorAttestation`
- Shared functions: `transitionState(DISPUTED)`
- Admin-only functions: `pause`, `setFeeRecipient` (with timelocks)

**Code Pattern:**
```solidity
// Authorization: only transaction requester
require(msg.sender == tx.requester, "Unauthorized");
```

**Rationale:** Unauthorized state changes are attacks. The protocol enforces identity-based permissions.

---

## 6. Emergency Control Invariant

**Principle:** Circuit breakers protect against catastrophic failure, but cannot steal funds.

**Implementation:**
- `pause()` stops state transitions, not fund withdrawals
- Emergency withdrawal requires 7-day timelock
- Pauser role separated from admin role

**Code Pattern:**
```solidity
// Pause blocks state changes, not fund recovery
modifier whenNotPaused() {
    require(!paused, "Protocol paused");
    _;
}
```

**Rationale:** Systems fail; humans make mistakes. Emergency controls must exist but must not enable theft.

---

## 7. Economic Parameter Delay Invariant

**Principle:** Fee changes require timelock to prevent surprise extraction.

**Implementation:**
- `scheduleFeeChange()` + `executeFeeChange()` pattern
- 2-day minimum delay (ECONOMIC_PARAM_DELAY)
- Fee cap enforced (MAX_PLATFORM_FEE_CAP = 5%)

**Code Pattern:**
```solidity
// Economic changes require advance notice
require(block.timestamp >= scheduledTime + ECONOMIC_PARAM_DELAY, "Timelock active");
```

**Rationale:** Instant fee changes enable value extraction. Timelocks enable user exit before unwanted changes.

---

## 8. Conservation Invariant

**Principle:** Funds entering the system equal funds leaving the system.

**Implementation:**
- Total deposits tracked
- Total settlements tracked
- Escrow balance reconciliation in tests

**Code Pattern:**
```solidity
// Fund conservation: in = out
uint256 totalOut = providerAmount + platformFee;
require(totalOut == escrowAmount, "Conservation violated");
```

**Rationale:** Funds appearing or disappearing indicate theft or loss. Conservation ensures accounting integrity.

---

## 9. Deadline Enforcement Invariant

**Principle:** Time-bound commitments expire if not fulfilled.

**Implementation:**
- Transaction deadline checked before acceptance
- Expired transactions can be cancelled
- Block timestamp used for time verification

**Code Pattern:**
```solidity
// Deadline protection: time-bound commitments
require(block.timestamp <= tx.deadline, "Deadline expired");
```

**Rationale:** Indefinite commitments enable griefing. Deadlines enforce liveness and economic efficiency.

---

## 10. Dispute Window Invariant

**Principle:** Both parties get time to contest delivery before finalization.

**Implementation:**
- Dispute window starts after `DELIVERED` state
- Finalization blocked during window
- Window duration set per transaction (max 30 days)

**Code Pattern:**
```solidity
// Dispute protection: verification time before finality
require(block.timestamp > tx.deliveredAt + tx.disputeWindow, "Dispute window active");
```

**Rationale:** Instant finalization enables fraud. Dispute windows enable verification and dispute.

---

## Mapping to CLAUDE.md Invariants

This covenant implements the 10 Critical Invariants specified in `CLAUDE.md`:

1. **Escrow Solvency** → Solvency Invariant (#1)
2. **State Machine Integrity** → Finality Invariant (#4)
3. **Fee Bounds** → Economic Parameter Delay Invariant (#7)
4. **Deadline Enforcement** → Deadline Enforcement Invariant (#9)
5. **Access Control** → Access Control Invariant (#5)
6. **Dispute Window** → Dispute Window Invariant (#10)
7. **Pause Effectiveness** → Emergency Control Invariant (#6)
8. **Economic Parameter Delays** → Economic Parameter Delay Invariant (#7)
9. **Single Transaction Per ID** → (Enforced in constructor/create logic)
10. **Fund Conservation** → Conservation Invariant (#8)

---

## Verification

These invariants are verified through:
- **Unit tests**: `test/ACTPKernel.t.sol`
- **Fuzz tests**: `test/ACTPKernelFuzz.t.sol`
- **Integration tests**: SDK `test/integration/`
- **Static analysis**: Slither, Mythril
- **Formal verification**: Planned (Month 12-18)

Every invariant violation should cause:
1. Transaction revert (runtime)
2. Test failure (development)
3. Security alert (monitoring)

---

## Maintenance

When modifying contracts:
1. **Check**: Does this change violate any invariant?
2. **Verify**: Do existing tests still pass?
3. **Add**: New tests for new edge cases
4. **Document**: Update this file if new invariants added

The covenant is not negotiable. Code that violates these principles is incorrect by definition.

---

**Last Updated:** 2025-12-22
**Version:** 1.0 (Initial deployment)
