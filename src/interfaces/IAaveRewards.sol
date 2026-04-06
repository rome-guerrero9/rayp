// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Aave v3 incentives controller interface.
interface IAaveRewards {
    function claimAllRewards(address[] calldata assets, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}
