// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";
import {BondEscalation} from "../src/BondEscalation.sol";
import {CompositeMediator} from "../src/CompositeMediator.sol";
import {EscrowVault} from "../src/escrow/EscrowVault.sol";
import {FeeSplitVault} from "../src/escrow/FeeSplitVault.sol";
import {ArchiveTreasury} from "../src/treasury/ArchiveTreasury.sol";
import {IACTPKernel} from "../src/interfaces/IACTPKernel.sol";
import {ICompositeMediator} from "../src/interfaces/ICompositeMediator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOOV3} from "../test/mocks/MockOOV3.sol";
import {BlacklistUSDC} from "../test/audit/F17F59_FeeAccounting.t.sol";

/**
 * @title DeployLocalFeeSplitStack
 * @notice ANVIL-ONLY (chainId 31337) candidate stack for the FeeSplitVault acceptance tooling:
 *         blockable test token, kernel, EscrowVault, FeeSplitVault, archive treasury, mock OOV3,
 *         CompositeMediator and BondEscalation, wired as DeployLocalDisputeStack does.
 *
 *         The token is BlacklistUSDC, so that a fee push can fail and credits can occur; the Sepolia
 *         token cannot do that. `approveMediator` starts the 2-day activation delay: advance anvil
 *         time past it before a ruling is finalized.
 *
 * Env: PRIVATE_KEY (deployer = admin, pauser, uploader), FEE_RECIPIENT (address).
 */
contract DeployLocalFeeSplitStack is Script {
    function run() external {
        require(block.chainid == 31337, "DeployLocalFeeSplitStack: anvil (31337) only");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast(deployerKey);
        BlacklistUSDC usdc = new BlacklistUSDC();
        ACTPKernel kernel = new ACTPKernel(deployer, deployer, feeRecipient, address(0), address(usdc), 1 hours);
        EscrowVault plain = new EscrowVault(address(usdc), address(kernel));
        FeeSplitVault vault = new FeeSplitVault(address(usdc), address(kernel));
        kernel.approveEscrowVault(address(plain), true);
        kernel.approveEscrowVault(address(vault), true);
        ArchiveTreasury archive = new ArchiveTreasury(address(usdc), address(kernel), deployer);
        kernel.setArchiveTreasury(address(archive));

        CompositeMediator mediator = new CompositeMediator(IACTPKernel(address(kernel)));
        address[2] memory fixedEvaluators = [address(0xF1), address(0xF2)];
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = address(0xF3);
        BondEscalation bond = new BondEscalation(
            IACTPKernel(address(kernel)),
            IERC20(address(usdc)),
            ICompositeMediator(address(mediator)),
            deployer,
            fixedEvaluators,
            rotatingPool,
            address(new MockOOV3())
        );
        mediator.initialize(address(bond));
        kernel.approveMediator(address(mediator), true);
        vm.stopBroadcast();

        console2.log("DEPLOY_JSON_BEGIN");
        console2.log(string.concat('{"token":"', vm.toString(address(usdc)), '",'));
        console2.log(string.concat('"kernel":"', vm.toString(address(kernel)), '",'));
        console2.log(string.concat('"plainVault":"', vm.toString(address(plain)), '",'));
        console2.log(string.concat('"feeSplitVault":"', vm.toString(address(vault)), '",'));
        console2.log(string.concat('"archive":"', vm.toString(address(archive)), '",'));
        console2.log(string.concat('"mediator":"', vm.toString(address(mediator)), '",'));
        console2.log(string.concat('"bond":"', vm.toString(address(bond)), '",'));
        console2.log(string.concat('"deployer":"', vm.toString(deployer), '"}'));
        console2.log("DEPLOY_JSON_END");
    }
}
