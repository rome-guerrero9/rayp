// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseStrategy.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IAaveRewards.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/AggregatorV3Interface.sol";

/**
 * @title  BearStrategy
 * @notice RAYP strategy for the BEAR regime (regime 2).
 *         Swaps WETH to USDC, supplies USDC to Aave v3 for capital preservation.
 *         On exit, withdraws USDC from Aave and swaps back to WETH.
 *
 *         Integration: Aave v3 + Uniswap V3 + Chainlink (Arbitrum mainnet)
 */
contract BearStrategy is BaseStrategy {

    error StalePriceFeed();

    IAavePool              public immutable aavePool;
    IAaveRewards           public immutable aaveRewards;
    ISwapRouter            public immutable swapRouter;
    IERC20                 public immutable rewardToken;
    IERC20                 public immutable usdc;
    IERC20                 public immutable aUSDC;
    AggregatorV3Interface  public immutable priceFeed;
    uint24                 public immutable swapFeeTier;
    uint24                 public constant  SWAP_FEE_TIER_HARVEST = 3000;

    uint256 public constant MIN_HARVEST_USD      = 10e18;
    uint256 public constant STALENESS_THRESHOLD  = 7200;
    uint256 public constant SWAP_SLIPPAGE_BPS    = 50;   // 0.5% buffer
    uint256 public constant HEALTH_MIN_RATIO_BPS = 9900; // 99%

    // Pre-computed scaling factors (set in constructor, avoids runtime EXP)
    uint256 private immutable _usdcScale;  // 10 ** (18 - usdcDecimals)
    uint256 private immutable _feedScale;  // 10 ** (18 - feedDecimals)

    uint256 public totalDepositedUSDC;

    constructor(
        address _asset,
        address _vault,
        address _guardian,
        address _aavePool,
        address _aaveRewards,
        address _swapRouter,
        address _rewardToken,
        address _usdc,
        address _priceFeed,
        uint24  _swapFeeTier
    ) BaseStrategy(_asset, _vault, _guardian, 2) {
        aavePool     = IAavePool(_aavePool);
        aaveRewards  = IAaveRewards(_aaveRewards);
        swapRouter   = ISwapRouter(_swapRouter);
        rewardToken  = IERC20(_rewardToken);
        usdc         = IERC20(_usdc);
        priceFeed    = AggregatorV3Interface(_priceFeed);
        swapFeeTier  = _swapFeeTier;

        uint8 usdcDec = 6; // USDC on Arbitrum
        uint8 feedDec = AggregatorV3Interface(_priceFeed).decimals();
        _usdcScale = 10 ** (18 - usdcDec);
        _feedScale = 10 ** (18 - feedDec);

        (,,,,,,,,address _aUSDC,,,,,,) = IAavePool(_aavePool).getReserveData(_usdc);
        aUSDC = IERC20(_aUSDC);

        IERC20(_asset).approve(_swapRouter, type(uint256).max);
        IERC20(_usdc).approve(_aavePool, type(uint256).max);
        IERC20(_usdc).approve(_swapRouter, type(uint256).max);
        IERC20(_rewardToken).approve(_swapRouter, type(uint256).max);
    }

    function name() external pure override returns (string memory) {
        return "RAYP Bear: Aave USDC";
    }

    function targetLeverage() external pure override returns (uint256) {
        return 1e4;
    }

    function estimatedWithdrawalSlippageBps() external pure override returns (uint256) {
        return SWAP_SLIPPAGE_BPS;
    }

    // ─── Accounting ───────────────────────────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
        uint256 usdcBalance = aUSDC.balanceOf(address(this));
        if (usdcBalance == 0) return 0;
        return _usdcToWeth(usdcBalance);
    }

    function accruedYield() external view override returns (uint256) {
        uint256 usdcBalance = aUSDC.balanceOf(address(this));
        if (usdcBalance <= totalDepositedUSDC) return 0;
        // Single oracle read for both conversions
        return _usdcToWeth(usdcBalance - totalDepositedUSDC);
    }

    // ─── Core strategy functions ──────────────────────────────────────────────

    function _deploy(uint256 assets) internal override returns (uint256 deployedTotal) {
        uint256 usdcReceived = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           asset,
            tokenOut:          address(usdc),
            fee:               swapFeeTier,
            recipient:         address(this),
            amountIn:          assets,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));

        aavePool.supply(address(usdc), usdcReceived, address(this), 0);
        totalDepositedUSDC += usdcReceived;
        return totalAssets();
    }

    function _liquidate(uint256 assets) internal override returns (uint256 assetsOut) {
        uint256 usdcNeeded = _wethToUsdc(assets);
        usdcNeeded = (usdcNeeded * (10000 + SWAP_SLIPPAGE_BPS)) / 10000;

        uint256 aBalance = aUSDC.balanceOf(address(this));
        if (usdcNeeded > aBalance) usdcNeeded = aBalance;

        uint256 usdcWithdrawn = aavePool.withdraw(address(usdc), usdcNeeded, address(this));

        assetsOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(usdc),
            tokenOut:          asset,
            fee:               swapFeeTier,
            recipient:         address(this),
            amountIn:          usdcWithdrawn,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));

        totalDepositedUSDC = totalDepositedUSDC > usdcWithdrawn
            ? totalDepositedUSDC - usdcWithdrawn
            : 0;
    }

    function _liquidateAll() internal override returns (uint256 assetsOut) {
        uint256 aBalance = aUSDC.balanceOf(address(this));
        if (aBalance == 0) return 0;

        uint256 usdcWithdrawn = aavePool.withdraw(address(usdc), type(uint256).max, address(this));

        assetsOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(usdc),
            tokenOut:          asset,
            fee:               swapFeeTier,
            recipient:         address(this),
            amountIn:          usdcWithdrawn,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));

        totalDepositedUSDC = 0;
    }

    function _harvestRewards() internal override returns (uint256 yieldHarvested) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(aUSDC);

        (, uint256[] memory amounts) = aaveRewards.claimAllRewards(tokens, address(this));

        uint256 rewardAmount = amounts.length > 0 ? amounts[0] : 0;
        if (rewardAmount < MIN_HARVEST_USD / 100) return 0;

        uint256 usdcBefore = usdc.balanceOf(address(this));

        swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(rewardToken),
            tokenOut:          address(usdc),
            fee:               SWAP_FEE_TIER_HARVEST,
            recipient:         address(this),
            amountIn:          rewardAmount,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));

        uint256 usdcGained = usdc.balanceOf(address(this)) - usdcBefore;

        if (usdcGained > 0) {
            aavePool.supply(address(usdc), usdcGained, address(this), 0);
            yieldHarvested = _usdcToWeth(usdcGained);
        }
    }

    function _checkProtocolHealth()
        internal
        view
        override
        returns (bool healthy, string memory reason)
    {
        (uint256 configuration,,,,,,,,,,,,,,) = aavePool.getReserveData(address(usdc));
        if ((configuration >> 60) & 1 == 1) return (false, "Aave USDC pool paused");

        uint256 aBalance = aUSDC.balanceOf(address(this));
        if (totalDepositedUSDC > 0 && aBalance == 0) {
            return (false, "aUSDC balance unexpectedly zero");
        }

        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (price <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD) {
            return (false, "ETH/USD price feed stale or invalid");
        }

        if (totalDepositedUSDC > 0) {
            uint256 minExpected = (totalDepositedUSDC * HEALTH_MIN_RATIO_BPS) / 10_000;
            if (aBalance < minExpected) {
                return (false, "aUSDC balance below 99% of deposited");
            }
        }

        return (true, "");
    }

    // ─── Price conversion — reverts on stale feed instead of returning 0 ──────

    function _getEthPrice18() internal view returns (uint256) {
        (, int256 ethPrice,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (ethPrice <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD) {
            revert StalePriceFeed();
        }
        return uint256(ethPrice) * _feedScale;
    }

    function _usdcToWeth(uint256 usdcAmount) internal view returns (uint256) {
        if (usdcAmount == 0) return 0;
        uint256 ethPrice18 = _getEthPrice18();
        uint256 usdValue18 = usdcAmount * _usdcScale;
        return (usdValue18 * 1e18) / ethPrice18;
    }

    function _wethToUsdc(uint256 wethAmount) internal view returns (uint256) {
        if (wethAmount == 0) return 0;
        uint256 ethPrice18 = _getEthPrice18();
        uint256 usdValue18 = (wethAmount * ethPrice18) / 1e18;
        return usdValue18 / _usdcScale;
    }
}
