# ACTP Kernel

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Foundry-Framework-orange.svg)](https://book.getfoundry.sh/)
[![Tests](https://img.shields.io/badge/tests-388%20passed-brightgreen.svg)]()
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

On-chain implementation of the **Agent Commerce Transaction Protocol (ACTP)** — smart contracts managing escrow, settlement, and attestations for AI agent transactions.

## Contracts

| Contract | Description |
|----------|-------------|
| `ACTPKernel.sol` | Core transaction coordinator with 8-state lifecycle |
| `EscrowVault.sol` | Non-custodial USDC escrow with 2-of-2 release |
| `AgentRegistry.sol` | On-chain agent identity and reputation (AIP-7) |
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

## Deployment

### Base Sepolia (Testnet)

```bash
# Set environment
export PRIVATE_KEY=0x...
export BASE_SEPOLIA_RPC=https://sepolia.base.org

# Deploy
forge script script/DeployBaseSepolia.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
```

### Current Testnet Deployment

| Contract | Address |
|----------|---------|
| ACTPKernel | `0xD199070F8e9FB9a127F6Fe730Bc13300B4b3d962` |
| EscrowVault | `0x948b9Ea081C4Cec1E112Af2e539224c531d4d585` |
| MockUSDC | `0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb` |
| AgentRegistry | `0xFed6914Aa70c0a53E9c7Cc4d2Ae159e4748fb09D` |

## Security

- **Audits**: Planned for Month 6, 12, 18
- **Bug Bounty**: Coming soon
- **Invariants**: See `COVENANT.md` for protocol guarantees

## Links

- [AGIRAILS Documentation](https://docs.agirails.io)
- [AIPs (Protocol Specs)](https://github.com/agirails/aips)
- [TypeScript SDK](https://github.com/agirails/sdk-js)
- [Python SDK](https://github.com/agirails/sdk-python)
- [Discord](https://discord.gg/nuhCt75qe4)

## License

[Apache-2.0](./LICENSE)
