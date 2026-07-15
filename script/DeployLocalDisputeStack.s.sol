// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ACTPKernel} from "../src/ACTPKernel.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../src/tokens/MockUSDC.sol";
import {MockOOV3} from "../test/mocks/MockOOV3.sol";

/**
 * @title DeployLocalDisputeStack
 * @notice ANVIL-ONLY (chainId 31337) full AIP-14c v2 dispute-stack deployment for the
 *         capstone E2E: MockUSDC → ACTPKernel(v2) → EscrowVault → MockOOV3 →
 *         CompositeMediator → BondEscalation → wiring. Mirrors the canonical
 *         `test/helpers/DisputeTestBase._setUpStack()` order, with the deployer EOA as
 *         admin/pauser/feeRecipient (a script contract admin would be unusable post-deploy).
 *
 *         NOTE: `kernel.approveMediator` starts the 2-day MEDIATOR_APPROVAL_DELAY — the
 *         E2E harness advances anvil time past it before `finalize()` resolves kernel state.
 *
 * Env:
 *   PRIVATE_KEY            deployer (admin/pauser/feeRecipient)
 *   EVALUATOR_FIXED_0/1    fixed evaluator addresses (on-chain registry slots 0/1)
 *   EVALUATOR_ROTATING_0..2 rotating pool addresses (on-chain order)
 *   FUND_0..2 (optional)   addresses to mint 1M mUSDC each (requester/provider/proposer)
 */
contract DeployLocalDisputeStack is Script {
    function run() external {
        require(block.chainid == 31337, "DeployLocalDisputeStack: anvil (31337) only");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address fixed0 = vm.envAddress("EVALUATOR_FIXED_0");
        address fixed1 = vm.envAddress("EVALUATOR_FIXED_1");
        address[] memory rotatingPool = new address[](3);
        rotatingPool[0] = vm.envAddress("EVALUATOR_ROTATING_0");
        rotatingPool[1] = vm.envAddress("EVALUATOR_ROTATING_1");
        rotatingPool[2] = vm.envAddress("EVALUATOR_ROTATING_2");

        vm.startBroadcast(deployerKey);

        // 1) Token + kernel + escrow (deployer EOA as admin/pauser/feeRecipient).
        MockUSDC usdc = new MockUSDC();
        ACTPKernel kernel = new ACTPKernel(deployer, deployer, deployer, address(0), address(usdc), 1 hours);
        EscrowVault escrow = new EscrowVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(escrow), true);

        // 2) Mock UMA OOV3 (BondEscalation UMA_OOV3 testability override).
        MockOOV3 oov3 = new MockOOV3();

        // 3) CompositeMediator + BondEscalation, wired per _setUpStack().
        CompositeMediator mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        address[2] memory fixedEvaluators = [fixed0, fixed1];
        BondEscalation bond = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(mediator)),
            deployer,
            fixedEvaluators,
            rotatingPool,
            address(oov3)
        );
        mediator.initialize(address(bond));
        kernel.approveMediator(address(mediator), true);

        // 4) Fund actors (1M mUSDC each) when provided.
        for (uint256 i = 0; i < 3; i++) {
            string memory key = string.concat("FUND_", vm.toString(i));
            address who = vm.envOr(key, address(0));
            if (who != address(0)) {
                usdc.mint(who, 1_000_000 * 1e6);
            }
        }

        vm.stopBroadcast();

        // Machine-readable summary (the E2E harness parses these lines).
        console2.log("DEPLOY_JSON_BEGIN");
        console2.log(string.concat('{"usdc":"', vm.toString(address(usdc)), '",'));
        console2.log(string.concat('"kernel":"', vm.toString(address(kernel)), '",'));
        console2.log(string.concat('"escrowVault":"', vm.toString(address(escrow)), '",'));
        console2.log(string.concat('"mockOOV3":"', vm.toString(address(oov3)), '",'));
        console2.log(string.concat('"compositeMediator":"', vm.toString(address(mediator)), '",'));
        console2.log(string.concat('"bondEscalation":"', vm.toString(address(bond)), '",'));
        console2.log(string.concat('"deployer":"', vm.toString(deployer), '"}'));
        console2.log("DEPLOY_JSON_END");
        console2.log("kernelVersion:");
        console2.logBytes32(kernel.kernelVersion());
    }
}
