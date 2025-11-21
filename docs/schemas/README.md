# AGIRAILS AIP Schemas

This directory contains JSON Schema and EIP-712 type definitions for all AGIRAILS Improvement Proposals.

## Status: ❌ NOT YET CREATED

All schema files are placeholders awaiting implementation. See [AIP-0.md](../AIP-0.md) §5.2 for blocking status.

---

## Schema Files (Planned)

### AIP-0.1: Provider Notification ✅ DRAFT COMPLETE

**Blocking: YES** - Required for IPFS Pubsub communication

- [x] `aip-0.1-notification.schema.json` - JSON Schema ✅
- [x] `aip-0.1-notification.eip712.json` - EIP-712 types ✅

**Status:** Draft schemas created, awaiting review and implementation
**Owner:** Protocol Team
**Next Steps:** Create SDK `NotificationBuilder` class

---

### AIP-1: Request Metadata

**Blocking: YES** - Required for consumer node implementation

- [ ] `aip-1-request.schema.json` - JSON Schema for request metadata validation
- [ ] `aip-1-request.eip712.json` - EIP-712 type definitions for signing

**Owner:** Protocol Team
**Deadline:** Before testnet launch
**Depends On:** Deployed contract addresses (for verifyingContract)

---

### AIP-4: Delivery Proof

**Blocking: YES** - Required for provider node implementation

- [ ] `aip-4-delivery.schema.json` - JSON Schema for delivery proof validation
- [ ] `aip-4-delivery.eip712.json` - EIP-712 type definitions for signing

**Owner:** Protocol Team
**Deadline:** Before testnet launch
**Depends On:** EAS schema UID for delivery proofs

---

### AIP-2: Quote Message (Optional)

**Blocking: NO** - Not implemented in v0.1

- [ ] `aip-2-quote.schema.json`
- [ ] `aip-2-quote.eip712.json`

---

### AIP-5: Dispute Evidence (Future)

**Blocking: NO** - Post-launch feature

- [ ] `aip-5-dispute.schema.json`
- [ ] `aip-5-dispute.eip712.json`

---

### AIP-6: Resolution Decision (Future)

**Blocking: NO** - Post-launch feature

- [ ] `aip-6-resolution.schema.json`
- [ ] `aip-6-resolution.eip712.json`

---

## Schema Format

### JSON Schema Files (`*.schema.json`)

Used for runtime validation of message payloads. Must follow JSON Schema Draft 7 specification.

**Example structure:**
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "AIP-1 Request Metadata",
  "type": "object",
  "required": ["txId", "consumer", "provider", "serviceType"],
  "properties": {
    "txId": {
      "type": "string",
      "pattern": "^0x[a-fA-F0-9]{64}$"
    }
  }
}
```

---

### EIP-712 Type Files (`*.eip712.json`)

Used for typed structured data signing. Must match EIP-712 specification.

**Example structure:**
```json
{
  "domain": {
    "name": "AGIRAILS",
    "version": "1",
    "chainId": 84532,
    "verifyingContract": "<ACTP_KERNEL_ADDRESS>"
  },
  "primaryType": "Request",
  "types": {
    "Request": [
      { "name": "txId", "type": "bytes32" },
      { "name": "consumer", "type": "string" },
      { "name": "provider", "type": "string" },
      { "name": "serviceType", "type": "string" }
    ]
  }
}
```

---

## Implementation Checklist

**Before creating schemas:**
1. ✅ Review AIP-0 meta protocol requirements
2. ✅ Finalize message field requirements (see AIP-1 and AIP-4 specs when created)
3. ✅ Ensure deployed contract addresses available (for verifyingContract)

**When creating schemas:**
1. Create JSON Schema file with all required/optional fields
2. Create EIP-712 type definition matching JSON Schema
3. Add validation examples (valid and invalid payloads)
4. Compute EIP-712 type hash: `keccak256(encodeType('PrimaryType'))`
5. Update AIP-0.md §5.2 with actual type hash values

**After creating schemas:**
1. Implement SDK `RequestBuilder` and `DeliveryProofBuilder`
2. Add schema validation to SDK message creation
3. Write unit tests validating schema compliance
4. Update AIP-0.md to mark schemas as ✅ Available

---

## References

- [JSON Schema Specification](https://json-schema.org/specification.html)
- [EIP-712: Typed Structured Data Hashing and Signing](https://eips.ethereum.org/EIPS/eip-712)
- [AIP-0: Meta Protocol](../AIP-0.md)

---

**Last Updated:** 2025-11-16
**Status:** Awaiting implementation
