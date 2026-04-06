// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AaveMoneyMarketStrategy.sol";

/**
 * @title  NeutralStrategy
 * @notice RAYP strategy for the NEUTRAL regime (regime 0).
 *         Supplies WETH to Aave v3 for moderate, low-risk lending yield.
 *         Default strategy for ranging or uncertain markets.
 */
contract NeutralStrategy is AaveMoneyMarketStrategy {
    constructor(
        address _asset,
        address _vault,
        address _guardian,
        address _aavePool,
        address _aaveRewards,
        address _swapRouter,
        address _rewardToken
    ) AaveMoneyMarketStrategy(_asset, _vault, _guardian, 0, _aavePool, _aaveRewards, _swapRouter, _rewardToken) {}

    function name() external pure override returns (string memory) {
        return "RAYP Neutral: Aave WETH";
    }
}
