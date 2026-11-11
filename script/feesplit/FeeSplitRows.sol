// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ACTPKernel} from "../../src/ACTPKernel.sol";
import {BondEscalation} from "../../src/BondEscalation.sol";
import {CompositeMediator} from "../../src/CompositeMediator.sol";
import {EscrowVault} from "../../src/escrow/EscrowVault.sol";
import {FeeSplitVault} from "../../src/escrow/FeeSplitVault.sol";
import {IFeeSplitVault} from "../../src/interfaces/IFeeSplitVault.sol";
import {IACTPKernel} from "../../src/interfaces/IACTPKernel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FeeSplitRows — the acceptance rows as live transactions, in two stages.
 * @notice Arm creates the escrows of a row set, does everything that is not time-gated, and writes
 *         a run file. Exec reads a run file, refuses to run before the recorded time, and performs
 *         the time-gated half (finalize a ruling after liveness, cancel after the deadline, recover
 *         a stalled escrow, force-resolve a stale dispute).
 *
 *         A run file is written once, when its escrows are created, and never rewritten: it is the
 *         manifest the reconciler (deployments/scripts/reconcile_feesplit.py) checks the chain
 *         against. The scripts assert states, not amounts; amounts are the reconciler's job.
 *
 *         Addresses come from the environment, never from constants:
 *           FEE_SPLIT_KERNEL, FEE_SPLIT_VAULT, PLAIN_VAULT, COMPOSITE_MEDIATOR, BOND_ESCALATION
 *           REQUESTER_KEY, PROVIDER_KEY, KEEPER_KEY      dedicated acceptance keys
 *           ADMIN_KEY                                    kernel admin; only for explicit-proof rows
 *           INTEGRATOR                                   integrator address (receives only)
 *           ACCEPT_NO_MINT=true                          the token is not mintable; actors are funded
 *         Networks: a local anvil stack (31337) and Base Sepolia (84532). Nothing else.
 */
abstract contract FeeSplitRows is Script {
    string internal constant RUN_DIR = "deployments/feesplit-acceptance/";
    bytes32 internal constant SERVICE = keccak256("feesplit-acceptance");
    uint256 internal constant ONE = 1_000_000;
    uint8 internal constant D = 0; // PAYOUT_ONLY
    uint8 internal constant B = 1; // BOTH_AFTER_DISPUTE
    uint8 internal constant NONE = 2; // no terms

    ACTPKernel internal kernel;
    FeeSplitVault internal vault;
    EscrowVault internal plain;
    CompositeMediator internal mediator;
    BondEscalation internal bond;
    IERC20 internal token;

    uint256 internal requesterKey;
    uint256 internal providerKey;
    uint256 internal keeperKey;
    address internal requester;
    address internal provider;
    address internal keeper;
    address internal integrator;
    bool internal noMint;

    string internal entries;
    uint256 internal entryCount;

    // ----- environment -----

    function _loadStack() internal {
        require(block.chainid == 31337 || block.chainid == 84532, "FeeSplitRows: local anvil or Base Sepolia only");
        kernel = ACTPKernel(vm.envAddress("FEE_SPLIT_KERNEL"));
        vault = FeeSplitVault(vm.envAddress("FEE_SPLIT_VAULT"));
        plain = EscrowVault(vm.envAddress("PLAIN_VAULT"));
        mediator = CompositeMediator(vm.envAddress("COMPOSITE_MEDIATOR"));
        bond = BondEscalation(vm.envAddress("BOND_ESCALATION"));
        token = IERC20(address(kernel.USDC()));
        require(vault.kernel() == address(kernel) && plain.kernel() == address(kernel), "vaults are not this kernel's");
        require(address(bond.compositeMediator()) == address(mediator), "bond is not this mediator's");

        requesterKey = vm.envUint("REQUESTER_KEY");
        providerKey = vm.envUint("PROVIDER_KEY");
        keeperKey = vm.envUint("KEEPER_KEY");
        requester = vm.addr(requesterKey);
        provider = vm.addr(providerKey);
        keeper = vm.addr(keeperKey);
        integrator = vm.envAddress("INTEGRATOR");
        noMint = vm.envOr("ACCEPT_NO_MINT", false);
    }

    function _prefix() internal view returns (string memory) {
        return block.chainid == 31337 ? "local" : "sepolia";
    }

    // ----- building blocks (each broadcasts as the actor who must sign) -----

    function _mint(address to, uint256 amount) internal {
        if (noMint) return;
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(ok, "token is not mintable: fund the actors and set ACCEPT_NO_MINT=true");
    }

    /// @dev Creates and funds one escrow. `profile == NONE` registers no terms.
    function _open(uint256 amount, uint16 bps, uint8 profile, address escrowVault, uint256 deadlineIn)
        internal
        returns (bytes32 txId)
    {
        if (profile != NONE && vault.integratorMaxBps(provider, integrator) < bps) {
            vm.broadcast(providerKey);
            vault.setIntegratorApproval(integrator, bps);
        }
        vm.startBroadcast(requesterKey);
        _mint(requester, amount);
        txId = kernel.createTransaction(
            provider, requester, amount, block.timestamp + deadlineIn, 1 hours, SERVICE, bytes32(0), 0, 0
        );
        token.approve(escrowVault, amount);
        if (profile != NONE) {
            vault.setEscrowTerms(
                txId, integrator, bps, profile == B ? IFeeSplitVault.FeeProfile.BOTH_AFTER_DISPUTE : IFeeSplitVault.FeeProfile.PAYOUT_ONLY
            );
        }
        kernel.linkEscrow(txId, escrowVault, txId);
        vm.stopBroadcast();
    }

    function _start(bytes32 txId) internal {
        vm.broadcast(providerKey);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
    }

    function _deliver(bytes32 txId) internal {
        vm.broadcast(providerKey);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(uint256(1 hours), keccak256("result")));
    }

    function _settle(bytes32 txId) internal {
        vm.broadcast(requesterKey);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, "");
    }

    function _dispute(bytes32 txId, uint256 disputerKey) internal {
        IACTPKernel.TransactionView memory t = kernel.getTransaction(txId);
        uint256 entryBond = (t.amount * t.disputeBondBpsLocked) / 10_000;
        if (entryBond < ONE) entryBond = ONE;
        vm.startBroadcast(disputerKey);
        _mint(vm.addr(disputerKey), entryBond);
        token.approve(t.escrowContract, entryBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopBroadcast();
    }

    function _disputeId(bytes32 txId) internal pure returns (bytes32) {
        return keccak256(abi.encode("ACTP_DISPUTE_V1", txId));
    }

    /// @dev Tier-1 liveness for an escrow of `principal` (BondEscalation._livenessForEscrow).
    function _liveness(uint256 principal) internal pure returns (uint256) {
        if (principal < 50 * ONE) return 1 hours;
        if (principal < 500 * ONE) return 2 hours;
        if (principal < 5000 * ONE) return 4 hours;
        return 8 hours;
    }

    /// @dev The keeper opens the dispute in BondEscalation and proposes a ruling directly.
    function _propose(bytes32 txId, uint8 ruling, uint16 splitBps) internal returns (uint256 earliestExec) {
        uint256 principal = kernel.escrowPrincipal(txId);
        vm.startBroadcast(keeperKey);
        _mint(keeper, 500 * ONE); // escalation bond: 2% of the principal, at most 500
        token.approve(address(bond), 500 * ONE);
        bytes32 disputeId = bond.openDispute(txId);
        bond.proposeDirectly(disputeId, ruling, splitBps);
        vm.stopBroadcast();
        earliestExec = block.timestamp + _liveness(principal) + 10 minutes;
    }

    // ----- run file -----

    function _profileName(uint8 profile) internal pure returns (string memory) {
        return profile == D ? "D" : (profile == B ? "B" : "-");
    }

    /// @dev One manifest entry. `row` is an acceptance row of the plan ("" for smoke and soak jobs);
    ///      `variant` tells apart the outcomes one row lists ("settle", "win").
    function _entry(
        string memory label,
        string memory row,
        string memory variant,
        uint8 profile,
        uint16 bps,
        bytes32 txId,
        string memory outcome,
        string memory exec,
        uint256 earliestExec,
        bool adminResolved
    ) internal {
        IACTPKernel.TransactionView memory t = kernel.getTransaction(txId);
        string memory head = string.concat(
            entryCount == 0 ? "" : ",\n    ",
            '{"label":"', label, '","row":"', row, '","variant":"', variant, '","profile":"', _profileName(profile), '"'
        );
        string memory parties = string.concat(
            ',"txId":"', vm.toString(txId), '","vault":"', vm.toString(t.escrowContract), '","requester":"',
            vm.toString(t.requester), '","provider":"', vm.toString(t.provider), '","amount":', vm.toString(t.amount)
        );
        string memory terms = string.concat(
            ',"integrator":"', vm.toString(profile == NONE ? address(0) : integrator), '","bps":', vm.toString(uint256(bps))
        );
        string memory tail = string.concat(
            ',"outcome":"', outcome, '","exec":"', exec, '","earliestExec":', vm.toString(earliestExec),
            ',"adminResolved":', adminResolved ? "true" : "false", "}"
        );
        entries = string.concat(entries, head, parties, terms, tail);
        entryCount++;
        console2.log(string.concat("armed ", label), vm.toString(txId));
    }

    function _writeRunFile(string memory set) internal returns (string memory path) {
        require(entryCount > 0, "nothing was armed");
        string memory header = string.concat(
            '{\n  "version":1,"kind":"run","set":"', set, '","chainId":', vm.toString(block.chainid), ',"armBlock":', vm.toString(block.number),
            ',"armTime":', vm.toString(block.timestamp)
        );
        string memory stack = string.concat(
            ',\n  "kernel":"', vm.toString(address(kernel)), '","feeSplitVault":"', vm.toString(address(vault)),
            '","plainVault":"', vm.toString(address(plain)), '","token":"', vm.toString(address(token)), '"'
        );
        string memory body = string.concat(',\n  "count":', vm.toString(entryCount), ',\n  "entries":[\n    ', entries, "\n  ]\n}\n");
        path = string.concat(RUN_DIR, _prefix(), "-", set, "-", vm.toString(block.number), ".json");
        vm.writeFile(path, string.concat(header, stack, body));
        console2.log("run file:", path);
    }

    // ----- arm: one function per kind of row -----

    function _armSettle(string memory label, string memory row, string memory variant, uint8 profile, uint256 amount, uint16 bps, bool usePlain)
        internal
    {
        bytes32 txId = _open(amount, bps, profile, usePlain ? address(plain) : address(vault), 7 days);
        _start(txId);
        _deliver(txId);
        _settle(txId);
        _entry(label, row, variant, profile, bps, txId, "SETTLED", "none", 0, false);
    }

    function _armMilestones(string memory label, string memory row, uint8 profile, uint256 amount, uint16 bps, uint256[] memory parts)
        internal
    {
        bytes32 txId = _open(amount, bps, profile, address(vault), 7 days);
        _start(txId);
        vm.startBroadcast(requesterKey);
        for (uint256 i; i < parts.length; i++) kernel.releaseMilestone(txId, parts[i]);
        vm.stopBroadcast();
        _deliver(txId);
        _settle(txId);
        _entry(label, row, "", profile, bps, txId, "SETTLED", "none", 0, false);
    }

    /// @dev Dispute opened by a party, proposed directly, finalized unchallenged by Exec after liveness.
    function _armRuling(
        string memory label,
        string memory row,
        string memory variant,
        uint8 profile,
        uint256 amount,
        uint16 bps,
        uint8 ruling,
        uint16 splitBps,
        bool providerDisputes
    ) internal {
        bytes32 txId = _open(amount, bps, profile, address(vault), 7 days);
        _start(txId);
        _deliver(txId);
        _dispute(txId, providerDisputes ? providerKey : requesterKey);
        uint256 earliest = _propose(txId, ruling, splitBps);
        _entry(label, row, variant, profile, bps, txId, ruling == 2 ? "CANCELLED" : "SETTLED", "finalize", earliest, false);
    }

    /// @dev Explicit-amount proof: the resolver stack cannot express it, so the kernel admin resolves.
    function _armAdminProof(string memory label, string memory row, uint8 profile, uint256 amount, uint16 bps, bytes memory proof)
        internal
    {
        uint256 adminKey = vm.envUint("ADMIN_KEY");
        require(vm.addr(adminKey) == kernel.admin(), "ADMIN_KEY is not the kernel admin");
        bytes32 txId = _open(amount, bps, profile, address(vault), 7 days);
        _start(txId);
        _deliver(txId);
        _dispute(txId, requesterKey);
        vm.broadcast(adminKey);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);
        _entry(label, row, "", profile, bps, txId, "SETTLED", "none", 0, true);
    }

    function _armProviderCancel(string memory label, string memory row, uint8 profile, uint256 amount, uint16 bps) internal {
        bytes32 txId = _open(amount, bps, profile, address(vault), 7 days);
        vm.broadcast(providerKey);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        _entry(label, row, "", profile, bps, txId, "CANCELLED", "none", 0, false);
    }

    /// @dev The requester may cancel a COMMITTED job only after its deadline (minimum one hour).
    function _armRequesterCancel(string memory label, string memory row, uint8 profile, uint256 amount, uint16 bps) internal {
        bytes32 txId = _open(amount, bps, profile, address(vault), 70 minutes);
        _entry(label, row, "", profile, bps, txId, "CANCELLED", "requesterCancel", block.timestamp + 71 minutes, false);
    }

    function _armStalled(string memory label, string memory row, uint8 profile, uint256 amount, uint16 bps) internal {
        bytes32 txId = _open(amount, bps, profile, address(vault), 70 minutes);
        _start(txId);
        _entry(
            label, row, "", profile, bps, txId, "CANCELLED", "recover", block.timestamp + 71 minutes + kernel.recoveryGrace(), false
        );
    }

    /// @dev Forced 50/50 after 30 days: the long-running row.
    function _armForceStale(string memory label, string memory row, uint8 profile, uint256 amount, uint16 bps) internal {
        bytes32 txId = _open(amount, bps, profile, address(vault), 7 days);
        _start(txId);
        _deliver(txId);
        _dispute(txId, requesterKey);
        vm.broadcast(keeperKey);
        bond.openDispute(txId);
        _entry(label, row, "", profile, bps, txId, "CANCELLED", "forceStale", block.timestamp + 30 days + 10 minutes, false);
    }

    // ----- exec: the time-gated half -----

    function _state(string memory name) internal pure returns (IACTPKernel.State) {
        return keccak256(bytes(name)) == keccak256("SETTLED") ? IACTPKernel.State.SETTLED : IACTPKernel.State.CANCELLED;
    }

    /// @dev Executes every entry of the run file that still has a time-gated half. Refuses the whole
    ///      run while any such entry is before its recorded time.
    function _execRunFile(string memory path) internal {
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "run file is for another chain");
        require(vm.parseJsonAddress(json, ".kernel") == address(kernel), "run file is for another kernel");
        uint256 count = vm.parseJsonUint(json, ".count");
        uint256 done;
        for (uint256 i; i < count; i++) {
            string memory at = string.concat(".entries[", vm.toString(i), "]");
            string memory exec = vm.parseJsonString(json, string.concat(at, ".exec"));
            if (keccak256(bytes(exec)) == keccak256("none")) continue;
            bytes32 txId = vm.parseJsonBytes32(json, string.concat(at, ".txId"));
            string memory label = vm.parseJsonString(json, string.concat(at, ".label"));
            IACTPKernel.State outcome = _state(vm.parseJsonString(json, string.concat(at, ".outcome")));
            IACTPKernel.State current = kernel.getTransaction(txId).state;
            if (current == IACTPKernel.State.SETTLED || current == IACTPKernel.State.CANCELLED) {
                require(current == outcome, string.concat("terminal in another state: ", label));
                continue; // already executed
            }
            uint256 earliest = vm.parseJsonUint(json, string.concat(at, ".earliestExec"));
            require(block.timestamp >= earliest, string.concat("too early for ", label));
            _execOne(exec, txId);
            require(kernel.getTransaction(txId).state == outcome, string.concat("unexpected state after ", label));
            console2.log(string.concat("executed ", label), vm.toString(txId));
            done++;
        }
        console2.log("entries executed:", done);
    }

    function _execOne(string memory exec, bytes32 txId) internal {
        bytes32 kind = keccak256(bytes(exec));
        if (kind == keccak256("finalize")) {
            vm.broadcast(keeperKey);
            bond.finalize(_disputeId(txId));
        } else if (kind == keccak256("requesterCancel")) {
            vm.broadcast(requesterKey);
            kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");
        } else if (kind == keccak256("recover")) {
            vm.broadcast(keeperKey);
            kernel.recoverStalledInProgress(txId);
        } else if (kind == keccak256("forceStale")) {
            vm.broadcast(keeperKey);
            bond.forceResolveStale(_disputeId(txId));
        } else {
            revert(string.concat("unknown exec kind: ", exec));
        }
    }

    function _selected(string memory label) internal view returns (bool) {
        string memory rows = vm.envOr("ACCEPT_ROWS", string("all"));
        if (keccak256(bytes(rows)) == keccak256("all")) return true;
        string[] memory wanted = vm.split(rows, ",");
        for (uint256 i; i < wanted.length; i++) {
            if (keccak256(bytes(wanted[i])) == keccak256(bytes(label))) return true;
        }
        return false;
    }
}
