// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

interface IEscrowValidator {
    function createEscrow(bytes32 escrowId, address requester, address provider, uint256 amount) external;

    function verifyEscrow(
        bytes32 escrowId,
        address requester,
        address provider,
        uint256 amount
    ) external view returns (bool isActive, uint256 escrowAmount);

    function payoutToProvider(bytes32 escrowId, uint256 amount) external returns (uint256 amountReleased);

    function refundToRequester(bytes32 escrowId, uint256 amount) external returns (uint256 amountReleased);

    function payout(bytes32 escrowId, address recipient, uint256 amount) external returns (uint256 amountReleased);

    function remaining(bytes32 escrowId) external view returns (uint256);
}
