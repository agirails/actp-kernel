// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {console2} from "forge-std/Script.sol";
import {FeeSplitRows} from "./feesplit/FeeSplitRows.sol";
import {BatchWallet} from "./feesplit/BatchWallet.sol";
import {IFeeSplitVault} from "../src/interfaces/IFeeSplitVault.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";

interface IBlockableToken {
    function setBlocked(address who, bool blocked) external;
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title SelfTestFeeSplitLocal — the scenarios of the reconciler self-tests, on a local anvil stack.
 * @notice ANVIL-ONLY. Driven by deployments/scripts/feesplit_selftest.py, which advances time
 *         between the stages and runs the reconciler. Honest fixtures H1-H8 of the plan:
 *           H1 a completed dispute with the bond released to the winner (A9, profile B)
 *           H2 a split exit with the bond returned to the initiator (A7)
 *           H3 a plain-vault control (A1)
 *           H4 a credit retained at one report and withdrawn at the next (A15, then A17)
 *           H5 one transaction that settles an escrow and withdraws a credit of the same integrator;
 *              and one that settles with the integrator blocked, unblocks it and withdraws the old
 *              and the new credit together
 *           H6 a stale dispute, pending first and force-resolved later (A25, armLongRunning)
 *           H7 a donation on its own, and a donation inside the transaction that links an escrow
 *           H8 an escrow linked by an address outside the manifest and left in COMMITTED; and one
 *              whose provider is the kernel itself, cancelled by its requester after the deadline
 *         and the escrows of the seeded defects D1, D2 and D5 against a defective vault build.
 *
 * Extra env: FOREIGN_KEY (H8), WALLET (after deployWallet), DEFECT (armDefect).
 */
contract SelfTestFeeSplitLocal is FeeSplitRows {
    uint256 internal constant K = 1000 * ONE;

    function _local() internal {
        require(block.chainid == 31337, "SelfTestFeeSplitLocal: anvil (31337) only");
        _loadStack();
    }

    function deployWallet() external {
        _local();
        vm.broadcast(requesterKey);
        BatchWallet wallet = new BatchWallet();
        console2.log("WALLET", address(wallet));
    }

    function _call(address target, bytes memory data) internal pure returns (BatchWallet.Call memory) {
        return BatchWallet.Call({target: target, data: data});
    }

    function _walletTxId(address wallet, uint256 amount) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(wallet, provider, amount, SERVICE, kernel.requesterNonces(wallet)));
    }

    /// @dev Wallet escrow: create, approve, register terms and link in one transaction, with
    ///      `donation` units sent to the vault first in that same transaction.
    function _walletOpen(BatchWallet wallet, uint256 amount, uint8 profile, uint256 donation) internal returns (bytes32 txId) {
        txId = _walletTxId(address(wallet), amount);
        BatchWallet.Call[] memory calls = new BatchWallet.Call[](donation == 0 ? 4 : 5);
        uint256 n;
        if (donation != 0) {
            calls[n++] = _call(address(token), abi.encodeWithSelector(token.transfer.selector, address(vault), donation));
        }
        calls[n++] = _call(
            address(kernel),
            abi.encodeWithSelector(
                kernel.createTransaction.selector, provider, address(wallet), amount, block.timestamp + 7 days, 1 hours, SERVICE, bytes32(0), 0, 0
            )
        );
        calls[n++] = _call(address(token), abi.encodeWithSelector(token.approve.selector, address(vault), amount));
        calls[n++] = _call(
            address(vault),
            abi.encodeWithSelector(
                vault.setEscrowTerms.selector, txId, integrator, 100,
                profile == B ? IFeeSplitVault.FeeProfile.BOTH_AFTER_DISPUTE : IFeeSplitVault.FeeProfile.PAYOUT_ONLY
            )
        );
        calls[n++] = _call(address(kernel), abi.encodeWithSelector(kernel.linkEscrow.selector, txId, address(vault), txId));
        vm.startBroadcast(requesterKey);
        _mint(address(wallet), amount + donation);
        wallet.execute(calls);
        vm.stopBroadcast();
    }

    function armHonest() external {
        _local();
        BatchWallet wallet = BatchWallet(vm.envAddress("WALLET"));
        IBlockableToken blockable = IBlockableToken(address(token));

        // H3, H1, H2.
        _armSettle("H3-A1", "A1", "", NONE, K, 0, true);
        _armRuling("H1-A9-B", "A9", "", B, K, 100, 1, 0, false);
        _armRuling("H2-A7-B", "A7", "", B, K, 100, 2, 4000, false);
        _armRuling("H2-A7-D", "A7", "", D, K, 100, 2, 4000, false);

        // First credit: the integrator's push fails while it is blocked (A15 as A3).
        vm.broadcast(keeperKey);
        blockable.setBlocked(integrator, true);
        _armSettle("H5-credit-A15", "A15", "settle", D, K, 100, false);
        vm.broadcast(keeperKey);
        blockable.setBlocked(integrator, false);

        // H5: one transaction settles an A3-shaped escrow (10.000000 pushed to the integrator) and
        // withdraws the 10.000000 credit of the same integrator.
        bytes32 walletTx = _walletOpen(wallet, K, D, 0);
        _start(walletTx);
        _deliver(walletTx);
        BatchWallet.Call[] memory both = new BatchWallet.Call[](2);
        both[0] = _call(address(kernel), abi.encodeWithSelector(kernel.transitionState.selector, walletTx, IACTPKernel.State.SETTLED, ""));
        both[1] = _call(address(vault), abi.encodeWithSelector(vault.withdrawIntegratorCredit.selector, integrator));
        vm.broadcast(requesterKey);
        wallet.execute(both);
        _entry("H5-settle-and-withdraw", "A3", "", D, 100, walletTx, "SETTLED", "none", 0, false);

        // H5, second shape: a credit exists, the next settlement is credited as well, and the same
        // transaction unblocks the integrator and withdraws both credits as one transfer.
        vm.broadcast(keeperKey);
        blockable.setBlocked(integrator, true);
        _armSettle("H5-second-credit-A15", "A15", "settle", D, K, 100, false);
        bytes32 creditedTx = _walletOpen(wallet, K, D, 0);
        _start(creditedTx);
        _deliver(creditedTx);
        BatchWallet.Call[] memory three = new BatchWallet.Call[](3);
        three[0] = _call(address(kernel), abi.encodeWithSelector(kernel.transitionState.selector, creditedTx, IACTPKernel.State.SETTLED, ""));
        three[1] = _call(address(token), abi.encodeWithSelector(blockable.setBlocked.selector, integrator, false));
        three[2] = _call(address(vault), abi.encodeWithSelector(vault.withdrawIntegratorCredit.selector, integrator));
        vm.broadcast(requesterKey);
        wallet.execute(three);
        _entry("H5-credit-unblock-withdraw", "A15", "settle", D, 100, creditedTx, "SETTLED", "none", 0, false);

        // H4: a second credit, retained until after the first report.
        vm.broadcast(keeperKey);
        blockable.setBlocked(integrator, true);
        _armSettle("H4-credit-A15", "A15", "settle", B, K, 100, false);

        // H7: a donation on its own, and one unit donated inside the transaction that links an escrow.
        vm.startBroadcast(keeperKey);
        blockable.mint(keeper, 5 * ONE);
        blockable.transfer(address(vault), 5 * ONE);
        vm.stopBroadcast();
        bytes32 donated = _walletOpen(wallet, K, D, 1);
        _start(donated);
        _deliver(donated);
        BatchWallet.Call[] memory settle = new BatchWallet.Call[](1);
        settle[0] = _call(address(kernel), abi.encodeWithSelector(kernel.transitionState.selector, donated, IACTPKernel.State.SETTLED, ""));
        vm.broadcast(requesterKey);
        wallet.execute(settle);
        _entry("H7-donation-in-link", "A15", "settle", D, 100, donated, "SETTLED", "none", 0, false);

        // H8: an escrow linked by an address outside the manifest, left in COMMITTED.
        uint256 foreignKey = vm.envUint("FOREIGN_KEY");
        address foreign = vm.addr(foreignKey);
        vm.startBroadcast(foreignKey);
        _mint(foreign, K);
        bytes32 foreignTx =
            kernel.createTransaction(provider, foreign, K, block.timestamp + 7 days, 1 hours, SERVICE, bytes32(0), 0, 0);
        token.approve(address(vault), K);
        vault.setEscrowTerms(foreignTx, integrator, 100, IFeeSplitVault.FeeProfile.BOTH_AFTER_DISPUTE);
        kernel.linkEscrow(foreignTx, address(vault), foreignTx);
        vm.stopBroadcast();
        console2.log("FOREIGN_TX", vm.toString(foreignTx));

        // H8, second shape: anyone may name the kernel as provider. Its requester cancels after the
        // deadline, and the 5% penalty is then a provider payment to the kernel, not an archive share.
        vm.startBroadcast(foreignKey);
        _mint(foreign, K);
        bytes32 kernelProviderTx = kernel.createTransaction(
            address(kernel), foreign, K, block.timestamp + 70 minutes, 1 hours, SERVICE, bytes32(0), 0, 0
        );
        token.approve(address(vault), K);
        kernel.linkEscrow(kernelProviderTx, address(vault), kernelProviderTx);
        vm.stopBroadcast();
        console2.log("FOREIGN_KERNEL_PROVIDER_TX", vm.toString(kernelProviderTx));

        _writeRunFile("selftest");
    }

    /// @dev H6: its own run file, because it stays open for 30 days.
    function armLongRunning() external {
        _local();
        _armForceStale("H6-A25", "A25", B, K, 1000);
        _writeRunFile("a25");
    }

    /// @dev H4, second half (A17): unblock the integrator, then anyone withdraws its credit.
    function withdrawCredit() external {
        _local();
        vm.startBroadcast(keeperKey);
        IBlockableToken(address(token)).setBlocked(integrator, false);
        vault.withdrawIntegratorCredit(integrator);
        vm.stopBroadcast();
    }

    /// @dev H8, second shape, after the deadline: the foreign requester cancels (FOREIGN_TX names it).
    function foreignCancel() external {
        _local();
        vm.broadcast(vm.envUint("FOREIGN_KEY"));
        kernel.transitionState(vm.envBytes32("FOREIGN_TX"), IACTPKernel.State.CANCELLED, "");
    }

    /// @dev One escrow against a defective vault build (FEE_SPLIT_VAULT names it).
    function armDefect() external {
        _local();
        bytes32 kind = keccak256(bytes(vm.envString("DEFECT")));
        if (kind == keccak256("D1")) {
            _armSettle("D1-A3", "A3", "", D, K, 100, false); // net basis: wrong provider-side share
            _writeRunFile("defect-d1");
        } else if (kind == keccak256("D2")) {
            _armProviderCancel("D2-A11-B", "A11", B, K, 100); // refund fee without a dispute
            _writeRunFile("defect-d2");
        } else if (kind == keccak256("D5")) {
            _armSettle("D5-A3", "A3", "", D, K, 100, false); // integrator increment paid twice
            _writeRunFile("defect-d5");
        } else {
            revert("unknown DEFECT");
        }
    }
}
