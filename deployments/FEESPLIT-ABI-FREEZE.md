# FeeSplitVault — ABI freeze

> **Frozen 2026-11-11** after plan steps 1-8 went green on `claudex/feesplit-vault` (base `origin/main`
> `b08c0c6`). This is the surface the SDK track builds against. The values below are generated with
> `forge inspect FeeSplitVault methodIdentifiers | abi | storageLayout`; do not change the contract
> surface without re-freezing here. A fix that follows the independent inspection re-freezes this file.
>
> **Scope.** `src/escrow/FeeSplitVault.sol` and `src/interfaces/IFeeSplitVault.sol`. Nothing in the
> kernel, `EscrowVault`, `IEscrowValidator`, `IACTPKernel`, `BondEscalation` or `CompositeMediator`
> changes; their freezes (`AIP14C-ABI-FREEZE.md`, `AIP14C-BOND-ABI-FREEZE.md`) stand.

## Identity

| Item | Value |
|---|---|
| Constructor | `constructor(address token, address kernel)`; both immutable; no owner, admin, pause or proxy |
| Runtime size | 11,875 B (EIP-170 limit 24,576 B) |
| ABI JSON sha256 (`forge inspect FeeSplitVault abi --json`) | `ee2516553fe7a5b058156ba67f516cfafae3701a2fd41630bc38e674db94e387` |
| Runtime codehash | pinned at deploy by `script/VerifyFeeSplitGate.s.sol` (it depends on the two immutables) |
| Compiler | solc 0.8.34, optimizer 200 runs, via-IR (`foundry.toml`) |

## Enums

| Enum | Values, in order |
|---|---|
| `FeeProfile` | `PAYOUT_ONLY` (0), `BOTH_AFTER_DISPUTE` (1) |
| `TermsState` | `NONE` (0), `PENDING_CONFIRM` (1), `CONFIRMED` (2), `VOID` (3) |

## Selectors

| Function | Selector |
|---|---|
| `MAX_INTEGRATOR_BPS()` | `0x756be4d5` |
| `bondBalance(bytes32)` | `0x696694e1` |
| `bondBalances(bytes32)` | `0xf0793c65` |
| `clearEscrowTerms(bytes32)` | `0xa34717e9` |
| `createEscrow(bytes32,address,address,uint256)` | `0x6e629653` |
| `depositBond(bytes32,address,uint256)` | `0x3c7a563f` |
| `escrows(bytes32)` | `0x2d83549c` |
| `integratorCredit(address)` | `0x79234fa4` |
| `integratorMaxBps(address,address)` | `0x04df1a9d` |
| `kernel()` | `0xd4aae0c4` |
| `kernelViewProbe(bytes32)` | `0x6f868fdc` |
| `lockedTerms(bytes32)` | `0xc35ead65` |
| `payout(bytes32,address,uint256)` | `0x1f52f7fa` |
| `payoutToProvider(bytes32,uint256)` | `0x46c354d5` |
| `pendingTerms(address,bytes32)` | `0x2f67b68b` |
| `previewDisputeRefund(uint256,uint16,uint16)` | `0xc82de9f2` |
| `protocolCredit()` | `0x37a9f4d5` |
| `quotePayout(bytes32,uint256)` | `0x06e7ba21` |
| `quoteRefund(bytes32,uint256)` | `0x6af9de54` |
| `quoteRefundIfDisputed(bytes32,uint256)` | `0x6fcc5908` |
| `refundToRequester(bytes32,uint256)` | `0x50725cea` |
| `releaseBond(bytes32,address,uint256)` | `0x06cf834a` |
| `remaining(bytes32)` | `0xbc1ed74c` |
| `setEscrowTerms(bytes32,address,uint16,uint8)` | `0xe3f7a09e` |
| `setIntegratorApproval(address,uint16)` | `0x11e4cee9` |
| `splitState(bytes32)` | `0x30010f35` |
| `token()` | `0xfc0c546a` |
| `totalBonds()` | `0xf263c470` |
| `totalIntegratorCredit()` | `0xde4fa621` |
| `totalLocked()` | `0x56891412` |
| `verifyEscrow(bytes32,address,address,uint256)` | `0x02dfe681` |
| `withdrawIntegratorCredit(address)` | `0xfaaf3444` |
| `withdrawProtocolCredit()` | `0x3b0f5df2` |

`escrows(bytes32)` returns `(address requester, address provider, uint256 amount, uint256 releasedAmount,
bool active)` and `bondBalances(bytes32)` returns `uint256`: the same shapes as `EscrowVault`, because the
SDKs decode them directly. `createEscrow`, `payoutToProvider`, `refundToRequester`, `payout`, `depositBond`
and `releaseBond` are kernel-only (`"Only kernel"`).

## Events

| Event | topic0 | indexed |
|---|---|---|
| `EscrowCompleted(bytes32,uint256)` | `0x82a430f306d755e5d38acfac963f5b835d609ad1b65b42b662946383c9032675` | escrowId |
| `EscrowCreated(bytes32,address,address,uint256)` | `0x0dd968c277d9dc6b36b6ec2b638324c3d937882c64ca109440bc050ebf26cb07` | escrowId, requester, provider |
| `EscrowDisputed(bytes32)` | `0x550ba3f95fa658596451573e6d789afa3858d8a992cb121712d3df88cff5765c` | escrowId |
| `EscrowPayout(bytes32,address,uint256)` | `0xcbd19c5ad86caf4a8a99c899dd9b4f95d1bf0384ac019dd9f7e6f165df3dba12` | escrowId, recipient |
| `EscrowTermsCleared(address,bytes32)` | `0x1231cc8335140efb5b66e586412300d2ddaac6d60435ba8a8549d72d0fd50068` | requester, escrowId |
| `EscrowTermsRegistered(address,bytes32,address,uint16,uint8)` | `0x1f31922e97b8df594f5ae99dff93ee83f63d35ec20678f66fd5191ca9c912f34` | requester, escrowId, integrator |
| `IntegratorApprovalSet(address,address,uint16)` | `0x50750394f9debea041a56f4e78f1bf7275b9b7c0d2ee0c45112fba9a2d9c2e3b` | provider, integrator |
| `IntegratorCreditWithdrawn(address,uint256)` | `0xd917e027dd47b1ec40e571fe07d9a218f725fbebb1d37c854b184c480c2a982c` | integrator |
| `IntegratorFeeSplit(bytes32,address,address,uint256,uint256,uint256,bool)` | `0x80c5ee7be441533a784dcc1c143e46d78bc7b261791505da85458d5284b7921d` | escrowId, provider, integrator |
| `IntegratorTermsLocked(bytes32,address,address,uint16,uint8)` | `0x7159cde083dab2fac156de44faeb90ecbfbef9e0c4b209c7064774e55ac318e8` | escrowId, provider, integrator |
| `ProtocolCreditWithdrawn(address,uint256)` | `0x9c64f63d1f0bc723ca5c6d41c9fd15e738cebb902712877be8a835239b01c89a` | recipient |
| `RefundFeeSplit(bytes32,address,address,uint256,uint256,uint256,uint256,bool,bool)` | `0xa118787f3a3d634632b9a4147e4c53baece1b2ac1557f8c8b0ef925d0be7207f` | escrowId, requester, integrator |
| `TermsConfirmed(bytes32,uint16)` | `0x4a6e7d7d0d4f5eb23820aa147cb9c1ce0bfcf45d9ce1da84b4cfb6f0443b6a57` | escrowId |
| `TermsVoided(bytes32)` | `0x71339aca1829744ae426d0a9135c3aff1b05083fe1b9403c49bca05e83509b8e` | escrowId |

`EscrowCreated`, `EscrowPayout` and `EscrowCompleted` keep the `EscrowVault` signatures. `EscrowPayout` is
emitted once per real token transfer, with the real recipient and amount; a credited fee emits none.
Per payout the vault's `IntegratorFeeSplit` precedes the kernel's `EscrowReleased`, and per refund the
vault's `RefundFeeSplit` precedes the kernel's `EscrowRefunded`; join on the escrow id and require
`providerSideAmount == EscrowReleased.amount`, `refundSideAmount == EscrowRefunded.amount`.

## Revert reasons (string reverts; the SDK and the acceptance negatives match on them)

| Reason | Where |
|---|---|
| `"Only kernel"` | every kernel-only mutator |
| `"Invalid integrator"` | `setIntegratorApproval`, `setEscrowTerms` (zero, the caller, the vault, the kernel, the token); `createEscrow` (the provider) |
| `"Bps above cap"` | `setIntegratorApproval`, `setEscrowTerms`, `previewDisputeRefund` (above 1000) |
| `"Bps zero"`, `"Invalid escrow ID"`, `"Escrow ID used"` | `setEscrowTerms` |
| `"No terms"` | `clearEscrowTerms` |
| `"Integrator not approved"` | `createEscrow`: no approval, or a rate above the provider's maximum |
| `"Terms need txId escrowId"` | `createEscrow`: terms registered and the escrow id is not the id of the transaction being linked |
| `"Escrow exists"`, `"Escrow ID used"`, `"Zero address"`, `"Amount zero"` | `createEscrow` |
| `"Escrow missing"`, `"Escrow inactive"`, `"Amount zero"`, `"Insufficient escrow"`, `"Zero recipient"` | disbursements |
| `"Insufficient bond"` | `releaseBond` |
| `"No credit"`, `"Fee recipient unavailable"` | credit withdrawals |
| `"Bad protocol bps"` | `previewDisputeRefund` (zero or above 500) |

## Kernel dependencies (read-only)

| Call | Use |
|---|---|
| `getTransaction(bytes32)` `0x4aae13ca` | static prefix of `TransactionView`, words 1 requester, 2 provider, 4 amount, 9 escrowContract, 10 escrowId, 14 platformFeeBpsLocked; a failed, short or malformed answer voids the terms, it never reverts a payout or a refund |
| `feeRecipient()` | recipient of the refund-side protocol fee and of `withdrawProtocolCredit` |

## Storage layout

| Slot | Name | Type |
|---|---|---|
| 0 | `escrows` | `mapping(bytes32 => EscrowData)` |
| 1 | `bondBalances` | `mapping(bytes32 => uint256)` |
| 2 | `integratorMaxBps` | `mapping(address => mapping(address => uint16))` |
| 3 | `_pending` | `mapping(address => mapping(bytes32 => Terms))` |
| 4 | `_locked` | `mapping(bytes32 => Locked)` (one slot per escrow, permanent) |
| 5 | `_split` | `mapping(bytes32 => Split)` (deleted on completion) |
| 6 | `integratorCredit` | `mapping(address => uint256)` |
| 7 | `protocolCredit` | `uint256` |
| 8 | `totalLocked` | `uint256` |
| 9 | `totalBonds` | `uint256` |
| 10 | `totalIntegratorCredit` | `uint256` |
