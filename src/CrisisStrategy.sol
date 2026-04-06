// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AaveMoneyMarketStrategy.sol";

/**
 * @title  CrisisStrategy
 * @notice RAYP strategy for the CRISIS regime (regime 3).
 *         Supplies WETH to Aave v3 as a safe harbor during market crises.
 *         Zero directional exposure, instant liquidity, capital preservation first.
 */
contract CrisisStrategy is AaveMoneyMarketStrategy {
    constructor(
        address _asset,
        address _vault,
        address _guardian,
        address _aavePool,
        address _aaveRewards,
        address _swapRouter,
        address _rewardToken
    ) AaveMoneyMarketStrategy(_asset, _vault, _guardian, 3, _aavePool, _aaveRewards, _swapRouter, _rewardToken) {}

    function name() external pure override returns (string memory) {
        return "RAYP Crisis Strategy - Aave v3 money market";
    }
}
