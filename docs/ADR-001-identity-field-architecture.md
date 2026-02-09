# ADR-001: Identity Field Architecture

**Status:** Accepted
**Date:** 2026-02-06
**Authors:** AGIRAILS Team

---

## Context

ACTP (Agent Commerce Transaction Protocol) needs to support agent identity tracking for reputation purposes. The initial implementation added `uint256 agentId` to support ERC-8004 (Trustless Agents) integration.

**Question raised:** Should we use a more flexible identity representation (e.g., `bytes32 identityHash + uint8 identityType`) to support future identity providers like ENS, Lens, Farcaster, or other standards?

## Decision

**We will keep `uint256 agentId` as an ERC-8004 specific field.**

Multi-identity support will be handled off-chain via subgraph indexers, not on-chain.

## Rationale

### 1. Protocol Simplicity (Vitalik Test)

| Test | `uint256 agentId` | `bytes32 + type` |
|------|-------------------|------------------|
| Trustless | PASS - simple uint | FAIL - needs decoder |
| Walkaway | PASS - obvious ERC-8004 | FAIL - type enum maintenance |
| Self-Sovereign | PASS - clear semantics | FAIL - centralized type registry |

> "An ideal protocol fits onto a single page." — Vitalik Buterin

### 2. Strategic Positioning

AGIRAILS is explicitly positioned as "the settlement layer for ERC-8004 agents". Tight ERC-8004 coupling is strategic, not limiting.

### 3. Identity is Off-Chain Concern

The `agentId` field is:
- NOT validated on-chain
- NOT used in state machine logic
- NOT part of protocol invariants
- ONLY used for off-chain indexing and reputation correlation

If identity doesn't affect on-chain behavior, it shouldn't drive on-chain complexity.

### 4. 5-Year Probability Analysis

| Scenario | Probability | Implication |
|----------|-------------|-------------|
| ERC-8004 dominates | 60% | Tight coupling = strategic win |
| Fragmentation persists | 30% | Off-chain indexers solve it |
| New standard supersedes | 10% | Contract upgrade required anyway |

### 5. YAGNI Principle

Adding `identityType` discrimination would create:
- New enum to maintain
- Decoder logic complexity
- Expanded test surface
- Future migration burden

We don't solve problems that don't exist yet.

## Consequences

### Positive

- Protocol remains simple and auditable
- Perfect type alignment with ERC-8004 (both use `uint256`)
- No maintenance burden for identity type registry
- Subgraph handles multi-identity enrichment naturally

### Negative

- Future identity systems cannot be tracked on-chain (by design)
- Requires clear documentation to prevent misuse

### Neutral

- Gas cost unchanged (`uint256` = `bytes32` = 1 storage slot)

## Alternatives Considered

| Option | Why Rejected |
|--------|--------------|
| `bytes32 identityHash` | Loses ERC-8004 native alignment, adds encoding complexity |
| `bytes32 + uint8 identityType` | Centralized type registry, maintenance burden |
| Off-chain only (no field) | Already implemented, removes ERC-8004 traceability |
| Use `metadata` field | Conflicts with AIP-2 quote hash, unclear semantics |

## Implementation

1. **Keep current implementation** - `uint256 agentId` in Transaction struct
2. **Update documentation** - Clarify field is ERC-8004 specific
3. **Enhance NatSpec** - Add parameter documentation
4. **Subgraph enrichment** - Handle multi-identity correlation off-chain

## Multi-Identity Off-Chain Strategy

The subgraph enriches transactions with identity from ANY source by querying external registries using the `provider` address.

### Subgraph Schema

```graphql
# schema.graphql

type Transaction @entity {
  id: ID!                           # bytes32 transactionId
  requester: Bytes!
  provider: Bytes!
  amount: BigInt!
  state: Int!
  createdAt: BigInt!
  deadline: BigInt!

  # On-chain identity (from TransactionCreated event)
  erc8004AgentId: BigInt            # 0 = not an ERC-8004 agent

  # Off-chain identity enrichment
  providerIdentity: ProviderIdentity @derivedFrom(field: "transactions")
}

type ProviderIdentity @entity {
  id: ID!                           # provider address
  address: Bytes!

  # ERC-8004 (from on-chain)
  erc8004AgentId: BigInt
  erc8004Name: String               # From agent metadata

  # ENS (reverse resolution)
  ensName: String                   # e.g., "vitalik.eth"
  ensAvatar: String

  # Lens Protocol
  lensProfileId: BigInt
  lensHandle: String                # e.g., "stani.lens"

  # Farcaster
  farcasterFid: BigInt
  farcasterUsername: String

  # Aggregate reputation
  totalTransactions: BigInt!
  successfulSettlements: BigInt!
  disputesLost: BigInt!

  transactions: [Transaction!]!
}
```

### Enrichment Handler

```typescript
// src/mapping.ts

import { TransactionCreated } from '../generated/ACTPKernel/ACTPKernel'
import { Transaction, ProviderIdentity } from '../generated/schema'

export function handleTransactionCreated(event: TransactionCreated): void {
  // Create Transaction entity
  let tx = new Transaction(event.params.transactionId.toHexString())
  tx.requester = event.params.requester
  tx.provider = event.params.provider
  tx.amount = event.params.amount
  tx.state = 0 // INITIATED
  tx.createdAt = event.block.timestamp
  tx.deadline = event.params.deadline
  tx.erc8004AgentId = event.params.agentId
  tx.save()

  // Upsert ProviderIdentity
  let providerId = event.params.provider.toHexString()
  let identity = ProviderIdentity.load(providerId)

  if (!identity) {
    identity = new ProviderIdentity(providerId)
    identity.address = event.params.provider
    identity.totalTransactions = BigInt.fromI32(0)
    identity.successfulSettlements = BigInt.fromI32(0)
    identity.disputesLost = BigInt.fromI32(0)

    // ENS enrichment (requires external call or separate indexer)
    // identity.ensName = resolveENS(event.params.provider)

    // Lens enrichment
    // identity.lensHandle = resolveLens(event.params.provider)

    // Farcaster enrichment
    // identity.farcasterUsername = resolveFarcaster(event.params.provider)
  }

  // Update ERC-8004 if provided
  if (event.params.agentId.gt(BigInt.fromI32(0))) {
    identity.erc8004AgentId = event.params.agentId
  }

  identity.totalTransactions = identity.totalTransactions.plus(BigInt.fromI32(1))
  identity.save()
}
```

### Query Examples

```graphql
# Get transaction with all provider identities
query TransactionWithIdentity($txId: ID!) {
  transaction(id: $txId) {
    id
    amount
    state
    erc8004AgentId
    provider
  }
  providerIdentity(id: $provider) {
    ensName
    lensHandle
    farcasterUsername
    erc8004Name
    totalTransactions
    successfulSettlements
  }
}

# Find providers by any identity
query FindProvider($ensName: String, $lensHandle: String) {
  providerIdentities(where: {
    or: [
      { ensName: $ensName },
      { lensHandle: $lensHandle }
    ]
  }) {
    address
    ensName
    lensHandle
    erc8004AgentId
    totalTransactions
  }
}
```

## References

- [ERC-8004: Trustless Agents](https://eips.ethereum.org/EIPS/eip-8004)
- [AGIRAILS Protocol Simplicity Guidelines](../COVENANT.md)

---

*This ADR examines technical, strategic, and philosophical dimensions of the identity field decision.*
