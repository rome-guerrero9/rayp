// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseStrategy.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IAaveRewards.sol";
import "./interfaces/ISwapRouter.sol";

/**
 * @title  AaveMoneyMarketStrategy
 * @notice Shared base for strategies that simply supply the vault's asset to
 *         Aave v3 and earn lending yield. Used by both CrisisStrategy (regime 3)
 *         and NeutralStrategy (regime 0).
 *
 *         Concrete subclasses only override name().
 */
abstract contract AaveMoneyMarketStrategy is BaseStrategy {

    IAavePool     public immutable aavePool;
    IAaveRewards  public immutable aaveRewards;
    ISwapRouter   public immutable swapRouter;
    IERC20        public immutable aToken;
    IERC20        public immutable rewardToken;

    uint24  public constant SWAP_FEE_TIER   = 3000;
    uint256 public constant MIN_HARVEST_USD = 10e18;

    uint256 public totalDeposited;

    constructor(
        address _asset,
        address _vault,
        address _guardian,
        uint8   _targetRegime,
        address _aavePool,
        address _aaveRewards,
        address _swapRouter,
        address _rewardToken
    ) BaseStrategy(_asset, _vault, _guardian, _targetRegime) {
        aavePool     = IAavePool(_aavePool);
        aaveRewards  = IAaveRewards(_aaveRewards);
        swapRouter   = ISwapRouter(_swapRouter);
        rewardToken  = IERC20(_rewardToken);

        (,,,,,,,,address _aToken,,,,,,) = IAavePool(_aavePool).getReserveData(_asset);
        aToken = IERC20(_aToken);

        IERC20(_asset).approve(_aavePool, type(uint256).max);
        IERC20(_rewardToken).approve(_swapRouter, type(uint256).max);
    }

    function targetLeverage() external pure override returns (uint256) {
        return 1e4;
    }

    function estimatedWithdrawalSlippageBps() external pure override returns (uint256) {
        return 5;
    }

    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function accruedYield() external view override returns (uint256) {
        uint256 current = totalAssets();
        return current > totalDeposited ? current - totalDeposited : 0;
    }

    function _deploy(uint256 assets) internal override returns (uint256 deployedTotal) {
        aavePool.supply(asset, assets, address(this), 0);
        totalDeposited += assets;
        return totalAssets();
    }

    function _liquidate(uint256 assets) internal override returns (uint256 assetsOut) {
        assetsOut = aavePool.withdraw(asset, assets, address(this));
        // Fix: decrement totalDeposited proportionally to avoid false health failures
        if (totalDeposited > assets) {
            totalDeposited -= assets;
        } else {
            totalDeposited = 0;
        }
    }

    function _liquidateAll() internal override returns (uint256 assetsOut) {
        uint256 bal = aToken.balanceOf(address(this));
        if (bal == 0) return 0;
        assetsOut = aavePool.withdraw(asset, type(uint256).max, address(this));
        totalDeposited = 0;
    }

    function _harvestRewards() internal override returns (uint256 yieldHarvested) {
        address[] memory aTokens = new address[](1);
        aTokens[0] = address(aToken);

        (, uint256[] memory amounts) = aaveRewards.claimAllRewards(aTokens, address(this));

        uint256 rewardAmount = amounts.length > 0 ? amounts[0] : 0;
        if (rewardAmount < MIN_HARVEST_USD / 100) return 0;

        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));

        swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(rewardToken),
            tokenOut:          asset,
            fee:               SWAP_FEE_TIER,
            recipient:         address(this),
            amountIn:          rewardAmount,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));

        uint256 swappedAssets = IERC20(asset).balanceOf(address(this)) - assetsBefore;

        if (swappedAssets > 0) {
            aavePool.supply(asset, swappedAssets, address(this), 0);
            yieldHarvested = swappedAssets;
        }
    }

    function _checkProtocolHealth()
        internal
        view
        override
        returns (bool healthy, string memory reason)
    {
        (uint256 configuration,,,,,,,,,,,,,,) = aavePool.getReserveData(asset);
        bool poolPaused = (configuration >> 60) & 1 == 1;
        if (poolPaused) return (false, "Aave pool paused for asset");

        uint256 aBalance = aToken.balanceOf(address(this));
        if (totalDeposited > 0 && aBalance == 0) {
            return (false, "aToken balance unexpectedly zero");
        }

        if (totalDeposited > 0) {
            uint256 minExpected = (totalDeposited * 9900) / 10_000;
            if (aBalance < minExpected) {
                return (false, "aToken balance below 99% of deposited amount");
            }
        }

        return (true, "");
    }
}
