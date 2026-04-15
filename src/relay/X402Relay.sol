// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title X402Relay
 * @notice Atomic fee-splitting relay for x402 HTTP payments.
 *
 * Splits each payment into provider net (99%) + platform fee (1%).
 * Same economic model as ACTPKernel: 1% fee, $0.05 minimum, 5% hard cap.
 *
 * Flow:
 *   1. Requester approves this contract for grossAmount
 *   2. Requester calls payWithFee(provider, grossAmount, serviceId)
 *   3. Contract transfers providerNet to provider, fee to feeRecipient
 *   4. Emits X402Payment event for audit trail
 */
contract X402Relay is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // State
    // ========================================================================

    IERC20 public immutable usdc;
    address public admin;
    address public pendingAdmin;
    address public feeRecipient;
    uint16 public platformFeeBps;

    // ========================================================================
    // Constants
    // ========================================================================

    uint256 public constant MAX_BPS = 10_000;
    uint16 public constant MAX_FEE_CAP = 500; // 5% hard cap (same as ACTPKernel)
    uint256 public constant MIN_FEE = 50_000; // $0.05 USDC (6 decimals)

    // ========================================================================
    // Events
    // ========================================================================

    event X402Payment(
        address indexed from,
        address indexed provider,
        uint256 providerAmount,
        uint256 fee,
        bytes32 serviceId
    );
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PlatformFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ========================================================================
    // Modifiers
    // ========================================================================

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    /**
     * @param _usdc USDC token address
     * @param _feeRecipient Treasury address for platform fees
     * @param _platformFeeBps Fee in basis points (100 = 1%)
     * @param _admin Admin address for parameter updates
     */
    constructor(
        address _usdc,
        address _feeRecipient,
        uint16 _platformFeeBps,
        address _admin
    ) {
        require(_usdc != address(0), "Zero USDC");
        require(_feeRecipient != address(0), "Zero feeRecipient");
        require(_admin != address(0), "Zero admin");
        require(_platformFeeBps <= MAX_FEE_CAP, "Fee exceeds cap");

        usdc = IERC20(_usdc);
        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
        admin = _admin;
    }

    // ========================================================================
    // Core
    // ========================================================================

    /**
     * @notice Execute x402 payment with automatic fee splitting.
     * @dev Requester must have approved this contract for grossAmount.
     *      Fee = max(grossAmount * platformFeeBps / MAX_BPS, MIN_FEE).
     *      Reverts if grossAmount < MIN_FEE (prevents dust payments).
     *
     * @param provider Recipient address
     * @param grossAmount Total USDC amount (6 decimals)
     * @param serviceId Optional service identifier for audit trail
     * @return fee The platform fee deducted
     */
    function payWithFee(
        address provider,
        uint256 grossAmount,
        bytes32 serviceId
    ) external nonReentrant returns (uint256 fee) {
        require(provider != address(0), "Zero provider");
        require(grossAmount >= MIN_FEE, "Amount below minimum");

        fee = _calculateFee(grossAmount);
        uint256 providerNet = grossAmount - fee;
        require(providerNet > 0, "Provider would receive nothing");

        // CEI: interactions last
        usdc.safeTransferFrom(msg.sender, provider, providerNet);
        if (fee > 0) {
            usdc.safeTransferFrom(msg.sender, feeRecipient, fee);
        }

        emit X402Payment(msg.sender, provider, providerNet, fee, serviceId);
    }

    // ========================================================================
    // Admin
    // ========================================================================

    /**
     * @notice Update fee recipient (treasury) address.
     */
    function setFeeRecipient(address _feeRecipient) external onlyAdmin {
        require(_feeRecipient != address(0), "Zero feeRecipient");
        address old = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(old, _feeRecipient);
    }

    /**
     * @notice Update platform fee basis points.
     */
    function setPlatformFeeBps(uint16 _platformFeeBps) external onlyAdmin {
        require(_platformFeeBps <= MAX_FEE_CAP, "Fee exceeds cap");
        uint16 old = platformFeeBps;
        platformFeeBps = _platformFeeBps;
        emit PlatformFeeBpsUpdated(old, _platformFeeBps);
    }

    /**
     * @notice Initiate two-step admin transfer. New admin must call acceptAdmin().
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    /**
     * @notice Accept admin transfer. Must be called by the pending admin.
     */
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "Not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        delete pendingAdmin;
        emit AdminTransferred(oldAdmin, admin);
    }

    // ========================================================================
    // View
    // ========================================================================

    /**
     * @notice Calculate fee for a given gross amount.
     * @dev fee = max(grossAmount * platformFeeBps / MAX_BPS, MIN_FEE)
     */
    function _calculateFee(uint256 grossAmount) internal view returns (uint256) {
        uint256 bpsFee = (grossAmount * platformFeeBps) / MAX_BPS;
        return bpsFee > MIN_FEE ? bpsFee : MIN_FEE;
    }

    /**
     * @notice Preview fee for a given gross amount (external view).
     * @dev Reverts if grossAmount < MIN_FEE (same guard as payWithFee).
     */
    function calculateFee(uint256 grossAmount) external view returns (uint256) {
        require(grossAmount >= MIN_FEE, "Amount below minimum");
        return _calculateFee(grossAmount);
    }
}
