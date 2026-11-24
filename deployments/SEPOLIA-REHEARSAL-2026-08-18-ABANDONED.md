# Base Sepolia — kernel-v2 rehearsal 2026-08-18 — ABANDONED

A partial `script/DeployKernelV2.s.sol` run on Base Sepolia (chainId 84532), executed on 2026-08-18 13:25 UTC
from commit `3d8d131` as the Sepolia rehearsal of the remediated kernel-v2 during mainnet deploy prep
(work log `2026-08-18-f6-mainnet-deploy-prep`). It was never recorded in `deployments/` at the time.

**Status: abandoned.** Nothing points at these contracts and nothing should. The stack was never completed
(no AgentRegistry, no ArchiveTreasury, no dispute system), was never wired into `base-sepolia.json`,
`aip14b.json` or either SDK, and is superseded by the `b08c0c6` stack in
[`SEPOLIA-B08C0C6-2026-11-23.md`](./SEPOLIA-B08C0C6-2026-11-23.md). The contracts stay on chain; this file
exists so the addresses are not mistaken for a live deployment later.

## What was broadcast

Source: the local Foundry broadcast record `broadcast/DeployKernelV2.s.sol/84532/run-1787059545340.json`
(`broadcast/` is not tracked in git).

| Step | Contract / call | Address | Block | Tx |
|---|---|---|---|---|
| CREATE | ACTPKernel | [`0xFbc45522D10B969e009EBFD14F56bc14958e0796`](https://sepolia.basescan.org/address/0xFbc45522D10B969e009EBFD14F56bc14958e0796) | 45645531 | [`0x3da4009b…7497`](https://sepolia.basescan.org/tx/0x3da4009bc54e0d68deaf49a41556acf9dd1be4c1c7af593734c545fc7b7f9497) |
| CREATE | EscrowVault | [`0x0EadD05acf4Dae89891c1673A611B9492B7aDEBb`](https://sepolia.basescan.org/address/0x0EadD05acf4Dae89891c1673A611B9492B7aDEBb) | 45645560 | [`0x974cce20…3ccf`](https://sepolia.basescan.org/tx/0x974cce20c9dade88f5ed4340a720c5ffb07e22e1a05020426fbd68236b573ccf) |
| CALL | `kernel.approveEscrowVault(vault, true)` | — | 45645629 | [`0xca336398…0f91`](https://sepolia.basescan.org/tx/0xca3363988ff7470e0c8adc580f5041a4ec840084b01d3c56f8e08f82f5240f91) |

Kernel constructor: admin = pauser = `0x42a2f11555B9363fB7eBDcdc76D7Cb26e01dCB00`, feeRecipient =
`0x866ECF4b0E79EA6095c19e4adA4Ed872373fF6b7`, agentRegistry = `address(0)`, usdc = MockUSDC
`0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb`, recoveryGrace = 3600 s.

## On-chain state (read-only, public RPC `sepolia.base.org`, 2026-11-24)

| Check | Result |
|---|---|
| Kernel runtime codehash | `0x0684d705630c5a80afd93220b60b897834b0adec79f340a28986843e68bf5cad` |
| Vault runtime codehash | `0xa56cc17177fbe553887ad68b3d5db060bbfa62a088e97e55330590396e65bdf8` |
| `vault.kernel()` | the 2026-08-18 kernel above |
| `kernel.agentRegistry()` | `address(0)` |
| `kernel.archiveTreasury()` | `address(0)` |
| MockUSDC balance of the vault | 0 (no funds stranded) |

The kernel codehash differs from the `b08c0c6` kernel (`0x819f4b41…`), so the two are distinguishable by
codehash. `kernelVersion()` returns the same constant on both (`0x6237ef5c…`), so do not use it to tell
these deployments apart.

## Why it is abandoned and not completed

- It was built from `3d8d131`, before the later security fixes (`6e90e42`, `36170c9`) that the `b08c0c6`
  candidate contains.
- It holds no funds and has no registry, archive or resolver wired, so there is nothing to migrate.
- Completing it would put a second, older candidate on Sepolia next to `b08c0c6` for no gain.
