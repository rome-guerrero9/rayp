// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IStrategy.sol";
import "../src/BullStrategy.sol";

// Reuse MockChainlinkFeed from BearStrategy test
import {MockChainlinkFeed} from "./BearStrategy.t.sol";

// ── Mock ERC20 ───────────────────────────────────────────────────────────────

contract MockERC20Bull {
    string  public name;
    uint8   public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, uint8 _decimals) {
        name = _name;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply     -= amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }
}

// ── Mock Aave Pool with flash loan, borrow, repay ────────────────────────────

interface IFlashLoanReceiver {
    function executeOperation(
        address asset, uint256 amount, uint256 premium,
        address initiator, bytes calldata params
    ) external returns (bool);
}

contract MockAavePoolBull {
    MockERC20Bull public weth;
    MockERC20Bull public usdc;
    MockERC20Bull public aWETH;
    MockERC20Bull public debtUSDC;
    bool          public paused;

    // Simulated health factor (18 decimals)
    uint256 public healthFactor = 2e18; // healthy by default

    constructor(address _weth, address _usdc, address _aWETH, address _debtUSDC) {
        weth     = MockERC20Bull(_weth);
        usdc     = MockERC20Bull(_usdc);
        aWETH    = MockERC20Bull(_aWETH);
        debtUSDC = MockERC20Bull(_debtUSDC);
    }

    function supply(address asset_, uint256 amount, address onBehalfOf, uint16) external {
        require(!paused, "pool paused");
        MockERC20Bull(asset_).transferFrom(msg.sender, address(this), amount);
        if (asset_ == address(weth)) {
            aWETH.mint(onBehalfOf, amount);
        }
    }

    function withdraw(address asset_, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aWETH.balanceOf(msg.sender);
        uint256 actual = amount == type(uint256).max ? bal : amount;
        aWETH.burn(msg.sender, actual);
        weth.transfer(to, actual);
        return actual;
    }

    function borrow(address asset_, uint256 amount, uint256, uint16, address onBehalfOf) external {
        require(!paused, "pool paused");
        // Mint USDC to borrower (simulate borrowing)
        usdc.mint(msg.sender, amount);
        // Track debt
        debtUSDC.mint(onBehalfOf, amount);
    }

    function repay(address, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        uint256 debtBal = debtUSDC.balanceOf(onBehalfOf);
        uint256 actual  = amount > debtBal ? debtBal : amount;
        usdc.transferFrom(msg.sender, address(this), actual);
        debtUSDC.burn(onBehalfOf, actual);
        return actual;
    }

    function setUserUseReserveAsCollateral(address, bool) external {}

    function flashLoanSimple(
        address receiverAddress,
        address asset_,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        // Transfer flash loan amount to receiver
        MockERC20Bull(asset_).mint(receiverAddress, amount);

        // Premium = 0.05% (Aave v3 default)
        uint256 premium = (amount * 5) / 10000;

        // Call executeOperation on receiver
        IFlashLoanReceiver(receiverAddress).executeOperation(
            asset_, amount, premium, receiverAddress, params
        );

        // Pull back amount + premium
        MockERC20Bull(asset_).transferFrom(receiverAddress, address(this), amount + premium);
    }

    function getUserAccountData(address) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        return (0, 0, 0, 0, 0, healthFactor);
    }

    function getReserveData(address asset_) external view returns (
        uint256,uint128,uint128,uint128,uint128,uint128,
        uint40,uint16,address,address,address,address,uint128,uint128,uint128
    ) {
        uint256 config = paused ? (uint256(1) << 60) : 0;
        if (asset_ == address(weth)) {
            return (config,0,0,0,0,0,0,0,address(aWETH),address(0),address(debtUSDC),address(0),0,0,0);
        } else {
            // USDC reserve: variableDebtToken is at index 10
            return (config,0,0,0,0,0,0,0,address(0),address(0),address(debtUSDC),address(0),0,0,0);
        }
    }

    function setPaused(bool _p) external { paused = _p; }
    function setHealthFactor(uint256 _hf) external { healthFactor = _hf; }
}

// ── Mock Aave Rewards ────────────────────────────────────────────────────────

contract MockAaveRewardsBull {
    MockERC20Bull public rewardToken;
    uint256 public rewardPerClaim = 50e18;

    constructor(address _rewardToken) { rewardToken = MockERC20Bull(_rewardToken); }

    function claimAllRewards(address[] calldata, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
    {
        rewardToken.mint(to, rewardPerClaim);
        rewardsList    = new address[](1);
        rewardsList[0] = address(rewardToken);
        claimedAmounts = new uint256[](1);
        claimedAmounts[0] = rewardPerClaim;
    }
}

// ── Bidirectional mock swap router ───────────────────────────────────────────

contract MockSwapRouterBull {
    uint256 public ethPriceUsdc; // e.g., 3000e6
    MockERC20Bull public weth;
    MockERC20Bull public usdc;

    constructor(address _weth, address _usdc, uint256 _ethPriceUsdc) {
        weth = MockERC20Bull(_weth);
        usdc = MockERC20Bull(_usdc);
        ethPriceUsdc = _ethPriceUsdc;
    }

    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee;
        address recipient; uint256 amountIn;
        uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        MockERC20Bull(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        if (params.tokenIn == address(usdc) && params.tokenOut == address(weth)) {
            amountOut = (params.amountIn * 1e18) / ethPriceUsdc;
            weth.mint(params.recipient, amountOut);
        } else if (params.tokenIn == address(weth) && params.tokenOut == address(usdc)) {
            amountOut = (params.amountIn * ethPriceUsdc) / 1e18;
            usdc.mint(params.recipient, amountOut);
        } else {
            // Reward -> WETH: 1:1 for simplicity
            weth.mint(params.recipient, params.amountIn);
            amountOut = params.amountIn;
        }

        require(amountOut >= params.amountOutMinimum, "slippage");
    }
}

// ─────────────────────────────────────────────────────────────────────────────

contract BullStrategyTest is Test {

    BullStrategy       strategy;
    MockERC20Bull      weth;
    MockERC20Bull      usdc;
    MockERC20Bull      aWETH;
    MockERC20Bull      debtUSDC;
    MockERC20Bull      arbToken;
    MockAavePoolBull   aavePool;
    MockAaveRewardsBull aaveRewards;
    MockSwapRouterBull swapRouter;
    MockChainlinkFeed  priceFeed;

    address vault    = address(0xAAAA);
    address guardian = address(0xBBBB);

    uint256 constant ETH_PRICE = 3000;
    uint256 constant DEPOSIT   = 10e18;

    function setUp() public {
        weth     = new MockERC20Bull("WETH", 18);
        usdc     = new MockERC20Bull("USDC", 6);
        aWETH    = new MockERC20Bull("aWETH", 18);
        debtUSDC = new MockERC20Bull("debtUSDC", 6);
        arbToken = new MockERC20Bull("ARB", 18);

        aavePool    = new MockAavePoolBull(address(weth), address(usdc), address(aWETH), address(debtUSDC));
        aaveRewards = new MockAaveRewardsBull(address(arbToken));
        swapRouter  = new MockSwapRouterBull(address(weth), address(usdc), ETH_PRICE * 1e6);
        priceFeed   = new MockChainlinkFeed(int256(ETH_PRICE) * 1e8);

        // Fund the aave pool with WETH for withdrawals
        weth.mint(address(aavePool), 100_000e18);

        strategy = new BullStrategy(
            address(weth),
            vault,
            guardian,
            address(aavePool),
            address(aaveRewards),
            address(swapRouter),
            address(arbToken),
            address(usdc),
            address(priceFeed),
            500, // swap fee tier
            20000 // 2x leverage
        );

        weth.mint(vault, 1000e18);
        vm.prank(vault);
        weth.approve(address(strategy), type(uint256).max);
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(vault);
        weth.transfer(address(strategy), amount);
        strategy.deposit(amount, 0);
        vm.stopPrank();
    }

    // ── Metadata ────────────────────────────────────────────────────────────

    function test_Bull_TargetRegimeIsBull() public view {
        assertEq(strategy.targetRegime(), 1);
    }

    function test_Bull_NameIsCorrect() public view {
        assertEq(strategy.name(), "RAYP Bull: Aave Leveraged WETH");
    }

    function test_Bull_TargetLeverageIs2x() public view {
        assertEq(strategy.targetLeverage(), 20000);
    }

    function test_Bull_EstimatedSlippageIs100Bps() public view {
        assertEq(strategy.estimatedWithdrawalSlippageBps(), 100);
    }

    // ── Deploy: creates leveraged position ──────────────────────────────────

    function test_Bull_DeployCreatesLeveragedPosition() public {
        _deposit(DEPOSIT);

        // At 2x leverage: ~20 WETH supplied, ~30000 USDC debt (10 WETH worth)
        uint256 aWethBal = aWETH.balanceOf(address(strategy));
        uint256 debtBal  = debtUSDC.balanceOf(address(strategy));

        assertGt(aWethBal, DEPOSIT, "aWETH should be > deposit (leveraged)");
        assertGt(debtBal, 0, "should have USDC debt");
    }

    function test_Bull_TotalAssetsEqualsSupplyMinusDebt() public {
        _deposit(DEPOSIT);

        uint256 ta = strategy.totalAssets();
        // totalAssets should be close to initial deposit (supply - debt in WETH terms)
        // Not exact due to flash loan premium
        assertApproxEqRel(ta, DEPOSIT, 0.05e18, "totalAssets should be ~deposit");
    }

    // ── Partial liquidation ─────────────────────────────────────────────────

    function test_Bull_LiquidatePartiallyUnwinds() public {
        _deposit(DEPOSIT);

        uint256 taBefore = strategy.totalAssets();
        address recipient = address(0xCC);

        vm.prank(vault);
        uint256 out = strategy.withdraw(3e18, recipient, 0);

        assertGt(out, 0, "should return WETH");
        assertGt(weth.balanceOf(recipient), 0, "recipient should have WETH");
        assertLt(strategy.totalAssets(), taBefore, "totalAssets should decrease");
    }

    // ── Full liquidation (INV-3) ────────────────────────────────────────────

    function test_Bull_LiquidateAllFullyUnwinds() public {
        _deposit(DEPOSIT);

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);

        assertGt(out, 0, "should return WETH");
        assertEq(strategy.totalAssets(), 0, "INV-3: totalAssets must be 0");
        assertEq(aWETH.balanceOf(address(strategy)), 0, "aWETH should be 0");
        assertEq(debtUSDC.balanceOf(address(strategy)), 0, "debt should be 0");
        assertEq(strategy.totalDeposited(), 0, "tracking should be 0");
    }

    // ── Flash loan callback security ────────────────────────────────────────

    function test_Bull_FlashLoanCallbackRejectsExternalCaller() public {
        vm.expectRevert("not pool");
        strategy.executeOperation(
            address(usdc), 1000e6, 5e6, address(strategy),
            abi.encode(BullStrategy.FlashLoanAction.DEPLOY, uint256(10e18))
        );
    }

    function test_Bull_FlashLoanCallbackRejectsWrongInitiator() public {
        vm.prank(address(aavePool));
        vm.expectRevert("not self");
        strategy.executeOperation(
            address(usdc), 1000e6, 5e6, address(0xDEAD),
            abi.encode(BullStrategy.FlashLoanAction.DEPLOY, uint256(10e18))
        );
    }

    // ── Health check ────────────────────────────────────────────────────────

    function test_Bull_HealthCheckPasses() public {
        _deposit(DEPOSIT);
        (bool healthy, string memory reason) = strategy.healthCheck();
        assertTrue(healthy, reason);
    }

    function test_Bull_HealthCheckFailsOnLowHealthFactor() public {
        _deposit(DEPOSIT);
        aavePool.setHealthFactor(1.1e18); // below MIN_HEALTH_FACTOR of 1.3e18

        (bool healthy, string memory reason) = strategy.healthCheck();
        assertFalse(healthy);
        assertEq(reason, "health factor too low");
    }

    function test_Bull_HealthCheckFailsOnPoolPaused() public {
        _deposit(DEPOSIT);
        aavePool.setPaused(true);

        (bool healthy, string memory reason) = strategy.healthCheck();
        assertFalse(healthy);
        assertEq(reason, "Aave WETH pool paused");
    }

    function test_Bull_HealthCheckFailsOnStalePriceFeed() public {
        _deposit(DEPOSIT);
        vm.warp(10_000);
        priceFeed.setStale();

        // totalAssets() now reverts on stale feed; healthCheck catches it via try/catch
        (bool healthy, string memory reason) = strategy.healthCheck();
        assertFalse(healthy);
        assertEq(reason, "totalAssets() reverted");
    }

    // ── Harvest ─────────────────────────────────────────────────────────────

    function test_Bull_HarvestAddsSupply() public {
        _deposit(DEPOSIT);
        uint256 aWethBefore = aWETH.balanceOf(address(strategy));

        vm.prank(vault);
        strategy.harvestAndReport();

        assertGt(aWETH.balanceOf(address(strategy)), aWethBefore, "harvest should add supply");
    }

    // ── Emergency ───────────────────────────────────────────────────────────

    function test_Bull_EmergencyExitUnwindsLeverage() public {
        _deposit(DEPOSIT);

        vm.prank(guardian);
        strategy.triggerEmergencyExit();

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);
        assertGt(out, 0, "should unwind in emergency");
        assertEq(strategy.totalAssets(), 0, "INV-3 in emergency");
    }
}
