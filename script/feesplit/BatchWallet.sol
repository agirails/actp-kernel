// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title BatchWallet — minimal stand-in for a smart wallet: its owner sends any batch of calls in
///        one transaction. Local acceptance self-tests only (never deployed to a public network).
/// @dev Only the requester can link an escrow, so a contract requester is what lets one transaction
///      hold a donation and a link, or a settlement and a credit withdrawal.
contract BatchWallet {
    struct Call {
        address target;
        bytes data;
    }

    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function execute(Call[] calldata calls) external returns (bytes[] memory results) {
        require(msg.sender == owner, "Only owner");
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory result) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }
}
