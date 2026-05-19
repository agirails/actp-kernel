# ACTP Kernel

[![Solidity](https://img.shields.io/badge/Solidity-0.8.34-blue.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Foundry-Framework-orange.svg)](https://book.getfoundry.sh/)
[![Tests](https://img.shields.io/badge/tests-486%20passed-brightgreen.svg)]()
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

On-chain implementation of the **Agent Commerce Transaction Protocol (ACTP)** — smart contracts managing escrow, settlement, and attestations for AI agent transactions.

## Contracts

| Contract | Description |
|----------|-------------|
| `ACTPKernel.sol` | Core transaction coordinator with 8-state lifecycle |
| `EscrowVault.sol` | Non-custodial USDC escrow with 2-of-2 release |
| `AgentRegistry.sol` | On-chain agent identity, config publishing, and reputation (AIP-7) |
| `ArchiveTreasury.sol` | Arweave permanent storage funding from protocol fees |
| `AGIRAILSIdentityRegistry.sol` | ERC-1056 compatible DID registry (Sepolia only) |
| `MockUSDC.sol` | Test token for development (Sepolia only) |

> **Note**: `X402Relay.sol` is deprecated. The SDK's X402Adapter (since v3.3.0) routes payments directly buyer→seller via the [`@x402/fetch`](https://github.com/coinbase/x402) + facilitator pattern (EIP-3009 / Permit2). The contract is retained on Sepolia for legacy direct-call consumers but is not redeployed on mainnet.

## Transaction Lifecycle

```
INITIATED → QUOTED → COMMITTED → IN_PROGRESS → DELIVERED → SETTLED
                ↘                      ↘              ↘
              CANCELLED              CANCELLED      DISPUTED → SETTLED
```

## Quick Start

```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Run with verbosity
forge test -vvv

# Coverage report
forge coverage
```

## Deployed Contracts

### Base Mainnet *(redeployed 2026-05-19, Sourcify EXACT_MATCH verified)*

| Contract | Address |
|----------|---------|
| ACTPKernel | [`0x048c811352e8a3fECd5b0Ec4AA2c2b94083CC842`](https://basescan.org/address/0x048c811352e8a3fECd5b0Ec4AA2c2b94083CC842) |
| EscrowVault | [`0x262D5912A9612F0c66dA5d13B4E678D50ebC44b5`](https://basescan.org/address/0x262D5912A9612F0c66dA5d13B4E678D50ebC44b5) |
| AgentRegistry | [`0x64Cb18bfb3CC1aCb1370a3B01613391D3561a009`](https://basescan.org/address/0x64Cb18bfb3CC1aCb1370a3B01613391D3561a009) |
| ArchiveTreasury | [`0x6159A80Ce8362aBB2307FbaB4Ed4D3F4A4231Acc`](https://basescan.org/address/0x6159A80Ce8362aBB2307FbaB4Ed4D3F4A4231Acc) |
| USDC (Circle) | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) |

See [`deployments/base-mainnet.json`](./deployments/base-mainnet.json) for deploy block, tx hashes, Safe owner set, and post-deploy wiring state.

### Base Sepolia (Testnet) *(redeployed 2026-05-19 to match mainnet ABI)*

| Contract | Address |
|----------|---------|
| ACTPKernel | [`0x9d25A874f046185d9237Cd4954C88D2B74B0021b`](https://sepolia.basescan.org/address/0x9d25A874f046185d9237Cd4954C88D2B74B0021b) |
| EscrowVault | [`0x7dF07327090efcA73DCBa70414aA3131Fc6d2efB`](https://sepolia.basescan.org/address/0x7dF07327090efcA73DCBa70414aA3131Fc6d2efB) |
| AgentRegistry | [`0xD91F9aBfBf60b4a2Fd5317ab0cDF3F44faB5D656`](https://sepolia.basescan.org/address/0xD91F9aBfBf60b4a2Fd5317ab0cDF3F44faB5D656) |
| ArchiveTreasury | [`0x2eE4f7bE289fc9EFC2F9f2D6E53e50abDF23A3eb`](https://sepolia.basescan.org/address/0x2eE4f7bE289fc9EFC2F9f2D6E53e50abDF23A3eb) |
| AGIRAILSIdentityRegistry | [`0xce9749c768b425fab0daa0331047d1340ec99a88`](https://sepolia.basescan.org/address/0xce9749c768b425fab0daa0331047d1340ec99a88) |
| X402Relay (deprecated) | [`0x110b25bb3d45c40dfcf34bb451aa7069b2a1cb3b`](https://sepolia.basescan.org/address/0x110b25bb3d45c40dfcf34bb451aa7069b2a1cb3b) |
| MockUSDC | [`0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb`](https://sepolia.basescan.org/address/0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb) |

See [`deployments/base-sepolia.json`](./deployments/base-sepolia.json) for deploy details.

## Security

- **Audits**: Internal review (Feb 2026), independent code review (Apr 2026), external source-level audit (May 2026) — all findings closed. See [`SECURITY.md`](./SECURITY.md).
- **Invariants**: See [`COVENANT.md`](./COVENANT.md) for protocol guarantees.
- **Admin**: Gnosis Safe 2-of-4 multisig ([`0x61fE…b7f2`](https://basescan.org/address/0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2)).
- **Disclosure**: security@agirails.io

## Links

- [AGIRAILS Documentation](https://docs.agirails.io)
- [AIPs (Protocol Specs)](https://github.com/agirails/aips)
- [TypeScript SDK](https://github.com/agirails/sdk-js) (npm `@agirails/sdk@4.0.0`)
- [Python SDK](https://github.com/agirails/python-sdk-v2) (PyPI `agirails`)
- [n8n Node](https://github.com/agirails/n8n-nodes-actp) (npm `n8n-nodes-actp`)
- [Discord](https://discord.gg/nuhCt75qe4)

## License

[Apache-2.0](./LICENSE)
