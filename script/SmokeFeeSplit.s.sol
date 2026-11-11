// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeSplitRows} from "./feesplit/FeeSplitRows.sol";

/**
 * @title SmokeFeeSplit — first live transactions through a freshly approved FeeSplitVault.
 * @notice The shapes of A3, A4 and A7 in both profiles, A9 in profile B and A12, at 10 USDC each.
 *         Two stages, because a ruling needs its liveness and a requester cancel needs the deadline:
 *           SMOKE_STAGE=arm   creates the escrows and writes a run file (set "smoke")
 *           SMOKE_STAGE=exec  after the recorded time: finalizes and cancels (RUN_FILE=...)
 *         The entries name no acceptance row: at 10 USDC the kernel's minimum fee applies to small
 *         shares, so the amounts are not a scaled copy of the table. The reconciler checks them
 *         against the fee rules to the micro-USDC:
 *           python3 deployments/scripts/reconcile_feesplit.py ... --runs '<the smoke run file>'
 *
 * Run: SMOKE_STAGE=arm  forge script script/SmokeFeeSplit.s.sol --rpc-url $RPC --broadcast --slow
 *      SMOKE_STAGE=exec RUN_FILE=... forge script script/SmokeFeeSplit.s.sol --rpc-url $RPC --broadcast --slow
 */
contract SmokeFeeSplit is FeeSplitRows {
    uint256 internal constant AMOUNT = 10 * ONE;

    function run() external {
        _loadStack();
        if (keccak256(bytes(vm.envString("SMOKE_STAGE"))) == keccak256("exec")) {
            _execRunFile(vm.envString("RUN_FILE"));
            return;
        }
        uint256[] memory parts = new uint256[](2);
        parts[0] = AMOUNT / 4;
        parts[1] = AMOUNT / 4;
        for (uint8 p = D; p <= B; p++) {
            string memory suffix = p == D ? "-D" : "-B";
            _armSettle(string.concat("smoke-A3", suffix), "", "", p, AMOUNT, 100, false);
            _armMilestones(string.concat("smoke-A4", suffix), "", p, AMOUNT, 100, parts);
            _armRuling(string.concat("smoke-A7", suffix), "", "", p, AMOUNT, 100, 2, 4000, false);
        }
        _armRuling("smoke-A9-B", "", "", B, AMOUNT, 100, 1, 0, false);
        _armRequesterCancel("smoke-A12-D", "", D, AMOUNT, 100);
        _writeRunFile("smoke");
    }
}
