// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../../src/tokens/MockUSDC.sol";
import "../../src/escrow/EscrowVault.sol";

/**
 * Echidna solvency campaign for EscrowVault.
 *
 * A property-based second line of defence next to the Foundry conservation invariant. The harness
 * acts as the KERNEL (EscrowVault(kernel = address(this))), so it drives createEscrow / payout /
 * refund / depositBond / releaseBond directly, without vm cheatcodes (Echidna does not run them
 * the way Foundry does).
 *
 * Invariant (Escrow Solvency): after EVERY sequence the vault's token balance equals the sum of
 * outstanding escrow remainders plus outstanding bonds. The harness is the only source of funds,
 * so equality holds exactly: a shortfall means insolvency, a surplus means stranded funds.
 * Echidna searches for a create/payout/refund/deposit/release sequence with random arguments
 * that breaks it.
 *
 * Run from the actp-kernel root:
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

    // ---- fuzzed actions (all go through the harness, so msg.sender to the vault is the kernel) ----

    function act_createEscrow(uint256 seed, uint256 amount) public {
        bytes32 id = _track(seed);
        (, , uint256 a, , ) = vault.escrows(id);
        if (a != 0) return; // slot taken
        amount = 1 + (amount % 1_000_000);
        // requester = address(this): the harness holds the tokens and has approved the vault
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

    // Deliberate OVER-requests: correct code rejects them (require amount <= available), so they
    // are no-ops; a relaxed bound (e.g. `<= available + 1`) lets them through and breaks solvency.
    // A mutation run showed that without these, both Foundry and Echidna miss an off-by-one bound.
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

    // ---- invariant ----

    function echidna_solvent() public view returns (bool) {
        uint256 outstanding;
        for (uint256 i = 0; i < ids.length; i++) {
            outstanding += vault.remaining(ids[i]);
            outstanding += vault.bondBalances(ids[i]);
        }
        return usdc.balanceOf(address(vault)) == outstanding;
    }
}
