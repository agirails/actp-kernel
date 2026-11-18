// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../../src/tokens/MockUSDC.sol";
import "../../src/escrow/EscrowVault.sol";

/**
 * Echidna solvency campaign for EscrowVault — Poligon meta contracts (2026-11-18).
 *
 * Drugi (property-based) napadač uz postojeću Foundry conservation invarijantu. Harness
 * glumi KERNEL (EscrowVault(kernel = address(this))), pa izravno vozi createEscrow / payout /
 * refund / depositBond / releaseBond — bez vm cheatcodeova (koje Echidna ne vozi kao Foundry).
 *
 * Invarijanta (AGIRAILS CLAUDE.md #1 — Escrow Solvency): nakon SVAKE sekvence vault token-balans
 * >= zbroj nepodmirenih escrow ostataka + zbroj nepodmirenih bondova. Echidna traži sekvencu
 * (create/payout/refund/deposit/release s nasumičnim argumentima) koja to ruši.
 *
 * Pokretanje (iz actp-kernel korijena):
 *   echidna test/echidna/EscrowVaultSolvency.sol --contract EscrowVaultSolvency \
 *     --config test/echidna/echidna.yaml
 */
contract EscrowVaultSolvency {
    MockUSDC public usdc;
    EscrowVault public vault;

    bytes32[] internal ids;
    mapping(bytes32 => bool) internal known;

    address internal constant PROVIDER = address(0xB0B);

    constructor() {
        usdc = new MockUSDC();
        vault = new EscrowVault(address(usdc), address(this)); // harness == kernel
        usdc.mint(address(this), 1_000_000_000_000_000);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _track(uint256 seed) internal returns (bytes32 id) {
        id = keccak256(abi.encodePacked(seed));
        if (!known[id]) {
            known[id] = true;
            ids.push(id);
        }
    }

    function _existing(uint256 seed) internal view returns (bytes32) {
        if (ids.length == 0) return bytes32(0);
        return ids[seed % ids.length];
    }

    // ---- akcije koje Echidna fuzza (sve idu kroz harness => msg.sender vaultu = kernel) ----

    function act_createEscrow(uint256 seed, uint256 amount) public {
        bytes32 id = _track(seed);
        (, , uint256 a, , ) = vault.escrows(id);
        if (a != 0) return; // slot zauzet
        amount = 1 + (amount % 1_000_000);
        // requester = address(this): harness drži tokene i dao je approve vaultu
        vault.createEscrow(id, address(this), PROVIDER, amount);
    }

    function act_payout(uint256 seed, uint256 amount) public {
        bytes32 id = _existing(seed);
        if (id == bytes32(0)) return;
        uint256 rem = vault.remaining(id);
        if (rem == 0) return;
        vault.payout(id, PROVIDER, 1 + (amount % rem));
    }

    function act_refund(uint256 seed, uint256 amount) public {
        bytes32 id = _existing(seed);
        if (id == bytes32(0)) return;
        uint256 rem = vault.remaining(id);
        if (rem == 0) return;
        vault.refundToRequester(id, 1 + (amount % rem));
    }

    function act_depositBond(uint256 seed, uint256 amount) public {
        bytes32 id = _track(seed);
        amount = 1 + (amount % 1_000_000);
        vault.depositBond(id, address(this), amount);
    }

    function act_releaseBond(uint256 seed, uint256 amount) public {
        bytes32 id = _existing(seed);
        if (id == bytes32(0)) return;
        uint256 b = vault.bondBalances(id);
        if (b == 0) return;
        vault.releaseBond(id, PROVIDER, 1 + (amount % b));
    }

    // Namjerni PREKO-zahtjevi: ispravan kod ih odbija (require amount <= available),
    // pa su no-op; relaksacija bounda (npr. `<= available + 1`) pusti ih i obori solvency.
    // Mutation (2026-11-18) je pokazao da bez ovoga i Foundry i Echidna promaše off-by-one bound.
    function act_payoutOverByOne(uint256 seed) public {
        bytes32 id = _existing(seed);
        if (id == bytes32(0)) return;
        vault.payout(id, PROVIDER, vault.remaining(id) + 1);
    }

    function act_refundOverByOne(uint256 seed) public {
        bytes32 id = _existing(seed);
        if (id == bytes32(0)) return;
        vault.refundToRequester(id, vault.remaining(id) + 1);
    }

    // ---- invarijanta ----

    function echidna_solvent() public view returns (bool) {
        uint256 outstanding;
        for (uint256 i = 0; i < ids.length; i++) {
            outstanding += vault.remaining(ids[i]);
            outstanding += vault.bondBalances(ids[i]);
        }
        return usdc.balanceOf(address(vault)) >= outstanding;
    }
}
