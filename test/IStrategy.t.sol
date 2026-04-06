// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/IStrategy.sol";
import "../src/BaseStrategy.sol";
import "../src/CrisisStrategy.sol";

/**
 * @title  IStrategyTest
 * @notice Two-layer test suite:
 *
 *         Layer 1 — Interface compliance (StrategyInvariantTest)
 *         ────────────────────────────────────────────────────────
 *         Tests every IStrategy invariant against a MockStrategy that is
 *         deliberately minimal. Any concrete strategy that passes all vault
 *         interactions must satisfy these invariants. Run this suite against
 *         any new strategy to verify compliance before deployment.
 *
 *         Layer 2 — CrisisStrategy integration (CrisisStrategyTest)
 *         ────────────────────────────────────────────────────────────
 *         Tests the concrete Aave v3 integration with mock protocol contracts.
 *         Covers deposit, partial withdraw, full exit, harvest, and all
 *         health check failure modes.
 *
 * Run:    forge test --match-contract IStrategyTest -vvv
 *         forge test --match-contract CrisisStrategyTest -vvv
 */

// ── Minimal ERC-20 mock ───────────────────────────────────────────────────────

contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name) { name = _name; symbol = _name; }

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

// ── Mock Aave pool ────────────────────────────────────────────────────────────

contract MockAavePool {
    MockERC20 public asset;
    MockERC20 public aToken;
    bool      public paused;

    constructor(address _asset, address _aToken) {
        asset  = MockERC20(_asset);
        aToken = MockERC20(_aToken);
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        require(!paused, "pool paused");
        asset.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 actual = amount == type(uint256).max ? bal : amount;
        aToken.burn(msg.sender, actual);
        asset.transfer(to, actual);
        return actual;
    }

    function getReserveData(address) external view returns (
        uint256,uint128,uint128,uint128,uint128,uint128,
        uint40,uint16,address,address,address,address,uint128,uint128,uint128
    ) {
        uint256 config = paused ? (uint256(1) << 60) : 0;
        return (config,0,0,0,0,0,0,0,address(aToken),address(0),address(0),address(0),0,0,0);
    }

    function setPaused(bool _p) external { paused = _p; }
}

// ── Mock Aave rewards ─────────────────────────────────────────────────────────

contract MockAaveRewards {
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

// ── Mock swap router ──────────────────────────────────────────────────────────

contract MockSwapRouter {
    MockERC20 public outputToken;
    uint256   public outputPerInput = 1e18; // 1:1 by default

    constructor(address _outputToken) { outputToken = MockERC20(_outputToken); }

    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee;
        address recipient; uint256 amountIn;
        uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // Burn input (transfer from caller is already approved)
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * outputPerInput) / 1e18;
        outputToken.mint(params.recipient, amountOut);
    }

    function setOutputPerInput(uint256 ratio) external { outputPerInput = ratio; }
}

// ── Minimal mock strategy for invariant tests ─────────────────────────────────

contract MockStrategy is BaseStrategy {
    uint256 private _deployed;
    bool    public  forceHealthFail;
    string  public  healthFailReason;

    constructor(address _asset, address _vault, address _guardian)
        BaseStrategy(_asset, _vault, _guardian, 3) {}

    function name() external pure override returns (string memory) {
        return "Mock Strategy";
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + _deployed;
    }

    function _deploy(uint256 assets) internal override returns (uint256) {
        _deployed += assets;
        return totalAssets();
    }

    function _liquidate(uint256 assets) internal override returns (uint256) {
        uint256 actual = assets > _deployed ? _deployed : assets;
        _deployed -= actual;
        MockERC20(asset).mint(address(this), actual); // simulate protocol return
        return actual;
    }

    function _liquidateAll() internal override returns (uint256 assetsOut) {
        assetsOut = _deployed;
        if (_deployed > 0) {
            MockERC20(asset).mint(address(this), _deployed);
            _deployed = 0;
        }
    }

    function _harvestRewards() internal override returns (uint256) {
        MockERC20(asset).mint(address(this), 1e18); // 1 token yield
        _deployed += 1e18;
        return 1e18;
    }

    function _checkProtocolHealth()
        internal
        view
        override
        returns (bool healthy, string memory reason)
    {
        if (forceHealthFail) return (false, healthFailReason);
        return (true, "");
    }

    function setHealthFail(bool fail, string calldata reason) external {
        forceHealthFail = fail;
        healthFailReason = reason;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Layer 1: Interface invariant tests (run against any strategy)
// ═════════════════════════════════════════════════════════════════════════════

contract StrategyInvariantTest is Test {

    MockStrategy strategy;
    MockERC20    token;

    address vault    = address(0xAAAA);
    address guardian = address(0xBBBB);

    uint256 constant DEPOSIT = 100e18;

    function setUp() public {
        token    = new MockERC20("WETH");
        strategy = new MockStrategy(address(token), vault, guardian);
        token.mint(vault, 1000e18);
    }

    function _vaultDeposit(uint256 amount) internal {
        vm.startPrank(vault);
        token.transfer(address(strategy), amount);
        strategy.deposit(amount, 0);
        vm.stopPrank();
    }

    // ── INV-1: totalAssets() non-decreasing in normal operation ─────────────

    function test_INV1_TotalAssetsNonDecreasingOnDeposit() public {
        uint256 before = strategy.totalAssets();
        _vaultDeposit(DEPOSIT);
        assertGe(strategy.totalAssets(), before, "INV-1: totalAssets decreased on deposit");
    }

    // ── INV-2: withdraw() delivers exactly assetsOut in same tx ─────────────

    function test_INV2_WithdrawDeliversExactAmount() public {
        _vaultDeposit(DEPOSIT);

        address recipient = address(0xCC);
        uint256 balBefore = token.balanceOf(recipient);

        vm.prank(vault);
        uint256 assetsOut = strategy.withdraw(50e18, recipient, 0);

        uint256 delivered = token.balanceOf(recipient) - balBefore;
        assertEq(delivered, assetsOut, "INV-2: delivered != reported assetsOut");
        assertGt(assetsOut, 0, "INV-2: zero delivery");
    }

    // ── INV-3: withdrawAll() empties strategy ────────────────────────────────

    function test_INV3_WithdrawAllLeavesZeroAssets() public {
        _vaultDeposit(DEPOSIT);

        vm.prank(vault);
        strategy.withdrawAll(address(0xCC), 0);

        assertEq(strategy.totalAssets(), 0, "INV-3: totalAssets() != 0 after withdrawAll()");
    }

    // ── INV-4: EMERGENCY_EXIT rejects deposit, accepts withdrawAll ───────────

    function test_INV4_EmergencyExitRejectsDepositAcceptsWithdraw() public {
        _vaultDeposit(DEPOSIT);

        vm.prank(guardian);
        strategy.triggerEmergencyExit();

        assertEq(uint8(strategy.state()), uint8(IStrategy.StrategyState.EMERGENCY_EXIT));

        // deposit must revert
        vm.startPrank(vault);
        token.transfer(address(strategy), 10e18);
        vm.expectRevert();
        strategy.deposit(10e18, 0);
        vm.stopPrank();

        // withdrawAll must succeed
        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);
        assertGt(out, 0, "INV-4: withdrawAll returned 0 in emergency exit");
    }

    // ── INV-5: harvestAndReport() never reverts ──────────────────────────────

    function test_INV5_HarvestNeverReverts() public {
        // Even with nothing deposited, harvest should not revert
        vm.prank(vault);
        uint256 assets = strategy.harvestAndReport();
        // Returns 0 or more — just must not revert
        assertGe(assets, 0);
    }

    function test_INV5_HarvestNeverRevertsWithAssets() public {
        _vaultDeposit(DEPOSIT);
        vm.prank(vault);
        uint256 assets = strategy.harvestAndReport();
        assertGt(assets, 0, "should report assets after harvest");
    }

    // ── Access control: only vault can call privileged functions ─────────────

    function test_OnlyVaultCanDeposit() public {
        vm.expectRevert();
        vm.prank(address(0xDEAD));
        strategy.deposit(100e18, 0);
    }

    function test_OnlyVaultCanWithdraw() public {
        _vaultDeposit(DEPOSIT);
        vm.expectRevert();
        vm.prank(address(0xDEAD));
        strategy.withdraw(50e18, address(0xCC), 0);
    }

    function test_OnlyVaultCanWithdrawAll() public {
        _vaultDeposit(DEPOSIT);
        vm.expectRevert();
        vm.prank(address(0xDEAD));
        strategy.withdrawAll(address(0xCC), 0);
    }

    function test_OnlyVaultCanHarvest() public {
        vm.expectRevert();
        vm.prank(address(0xDEAD));
        strategy.harvestAndReport();
    }

    function test_OnlyGuardianCanTriggerEmergencyExit() public {
        vm.expectRevert();
        vm.prank(vault);
        strategy.triggerEmergencyExit();

        vm.prank(guardian);
        strategy.triggerEmergencyExit();
        assertEq(uint8(strategy.state()), uint8(IStrategy.StrategyState.EMERGENCY_EXIT));
    }

    function test_OnlyGuardianCanWindDown() public {
        vm.expectRevert();
        vm.prank(vault);
        strategy.windDown();

        vm.prank(guardian);
        strategy.windDown();
        assertEq(uint8(strategy.state()), uint8(IStrategy.StrategyState.WIND_DOWN));
    }

    // ── Slippage protection ──────────────────────────────────────────────────

    function test_DepositRevertsIfBelowMinDeployedOut() public {
        vm.prank(vault);
        token.transfer(address(strategy), DEPOSIT);
        vm.prank(vault);
        vm.expectRevert();
        strategy.deposit(DEPOSIT, DEPOSIT * 2); // impossible minimum
    }

    function test_WithdrawRevertsIfBelowMinAssetsOut() public {
        _vaultDeposit(DEPOSIT);
        vm.prank(vault);
        vm.expectRevert();
        strategy.withdraw(50e18, address(0xCC), 50e18 * 2); // impossible minimum
    }

    // ── Health check auto-emergency ──────────────────────────────────────────

    function test_HealthCheckAutoTriggersEmergencyAfterTwoFailures() public {
        strategy.setHealthFail(true, "test failure");

        strategy.healthCheck(); // failure 1
        assertEq(uint8(strategy.state()), uint8(IStrategy.StrategyState.ACTIVE));

        strategy.healthCheck(); // failure 2 — auto-emergency
        assertEq(uint8(strategy.state()), uint8(IStrategy.StrategyState.EMERGENCY_EXIT),
            "should auto-trigger emergency after 2 consecutive failures");
    }

    function test_HealthCheckResetsCounterOnSuccess() public {
        strategy.setHealthFail(true, "test");
        strategy.healthCheck(); // failure 1

        strategy.setHealthFail(false, "");
        strategy.healthCheck(); // success — resets counter

        strategy.setHealthFail(true, "test");
        strategy.healthCheck(); // failure 1 again (not 2)
        assertEq(uint8(strategy.state()), uint8(IStrategy.StrategyState.ACTIVE),
            "counter should have reset; emergency should not trigger");
    }

    // ── Metadata invariants ──────────────────────────────────────────────────

    function test_TargetRegimeIsValid() public view {
        uint8 regime = strategy.targetRegime();
        assertLe(regime, 3, "targetRegime must be 0-3");
    }

    function test_EstimatedNetAssetsLEQTotalAssets() public {
        _vaultDeposit(DEPOSIT);
        assertLe(
            strategy.estimatedNetAssets(),
            strategy.totalAssets(),
            "estimatedNetAssets must be <= totalAssets"
        );
    }

    function test_TargetLeverageGEQ1x() public view {
        assertGe(strategy.targetLeverage(), 1e4, "leverage must be >= 1x");
    }

    // ── Fuzz: any valid deposit amount satisfies INV-3 ───────────────────────

    function testFuzz_WithdrawAllAlwaysEmptiesStrategy(uint256 amount) public {
        vm.assume(amount >= 1e6 && amount <= 1000e18);
        token.mint(vault, amount);
        _vaultDeposit(amount);

        vm.prank(vault);
        strategy.withdrawAll(address(0xCC), 0);

        assertEq(strategy.totalAssets(), 0, "INV-3 violated for fuzz amount");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Layer 2: CrisisStrategy concrete tests
// ═════════════════════════════════════════════════════════════════════════════

contract CrisisStrategyTest is Test {

    CrisisStrategy  strategy;
    MockERC20       weth;
    MockERC20       aToken;
    MockERC20       arbToken;
    MockAavePool    aavePool;
    MockAaveRewards aaveRewards;
    MockSwapRouter  swapRouter;

    address vault    = address(0xAAAA);
    address guardian = address(0xBBBB);

    uint256 constant DEPOSIT = 100e18;

    function setUp() public {
        weth     = new MockERC20("WETH");
        aToken   = new MockERC20("aWETH");
        arbToken = new MockERC20("ARB");

        aavePool    = new MockAavePool(address(weth), address(aToken));
        aaveRewards = new MockAaveRewards(address(arbToken));
        swapRouter  = new MockSwapRouter(address(weth));

        // Give aavePool ability to transfer aTokens
        // (MockAavePool mints aTokens directly, weth needs to be pre-funded)
        weth.mint(address(aavePool), 10_000e18);

        strategy = new CrisisStrategy(
            address(weth),
            vault,
            guardian,
            address(aavePool),
            address(aaveRewards),
            address(swapRouter),
            address(arbToken)
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

    // ── Deployment ───────────────────────────────────────────────────────────

    function test_Crisis_DepositMintsATokens() public {
        _deposit(DEPOSIT);
        assertEq(aToken.balanceOf(address(strategy)), DEPOSIT, "should hold aTokens 1:1");
        assertEq(strategy.totalAssets(), DEPOSIT);
    }

    function test_Crisis_TotalAssetsEqualsATokenBalance() public {
        _deposit(DEPOSIT);
        assertEq(strategy.totalAssets(), aToken.balanceOf(address(strategy)));
    }

    function test_Crisis_TargetRegimeIsCrisis() public view {
        assertEq(strategy.targetRegime(), 3);
    }

    function test_Crisis_TargetLeverageIs1x() public view {
        assertEq(strategy.targetLeverage(), 1e4);
    }

    // ── Withdrawal ───────────────────────────────────────────────────────────

    function test_Crisis_PartialWithdrawDeliversAssets() public {
        _deposit(DEPOSIT);

        address recipient = address(0xCC);
        vm.prank(vault);
        uint256 out = strategy.withdraw(50e18, recipient, 0);

        assertEq(out, 50e18, "should deliver exact 50 WETH");
        assertEq(weth.balanceOf(recipient), 50e18);
        assertEq(strategy.totalAssets(), 50e18, "remaining should be 50 WETH");
    }

    function test_Crisis_WithdrawAllEmptiesAToken() public {
        _deposit(DEPOSIT);

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);

        assertGt(out, 0);
        assertEq(strategy.totalAssets(), 0, "INV-3: aToken balance should be 0");
        assertEq(aToken.balanceOf(address(strategy)), 0);
    }

    function test_Crisis_WithdrawMoreThanAvailableReverts() public {
        _deposit(DEPOSIT);

        vm.prank(vault);
        vm.expectRevert();
        strategy.withdraw(DEPOSIT * 2, address(0xCC), 0);
    }

    // ── Harvest ──────────────────────────────────────────────────────────────

    function test_Crisis_HarvestCompoundsRewardsIntoAave() public {
        _deposit(DEPOSIT);
        uint256 assetsBefore = strategy.totalAssets();

        vm.prank(vault);
        uint256 assetsAfter = strategy.harvestAndReport();

        assertGt(assetsAfter, assetsBefore, "harvest should increase totalAssets");
        assertGt(strategy.lastHarvestTimestamp(), 0);
    }

    function test_Crisis_HarvestTimestampUpdated() public {
        _deposit(DEPOSIT);
        assertEq(strategy.lastHarvestTimestamp(), 0);

        vm.prank(vault);
        strategy.harvestAndReport();

        assertEq(strategy.lastHarvestTimestamp(), uint40(block.timestamp));
    }

    // ── Health check ─────────────────────────────────────────────────────────

    function test_Crisis_HealthCheckPassesNormally() public {
        _deposit(DEPOSIT);
        (bool healthy, string memory reason) = strategy.healthCheck();
        assertTrue(healthy, reason);
    }

    function test_Crisis_HealthCheckFailsWhenPoolPaused() public {
        _deposit(DEPOSIT);
        aavePool.setPaused(true);

        (bool healthy, string memory reason) = strategy.healthCheck();
        assertFalse(healthy);
        assertEq(reason, "Aave pool paused for asset");
    }

    function test_Crisis_HealthCheckPassesWithZeroDeposit() public {
        // No assets deposited — should still be healthy
        (bool healthy,) = strategy.healthCheck();
        assertTrue(healthy);
    }

    // ── State machine ─────────────────────────────────────────────────────────

    function test_Crisis_WindDownRejectsNewDeposits() public {
        _deposit(DEPOSIT);

        vm.prank(guardian);
        strategy.windDown();

        weth.mint(vault, 10e18);
        vm.startPrank(vault);
        weth.transfer(address(strategy), 10e18);
        vm.expectRevert();
        strategy.deposit(10e18, 0);
        vm.stopPrank();
    }

    function test_Crisis_WindDownAllowsWithdrawals() public {
        _deposit(DEPOSIT);

        vm.prank(guardian);
        strategy.windDown();

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);
        assertGt(out, 0, "should still allow exit in WIND_DOWN state");
    }

    function test_Crisis_EmergencyExitAllowsWithdrawAll() public {
        _deposit(DEPOSIT);

        vm.prank(guardian);
        strategy.triggerEmergencyExit();

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);
        assertGt(out, 0, "emergency exit must support withdrawAll");
    }

    // ── Slippage ──────────────────────────────────────────────────────────────

    function test_Crisis_EstimatedSlippageIs5Bps() public view {
        assertEq(strategy.estimatedWithdrawalSlippageBps(), 5);
    }

    function test_Crisis_EstimatedNetAssetsLTETotalAssets() public {
        _deposit(DEPOSIT);
        assertLe(strategy.estimatedNetAssets(), strategy.totalAssets());
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_Crisis_AnyDepositAmount(uint256 amount) public {
        vm.assume(amount >= 1e6 && amount <= 500e18);
        weth.mint(vault, amount);
        _deposit(amount);

        assertEq(strategy.totalAssets(), amount);

        vm.prank(vault);
        strategy.withdrawAll(address(0xCC), 0);

        assertEq(strategy.totalAssets(), 0);
    }
}
