// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ACTPKernel.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/escrow/EscrowVault.sol";
import "../src/interfaces/IACTPKernel.sol";

/**
 * @title E2E_AIP14_Fork
 * @notice Fork test against deployed Base Sepolia AIP-14 contracts
 *
 * Usage:
 *   source .env
 *   forge test --match-contract E2E_AIP14_Fork --fork-url $BASE_SEPOLIA_RPC -vvv
 */
contract E2E_AIP14_Fork is Test {
    ACTPKernel kernel = ACTPKernel(0x0ba0b17554601b30F5406e74d2208f567C12CcFE);
    EscrowVault escrow = EscrowVault(0xedC62264301A119207f1f89C6bDE4Fd7a7A4CeB4);
    MockUSDC usdc = MockUSDC(0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb);

    address admin = 0x42a2f11555B9363fB7eBDcdc76D7Cb26e01dCB00;
    address requester = address(0xA001);
    address provider = address(0xB002);

    uint256 constant TX_AMOUNT = 100_000_000; // $100

    function setUp() public {
        // Skip if not running with --fork-url (no code at deployed addresses)
        if (address(kernel).code.length == 0) {
            vm.skip(true);
        }
        // Mint and approve for requester
        usdc.mint(requester, 10_000_000_000);
        vm.prank(requester);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _createDisputed(bytes32 salt) internal returns (bytes32 txId) {
        vm.prank(requester);
        txId = kernel.createTransaction(
            provider, requester, TX_AMOUNT,
            block.timestamp + 30 days, 2 days, salt, bytes32(0), 0, 0
        );

        vm.prank(requester);
        kernel.linkEscrow(txId, address(escrow), txId);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days, keccak256("result")));

        uint256 bond = (TX_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        if (bond < kernel.MIN_DISPUTE_BOND()) bond = kernel.MIN_DISPUTE_BOND();

        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    function testE2E_RequesterAgentId() public {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, TX_AMOUNT,
            block.timestamp + 30 days, 2 days,
            keccak256("e2e-agentid"), bytes32(0), 0, 42
        );

        IACTPKernel.TransactionView memory txn = kernel.getTransaction(txId);
        assertEq(txn.requesterAgentId, 42);
    }

    function testE2E_DisputeSettle_ProviderAtFault_BondToRequester() public {
        bytes32 txId = _createDisputed(keccak256("e2e-test1"));

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        assertTrue(bond > 0, "Bond should exist");
        assertEq(escrow.bondBalance(txId), bond);

        uint256 reqBal = usdc.balanceOf(requester);

        bytes memory proof = abi.encode(TX_AMOUNT, uint256(0), true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(escrow.bondBalance(txId), 0, "Bond not zero");
        assertEq(usdc.balanceOf(requester), reqBal + TX_AMOUNT + bond, "Requester gets escrow + bond");
    }

    function testE2E_DisputeSettle_ProviderNotAtFault_BondToProvider() public {
        bytes32 txId = _createDisputed(keccak256("e2e-test2"));

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 provBal = usdc.balanceOf(provider);

        bytes memory proof = abi.encode(uint256(0), TX_AMOUNT, false);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(escrow.bondBalance(txId), 0);
        uint256 fee = (TX_AMOUNT * kernel.platformFeeBps()) / kernel.MAX_BPS();
        assertEq(usdc.balanceOf(provider), provBal + TX_AMOUNT - fee + bond, "Provider gets escrow + bond");
    }

    function testE2E_DisputeCancelled_BondReturned() public {
        bytes32 txId = _createDisputed(keccak256("e2e-test3"));

        uint256 bond = kernel.getTransaction(txId).disputeBond;
        uint256 reqBal = usdc.balanceOf(requester);

        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.CANCELLED, "");

        assertEq(escrow.bondBalance(txId), 0);
        // Requester gets escrow refund + bond back
        assertEq(usdc.balanceOf(requester), reqBal + TX_AMOUNT + bond);
    }

    function testE2E_MinBondClamp() public {
        uint256 smallAmount = 5_000_000; // $5
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, smallAmount,
            block.timestamp + 30 days, 2 days,
            keccak256("e2e-test4"), bytes32(0), 0, 0
        );

        vm.prank(requester);
        kernel.linkEscrow(txId, address(escrow), txId);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days, keccak256("result")));

        uint256 minBond = kernel.MIN_DISPUTE_BOND();
        vm.startPrank(requester);
        usdc.approve(address(escrow), minBond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        assertEq(kernel.getTransaction(txId).disputeBond, minBond, "Bond not clamped to $1");
    }

    function testE2E_ProviderDisputes_ProviderAtFault_BondToRequester() public {
        // Provider opens dispute, found at fault -> bond goes to requester
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, TX_AMOUNT,
            block.timestamp + 30 days, 2 days,
            keccak256("e2e-test5"), bytes32(0), 0, 0
        );

        vm.prank(requester);
        kernel.linkEscrow(txId, address(escrow), txId);

        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days, keccak256("result")));

        // Provider disputes
        uint256 bond = (TX_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        usdc.mint(provider, bond);
        vm.startPrank(provider);
        usdc.approve(address(escrow), bond);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();

        assertEq(kernel.getTransaction(txId).disputeInitiator, provider);

        uint256 reqBal = usdc.balanceOf(requester);

        // Resolve: provider at fault -> bond to REQUESTER (not back to provider)
        bytes memory proof = abi.encode(TX_AMOUNT, uint256(0), true);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(admin);
        kernel.transitionState(txId, IACTPKernel.State.SETTLED, proof);

        assertEq(escrow.bondBalance(txId), 0);
        // Requester gets escrow + provider's forfeited bond
        assertEq(usdc.balanceOf(requester), reqBal + TX_AMOUNT + bond);
    }

    function testE2E_Events_DisputeOpened() public {
        vm.prank(requester);
        bytes32 txId = kernel.createTransaction(
            provider, requester, TX_AMOUNT,
            block.timestamp + 30 days, 2 days,
            keccak256("e2e-test6"), bytes32(0), 0, 0
        );
        vm.prank(requester);
        kernel.linkEscrow(txId, address(escrow), txId);
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.IN_PROGRESS, "");
        vm.prank(provider);
        kernel.transitionState(txId, IACTPKernel.State.DELIVERED, abi.encode(10 days, keccak256("result")));

        uint256 bond = (TX_AMOUNT * kernel.disputeBondBps()) / kernel.MAX_BPS();
        vm.startPrank(requester);
        usdc.approve(address(escrow), bond);

        // Expect DisputeOpened event
        vm.expectEmit(true, true, false, true);
        emit DisputeOpened(txId, requester, bond, block.timestamp);
        kernel.transitionState(txId, IACTPKernel.State.DISPUTED, "");
        vm.stopPrank();
    }

    // Mirror events
    event DisputeOpened(bytes32 indexed transactionId, address indexed initiator, uint256 bondAmount, uint256 timestamp);
}
