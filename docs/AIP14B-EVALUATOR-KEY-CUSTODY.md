# AIP-14b — Evaluator Key Custody & Registry Operations (P4-4)

> Scope: custody of the **evaluator signing keys** and the operational runbook for the
> on-chain evaluator registry in `src/BondEscalation.sol` (genesis seeding + add / remove / swap).
> Companion to `script/InitEvaluatorRegistry.s.sol` (the genesis-init simulation/assert harness).
>
> Spec refs: AIP-14b §4.1 (tier overview), §4.6 (evaluator registry), §4.8 (signature verification),
> §4.9 (registry governance), §4.10 (evaluator hardening).
> Invariants: **INV-16** (the AI verdict is challengeable, never self-authoritative),
> **INV-17** (registry mutations are timelocked — fixed updates + rotating additions = 2-day
> `EVALUATOR_UPDATE_DELAY`; removals immediate), **INV-18** (evaluator disjointness — fixed slots
> distinct from each other and from the rotating pool).
> Open question closed: **OQ-5** (non-timelocked genesis registry-init path EXISTS — it is the
> BondEscalation constructor; see §2 below).

---

## 0. The one rule

**Zero evaluator private keys live in this repository, in any deploy script, in any `.env`, or in any
committed file — ever.** The registry stores only the *public addresses*. The matching private keys
are KMS/keystore-resident and are generated **before** this task in a separate, access-controlled
procedure. `script/InitEvaluatorRegistry.s.sol` and `deployments/aip14b.json` carry only **address
placeholders resolved from environment variables at runtime**.

What the chain sees: three (or more) `address` values. What signs an `AIRuling`: a private key held
in KMS/keystore that the evaluator service loads at request time. The two are bound only by the fact
that `ECDSA.recover(digest, signature)` of a ruling equals a registered address (§4.8). The chain
never holds, derives, or transmits a private key.

---

## 1. What the registry holds (§4.6)

```solidity
address[2] public fixedEvaluators;   // slot 0, slot 1 — the two permanent evaluators
address[] public rotatingPool;       // >= 1 by contract; >= 3 by P4-4 operational policy
```

For each dispute, the third evaluator is picked deterministically from the pool (§4.8):

```
thirdEvaluator = rotatingPool[ uint256(keccak256(abi.encode(disputeId))) % rotatingPool.length ]
```

A signed `AIRuling` is accepted only when **≥ 2 of the 3** addresses (`fixedEvaluators[0]`,
`fixedEvaluators[1]`, the disputed-id-selected `thirdEvaluator`) produce valid EIP-712 signatures
(§4.8 threshold = 2). This 2-of-3 is the reason key custody matters: a single compromised key cannot
move funds; an attacker needs to compromise **two distinct** evaluator keys *and* still survive the
Tier-1 bond-escalation challenge window (INV-16 — the verdict is challengeable, never final on its
own).

### Vendor lineage (D1) vs signing address (KMS)

Decision **D1** fixes the *model vendor lineages*: the two fixed slots MUST be served by models from
independent vendors with distinct training lineages (§4.10 #4, e.g. **Claude + GPT**), and the
rotating pool SHOULD add a **third lineage** (e.g. **Gemini**). This is a constraint on *which model
service produces the ruling*, not on the key.

The **signing addresses are KMS-derived** and bear no on-chain relationship to the vendor. Lineage is
an operational/organizational property enforced off-chain (which KMS key each evaluator service uses,
documented in the runbook below), not something the contract can read. Therefore the registry stores
generic, opaque addresses; the *mapping* address → vendor lineage lives only in this doc + the secure
ops inventory, never in code.

| Role | Vendor lineage (D1, §4.10 #4) | Key location | On-chain field |
|------|-------------------------------|--------------|----------------|
| Fixed slot 0 | Lineage A (e.g. Claude) — MUST differ from slot 1 | KMS key `evaluator-fixed-0` | `fixedEvaluators[0]` |
| Fixed slot 1 | Lineage B (e.g. GPT) — MUST differ from slot 0 | KMS key `evaluator-fixed-1` | `fixedEvaluators[1]` |
| Rotating 0..N | Lineage C+ (e.g. Gemini, …) SHOULD add a third lineage | KMS keys `evaluator-rotating-{i}` | `rotatingPool[i]` |

---

## 2. Genesis seeding is the constructor (OQ-5)

There is **no post-deploy `seed()` function**. The registry is populated **once, non-timelocked, in
the BondEscalation constructor** (`src/BondEscalation.sol`, "OQ-5 genesis seeding"):

```solidity
constructor(
    IACTPKernel kernel_, IERC20 usdc_, ICompositeMediator compositeMediator_,
    address admin_,
    address[2] memory fixedEvaluators_,   // <-- genesis fixed set
    address[] memory rotatingPool_,       // <-- genesis rotating set
    address umaOOV3_
)
```

**Why non-timelocked at genesis (OQ-5):** every *later* mutation is guarded by the 2-day
`EVALUATOR_UPDATE_DELAY` (INV-17). If genesis seeding went through the same timelock, the very first
dispute would be unservable for 2 days after deploy. The constructor therefore writes the live
registry directly — exactly once, at the moment the contract comes into existence, before any
external party can interact with it. This is safe because the constructor caller is the deployer and
the seeded set is fully asserted against the intended config (`script/InitEvaluatorRegistry.s.sol`
`_assertRegistry`).

The constructor enforces INV-18 at seed time:
- `fixedEvaluators_[0] != 0`, `fixedEvaluators_[1] != 0`, and the two fixed slots differ.
- `rotatingPool_.length >= 1` (contract floor) and every member is non-zero and **disjoint from both
  fixed slots**.

`script/InitEvaluatorRegistry.s.sol` adds the **P4-4 operational floor of ≥ 3 rotating members**
(defense-in-depth over the contract's ≥ 1) and rejects duplicate rotating members, so the §4.8
rotating pick has real entropy.

### Running the genesis-init harness (simulation only — NO broadcast)

```bash
# Base Sepolia genesis simulation (testnet admin = deployer EOA)
DISPUTE_ADMIN=0x...                       \
EVALUATOR_FIXED_0=0x...                    \
EVALUATOR_FIXED_1=0x...                    \
EVALUATOR_ROTATING=0xAAA,0xBBB,0xCCC       \
forge script script/InitEvaluatorRegistry.s.sol --rpc-url "$BASE_SEPOLIA_RPC" --sig "runSepolia()"

# Base Mainnet genesis simulation (admin = Gnosis Safe; kernel = G3 v2 redeploy from env)
MAINNET_KERNEL_V2=0x...                    \
DISPUTE_ADMIN=0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2  \
EVALUATOR_FIXED_0=0x... EVALUATOR_FIXED_1=0x...           \
EVALUATOR_ROTATING=0x...,0x...,0x...       \
forge script script/InitEvaluatorRegistry.s.sol --rpc-url "$BASE_MAINNET_RPC" --sig "runMainnet()"
```

The addresses are supplied **from KMS-generated public keys via env** — the script never embeds them.
The real broadcast happens in **P4-1** (Sepolia) and **P6-1** (mainnet, Safe-submitted), not here.

---

## 3. Per-key custody

Each evaluator key is generated and held under one of the two approved custody models. Mainnet
production MUST use KMS; keystore is acceptable for testnet evaluators only.

### A. KMS (production — mandatory for mainnet)

- Key generated **inside** a cloud KMS / HSM (AWS KMS `secp256k1` key, or equivalent). The private
  key is **non-exportable**: it never leaves the HSM boundary, so it cannot be copied into a `.env`,
  a CI secret, or a container image.
- The evaluator service signs the EIP-712 `AIRuling` digest via a KMS `Sign` API call; it receives a
  signature, never the key.
- The **public address** is derived once at key creation and handed to the registry operator, who
  sets it as the corresponding `EVALUATOR_*` env var for the genesis init / governance call.
- IAM: only the evaluator service's role may invoke `Sign` on its own key; a *separate* admin role
  may rotate/disable. No human role has `GetKeyMaterial`/export.
- Audit: every `Sign` is CloudTrail-logged; alert on `Sign` calls outside the evaluator service's
  expected rate/identity.

### B. Encrypted keystore (testnet evaluators only)

- EIP-2335 / Web3 Secret Storage JSON keystore, AES-encrypted, password from a secrets manager
  (never committed, never in `.env`). Acceptable only for Sepolia evaluator signers, where funds are
  test funds and the UMA Tier-2 path is inert by design.
- The keystore file lives outside the repo tree and is excluded by `.gitignore`; only its derived
  public address enters the env.

**Forbidden for all keys:** plaintext private key in `.env`, in a deploy script, in a container layer,
in a CI variable, or in `deployments/aip14b.json`. The registry-init script reads **addresses only**.

---

## 4. Registry mutation runbook (§4.9, INV-17)

After genesis, every change goes through the on-chain governance surface
(`IBondEscalationAdmin`). **`admin` is the only authorized mutator** — testnet: deployer EOA;
**mainnet: the Gnosis Safe `0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2` (2-of-3)**, so every mainnet
mutation is a Safe transaction, never a raw key broadcast.

INV-18 disjointness is **re-checked at execute time** for additions (a fixed slot could have been
re-pointed to the same address while a rotating addition sat in the 2-day queue), so a config that was
disjoint at propose time but would overlap at execute time is rejected on `execute*`.

### 4.1 Swap a FIXED evaluator (e.g. rotate a compromised Claude key) — TIMELOCKED (2 days)

```
1. (admin)  proposeFixedEvaluatorUpdate(slot, newAddr)   // slot ∈ {0,1}; emits ...Proposed(unlockTime)
2. wait     >= EVALUATOR_UPDATE_DELAY (2 days)            // INV-17
3. (anyone) executeFixedEvaluatorUpdate(slot)            // re-checks: newAddr != other fixed slot,
                                                          // newAddr ∉ rotatingPool (INV-18); emits ...Updated
   (abort)  cancelFixedEvaluatorUpdate(slot)             // admin-only; clears the pending update
```
- `newAddr` is the **public address of a freshly KMS-generated key of the SAME vendor lineage**
  (D1 / §4.10 #4: slot 0 and slot 1 must remain distinct lineages after the swap).
- The 2-day delay is intentional: changing a fixed evaluator affects *all future disputes*, so the
  network gets advance notice and a cancel window.

### 4.2 Add a ROTATING evaluator — TIMELOCKED (2 days)

```
1. (admin)  proposeRotatingPoolAddition(newAddr)         // newAddr ∉ fixed slots (INV-18); emits ...Proposed
2. wait     >= EVALUATOR_UPDATE_DELAY (2 days)
3. (anyone) executeRotatingPoolAddition(index)           // re-checks INV-18 disjointness; emits RotatingPoolUpdated(_, true)
```
- `index` is the position in `pendingRotatingAdditions` (see `pendingRotatingAdditionsLength()`).

### 4.3 Remove a ROTATING evaluator — IMMEDIATE (rapid compromise response)

```
(admin) removeFromRotatingPool(index)                    // requires rotatingPool.length > 1; emits RotatingPoolUpdated(_, false)
```
- **Immediate by design (§4.9):** removal only shrinks the future selection set and cannot enable an
  immediate exploit, so a compromised rotating key can be ejected without waiting 2 days.
- The contract enforces `rotatingPool.length > 1` (cannot empty the pool). **P4-4 policy:** keep the
  pool ≥ 3; if a removal would drop it to 2, *first* run an addition (4.2) or treat the situation as
  an incident and pause (`pause()`) the entry paths while the pool is rebuilt.

### 4.4 "Swap" a rotating evaluator

There is no atomic rotating-swap. To replace rotating key X with Y while staying ≥ 3:
```
1. propose + (2 days) + execute addition of Y    (4.2)   // pool temporarily grows
2. removeFromRotatingPool(indexOfX)              (4.3)   // immediate
```
Doing the addition first guarantees the pool never dips below the operational floor during the swap.

### 4.5 Emergency

- **Pause:** `pause()` (admin) halts the pausable entry paths. Recovery/sync paths
  (`finalize`, `forceResolveStale`, `claimEscalationRefund`, `syncExternalResolution`) remain live
  (INV-9) so in-flight disputes can still settle.
- A single compromised evaluator key is **not** an emergency on its own: the 2-of-3 threshold +
  Tier-1 challengeability (INV-16) means one bad signature cannot finalize a wrong ruling. Eject the
  key (4.1 for fixed via the timelock, 4.3 for rotating immediately) and rotate.

---

## 5. Address write-back & where placeholders live

| Where | Holds | Form |
|-------|-------|------|
| KMS / keystore | private keys | **never leaves HSM / encrypted file** |
| Secure ops inventory (out of repo) | address → vendor-lineage → KMS-key mapping | access-controlled doc |
| `.env` (local, gitignored) | `EVALUATOR_FIXED_0/1`, `EVALUATOR_ROTATING[_i]`, `DISPUTE_ADMIN` | **addresses only**, placeholders in `.env.example` |
| `script/InitEvaluatorRegistry.s.sol` | reads the above env vars | **no literal addresses** (except known immutables: USDC, kernel) |
| `deployments/aip14b.json` | `disputeContracts.*` deployed addresses + `${EVALUATOR_*}` placeholders | written back at REAL broadcast (P4-1 / P6-1), `status: AWAIT_BROADCAST` until then |

The deployed `BondEscalation` / `CompositeMediator` addresses are written back into
`deployments/aip14b.json` (`disputeContracts.*.address`, `status: DEPLOYED`) **only at real broadcast
time** (P4-1 Sepolia / P6-1 mainnet) — P4-4 leaves them `null` / `AWAIT_BROADCAST`.

---

## 6. Pre-deploy checklist (run before P4-1 / P6-1 broadcast)

- [ ] All evaluator keys generated in KMS (mainnet) / encrypted keystore (testnet). **No key in repo.**
- [ ] Fixed slot 0 and slot 1 are **distinct vendor lineages** (D1 / §4.10 #4) and **distinct addresses** (INV-18).
- [ ] Rotating pool has **≥ 3 members**, all non-zero, all disjoint from the fixed slots, no duplicates (INV-18 + P4-4 floor).
- [ ] At least one rotating member is a **third lineage** (D1 SHOULD).
- [ ] `script/InitEvaluatorRegistry.s.sol` simulation passes `_assertRegistry` against the intended set.
- [ ] `DISPUTE_ADMIN` = deployer EOA (testnet) / Gnosis Safe `0x61fE…b7f2` (mainnet).
- [ ] Address → vendor-lineage → KMS-key mapping recorded in the secure ops inventory (NOT in repo).
- [ ] Post-deploy wiring planned: `mediator.initialize(bond)` (G4) → `kernel.approveMediator(mediator, true)` (2-day `MEDIATOR_APPROVAL_DELAY`), Safe-submitted on mainnet.
