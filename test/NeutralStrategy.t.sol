// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IStrategy.sol";
import "../src/NeutralStrategy.sol";

// Reuse mocks from IStrategy.t.sol
import {MockERC20, MockAavePool, MockAaveRewards, MockSwapRouter} from "./IStrategy.t.sol";

contract NeutralStrategyTest is Test {

    NeutralStrategy strategy;
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

        weth.mint(address(aavePool), 10_000e18);

        strategy = new NeutralStrategy(
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

    // ── Metadata ────────────────────────────────────────────────────────────

    function test_Neutral_TargetRegimeIsNeutral() public view {
        assertEq(strategy.targetRegime(), 0);
    }

    function test_Neutral_NameIsCorrect() public view {
        assertEq(strategy.name(), "RAYP Neutral: Aave WETH");
    }

    function test_Neutral_TargetLeverageIs1x() public view {
        assertEq(strategy.targetLeverage(), 1e4);
    }

    function test_Neutral_EstimatedSlippageIs5Bps() public view {
        assertEq(strategy.estimatedWithdrawalSlippageBps(), 5);
    }

    // ── Deposit ─────────────────────────────────────────────────────────────

    function test_Neutral_DepositMintsATokens() public {
        _deposit(DEPOSIT);
        assertEq(aToken.balanceOf(address(strategy)), DEPOSIT);
        assertEq(strategy.totalAssets(), DEPOSIT);
    }

    // ── Withdrawal ──────────────────────────────────────────────────────────

    function test_Neutral_PartialWithdraw() public {
        _deposit(DEPOSIT);
        address recipient = address(0xCC);

        vm.prank(vault);
        uint256 out = strategy.withdraw(50e18, recipient, 0);

        assertEq(out, 50e18);
        assertEq(weth.balanceOf(recipient), 50e18);
        assertEq(strategy.totalAssets(), 50e18);
    }

    function test_Neutral_WithdrawAllEmptiesPosition() public {
        _deposit(DEPOSIT);

        vm.prank(vault);
        uint256 out = strategy.withdrawAll(address(0xCC), 0);

        assertGt(out, 0);
        assertEq(strategy.totalAssets(), 0, "INV-3 violated");
    }

    // ── Harvest ─────────────────────────────────────────────────────────────

    function test_Neutral_HarvestCompoundsRewards() public {
        _deposit(DEPOSIT);
        uint256 before = strategy.totalAssets();

        vm.prank(vault);
        uint256 after_ = strategy.harvestAndReport();

        assertGt(after_, before);
    }

    // ── Health check ────────────────────────────────────────────────────────

    function test_Neutral_HealthCheckPasses() public {
        _deposit(DEPOSIT);
        (bool healthy, string memory reason) = strategy.healthCheck();
        assertTrue(healthy, reason);
    }

    function test_Neutral_HealthCheckFailsWhenPoolPaused() public {
        _deposit(DEPOSIT);
        aavePool.setPaused(true);

        (bool healthy, string memory reason) = strategy.healthCheck();
        assertFalse(healthy);
        assertEq(reason, "Aave pool paused for asset");
    }

    // ── INV-3 fuzz ──────────────────────────────────────────────────────────

    function testFuzz_Neutral_WithdrawAllAlwaysEmpties(uint256 amount) public {
        vm.assume(amount >= 1e6 && amount <= 500e18);
        weth.mint(vault, amount);
        _deposit(amount);

        vm.prank(vault);
        strategy.withdrawAll(address(0xCC), 0);
        assertEq(strategy.totalAssets(), 0, "INV-3 violated for fuzz amount");
    }
}
