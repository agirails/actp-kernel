// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {console2} from "forge-std/Script.sol";
import {FeeSplitRows} from "./feesplit/FeeSplitRows.sol";
import {IFeeSplitVault} from "../src/interfaces/IFeeSplitVault.sol";

/**
 * @title AcceptFeeSplitArm — arms the LIVE acceptance matrix of FeeSplitVault.
 * @notice Rows A1-A14 and A18-A24 at the amounts of the plan's acceptance table, in every profile a
 *         row lists. Disputes are opened by a party, proposed directly and finalized unchallenged by
 *         AcceptFeeSplitExec after liveness, so they pass through the deployed BondEscalation and
 *         CompositeMediator. A10 and A14 carry an explicit-amount proof and are resolved by the
 *         kernel admin; they are marked adminResolved in the run file.
 *
 *         run()            the matrix (ACCEPT_ROWS=label,label selects a subset; ACCEPT_SET names it)
 *         armLongRunning() A25: a forced 50/50 needs 30 days; it gets its own run file
 *         probeNegatives() A23, A26 and the consent negatives: not broadcast. Each is a call against live
 *                          state at the recorded block that must revert with the expected reason.
 *
 * Run: forge script script/AcceptFeeSplitArm.s.sol --rpc-url $RPC --broadcast --slow
 *      forge script script/AcceptFeeSplitArm.s.sol --sig "armLongRunning()" --rpc-url $RPC --broadcast --slow
 *      forge script script/AcceptFeeSplitArm.s.sol --sig "probeNegatives()" --rpc-url $RPC
 */
contract AcceptFeeSplitArm is FeeSplitRows {
    uint256 internal constant K = 1000 * ONE;

    function run() external {
        _loadStack();
        if (_selected("A1")) _armSettle("A1", "A1", "", NONE, K, 0, true);
        if (_selected("A2")) _armSettle("A2", "A2", "", NONE, K, 0, false);
        _armProfile(D, "-D");
        _armProfile(B, "-B");
        // Rows that list one profile only.
        if (_selected("A18-B-win")) _armRuling("A18-B-win", "A18", "win", B, K, 200, 1, 0, false);
        if (_selected("A21-B-win")) _armRuling("A21-B-win", "A21", "win", B, 100_000, 100, 1, 0, false);
        if (_selected("A24")) _armRuling("A24", "A24", "", B, K, 1000, 1, 0, true);
        _writeRunFile(vm.envOr("ACCEPT_SET", string("matrix")));
    }

    function _armProfile(uint8 p, string memory suffix) internal {
        string memory l;
        l = string.concat("A3", suffix);
        if (_selected(l)) _armSettle(l, "A3", "", p, K, 100, false);
        l = string.concat("A4", suffix);
        if (_selected(l)) _armMilestones(l, "A4", p, K, 100, _parts(250 * ONE, 250 * ONE, 0));
        l = string.concat("A5", suffix);
        if (_selected(l)) _armMilestones(l, "A5", p, K, 100, _parts(333_333_333, 333_333_333, 333_333_333));
        l = string.concat("A6", suffix);
        if (_selected(l)) _armRuling(l, "A6", "", p, K, 100, 2, 5000, false);
        l = string.concat("A7", suffix);
        if (_selected(l)) _armRuling(l, "A7", "", p, K, 100, 2, 4000, false);
        l = string.concat("A8", suffix);
        if (_selected(l)) _armRuling(l, "A8", "", p, K, 100, 0, 0, false);
        l = string.concat("A9", suffix);
        if (_selected(l)) _armRuling(l, "A9", "", p, K, 100, 1, 0, false);
        l = string.concat("A10", suffix);
        if (_selected(l)) {
            _armAdminProof(l, "A10", p, 2 * K, 100, abi.encode(uint256(999_999_901), uint256(1_000_000_099), true));
        }
        l = string.concat("A11", suffix);
        if (_selected(l)) _armProviderCancel(l, "A11", p, K, 100);
        l = string.concat("A12", suffix);
        if (_selected(l)) _armRequesterCancel(l, "A12", p, K, 100);
        l = string.concat("A13", suffix);
        if (_selected(l)) _armStalled(l, "A13", p, K, 100);
        l = string.concat("A14", suffix);
        if (_selected(l)) {
            // The paid mediator must itself be an approved mediator: the deployed CompositeMediator.
            _armAdminProof(l, "A14", p, K, 100, abi.encode(900 * ONE, uint256(0), address(mediator), 100 * ONE, true));
        }
        l = string.concat("A18", suffix);
        if (_selected(l)) _armSettle(l, "A18", "settle", p, K, 200, false);
        l = string.concat("A19", suffix);
        if (_selected(l)) _armSettle(l, "A19", "settle", p, ONE, 100, false);
        l = string.concat("A19", suffix, "-win");
        if (_selected(l)) _armRuling(l, "A19", "win", p, ONE, 100, 1, 0, false);
        l = string.concat("A20", suffix);
        if (_selected(l)) _armSettle(l, "A20", "", p, 5 * ONE, 100, false);
        l = string.concat("A21", suffix);
        if (_selected(l)) _armSettle(l, "A21", "settle", p, 100_000, 100, false);
        l = string.concat("A22", suffix);
        if (_selected(l)) _armSettle(l, "A22", "", p, 50_000, 100, false);
    }

    function _parts(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory parts) {
        parts = new uint256[](c == 0 ? 2 : 3);
        parts[0] = a;
        parts[1] = b;
        if (c != 0) parts[2] = c;
    }

    function armLongRunning() external {
        _loadStack();
        _armForceStale("A25", "A25", B, K, 1000);
        _writeRunFile("a25");
    }

    // ----- negatives: simulated calls against live state, never broadcast -----

    string internal negatives;
    uint256 internal negativeCount;

    function probeNegatives() external {
        _loadStack();
        address stranger = address(0xBAD);
        address unapproved = address(0x0BAD1);

        // Prerequisites, simulated: four unlinked transactions and the provider's approval at 100 bps.
        vm.prank(provider);
        vault.setIntegratorApproval(integrator, 100);
        vm.startPrank(requester);
        _mint(requester, 4 * K);
        token.approve(address(vault), 4 * K);
        bytes32[4] memory ids;
        for (uint256 i; i < 4; i++) {
            ids[i] = kernel.createTransaction(provider, requester, K, block.timestamp + 1 days, 1 hours, SERVICE, bytes32(0), 0, 0);
        }
        bytes32 notATx = keccak256("not a transaction id");
        vault.setEscrowTerms(notATx, integrator, 100, IFeeSplitVault.FeeProfile.PAYOUT_ONLY);
        vault.setEscrowTerms(ids[1], unapproved, 1, IFeeSplitVault.FeeProfile.PAYOUT_ONLY);
        vault.setEscrowTerms(ids[2], integrator, 101, IFeeSplitVault.FeeProfile.PAYOUT_ONLY);
        vault.setEscrowTerms(ids[3], provider, 100, IFeeSplitVault.FeeProfile.PAYOUT_ONLY);
        vm.stopPrank();
        uint256 requesterBalance = token.balanceOf(requester);
        uint256 vaultBalance = token.balanceOf(address(vault));

        bytes memory k = abi.encodeWithSelector(kernel.linkEscrow.selector, ids[0], address(vault), notATx);
        _negative("A23 terms registered, escrowId is not a transaction id", address(kernel), k, requester, "Escrow ID needs matching tx");
        k = abi.encodeWithSelector(kernel.linkEscrow.selector, ids[0], address(vault), keccak256("no terms, not a transaction id"));
        _negative("A23 no terms, escrowId is not a transaction id", address(kernel), k, requester, "Escrow ID needs matching tx");
        // A26: the stranger's own transaction, linked under the requester's transaction id.
        vm.startPrank(stranger);
        _mint(stranger, K);
        token.approve(address(vault), K);
        bytes32 strangerTx = kernel.createTransaction(provider, stranger, K, block.timestamp + 1 days, 1 hours, SERVICE, bytes32(0), 0, 0);
        vm.stopPrank();
        k = abi.encodeWithSelector(kernel.linkEscrow.selector, strangerTx, address(vault), ids[0]);
        _negative("A26 another requester's transaction id as escrowId", address(kernel), k, stranger, "Escrow ID needs matching tx");
        k = abi.encodeWithSelector(kernel.linkEscrow.selector, ids[1], address(vault), ids[1]);
        _negative("integrator the provider did not approve", address(kernel), k, requester, "Integrator not approved");
        k = abi.encodeWithSelector(kernel.linkEscrow.selector, ids[2], address(vault), ids[2]);
        _negative("rate above the provider's maximum", address(kernel), k, requester, "Integrator not approved");
        k = abi.encodeWithSelector(kernel.linkEscrow.selector, ids[3], address(vault), ids[3]);
        _negative("provider as its own integrator", address(kernel), k, requester, "Invalid integrator");

        bytes4 terms = vault.setEscrowTerms.selector;
        bytes32 id = keccak256("negatives");
        _negative("rate above 1000 bps", address(vault), abi.encodeWithSelector(terms, id, integrator, 1001, 0), requester, "Bps above cap");
        address[5] memory invalid = [address(0), requester, address(vault), address(kernel), address(token)];
        string[5] memory names = ["zero", "the requester", "the vault", "the kernel", "the token"];
        for (uint256 i; i < invalid.length; i++) {
            _negative(
                string.concat("invalid integrator: ", names[i]), address(vault),
                abi.encodeWithSelector(terms, id, invalid[i], 100, 0), requester, "Invalid integrator"
            );
        }

        bytes memory c = abi.encodeWithSelector(vault.createEscrow.selector, id, requester, provider, K);
        _negative("createEscrow by a non-kernel caller", address(vault), c, stranger, "Only kernel");
        c = abi.encodeWithSelector(vault.payoutToProvider.selector, id, K);
        _negative("payoutToProvider by a non-kernel caller", address(vault), c, stranger, "Only kernel");
        c = abi.encodeWithSelector(vault.refundToRequester.selector, id, K);
        _negative("refundToRequester by a non-kernel caller", address(vault), c, stranger, "Only kernel");
        c = abi.encodeWithSelector(vault.payout.selector, id, stranger, K);
        _negative("payout by a non-kernel caller", address(vault), c, stranger, "Only kernel");
        c = abi.encodeWithSelector(vault.depositBond.selector, id, requester, K);
        _negative("depositBond by a non-kernel caller", address(vault), c, stranger, "Only kernel");
        c = abi.encodeWithSelector(vault.releaseBond.selector, id, stranger, K);
        _negative("releaseBond by a non-kernel caller", address(vault), c, stranger, "Only kernel");

        require(token.balanceOf(requester) == requesterBalance, "requester balance changed");
        require(token.balanceOf(address(vault)) == vaultBalance, "vault balance changed");

        string memory path = string.concat(RUN_DIR, _prefix(), "-negatives-", vm.toString(block.number), ".json");
        vm.writeFile(
            path,
            string.concat(
                '{\n  "version":1,"kind":"negatives","chainId":', vm.toString(block.chainid), ',"block":', vm.toString(block.number),
                ',\n  "kernel":"', vm.toString(address(kernel)), '","feeSplitVault":"', vm.toString(address(vault)),
                '",\n  "balancesUnchanged":true,"count":', vm.toString(negativeCount), ',\n  "negatives":[\n    ', negatives, "\n  ]\n}\n"
            )
        );
        console2.log("negatives file:", path);
    }

    /// @dev The call must revert, and its revert data must be exactly Error(reason).
    function _negative(string memory name, address target, bytes memory data, address from, string memory reason) internal {
        vm.prank(from);
        (bool ok, bytes memory ret) = target.call(data);
        require(!ok, string.concat("negative did not revert: ", name));
        require(
            keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", reason)),
            string.concat("negative reverted with another reason: ", name)
        );
        negatives = string.concat(negatives, negativeCount == 0 ? "" : ",\n    ", '{"name":"', name, '","reason":"', reason, '"}');
        negativeCount++;
        console2.log(string.concat("reverts as expected: ", name));
    }
}
