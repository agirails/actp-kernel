# ACTP Kernel

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Foundry-Framework-orange.svg)](https://book.getfoundry.sh/)
[![Tests](https://img.shields.io/badge/tests-429%20passed-brightgreen.svg)]()
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

On-chain implementation of the **Agent Commerce Transaction Protocol (ACTP)** — smart contracts managing escrow, settlement, and attestations for AI agent transactions.

## Contracts

| Contract | Description |
|----------|-------------|
| `ACTPKernel.sol` | Core transaction coordinator with 8-state lifecycle |
| `EscrowVault.sol` | Non-custodial USDC escrow with 2-of-2 release |
| `AgentRegistry.sol` | On-chain agent identity, config publishing, and reputation (AIP-7) |
| `X402Relay.sol` | Atomic x402 payment fee splitting (1% with $0.05 min) |
| `ArchiveTreasury.sol` | Arweave permanent storage funding from protocol fees |
| `AGIRAILSIdentityRegistry.sol` | ERC-1056 compatible DID registry |
| `MockUSDC.sol` | Test token for development |

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

### Base Mainnet

| Contract | Address |
|----------|---------|
| ACTPKernel | [`0x132B9eB321dBB57c828B083844287171BDC92d29`](https://basescan.org/address/0x132B9eB321dBB57c828B083844287171BDC92d29) |
| EscrowVault | [`0x6aAF45882c4b0dD34130ecC790bb5Ec6be7fFb99`](https://basescan.org/address/0x6aAF45882c4b0dD34130ecC790bb5Ec6be7fFb99) |
| AgentRegistry | [`0x6fB222CF3DDdf37Bcb248EE7BBBA42Fb41901de8`](https://basescan.org/address/0x6fB222CF3DDdf37Bcb248EE7BBBA42Fb41901de8) |
| X402Relay | [`0x81DFb954A3D58FEc24Fc9c946aC2C71a911609F8`](https://basescan.org/address/0x81DFb954A3D58FEc24Fc9c946aC2C71a911609F8) |
| ArchiveTreasury | [`0x0516C411C0E8d75D17A768022819a0a4FB3cA2f2`](https://basescan.org/address/0x0516C411C0E8d75D17A768022819a0a4FB3cA2f2) |
| USDC (Circle) | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) |

### Base Sepolia (Testnet)

| Contract | Address |
|----------|---------|
| ACTPKernel | [`0x469CBADbACFFE096270594F0a31f0EEC53753411`](https://sepolia.basescan.org/address/0x469CBADbACFFE096270594F0a31f0EEC53753411) |
| EscrowVault | [`0x57f888261b629bB380dfb983f5DA6c70Ff2D49E5`](https://sepolia.basescan.org/address/0x57f888261b629bB380dfb983f5DA6c70Ff2D49E5) |
| AgentRegistry | [`0xDd6D66924B43419F484aE981F174b803487AF25A`](https://sepolia.basescan.org/address/0xDd6D66924B43419F484aE981F174b803487AF25A) |
| X402Relay | [`0x4DCD02b276Dbeab57c265B72435e90507b6Ac81A`](https://sepolia.basescan.org/address/0x4DCD02b276Dbeab57c265B72435e90507b6Ac81A) |
| ArchiveTreasury | [`0xACB672de092beaAE2cd286dD61Cb2352AF7159F1`](https://sepolia.basescan.org/address/0xACB672de092beaAE2cd286dD61Cb2352AF7159F1) |
| AGIRAILSIdentityRegistry | [`0xF64F748C7802a68Cb936a9213881fE74e83FDA97`](https://sepolia.basescan.org/address/0xF64F748C7802a68Cb936a9213881fE74e83FDA97) |
| MockUSDC | [`0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb`](https://sepolia.basescan.org/address/0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb) |

## Security

- **Audit Status**: Smart contracts passed security audit (February 2026) — no findings
- **Invariants**: See `COVENANT.md` for protocol guarantees
- **Admin**: Gnosis Safe 2-of-3 multisig ([`0x61fE...c2f2`](https://basescan.org/address/0x61fE58E9EdB380EA65EC74bD364D9D2cba30B7f2))
- **Contact**: security@agirails.io

## Links

- [AGIRAILS Documentation](https://docs.agirails.io)
- [AIPs (Protocol Specs)](https://github.com/agirails/aips)
- [TypeScript SDK](https://github.com/agirails/sdk-js) (npm `@agirails/sdk@2.5.0`)
- [Python SDK](https://github.com/agirails/sdk-python) (PyPI `agirails==2.3.0`)
- [n8n Node](https://github.com/agirails/n8n-nodes-actp) (npm `n8n-nodes-actp@2.3.0`)
- [Discord](https://discord.gg/nuhCt75qe4)

## License

[Apache-2.0](./LICENSE)
