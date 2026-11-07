// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDisputeSystem} from "../script/DeployDisputeSystem.s.sol";
import {ACTPKernel} from "../src/ACTPKernel.sol";

/// @dev A contract with code but WITHOUT the resolveDisputeWhilePaused selector — a stand-in for the
///      superseded pre-v2 kernel, used to prove the preflight kernel-version gate rejects it.
contract NoSelectorKernel {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

contract DeployDisputeSystemHarness is DeployDisputeSystem {
    /// @dev Sentinel USDC the kernel is deployed against, so the preflight token-match gate
    ///      (kernel.USDC() == c.usdc) is satisfiable with a known value.
    address internal constant USDC = 0x444b4e1A65949AB2ac75979D5d0166Eb7A248Ccb;

    /// @dev A REAL dispute-era kernel (has resolveDisputeWhilePaused + USDC()), so the preflight
    ///      kernel-version + token gates run against a genuine target rather than a stub.
    address internal disputeKernel;

    constructor() {
        disputeKernel =
            address(new ACTPKernel(address(this), address(this), address(this), address(0), USDC, 7 days));
    }

    /// @dev A valid base config wired to the real dispute-era kernel + matching USDC + 3 rotating slots.
    function _baseCfg() internal view returns (Cfg memory c) {
        c.network = "base-sepolia";
        c.isMainnet = false;
        c.kernel = disputeKernel;
        c.usdc = USDC;
        c.admin = address(this);
        c.fixedEvaluators[0] = address(0x1001);
        c.fixedEvaluators[1] = address(0x1002);
        address[] memory rotatingPool = new address[](3);
        rotatingPool[0] = address(0x2001);
        rotatingPool[1] = address(0x2002);
        rotatingPool[2] = address(0x2003);
        c.rotatingPool = rotatingPool;
    }

    function preflightWithRotating(address[] calldata rotatingPool)
        external
        view
        returns (uint256 rotatingLen)
    {
        Cfg memory c = _baseCfg();
        c.rotatingPool = rotatingPool;
        _preflight(c);
        return c.rotatingPool.length;
    }

    function broadcastingContext() external view returns (bool) {
        return _isBroadcasting();
    }

    /// @dev Exercises the DEPLOY_MOCK_OOV3 preflight guard: the mock is a TESTNET-ONLY
    ///      convenience and must hard-revert when combined with base-mainnet.
    function preflightWithMockOOV3(bool isMainnet, bool deployMock) external view {
        Cfg memory c = _baseCfg();
        c.network = isMainnet ? "base-mainnet" : "base-sepolia";
        c.isMainnet = isMainnet;
        c.deployMockOOV3 = deployMock;
        _preflight(c);
    }

    /// @dev Preflight against an arbitrary kernel (for the kernel-version / selector gate test).
    function preflightWithKernel(address kernel) external view {
        Cfg memory c = _baseCfg();
        c.kernel = kernel;
        _preflight(c);
    }

    /// @dev Preflight with a USDC that disagrees with the kernel's USDC() (token-match gate test).
    function preflightWithUsdc(address usdc) external view {
        Cfg memory c = _baseCfg();
        c.usdc = usdc;
        _preflight(c);
    }
}

contract DeployDisputeSystemScriptTest is Test {
    DeployDisputeSystemHarness internal harness;

    function setUp() public {
        harness = new DeployDisputeSystemHarness();
    }

    function testPreflightAcceptsThreeMemberRotatingList() public {
        address[] memory rotatingPool = new address[](3);
        rotatingPool[0] = address(0x2001);
        rotatingPool[1] = address(0x2002);
        rotatingPool[2] = address(0x2003);

        assertEq(harness.preflightWithRotating(rotatingPool), 3);
    }

    function testPreflightRejectsSingleRotatingMember() public {
        address[] memory rotatingPool = new address[](1);
        rotatingPool[0] = address(0x2001);

        vm.expectRevert("P4-4: rotating pool must be >= 3");
        harness.preflightWithRotating(rotatingPool);
    }

    function testPreflightRejectsDuplicateRotatingMember() public {
        address[] memory rotatingPool = new address[](3);
        rotatingPool[0] = address(0x2001);
        rotatingPool[1] = address(0x2002);
        rotatingPool[2] = address(0x2001);

        vm.expectRevert("Duplicate rotating evaluator");
        harness.preflightWithRotating(rotatingPool);
    }

    function testBroadcastingContextUsesFoundryContextNotEnv() public view {
        assertFalse(harness.broadcastingContext());
    }

    function testPreflightRejectsMockOOV3OnMainnet() public {
        vm.expectRevert("DEPLOY_MOCK_OOV3 is testnet-only (mainnet must use the canonical UMA OOV3)");
        harness.preflightWithMockOOV3(true, true);
    }

    function testPreflightAcceptsMockOOV3OnSepolia() public view {
        harness.preflightWithMockOOV3(false, true);
    }

    function testPreflightAcceptsMainnetWithoutMockOOV3() public view {
        harness.preflightWithMockOOV3(true, false);
    }

    /// @dev Fail-closed: a kernel WITHOUT resolveDisputeWhilePaused (the superseded pre-v2 kernel) is
    ///      rejected, so the dispute system can never be wired against a dead resolve path.
    function testPreflightRejectsKernelMissingResolveSelector() public {
        NoSelectorKernel bad = new NoSelectorKernel();
        vm.expectRevert("kernel missing resolveDisputeWhilePaused (needs the dispute-era v2 kernel)");
        harness.preflightWithKernel(address(bad));
    }

    /// @dev Fail-closed: a DISPUTE_USDC that disagrees with the kernel's own USDC() is rejected.
    function testPreflightRejectsUsdcMismatch() public {
        vm.expectRevert("kernel USDC != DISPUTE_USDC (token mismatch)");
        harness.preflightWithUsdc(address(0xDEAD));
    }
}
