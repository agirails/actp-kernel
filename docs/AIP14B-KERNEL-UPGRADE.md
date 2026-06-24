# AIP-14b — Kernel V2 Redeploy + Re-point Fan-out Runbook (P4-2)

> **Scope.** The ACTP kernel must be redeployed (not upgraded) to ship the AIP-14b
> three-tier dispute system. This document is the **load-bearing migration runbook**:
> it (1) states *why* a redeploy is required with on-chain evidence, (2) enumerates
> **every reference** to the OLD kernel and OLD vault that must be re-pointed, and
> (3) gives the ordered, Safe-submittable execution plan. It pairs with the deploy
> helper `script/DeployKernelV2.s.sol` and the address artifact `deployments/aip14b.json`.
>
> References: PRD §5.1 (resolver authorization), §11 (deploy/config). Decisions:
> `DISPUTE SYSTEM/AIP14B-DECISIONS.md` G1/G2/G3/G4.

---

## 0. TL;DR

- **Redeploy required — the kernel is NON-upgradeable (G3).** There is no proxy; the
  kernel is constructed with a plain `new ACTPKernel(...)`. The vault, registry and
  archive treasury bind the kernel via **`immutable`** fields, so a new kernel forces a
  new vault (mandatory) and fresh registry + archive (if those services must follow v2).
- **A NEW EscrowVault is part of the redeploy and MUST be approved** on the v2 kernel via
  `approveEscrowVault(newVault, true)`. Skip it and the kernel can never pay out, refund,
  or pay a mediator — *even admin dispute resolution reverts* (`"Vault not approved"`).
- **X402Relay does NOT reference the kernel or vault** (verified: zero `kernel`/`vault`
  symbols in `src/relay/X402Relay.sol`). It is NOT re-pointed at the contract level; it is
  only touched in the **paymaster allowlists** and the **SDK network config**.
- Mainnet wiring is **Safe-submitted** (admin = Gnosis Safe `0x61fE…b7f2`, 2-of-3). No
  private keys in any file; the deploy script emits Safe calldata, the Safe operator signs.

---

## 1. Why redeploy, not upgrade (G3 evidence)

The kernel has **no upgrade path** and three downstream contracts hardcode it as `immutable`.
A new kernel address therefore cannot be "pointed at" by the existing peripherals — they must
be redeployed against it.

| Contract | Field binding the kernel | Mutable? | Consequence for v2 |
|----------|--------------------------|----------|--------------------|
| `ACTPKernel` | n/a (no proxy; `new ACTPKernel(...)`) | **immutable code** | New address. |
| `EscrowVault` | `address public immutable kernel` (L29) | **immutable** | **NEW vault mandatory.** |
| `AgentRegistry` | `address public immutable actpKernel` (L41) | **immutable** | **Fresh registry** if registry must track v2; old registry stays bound to old kernel. |
| `ArchiveTreasury` | `IACTPKernel public immutable kernel` (L85) | **immutable** | **Fresh archive** if fee-archiving must follow v2; old archive stays bound to old kernel. |
| `X402Relay` | *(none — no kernel/vault reference)* | n/a | **No contract re-point.** Allowlist + SDK config only. |

The kernel→registry link is the *only* re-pointable edge: the kernel stores the registry in a
**mutable** slot updated through a 2-day timelock (`scheduleAgentRegistryUpdate` →
`executeAgentRegistryUpdate`). Everything else is one-directional immutable coupling, hence the
fresh-deploy requirement. This is the structural justification for G3 ("redeploy required").

### 1.1 The mandatory `approveEscrowVault` — grep-confirmed call sites

A v2 vault is inert until the v2 kernel approves it. Three internal fund-movement paths gate on
`approvedEscrowVaults[vault]` and revert `"Vault not approved"` otherwise
(`src/ACTPKernel.sol`):

- **L1049** `_payoutProviderAmount` — provider settlement payout.
- **L1145** `_refundRequester` — requester refund (cancellation / split resolution).
- **L1156** `_payoutMediator` — paid-mediator fee payout.

Because dispute resolution (`DISPUTED → SETTLED/CANCELLED`) routes through these helpers,
**even an admin-driven INV-6 resolution reverts** if the new vault was never approved. The deploy
script wires this atomically on testnet (admin == deployer) and emits it as **Safe TX 1
(MANDATORY)** on mainnet.

### 1.2 §5.1 resolver-authorization — grep-confirmed at the two "Resolver only" sites

The resolver set is `{admin} ∪ {approved mediators past their 2-day MEDIATOR_APPROVAL_DELAY}`,
computed by `_isApprovedResolver` (`src/ACTPKernel.sol` L755). Per G1 the **pauser is NOT a
resolver**. Both DISPUTED-exit authorization checks were confirmed by grep to call the same gate:

- **L781** — `_enforceAuthorization`, `DISPUTED → {SETTLED, CANCELLED}` edge:
  `require(_isApprovedResolver(msg.sender), "Resolver only");`
- **L990** — `_handleCancellation` cancellation/split path:
  `require(_isApprovedResolver(triggeredBy), "Resolver only");`

(A third, pause-exempt occurrence at **L279** in `resolveDisputeWhilePaused` applies the same
`_isApprovedResolver` gate.) **Migration impact:** `_isApprovedResolver` is `{admin} ∪ {mediators}`
with *no stored kernel/vault address* — it carries no stale reference, so the resolver authorization
needs **no code edit** for v2. What it *does* require operationally is that the v2 kernel re-runs
`approveMediator(CompositeMediator, true)` (the OLD kernel's mediator approval does NOT carry over),
which re-arms the 2-day mediator timelock on the new kernel. That step is owned by the dispute-system
deploy (`DeployDisputeSystem.s.sol` / P6-1), not this script, and is listed in the checklist below.

---

## 2. Redeploy order (what `script/DeployKernelV2.s.sol` does)

1. Deploy `ACTPKernel` v2 — 6-arg F-6 constructor
   `ACTPKernel(admin, pauser, feeRecipient, agentRegistry=0, usdc, recoveryGrace)`.
   `recoveryGrace` = **7 days (604800) mainnet**, **1 hour (3600) testnet** (`>= MIN_RECOVERY_GRACE`).
2. Deploy **NEW** `EscrowVault(usdc, kernelV2)`.
3. *(optional `DEPLOY_REGISTRY=true`)* Deploy fresh `AgentRegistry(kernelV2)`.
4. *(optional `DEPLOY_ARCHIVE=true`)* Deploy fresh `ArchiveTreasury(usdc, kernelV2, uploader)`.
5. Wire:
   - **testnet (admin == deployer):** atomic `approveEscrowVault(newVault, true)`,
     `setArchiveTreasury(newArchive)`, `archive.transferOwnership(admin)`,
     `scheduleAgentRegistryUpdate(newRegistry)`.
   - **mainnet (admin == Safe):** the script broadcasts **no** `onlyAdmin` call; it prints
     Safe-submittable calldata for each wiring step.

Addresses come from env / write-back (`MAINNET_KERNEL_V2`, `MAINNET_VAULT_V2`, …), never hardcoded
broadcast literals — the only hardcoded address is the immutable Circle USDC on mainnet.

---

## 3. THE RE-POINT FAN-OUT CHECKLIST (the enumerated deliverable)

Every reference to the **OLD kernel** (`0x132B…2d29` mainnet / `0x469C…3411` sepolia) and **OLD vault**
(`0x6aAF…Fb99` mainnet / `0x57f8…49E5` sepolia) that must be re-pointed or re-issued for v2.
"Type" is **re-point** (mutable update), **redeploy** (immutable → fresh contract), **re-add**
(allowlist entry keyed on address), or **config** (off-chain string).

### A. On-chain contract wiring

| # | Target | OLD ref | Action | Type | Owner |
|---|--------|---------|--------|------|-------|
| A1 | **EscrowVault** | old vault bound to old kernel (immutable) | Deploy NEW vault `(usdc, kernelV2)`. | redeploy | DeployKernelV2 |
| A2 | **v2 kernel ← vault** | — | `approveEscrowVault(newVault, true)` on v2 kernel. **MANDATORY** (§1.1). | re-point | Safe TX 1 / atomic |
| A3 | **AgentRegistry** | `actpKernel` immutable = old kernel (L41) | Deploy fresh `AgentRegistry(kernelV2)`; old registry stays on old kernel. | redeploy | DeployKernelV2 `DEPLOY_REGISTRY` |
| A4 | **v2 kernel ← registry** | — | `scheduleAgentRegistryUpdate(newRegistry)` then `executeAgentRegistryUpdate()` after 2-day timelock. | re-point | Safe TX 4 + permissionless exec |
| A5 | **ArchiveTreasury** | `kernel` immutable = old kernel (L85) | Deploy fresh `ArchiveTreasury(usdc, kernelV2, uploader)`; transfer ownership to Safe. | redeploy | DeployKernelV2 `DEPLOY_ARCHIVE` |
| A6 | **v2 kernel ← archive** | — | `setArchiveTreasury(newArchive)` on v2 kernel. | re-point | Safe TX 2/3 |
| A7 | **CompositeMediator** | `kernel` arg = old kernel | Deploy with `kernel = kernelV2` (G4 write-once `initialize`). | redeploy | DeployDisputeSystem (P4-1/P6-1) |
| A8 | **BondEscalation** | `kernel` arg = old kernel | Deploy with `kernel = kernelV2`, `usdc`, `compositeMediator`, `umaOOV3=0`. | redeploy | DeployDisputeSystem (P4-1/P6-1) |
| A9 | **v2 kernel ← mediator** | OLD kernel's `approveMediator` does NOT carry over | `approveMediator(CompositeMediator, true)` on v2 kernel → starts 2-day `MEDIATOR_APPROVAL_DELAY`. The mediator is NOT a resolver until the delay elapses (§1.2). | re-add | Safe (post-deploy) |
| A10 | **X402Relay** | *(no kernel/vault ref)* | **No contract change.** Relay is fee-only and chain-independent of the kernel. Touched only at B-row allowlists + SDK config. | — | — |
| A11 | **EAS DeliverySchema** | schema UID `0x1665…9c9a` is content-addressed, NOT kernel-bound | **No re-register.** The delivery attestation schema is reused verbatim; only the *attester/resolver* wiring (if any references the kernel) is re-checked. Confirm no resolver contract points at old kernel before reuse. | verify | Ops |

### B. Off-chain authority / allowlists (keyed on contract address — MUST be re-added for v2)

| # | Target | Why it breaks on v2 | Action |
|---|--------|---------------------|--------|
| B1 | **Gnosis Safe admin** (`0x61fE…b7f2`, 2-of-3) | Safe is the v2 kernel admin/pauser/feeRecipient; it must hold/queue all v2 `onlyAdmin` wiring txns (A2/A4/A6/A9). The OLD-kernel Safe txns are historical. | Build the v2 wiring batch (calldata from DeployKernelV2 + DeployDisputeSystem). |
| B2 | **CDP paymaster allowlist** | Old allowlist sponsors gas for the OLD kernel/vault/relay only. v2 kernel, v2 vault, and BondEscalation are NOT sponsored until added → publish/dispute txns fail to get gas. | **Re-add** v2 kernel, v2 vault, CompositeMediator, BondEscalation (and confirm X402Relay still present) to the CDP allowlist on both chains. |
| B3 | **Pimlico paymaster allowlist** | Same as B2 for the failover bundler/paymaster. | **Re-add** the same v2 set to the Pimlico allowlist on both chains. |
| B4 | **Evaluator signer registry** | BondEscalation is fresh (A8); its fixed/rotating evaluator set is constructor-seeded from `EVALUATOR_FIXED_0/1`, `EVALUATOR_ROTATING` (>=3; legacy fallback `EVALUATOR_ROTATING_0.._7`). | Confirm evaluator addresses unchanged; keys remain in KMS/keystore (never in repo). |

### C. Published SDK / integration network-config touchpoints (the 6 surfaces)

All six published packages embed the kernel/vault/registry/relay addresses in a network-config map
and must be re-released pointing at v2. Each ships independently.

| # | Surface | Where the addresses live | Action |
|---|---------|--------------------------|--------|
| C1 | **TypeScript SDK** (`@agirails/sdk`) | network config (`baseMainnet`/`baseSepolia` contracts map) | Bump kernel + vault (+ registry/archive if changed); add BondEscalation/CompositeMediator if surfaced; publish minor. |
| C2 | **Python SDK** (`agirails`) | mirror network config | Same address bump; publish to PyPI in lockstep with C1. |
| C3 | **n8n node** (`n8n-nodes-actp`) | embedded contract addresses | Bump + republish. |
| C4 | **CLI** (`actp …`, ships in the SDK) | reads the SDK network config | Covered by C1 build; verify `actp publish`/`pull`/`diff` resolve v2. |
| C5 | **OpenClaw skill** | SKILL config / examples referencing addresses | Update address references + examples; push skill. |
| C6 | **Claude Code plugin / agirails skill** | agent skill config + docs | Update address references in the skill and onboarding docs. |

> The address artifact `deployments/aip14b.json` and `deployments/base-mainnet.json` /
> `deployments/base-sepolia.json` are the canonical source the SDKs sync from — update them first,
> then propagate to C1–C6.

### D. In-flight transaction migration impact

- **Old kernel keeps running.** It is non-upgradeable and not destroyed; any transaction already
  `INITIATED…DISPUTED` on the OLD kernel **must be settled on the OLD kernel** — funds live in the
  OLD vault, which only the OLD kernel can move. There is **no state migration** of escrow between
  kernels (escrow IDs and balances are vault-local).
- **Drain-then-cutover.** Before announcing v2 as the default, drive all live OLD-kernel transactions
  to a terminal state (SETTLED/CANCELLED), or accept a dual-kernel window where the old kernel resolves
  legacy txns while new txns route to v2. The dispute system (mediator/UMA) is wired to v2 ONLY — legacy
  disputes on the OLD kernel resolve via the OLD kernel's existing resolver set (admin), NOT the new
  CompositeMediator.
- **Auto-settle / keeper jobs** that reference the OLD kernel address (e.g. the armed Sepolia
  auto-settle, `SmokeArmAutoSettle`/`SmokeExecAutoSettle`) must be re-pointed at v2 only after the
  legacy queue is drained, or split per-kernel.

### E. Integrator-notice checklist (publish when v2 goes live)

- [ ] New mainnet + sepolia addresses table (kernel v2, vault v2, registry v2, archive v2,
      CompositeMediator, BondEscalation) published in docs + `deployments/*.json`.
- [ ] SDK release notes (C1–C6) calling out the address change + minimum SDK version for v2.
- [ ] Explicit migration note: **legacy in-flight txns settle on the old kernel**; new txns require
      the updated SDK.
- [ ] Paymaster allowlist (CDP + Pimlico) re-add confirmed on both chains (gas sponsorship works for v2).
- [ ] Dispute system live notice: 3-tier dispute (bond escalation → UMA) available on v2 only;
      2-day mediator timelock window stated.
- [ ] Block explorer verification (Sourcify/Basescan) of all v2 contracts linked.

---

## 4. Ordered execution plan (mainnet, Safe-submitted)

1. **Deploy** (deployer hot key): `DeployKernelV2.s.sol` with `DEPLOY_REGISTRY`/`DEPLOY_ARCHIVE` as
   needed → kernel v2 + vault v2 (+ registry/archive). Verify contracts.
2. **Write back** kernel v2 / vault v2 (+ registry/archive) to `deployments/aip14b.json`,
   `deployments/base-mainnet.json`, and `.env` (`MAINNET_KERNEL_V2`, `MAINNET_VAULT_V2`).
3. **Safe batch #1** (kernel wiring): `approveEscrowVault(vaultV2, true)` *(A2 — MANDATORY)*;
   `setArchiveTreasury(archiveV2)` *(A6)*; `scheduleAgentRegistryUpdate(registryV2)` *(A4)*;
   `archive.transferOwnership(Safe)` *(A5)*.
4. **Deploy dispute system** (`DeployDisputeSystem.s.sol`) with `MAINNET_KERNEL_V2`/`MAINNET_VAULT_V2`
   → CompositeMediator + BondEscalation *(A7/A8)*; `initialize` per G4.
5. **Safe batch #2** (dispute wiring): `approveMediator(CompositeMediator, true)` on kernel v2
   *(A9 — starts 2-day mediator timelock)*.
6. **After timelocks:** permissionless `executeAgentRegistryUpdate()` (A4); mediator becomes an
   active resolver once `block.timestamp >= mediatorApprovedAt`.
7. **Allowlists:** re-add v2 kernel/vault/CompositeMediator/BondEscalation to CDP + Pimlico
   (both chains) *(B2/B3)*.
8. **Release** SDK touchpoints C1–C6 and publish the integrator notice (Section E).

> **Sequencing constraint:** A2 (approve vault) must precede any v2 transaction that can reach a
> payout/refund/mediator path, and A9 (approve mediator) must be submitted ≥ 2 days before the
> CompositeMediator is expected to resolve a live dispute on v2.
