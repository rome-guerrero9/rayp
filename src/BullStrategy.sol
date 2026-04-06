// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseStrategy.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IAaveRewards.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/AggregatorV3Interface.sol";

/**
 * @title  BullStrategy
 * @notice RAYP strategy for the BULL regime (regime 1).
 *         Creates a leveraged long ETH position via Aave v3:
 *         supply WETH, borrow USDC, swap USDC to WETH, re-supply.
 *         Uses flash loans for atomic entry/exit.
 *
 *         Integration: Aave v3 + Uniswap V3 + Chainlink (Arbitrum mainnet)
 */
contract BullStrategy is BaseStrategy {

    enum FlashLoanAction { DEPLOY, LIQUIDATE, LIQUIDATE_ALL }

    error StalePriceFeed();

    IAavePool              public immutable aavePool;
    IAaveRewards           public immutable aaveRewards;
    ISwapRouter            public immutable swapRouter;
    IERC20                 public immutable rewardToken;
    IERC20                 public immutable usdc;
    IERC20                 public immutable aWETH;
    IERC20                 public immutable debtUSDC;
    AggregatorV3Interface  public immutable priceFeed;
    uint24                 public immutable swapFeeTier;
    uint256                private immutable _targetLeverageBps;

    uint24  public constant  SWAP_FEE_TIER_HARVEST  = 3000;
    uint256 public constant  MIN_HEALTH_FACTOR      = 1.3e18;
    uint256 public constant  STALENESS_THRESHOLD    = 7200;
    uint256 public constant  SWAP_SLIPPAGE_BPS      = 50;
    uint256 public constant  FLASH_FEE_BUFFER_BPS   = 10;

    // Pre-computed scaling factors
    uint256 private immutable _usdcScale; // 10 ** 12 (18 - 6)
    uint256 private immutable _feedScale; // 10 ** (18 - feedDecimals)

    uint256 public totalDeposited;

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
        uint24  _swapFeeTier,
        uint256 targetLeverageBps_
    ) BaseStrategy(_asset, _vault, _guardian, 1) {
        aavePool           = IAavePool(_aavePool);
        aaveRewards        = IAaveRewards(_aaveRewards);
        swapRouter         = ISwapRouter(_swapRouter);
        rewardToken        = IERC20(_rewardToken);
        usdc               = IERC20(_usdc);
        priceFeed          = AggregatorV3Interface(_priceFeed);
        swapFeeTier        = _swapFeeTier;
        _targetLeverageBps = targetLeverageBps_;

        uint8 feedDec = AggregatorV3Interface(_priceFeed).decimals();
        _usdcScale = 10 ** 12;
        _feedScale = 10 ** (18 - feedDec);

        (,,,,,,,,address _aWETH,,,,,,) = IAavePool(_aavePool).getReserveData(_asset);
        aWETH = IERC20(_aWETH);

        (,,,,,,,,,,address _debtUSDC,,,,) = IAavePool(_aavePool).getReserveData(_usdc);
        debtUSDC = IERC20(_debtUSDC);

        IERC20(_asset).approve(_aavePool, type(uint256).max);
        IERC20(_asset).approve(_swapRouter, type(uint256).max);
        IERC20(_usdc).approve(_aavePool, type(uint256).max);
        IERC20(_usdc).approve(_swapRouter, type(uint256).max);
        IERC20(_rewardToken).approve(_swapRouter, type(uint256).max);
    }

    // ─── Metadata ─────────────────────────────────────────────────────────────

    function name() external pure override returns (string memory) {
        return "RAYP Bull: Aave Leveraged WETH";
    }

    function targetLeverage() external view override returns (uint256) {
        return _targetLeverageBps;
    }

    function estimatedWithdrawalSlippageBps() external pure override returns (uint256) {
        return 100;
    }

    // ─── Accounting ───────────────────────────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
        uint256 supplyWeth = aWETH.balanceOf(address(this));
        if (supplyWeth == 0) return 0;

        uint256 debtUsdc = debtUSDC.balanceOf(address(this));
        if (debtUsdc == 0) return supplyWeth;

        uint256 debtWeth = _usdcToWeth(debtUsdc);
        return supplyWeth > debtWeth ? supplyWeth - debtWeth : 0;
    }

    function accruedYield() external view override returns (uint256) {
        uint256 current = totalAssets();
        return current > totalDeposited ? current - totalDeposited : 0;
    }

    // ─── Deploy: leveraged entry via flash loan ───────────────────────────────

    function _deploy(uint256 assets) internal override returns (uint256 deployedTotal) {
        aavePool.supply(asset, assets, address(this), 0);
        aavePool.setUserUseReserveAsCollateral(asset, true);

        uint256 leverageMultiplier = _targetLeverageBps - 1e4;
        uint256 usdcToBorrow = (_wethToUsdc(assets) * leverageMultiplier) / 1e4;

        if (usdcToBorrow > 0) {
            bytes memory params = abi.encode(FlashLoanAction.DEPLOY, assets);
            aavePool.flashLoanSimple(address(this), address(usdc), usdcToBorrow, params, 0);
        }

        totalDeposited += assets;
        return totalAssets();
    }

    function _liquidate(uint256 assets) internal override returns (uint256 assetsOut) {
        uint256 supplyBal = aWETH.balanceOf(address(this));
        uint256 debtBal   = debtUSDC.balanceOf(address(this));

        if (debtBal == 0) {
            assetsOut = aavePool.withdraw(asset, assets, address(this));
            if (totalDeposited > assets) totalDeposited -= assets;
            else totalDeposited = 0;
            return assetsOut;
        }

        uint256 usdcToRepay = (debtBal * assets) / supplyBal;
        if (usdcToRepay == 0) usdcToRepay = 1;

        bytes memory params = abi.encode(FlashLoanAction.LIQUIDATE, assets);
        uint256 wethBefore = IERC20(asset).balanceOf(address(this));
        aavePool.flashLoanSimple(address(this), address(usdc), usdcToRepay, params, 0);
        assetsOut = IERC20(asset).balanceOf(address(this)) - wethBefore;

        if (totalDeposited > assets) totalDeposited -= assets;
        else totalDeposited = 0;
    }

    function _liquidateAll() internal override returns (uint256 assetsOut) {
        uint256 debtBal = debtUSDC.balanceOf(address(this));

        if (debtBal == 0) {
            uint256 supplyBal = aWETH.balanceOf(address(this));
            if (supplyBal == 0) return 0;
            assetsOut = aavePool.withdraw(asset, type(uint256).max, address(this));
            totalDeposited = 0;
            return assetsOut;
        }

        uint256 flashAmount = (debtBal * (10000 + FLASH_FEE_BUFFER_BPS)) / 10000;

        bytes memory params = abi.encode(FlashLoanAction.LIQUIDATE_ALL, uint256(0));
        uint256 wethBefore = IERC20(asset).balanceOf(address(this));
        aavePool.flashLoanSimple(address(this), address(usdc), flashAmount, params, 0);
        assetsOut = IERC20(asset).balanceOf(address(this)) - wethBefore;

        totalDeposited = 0;
    }

    // ─── Flash loan callback ──────────────────────────────────────────────────

    function executeOperation(
        address,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(aavePool), "not pool");
        require(initiator == address(this), "not self");

        (FlashLoanAction action, uint256 extraData) = abi.decode(params, (FlashLoanAction, uint256));

        if (action == FlashLoanAction.DEPLOY) {
            return _flashDeploy(amount, premium);
        } else if (action == FlashLoanAction.LIQUIDATE) {
            return _flashLiquidate(amount, premium, extraData);
        } else {
            return _flashLiquidateAll(amount, premium);
        }
    }

    function _flashDeploy(uint256 usdcAmount, uint256 premium) internal returns (bool) {
        uint256 wethReceived = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(usdc),
            tokenOut:          asset,
            fee:               swapFeeTier,
            recipient:         address(this),
            amountIn:          usdcAmount,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));

        aavePool.supply(asset, wethReceived, address(this), 0);

        uint256 totalOwed = usdcAmount + premium;
        aavePool.borrow(address(usdc), totalOwed, 2, 0, address(this));

        return true;
    }

    function _flashLiquidate(uint256 usdcAmount, uint256 premium, uint256 wethToWithdraw) internal returns (bool) {
        aavePool.repay(address(usdc), usdcAmount, 2, address(this));
        aavePool.withdraw(asset, wethToWithdraw, address(this));

        uint256 totalOwed = usdcAmount + premium;
        uint256 wethNeeded = _usdcToWeth(totalOwed);
        wethNeeded = (wethNeeded * (10000 + SWAP_SLIPPAGE_BPS)) / 10000;

        swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           asset,
            tokenOut:          address(usdc),
            fee:               swapFeeTier,
            recipient:         address(this),
            amountIn:          wethNeeded,
            amountOutMinimum:  totalOwed,
            sqrtPriceLimitX96: 0
        }));

        return true;
    }

    function _flashLiquidateAll(uint256 usdcAmount, uint256 premium) internal returns (bool) {
        uint256 debtBal = debtUSDC.balanceOf(address(this));
        aavePool.repay(address(usdc), debtBal, 2, address(this));
        aavePool.withdraw(asset, type(uint256).max, address(this));

        uint256 totalOwed = usdcAmount + premium;
        uint256 wethNeeded = _usdcToWeth(totalOwed);
        wethNeeded = (wethNeeded * (10000 + SWAP_SLIPPAGE_BPS)) / 10000;

        swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           asset,
            tokenOut:          address(usdc),
            fee:               swapFeeTier,
            recipient:         address(this),
            amountIn:          wethNeeded,
            amountOutMinimum:  totalOwed,
            sqrtPriceLimitX96: 0
        }));

        return true;
    }

    // ─── Harvest ──────────────────────────────────────────────────────────────

    function _harvestRewards() internal override returns (uint256 yieldHarvested) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aWETH);
        tokens[1] = address(debtUSDC);

        (, uint256[] memory amounts) = aaveRewards.claimAllRewards(tokens, address(this));

        uint256 rewardAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            rewardAmount += amounts[i];
        }
        if (rewardAmount == 0) return 0;

        uint256 wethBefore = IERC20(asset).balanceOf(address(this));

        swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(rewardToken),
            tokenOut:          asset,
            fee:               SWAP_FEE_TIER_HARVEST,
            recipient:         address(this),
            amountIn:          rewardAmount,
            amountOutMinimum:  0,
            sqrtPriceLimitX96: 0
        }));

        uint256 wethGained = IERC20(asset).balanceOf(address(this)) - wethBefore;

        if (wethGained > 0) {
            aavePool.supply(asset, wethGained, address(this), 0);
            yieldHarvested = wethGained;
        }
    }

    // ─── Health check ─────────────────────────────────────────────────────────

    function _checkProtocolHealth()
        internal
        view
        override
        returns (bool healthy, string memory reason)
    {
        (uint256 configWeth,,,,,,,,,,,,,,) = aavePool.getReserveData(asset);
        if ((configWeth >> 60) & 1 == 1) return (false, "Aave WETH pool paused");

        (uint256 configUsdc,,,,,,,,,,,,,,) = aavePool.getReserveData(address(usdc));
        if ((configUsdc >> 60) & 1 == 1) return (false, "Aave USDC pool paused");

        if (debtUSDC.balanceOf(address(this)) > 0) {
            (,,,,,uint256 healthFactor) = aavePool.getUserAccountData(address(this));
            if (healthFactor < MIN_HEALTH_FACTOR) return (false, "health factor too low");
        }

        if (totalDeposited > 0 && aWETH.balanceOf(address(this)) == 0) {
            return (false, "aWETH balance unexpectedly zero");
        }

        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (price <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD) {
            return (false, "ETH/USD price feed stale");
        }

        return (true, "");
    }

    // ─── Price conversion — reverts on stale feed ─────────────────────────────

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
