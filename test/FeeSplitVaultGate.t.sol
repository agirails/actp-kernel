// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FeeSplitTestBase} from "./helpers/FeeSplitTestBase.sol";
import {VerifyFeeSplitGate} from "../script/VerifyFeeSplitGate.s.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {FeeSplitVault} from "../src/escrow/FeeSplitVault.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOOV3} from "./mocks/MockOOV3.sol";
import {LegacyKernel8c77db7} from "./fixtures/LegacyKernel8c77db7.sol";

/// @title FeeSplitVaultGateTest — the deploy gate accepts the supported, correctly wired stack and
///        rejects each unsupported or mis-wired one with its own message (plan step 4c and step 8).
contract FeeSplitVaultGateTest is FeeSplitTestBase {
    VerifyFeeSplitGate internal gate;
    bytes32 internal probeTx;

    function setUp() public {
        _setUpStack();
        gate = new VerifyFeeSplitGate();
        probeTx = _open(1000 * ONE, 100, BOTH); // a real, linked transaction
    }

    function _inputs() internal view returns (VerifyFeeSplitGate.Inputs memory i) {
        i.kernel = address(kernel);
        i.vault = address(vault);
        i.mediator = address(mediator);
        i.bond = address(bondEscalation);
        i.probeTx = probeTx;
    }

    function _bond(CompositeMediator m) internal returns (BondEscalation) {
        address[2] memory fixedEvaluators = [makeAddr("fixed0"), makeAddr("fixed1")];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = makeAddr("rotating0");
        return new BondEscalation(
            IACTPKernel(address(kernel)), usdc, ICompositeMediator(address(m)), address(this), fixedEvaluators, rotatingPool,
            address(new MockOOV3())
        );
    }

    function test_Gate_Passes_RecordThenEnforce() public {
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        gate.verify(i); // RECORD: no pins
        i.kernelCodehash = address(kernel).codehash;
        i.mediatorCodehash = address(mediator).codehash;
        i.bondCodehash = address(bondEscalation).codehash;
        i.vaultCodehash = address(vault).codehash;
        gate.verify(i); // ENFORCE

        i.vaultCodehash = keccak256("another build");
        vm.expectRevert("GATE: vault codehash mismatch");
        gate.verify(i);
        i.vaultCodehash = address(vault).codehash;
        i.kernelCodehash = keccak256("another build");
        vm.expectRevert("GATE: kernel codehash mismatch");
        gate.verify(i);
    }

    /// @dev A real 8c77db7 kernel build: it has resolveDisputeWhilePaused and no escrowPrincipal.
    function test_Gate_Rejects_KernelWithoutEscrowPrincipal() public {
        address legacy = makeAddr("kernel 8c77db7");
        vm.etch(legacy, LegacyKernel8c77db7.RUNTIME);
        assertEq(legacy.code.length, 24_432);
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        i.kernel = legacy;
        vm.expectRevert("GATE: kernel lacks escrowPrincipal");
        gate.verify(i);
    }

    function test_Gate_Rejects_UninitializedMediator() public {
        CompositeMediator fresh = new CompositeMediator(IACTPKernel(address(kernel)));
        assertEq(address(fresh).codehash, address(mediator).codehash, "same code, different wiring");
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        i.mediator = address(fresh);
        vm.expectRevert("GATE: mediator is not initialized");
        gate.verify(i);
    }

    function test_Gate_Rejects_MediatorInitializedToAnotherBond() public {
        CompositeMediator other = new CompositeMediator(IACTPKernel(address(kernel)));
        BondEscalation named = _bond(other);
        BondEscalation wired = _bond(other);
        other.initialize(address(wired));
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        i.mediator = address(other);
        i.bond = address(named);
        vm.expectRevert("GATE: mediator.bondEscalation() != bond");
        gate.verify(i);
    }

    function test_Gate_Rejects_BondPointingAtAnotherMediator() public {
        CompositeMediator other = new CompositeMediator(IACTPKernel(address(kernel)));
        BondEscalation othersBond = _bond(other); // compositeMediator() == other
        CompositeMediator claimed = new CompositeMediator(IACTPKernel(address(kernel)));
        claimed.initialize(address(othersBond));
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        i.mediator = address(claimed);
        i.bond = address(othersBond);
        vm.expectRevert("GATE: bond.compositeMediator() != mediator");
        gate.verify(i);
    }

    function test_Gate_Rejects_MediatorInsideActivationDelay() public {
        CompositeMediator fresh = new CompositeMediator(IACTPKernel(address(kernel)));
        BondEscalation freshBond = _bond(fresh);
        fresh.initialize(address(freshBond));
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        i.mediator = address(fresh);
        i.bond = address(freshBond);
        vm.expectRevert("GATE: mediator is not an approved kernel resolver");
        gate.verify(i);

        kernel.approveMediator(address(fresh), true);
        vm.expectRevert("GATE: mediator approval is inside its activation delay");
        gate.verify(i);

        vm.warp(block.timestamp + 2 days);
        gate.verify(i);
    }

    function test_Gate_Rejects_VaultOfAnotherKernel() public {
        ACTPKernel otherKernel = new ACTPKernel(address(this), address(this), feeRecipient, address(0), address(usdc), 1 hours);
        FeeSplitVault otherVault = new FeeSplitVault(address(usdc), address(otherKernel));
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        i.vault = address(otherVault);
        vm.expectRevert("GATE: vault.kernel() != kernel");
        gate.verify(i);
    }

    function test_Gate_Rejects_UnknownProbeTransaction() public {
        VerifyFeeSplitGate.Inputs memory i = _inputs();
        i.probeTx = keccak256("not a transaction");
        vm.expectRevert("Tx missing");
        gate.verify(i);
    }

    function test_Gate_Rejects_UnapprovedVaultThatIsNotEmpty() public {
        // Revoke the vault through the timelock while it holds the probe escrow.
        kernel.scheduleEscrowVaultRevocation(address(vault));
        vm.warp(block.timestamp + 2 days);
        kernel.executeEscrowVaultRevocation(address(vault));
        vm.expectRevert("GATE: unapproved vault is not empty");
        gate.verify(_inputs());
    }
}
