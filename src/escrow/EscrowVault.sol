// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 *   █████╗ ██████╗ ██╗  ██╗ █████╗
 *  ██╔══██╗██╔══██╗██║  ██║██╔══██╗
 *  ███████║██████╔╝███████║███████║
 *  ██╔══██║██╔══██╗██╔══██║██╔══██║
 *  ██║  ██║██║  ██║██║  ██║██║  ██║
 *  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
 *
 *  AgenticOS Organism
 */

import "../interfaces/IEscrowValidator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EscrowVault - Arha Escrow Manager
 * @notice Non-custodial escrow vault for ACTP transactions
 */
contract EscrowVault is IEscrowValidator, ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct EscrowData {
        address requester;
        address provider;
        uint256 amount;
        uint256 releasedAmount;
        bool active;
    }

    IERC20 public immutable token;
    address public immutable kernel;

    mapping(bytes32 => EscrowData) public escrows;

    event EscrowCreated(bytes32 indexed escrowId, address indexed requester, address indexed provider, uint256 amount);
    event EscrowPayout(bytes32 indexed escrowId, address indexed recipient, uint256 amount);
    event EscrowCompleted(bytes32 indexed escrowId, uint256 totalReleased);

    constructor(address _token, address _kernel) {
        require(_token != address(0) && _kernel != address(0), "Zero address");
        require(_token != _kernel, "Token and kernel must differ");
        token = IERC20(_token);
        kernel = _kernel;
    }

    modifier onlyKernel() {
        // Authorization: only kernel coordinator
        require(msg.sender == kernel, "Only kernel");
        _;
    }

    function createEscrow(bytes32 escrowId, address requester, address provider, uint256 amount) external onlyKernel nonReentrant {
        require(escrows[escrowId].amount == 0, "Escrow exists");
        require(requester != address(0) && provider != address(0), "Zero address");
        require(amount > 0, "Amount zero");

        escrows[escrowId] = EscrowData({
            requester: requester,
            provider: provider,
            amount: amount,
            releasedAmount: 0,
            active: true
        });

        token.safeTransferFrom(requester, address(this), amount);

        // State changes must be observable
        emit EscrowCreated(escrowId, requester, provider, amount);
    }

    function verifyEscrow(
        bytes32 escrowId,
        address requester,
        address provider,
        uint256 amount
    ) external view override returns (bool isActive, uint256 escrowAmount) {
        EscrowData memory e = escrows[escrowId];
        bool matches = e.active && e.requester == requester && e.provider == provider && e.amount >= amount;
        return (matches, e.amount);
    }

    function payoutToProvider(bytes32 escrowId, uint256 amount) external override onlyKernel returns (uint256) {
        EscrowData storage e = escrows[escrowId];
        require(e.provider != address(0), "Escrow missing");
        return _disburse(e, escrowId, e.provider, amount);
    }

    function refundToRequester(bytes32 escrowId, uint256 amount) external override onlyKernel returns (uint256) {
        EscrowData storage e = escrows[escrowId];
        require(e.requester != address(0), "Escrow missing");
        return _disburse(e, escrowId, e.requester, amount);
    }

    function payout(bytes32 escrowId, address recipient, uint256 amount) external override onlyKernel returns (uint256) {
        EscrowData storage e = escrows[escrowId];
        require(recipient != address(0), "Zero recipient");
        return _disburse(e, escrowId, recipient, amount);
    }

    function remaining(bytes32 escrowId) external view override returns (uint256) {
        EscrowData memory e = escrows[escrowId];
        if (e.amount == 0) return 0;
        return e.amount - e.releasedAmount;
    }

    function _disburse(
        EscrowData storage e,
        bytes32 escrowId,
        address recipient,
        uint256 amount
    ) internal returns (uint256) {
        require(e.active, "Escrow inactive");
        require(amount > 0, "Amount zero");

        uint256 available = e.amount - e.releasedAmount;
        // Fund conservation: disbursement cannot exceed locked amount
        require(amount <= available, "Insufficient escrow");

        e.releasedAmount += amount;
        if (e.releasedAmount == e.amount) {
            e.active = false;
            emit EscrowCompleted(escrowId, e.amount);

            // M-1 FIX: Delete escrow data to allow ID reuse after completion
            // This resets amount to 0, allowing createEscrow check to pass for future use
            delete escrows[escrowId];
        }

        token.safeTransfer(recipient, amount);
        emit EscrowPayout(escrowId, recipient, amount);
        return amount;
    }
}
