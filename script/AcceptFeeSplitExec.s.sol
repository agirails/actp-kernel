// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeSplitRows} from "./feesplit/FeeSplitRows.sol";

/**
 * @title AcceptFeeSplitExec — the time-gated half of a run file written by an Arm script.
 * @notice Finalizes proposed rulings after liveness, cancels as the requester after the deadline,
 *         recovers stalled escrows, and force-resolves the stale dispute of A25. It refuses the
 *         whole run while any entry that still needs execution is before its recorded time, and it
 *         skips entries that are already in their terminal state, so it can be run again.
 *
 * Env: RUN_FILE (path of the run file) plus the stack and key variables of FeeSplitRows.
 * Run: RUN_FILE=deployments/feesplit-acceptance/sepolia-matrix-<block>.json \
 *      forge script script/AcceptFeeSplitExec.s.sol --rpc-url $RPC --broadcast --slow
 */
contract AcceptFeeSplitExec is FeeSplitRows {
    function run() external {
        _loadStack();
        _execRunFile(vm.envString("RUN_FILE"));
    }
}
