// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IStrategy.sol";
import "../src/BearStrategy.sol";

// ── Mock Chainlink price feed ────────────────────────────────────────────────

contract MockChainlinkFeed {
    int256  public price;
    uint8   public decimals_ = 8;
    uint256 public updatedAt;

    constructor(int256 _price) {
        price     = _price;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) { return decimals_; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (1, price, block.timestamp, updatedAt, 1);
    }

    function setPrice(int256 _price) external {
        price     = _price;
        updatedAt = block.timestamp;
    }

    function setStale() external {
        updatedAt = 0; // always stale relative to any block.timestamp > STALENESS_THRESHOLD
    }
}

// ── Extended mock ERC20 with configurable decimals ───────────────────────────

contract MockERC20 {
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

// ── Mock Aave pool for USDC ──────────────────────────────────────────────────

contract MockAavePoolBear {
    MockERC20 public usdc;
    MockERC20 public aUSDC;
    bool      public paused;

    constructor(address _usdc, address _aUSDC) {
        usdc  = MockERC20(_usdc);
        aUSDC = MockERC20(_aUSDC);
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        require(!paused, "pool paused");
        usdc.transferFrom(msg.sender, address(this), amount);
        aUSDC.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aUSDC.balanceOf(msg.sender);
        uint256 actual = amount == type(uint256).max ? bal : amount;
        aUSDC.burn(msg.sender, actual);
        usdc.transfer(to, actual);
        return actual;
    }

    function getReserveData(address) external view returns (
        uint256,uint128,uint128,uint128,uint128,uint128,
        uint40,uint16,address,address,address,address,uint128,uint128,uint128
    ) {
        uint256 config = paused ? (uint256(1) << 60) : 0;
        return (config,0,0,0,0,0,0,0,address(aUSDC),address(0),address(0),address(0),0,0,0);
    }

    function setPaused(bool _p) external { paused = _p; }
}

// ── Mock Aave rewards ────────────────────────────────────────────────────────

contract MockAaveRewardsBear {
    MockERC20 public rewardToken;
    uint256   public rewardPerClaim = 100e18;

    constructor(address _rewardToken) { rewardToken = MockERC20(_rewardToken); }

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

    function setRewardPerClaim(uint256 amount) external { rewardPerClaim = amount; }
}

// ── Bidirectional mock swap router ───────────────────────────────────────────

contract MockSwapRouterBear {
    // ETH price in USDC (6 decimals). e.g., 3000e6 means 1 WETH = 3000 USDC
    uint256 public ethPriceUsdc;
    MockERC20 public weth;
    MockERC20 public usdc;

    constructor(address _weth, address _usdc, uint256 _ethPriceUsdc) {
        weth = MockERC20(_weth);
        usdc = MockERC20(_usdc);
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
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        if (params.tokenIn == address(weth) && params.tokenOut == address(usdc)) {
            // WETH -> USDC: amountIn (18 dec) * ethPrice (6 dec) / 1e18
            amountOut = (params.amountIn * ethPriceUsdc) / 1e18;
            usdc.mint(params.recipient, amountOut);
        } else if (params.tokenIn == address(usdc) && params.tokenOut == address(weth)) {
            // USDC -> WETH: amountIn (6 dec) * 1e18 / ethPrice (6 dec)
            amountOut = (params.amountIn * 1e18) / ethPriceUsdc;
            weth.mint(params.recipient, amountOut);
        } else {
            // Reward token -> USDC: 1:1 for simplicity
            usdc.mint(params.recipient, params.amountIn);
            amountOut = params.amountIn;
        }
    }

    function setEthPrice(uint256 _price) external { ethPriceUsdc = _price; }
}

// ─────────────────────────────────────────────────────────────────────────────

contract BearStrategyTest is Test {

    BearStrategy       strategy;
    MockERC20          weth;
    MockERC20          usdc;
    MockERC20          aUSDC;
    MockERC20          arbToken;
    MockAavePoolBear   aavePool;
    MockAaveRewardsBear aaveRewards;
    MockSwapRouterBear swapRouter;
    MockChainlinkFeed  priceFeed;

    address vault    = address(0xAAAA);
    address guardian = address(0xBBBB);

    uint256 constant ETH_PRICE = 3000; // $3000
    uint256 constant DEPOSIT   = 10e18; // 10 WETH

    function setUp() public {
        weth     = new MockERC20("WETH", 18);
        usdc     = new MockERC20("USDC", 6);
        aUSDC    = new MockERC20("aUSDC", 6);
        arbToken = new MockERC20("ARB", 18);

        aavePool    = new MockAavePoolBear(address(usdc), address(aUSDC));
        aaveRewards = new MockAaveRewardsBear(address(arbToken));
        swapRouter  = new MockSwapRouterBear(address(weth), address(usdc), ETH_PRICE * 1e6);
        priceFeed   = new MockChainlinkFeed(int256(ETH_PRICE) * 1e8); // 8 decimal Chainlink

        // Fund Aave pool with USDC for withdrawals
        usdc.mint(address(aavePool), 100_000_000e6);

        strategy = new BearStrategy(
            address(weth),
            vault,
            guardian,
            address(aavePool),
            address(aaveRewards),
            address(swapRouter),
            address(arbToken),
            address(usdc),
            address(priceFeed),
            500 // 0.05% swap fee tier
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

    function test_Bear_TargetRegimeIsBear() public view {
        assertEq(strategy.targetRegime(), 2);
    }

    function test_Bear_NameIsCorrect() public view {
        assertEq(strategy.name(), "RAYP Bear: Aave USDC");
    }

    function test_Bear_TargetLeverageIs1x() public view {
        assertEq(strategy.targetLeverage(), 1e4);
    }

    function test_Bear_EstimatedSlippageIs50Bps() public view {
        assertEq(strategy.estimatedWithdrawalSlippageBps(), 50);
    }

    // ── Deposit: swaps WETH to USDC and supplies to Aave ────────────────────

    function test_Bear_DepositSwapsToUSDCAndSupplies() public {
        _deposit(DEPOSIT);

        // 10 WETH at $3000 = 30,000 USDC = 30_000e6
        uint256 expectedUsdc = (DEPOSIT * ETH_PRICE * 1e6) / 1e18;
        assertEq(aUSDC.balanceOf(address(strategy)), expectedUsdc, "aUSDC balance wrong");
        assertEq(strategy.totalDepositedUSDC(), expectedUsdc, "tracking wrong");
    }

    function test_Bear_TotalAssetsReturnsWethDenominated() public {
        _deposit(DEPOSIT);

        // totalAssets should be ~10 WETH (round-trip through oracle)
        uint256 ta = strategy.totalAssets();
        assertApproxEqRel(ta, DEPOSIT, 0.01e18, "totalAssets should be ~10 WETH");
    }

    function test_Bear_TotalAssetsUpdatesWithPriceChange() public {
        _deposit(DEPOSIT);

        // ETH price drops to $2000 - bear strategy preserves USDC value
        // so totalAssets in WETH terms should increase (same USDC, less ETH per USDC)
        priceFeed.setPrice(2000e8);
        uint256 ta = strategy.totalAssets();
        // 30000 USDC / 2000 = 15 WETH
        assertApproxEqRel(ta, 15e18, 0.01e18, "should be 15 WETH at $2000");
    }

    // ── Withdrawal ──────────────────────────────────────────────────────────

    function test_Bear_LiquidateSwapsBackToWeth() public {
        _deposit(DEPOSIT);

        address recipient = address(0xCC);
        vm.prank(vault);
        uint256 out = strategy.withdraw(5e18, recipient, 0);

        assertGt(out, 0, "should return WETH");
        assertGt(weth.balanceOf(recipient), 0, "recipient should have WETH");
    }

    function test_Bear_LiquidateAllEmptiesPosition() public {
        _deposit(DEPOSIT);

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);

        assertGt(out, 0, "should return WETH");
        assertEq(strategy.totalAssets(), 0, "INV-3: totalAssets must be 0");
        assertEq(aUSDC.balanceOf(address(strategy)), 0, "aUSDC should be 0");
        assertEq(strategy.totalDepositedUSDC(), 0, "tracking should be 0");
    }

    // ── Harvest ─────────────────────────────────────────────────────────────

    function test_Bear_HarvestCompoundsInUSDC() public {
        _deposit(DEPOSIT);
        uint256 aBalBefore = aUSDC.balanceOf(address(strategy));

        vm.prank(vault);
        strategy.harvestAndReport();

        // Rewards should have been swapped to USDC and re-supplied to Aave
        assertGt(aUSDC.balanceOf(address(strategy)), aBalBefore, "aUSDC should increase after harvest");
    }

    // ── Health check ────────────────────────────────────────────────────────

    function test_Bear_HealthCheckPasses() public {
        _deposit(DEPOSIT);
        (bool healthy, string memory reason) = strategy.healthCheck();
        assertTrue(healthy, reason);
    }

    function test_Bear_HealthCheckFailsOnPoolPaused() public {
        _deposit(DEPOSIT);
        aavePool.setPaused(true);

        (bool healthy, string memory reason) = strategy.healthCheck();
        assertFalse(healthy);
        assertEq(reason, "Aave USDC pool paused");
    }

    function test_Bear_HealthCheckFailsOnStalePriceFeed() public {
        _deposit(DEPOSIT);
        vm.warp(10_000); // warp AFTER deposit so feed is fresh during deposit
        priceFeed.setStale();

        // totalAssets() now reverts on stale feed; healthCheck catches it via try/catch
        (bool healthy, string memory reason) = strategy.healthCheck();
        assertFalse(healthy);
        assertEq(reason, "totalAssets() reverted");
    }

    function test_Bear_TotalAssetsRevertsOnStaleFeed() public {
        _deposit(DEPOSIT);
        vm.warp(10_000);
        priceFeed.setStale();

        vm.expectRevert(BearStrategy.StalePriceFeed.selector);
        strategy.totalAssets();
    }

    // ── Emergency ───────────────────────────────────────────────────────────

    function test_Bear_EmergencyExitUnwinds() public {
        _deposit(DEPOSIT);

        vm.prank(guardian);
        strategy.triggerEmergencyExit();

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);
        assertGt(out, 0, "should withdraw in emergency");
        assertEq(strategy.totalAssets(), 0, "INV-3 in emergency");
    }

    // ── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_Bear_AnyDepositWithdrawsClean(uint256 amount) public {
        vm.assume(amount >= 1e15 && amount <= 100e18);
        weth.mint(vault, amount);
        _deposit(amount);

        vm.prank(vault);
        strategy.withdrawAll(address(0xCC), 0);
        assertEq(strategy.totalAssets(), 0, "INV-3 violated");
    }
}
