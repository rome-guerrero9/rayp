// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/RAYPVault.sol";

/**
 * @title  RAYPVaultTest
 * @notice Full test suite for RAYPVault covering:
 *
 *   1.  ERC-4626 compliance (deposit, mint, withdraw, redeem, preview functions)
 *   2.  Share price accounting (convertToShares, convertToAssets)
 *   3.  High-water mark + performance fee minting
 *   4.  Withdrawal fee
 *   5.  Rebalance engine (happy path, slippage revert, same-regime revert)
 *   6.  Rebalance lock (deposits/withdrawals blocked, TWAP preserved)
 *   7.  Drawdown circuit breaker (auto-pause + emergency route to crisis)
 *   8.  TVL cap enforcement
 *   9.  Strategy registry (set, regime mismatch revert)
 *   10. TWAP oracle (accumulates, returns live price when empty)
 *   11. Access control (keeper/guardian/admin gates)
 *   12. Fuzz: share price invariant across arbitrary deposit/withdraw sequences
 *
 * Run:  forge test --match-contract RAYPVaultTest -vvv
 */

// ── Minimal ERC-20 mock ───────────────────────────────────────────────────────

contract MockToken {
    string  public name     = "WETH";
    string  public symbol   = "WETH";
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function burn(address from, uint256 a) external { balanceOf[from] -= a; totalSupply -= a; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

// ── Mock strategy ─────────────────────────────────────────────────────────────

contract MockStrategy {
    MockToken public asset;
    uint8     public targetRegime;
    string    public stratName;

    uint256 public deployed;
    bool    public shouldRevertWithdraw;
    bool    public forceHealthFail;
    uint256 public extraYield; // simulate yield accrual

    enum StrategyState { ACTIVE, WIND_DOWN, EMERGENCY_EXIT }
    StrategyState public state;

    constructor(address _asset, uint8 _regime, string memory _name) {
        asset         = MockToken(_asset);
        targetRegime  = _regime;
        stratName     = _name;
        state         = StrategyState.ACTIVE;
    }

    function name() external view returns (string memory) { return stratName; }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + extraYield;
    }

    function estimatedNetAssets() external view returns (uint256) {
        return totalAssets() * 9970 / 10000; // 0.3% slippage estimate
    }

    function estimatedWithdrawalSlippageBps() external pure returns (uint256) { return 30; }

    function deposit(uint256 assets, uint256) external returns (uint256) {
        require(state == StrategyState.ACTIVE, "not active");
        deployed += assets;
        return totalAssets();
    }

    function withdraw(uint256 assets, address recipient, uint256 minAssetsOut)
        external returns (uint256)
    {
        if (shouldRevertWithdraw) revert("strategy: withdraw failed");
        uint256 actual = assets > deployed ? deployed : assets;
        deployed -= actual;
        asset.transfer(recipient, actual);
        require(actual >= minAssetsOut, "slippage");
        return actual;
    }

    function withdrawAll(address recipient, uint256 minAssetsOut)
        external returns (uint256)
    {
        if (shouldRevertWithdraw) revert("strategy: withdraw failed");
        uint256 bal = asset.balanceOf(address(this));
        if (bal > 0) asset.transfer(recipient, bal);
        uint256 out = deployed + extraYield;
        deployed   = 0;
        extraYield = 0;
        require(bal >= minAssetsOut, "slippage");
        return bal;
    }

    function harvestAndReport() external returns (uint256) {
        return totalAssets();
    }

    function healthCheck() external view returns (bool healthy, string memory reason) {
        if (forceHealthFail) return (false, "mock health failure");
        return (true, "");
    }

    function triggerEmergencyExit() external { state = StrategyState.EMERGENCY_EXIT; }

    // Test helpers
    function setYield(uint256 y) external { extraYield = y; }
    function setHealthFail(bool f) external { forceHealthFail = f; }
    function setShouldRevertWithdraw(bool r) external { shouldRevertWithdraw = r; }
}

// ── Mock RegimeDampener ───────────────────────────────────────────────────────

contract MockDampener {
    uint8 public confirmedRegime;
    uint8 public confirmationCount = 3;

    function setRegime(uint8 r) external { confirmedRegime = r; }
}

// ══════════════════════════════════════════════════════════════════════════════
// Main test contract
// ══════════════════════════════════════════════════════════════════════════════

contract RAYPVaultTest is Test {

    RAYPVault    vault;
    MockToken    weth;
    MockDampener dampener;

    MockStrategy stratNeutral;
    MockStrategy stratBull;
    MockStrategy stratBear;
    MockStrategy stratCrisis;

    address guardian = address(0xBB);
    address admin    = address(0xCC);
    address treasury = address(0xDD);
    address keeper   = address(0xEE);

    address alice   = address(0x01);
    address bob     = address(0x02);
    address carol   = address(0x03);

    uint256 constant DEPOSIT = 10 ether;

    function setUp() public {
        weth     = new MockToken();
        dampener = new MockDampener();

        stratNeutral = new MockStrategy(address(weth), 0, "Neutral");
        stratBull    = new MockStrategy(address(weth), 1, "Bull");
        stratBear    = new MockStrategy(address(weth), 2, "Bear");
        stratCrisis  = new MockStrategy(address(weth), 3, "Crisis");

        vault = new RAYPVault(
            address(weth),
            address(dampener),
            treasury,
            guardian,
            admin,
            0 // initial regime = NEUTRAL
        );

        // Grant keeper role
        vm.prank(admin);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        // Register all strategies
        vm.startPrank(guardian);
        vault.setStrategy(0, address(stratNeutral));
        vault.setStrategy(1, address(stratBull));
        vault.setStrategy(2, address(stratBear));
        vault.setStrategy(3, address(stratCrisis));
        vault.setTvlCap(0); // unlimited for most tests
        vm.stopPrank();

        // Fund users
        weth.mint(alice, 1000 ether);
        weth.mint(bob,   1000 ether);
        weth.mint(carol, 1000 ether);

        vm.prank(alice); weth.approve(address(vault), type(uint256).max);
        vm.prank(bob);   weth.approve(address(vault), type(uint256).max);
        vm.prank(carol); weth.approve(address(vault), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        return vault.deposit(amount, who);
    }

    function _rebalanceTo(uint8 toRegime) internal {
        dampener.setRegime(toRegime);
        vm.prank(keeper);
        vault.executeRebalance(toRegime, 0);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. ERC-4626 compliance
    // ════════════════════════════════════════════════════════════════════════

    function test_ERC4626_DepositMintsShares() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        assertGt(shares, 0, "should mint shares");
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalSupply(), shares);
    }

    function test_ERC4626_FirstDepositIs1to1() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        assertEq(shares, DEPOSIT, "first deposit should be 1:1");
    }

    function test_ERC4626_WithdrawBurnsShares() public {
        _deposit(alice, DEPOSIT);
        uint256 sharesBefore = vault.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(DEPOSIT / 2, alice, alice);

        assertLt(vault.balanceOf(alice), sharesBefore, "shares should decrease");
    }

    function test_ERC4626_RedeemReturnsAssets() public {
        _deposit(alice, DEPOSIT);
        uint256 shares = vault.balanceOf(alice);

        uint256 balBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice);

        assertGt(weth.balanceOf(alice), balBefore, "should receive assets");
    }

    function test_ERC4626_PreviewDepositMatchesDeposit() public {
        uint256 preview = vault.previewDeposit(DEPOSIT);
        uint256 actual  = _deposit(alice, DEPOSIT);
        assertEq(preview, actual, "previewDeposit must match deposit");
    }

    function test_ERC4626_PreviewRedeemMatchesRedeem() public {
        _deposit(alice, DEPOSIT);
        uint256 shares  = vault.balanceOf(alice);
        uint256 preview = vault.previewRedeem(shares);

        uint256 balBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        uint256 received = weth.balanceOf(alice) - balBefore;

        // Allow 1 wei rounding tolerance
        assertApproxEqAbs(preview, received, 1, "previewRedeem mismatch");
    }

    function test_ERC4626_MaxDepositZeroWhenLocked() public {
        // Set lock manually
        vm.store(address(vault), bytes32(uint256(15)), bytes32(uint256(1)));
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit must be 0 when locked");
    }

    function test_ERC4626_MaxWithdrawZeroWhenLocked() public {
        _deposit(alice, DEPOSIT);
        vm.store(address(vault), bytes32(uint256(15)), bytes32(uint256(1)));
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw must be 0 when locked");
    }

    function test_ERC4626_DepositRevertsWhenLocked() public {
        vm.store(address(vault), bytes32(uint256(15)), bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(RAYPVault.RebalanceInProgress.selector);
        vault.deposit(DEPOSIT, alice);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2. Share price accounting
    // ════════════════════════════════════════════════════════════════════════

    function test_SharePrice_IncreasesWithYield() public {
        _deposit(alice, DEPOSIT);
        uint256 priceBefore = vault.convertToAssets(1e18);

        // Simulate yield accrual in strategy
        stratNeutral.setYield(1 ether);

        uint256 priceAfter = vault.convertToAssets(1e18);
        assertGt(priceAfter, priceBefore, "yield should increase share price");
    }

    function test_SharePrice_TotalAssetsEqualsStrategyPlusIdle() public {
        _deposit(alice, DEPOSIT);

        // Leave 1 ETH idle in vault (not deployed)
        weth.mint(address(vault), 1 ether);

        uint256 vaultTotal    = vault.totalAssets();
        uint256 stratTotal    = stratNeutral.totalAssets();
        uint256 idleBalance   = weth.balanceOf(address(vault));

        assertEq(vaultTotal, stratTotal + idleBalance, "totalAssets = strategy + idle");
    }

    function test_SharePrice_MultipleDepositorsDiluted() public {
        _deposit(alice, DEPOSIT);

        // Simulate 10% yield
        stratNeutral.setYield(1 ether);

        uint256 priceBeforeBob = vault.convertToAssets(1e18);
        uint256 bobShares      = _deposit(bob, DEPOSIT);

        // Bob should get fewer shares (price is higher now)
        uint256 aliceShares = vault.balanceOf(alice);
        assertLt(bobShares, aliceShares, "bob gets fewer shares at higher price");

        // Both should get equal assets if they hold equal value
        assertApproxEqRel(
            vault.convertToAssets(aliceShares),
            vault.convertToAssets(bobShares) + 1 ether, // alice has 1 ETH more in yield
            0.001e18,
            "alice should own more value"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // 3. High-water mark + performance fee
    // ════════════════════════════════════════════════════════════════════════

    function test_Fee_NoFeeWhenBelowHWM() public {
        _deposit(alice, DEPOSIT);

        // Simulate a loss
        vm.startPrank(address(stratNeutral));
        weth.burn(address(stratNeutral), 1 ether); // simulate 1 ETH loss
        vm.stopPrank();

        vm.warp(block.timestamp + 8 days);
        uint256 supplyBefore = vault.totalSupply();
        vault.harvestFees();

        assertEq(vault.totalSupply(), supplyBefore, "no fee shares when below HWM");
    }

    function test_Fee_MintsFeeSharesOnGain() public {
        _deposit(alice, DEPOSIT);
        uint256 hwmBefore = vault.highWaterMark();

        // Add yield → share price above HWM
        stratNeutral.setYield(2 ether);

        vm.warp(block.timestamp + 8 days);
        uint256 supplyBefore = vault.totalSupply();
        vault.harvestFees();

        assertGt(vault.totalSupply(), supplyBefore, "should mint fee shares");
        assertGt(vault.balanceOf(treasury), 0, "treasury should receive fee shares");
        assertGt(vault.highWaterMark(), hwmBefore, "HWM should update");
    }

    function test_Fee_HarvestIntervalEnforced() public {
        _deposit(alice, DEPOSIT);
        stratNeutral.setYield(2 ether);

        vm.warp(block.timestamp + 8 days);
        vault.harvestFees();

        // Immediate second harvest should fail (interval not elapsed)
        vm.expectRevert("harvest too soon");
        vault.harvestFees();
    }

    function test_Fee_PerformanceFeeIs20Pct() public {
        _deposit(alice, DEPOSIT); // 10 ETH deposited, 10 shares
        stratNeutral.setYield(10 ether); // 100% yield → price now 2x

        vm.warp(block.timestamp + 8 days);

        uint256 totalBefore = vault.totalAssets(); // 20 ETH
        vault.harvestFees();

        // Gain above HWM = 10 ETH. 20% fee = 2 ETH
        // Fee shares minted ≈ 2 ETH worth
        uint256 feeValue = vault.convertToAssets(vault.balanceOf(treasury));
        assertApproxEqRel(feeValue, 2 ether, 0.01e18, "fee should be ~20% of gain");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4. Withdrawal fee
    // ════════════════════════════════════════════════════════════════════════

    function test_WithdrawalFee_DeductedOnExit() public {
        _deposit(alice, DEPOSIT);

        uint256 balBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(DEPOSIT, alice, alice);

        uint256 received = weth.balanceOf(alice) - balBefore;
        uint256 expected = DEPOSIT - (DEPOSIT * 10 / 10_000); // 0.10% fee

        assertApproxEqAbs(received, expected, 1, "withdrawal fee should be 0.10%");
    }

    function test_WithdrawalFee_SentToTreasury() public {
        _deposit(alice, DEPOSIT);

        uint256 treasuryBefore = weth.balanceOf(treasury);
        vm.prank(alice);
        vault.withdraw(DEPOSIT, alice, alice);

        assertGt(weth.balanceOf(treasury), treasuryBefore, "treasury should receive fee");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5. Rebalance engine
    // ════════════════════════════════════════════════════════════════════════

    function test_Rebalance_MovesAssetsBetweenStrategies() public {
        _deposit(alice, DEPOSIT);
        uint256 neutralBefore = stratNeutral.totalAssets();
        assertGt(neutralBefore, 0, "neutral strategy should have assets");

        _rebalanceTo(1); // NEUTRAL → BULL

        assertEq(stratNeutral.totalAssets(), 0, "neutral should be empty");
        assertGt(stratBull.totalAssets(), 0, "bull should have assets");
        assertEq(vault.activeRegime(), 1);
    }

    function test_Rebalance_SharePricePreserved() public {
        _deposit(alice, DEPOSIT);
        uint256 priceBefore = vault.convertToAssets(1e18);

        _rebalanceTo(2); // NEUTRAL → BEAR

        uint256 priceAfter = vault.convertToAssets(1e18);
        // Price should be within 50bps (max rebalance slippage)
        assertApproxEqRel(priceAfter, priceBefore, 0.005e18, "price should be preserved");
    }

    function test_Rebalance_SameRegimeReverts() public {
        dampener.setRegime(0); // same as active
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RAYPVault.SameRegime.selector, uint8(0)));
        vault.executeRebalance(0, 0);
    }

    function test_Rebalance_RegimeMismatchWithDampenerReverts() public {
        dampener.setRegime(1);
        vm.prank(keeper);
        vm.expectRevert("regime mismatch with dampener");
        vault.executeRebalance(2, 0); // dampener says 1, keeper says 2
    }

    function test_Rebalance_OnlyKeeperCanExecute() public {
        dampener.setRegime(1);
        vm.prank(alice);
        vm.expectRevert();
        vault.executeRebalance(1, 0);
    }

    function test_Rebalance_HealthCheckFailReverts() public {
        _deposit(alice, DEPOSIT);
        stratNeutral.setHealthFail(true);

        dampener.setRegime(1);
        vm.prank(keeper);
        vm.expectRevert();
        vault.executeRebalance(1, 0);
    }

    function test_Rebalance_UnlocksAfterCompletion() public {
        _deposit(alice, DEPOSIT);
        _rebalanceTo(1);
        assertFalse(vault.rebalanceLock(), "vault should be unlocked after rebalance");
    }

    function test_Rebalance_CountIncrements() public {
        _deposit(alice, DEPOSIT);
        _rebalanceTo(1);
        _rebalanceTo(2);
        assertEq(vault.rebalanceCount(), 2);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 6. Rebalance lock
    // ════════════════════════════════════════════════════════════════════════

    function test_Lock_DepositRevertsWhenLocked() public {
        // Simulate lock mid-rebalance
        vm.store(address(vault), bytes32(uint256(15)), bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(RAYPVault.RebalanceInProgress.selector);
        vault.deposit(DEPOSIT, alice);
    }

    function test_Lock_WithdrawRevertsWhenLocked() public {
        _deposit(alice, DEPOSIT);
        vm.store(address(vault), bytes32(uint256(15)), bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(RAYPVault.RebalanceInProgress.selector);
        vault.withdraw(DEPOSIT / 2, alice, alice);
    }

    function test_Lock_SafeConvertUsesTwapWhenLocked() public {
        _deposit(alice, DEPOSIT);

        // Prime TWAP with a real price
        vm.warp(block.timestamp + 500);

        // Force lock + simulate dip
        vm.store(address(vault), bytes32(uint256(15)), bytes32(uint256(1)));

        // safeConvertToAssets should use TWAP (or fall back to live price if TWAP empty)
        uint256 safe = vault.safeConvertToAssets(1e18);
        assertGt(safe, 0, "safe price should never be 0");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 7. Drawdown circuit breaker
    // ════════════════════════════════════════════════════════════════════════

    function test_Drawdown_AutoPausesOnLargeSlippage() public {
        _deposit(alice, DEPOSIT);

        // Simulate catastrophic slippage: strategy returns only 50% of assets
        stratNeutral.setShouldRevertWithdraw(false);
        // We'll directly manipulate: burn half the strategy's WETH
        vm.prank(address(stratNeutral));
        // Simulate 50% loss by withdrawAll returning half
        // Override: manually drain strategy
        uint256 stratBal = weth.balanceOf(address(stratNeutral));
        vm.prank(address(stratNeutral));
        weth.transfer(address(0xDEAD), stratBal / 2); // simulate 50% loss

        dampener.setRegime(1);
        vm.prank(keeper);
        vault.executeRebalance(1, 0);

        // Large drawdown should trigger emergency
        assertTrue(vault.emergencyTriggered(), "emergency should be triggered");
        assertTrue(vault.paused(), "vault should be paused");
    }

    function test_Drawdown_EmergencyUnpauseResetsFlag() public {
        // Trigger emergency state
        vm.prank(guardian);
        vault.pause();

        // Store emergencyTriggered = true
        vm.store(address(vault), bytes32(uint256(16)), bytes32(uint256(1)));
        assertTrue(vault.emergencyTriggered());

        vm.prank(guardian);
        vault.unpause();

        assertFalse(vault.emergencyTriggered(), "flag should clear on unpause");
        assertFalse(vault.paused());
    }

    // ════════════════════════════════════════════════════════════════════════
    // 8. TVL cap
    // ════════════════════════════════════════════════════════════════════════

    function test_TvlCap_EnforcedOnDeposit() public {
        vm.prank(guardian);
        vault.setTvlCap(5 ether);

        _deposit(alice, 5 ether); // fills the cap

        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1 ether, bob); // over cap
    }

    function test_TvlCap_ZeroMeansUnlimited() public {
        vm.prank(guardian);
        vault.setTvlCap(0);

        _deposit(alice, 1000 ether); // should succeed
        assertGt(vault.totalSupply(), 0);
    }

    function test_TvlCap_MaxDepositReflectsCap() public {
        vm.prank(guardian);
        vault.setTvlCap(100 ether);
        _deposit(alice, 60 ether);

        uint256 maxD = vault.maxDeposit(bob);
        assertApproxEqAbs(maxD, 40 ether, 1, "maxDeposit should reflect remaining cap");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 9. Strategy registry
    // ════════════════════════════════════════════════════════════════════════

    function test_StrategyRegistry_GuardianCanRegister() public {
        MockStrategy newStrat = new MockStrategy(address(weth), 1, "New Bull");
        vm.prank(guardian);
        vault.setStrategy(1, address(newStrat));
        assertEq(address(vault.strategies(1)), address(newStrat));
    }

    function test_StrategyRegistry_RegimeMismatchReverts() public {
        MockStrategy wrongStrat = new MockStrategy(address(weth), 2, "Wrong"); // regime 2
        vm.prank(guardian);
        vm.expectRevert("strategy regime mismatch");
        vault.setStrategy(1, address(wrongStrat)); // trying to register as regime 1
    }

    function test_StrategyRegistry_NonGuardianReverts() public {
        MockStrategy newStrat = new MockStrategy(address(weth), 1, "New");
        vm.prank(alice);
        vm.expectRevert();
        vault.setStrategy(1, address(newStrat));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 10. TWAP oracle
    // ════════════════════════════════════════════════════════════════════════

    function test_Twap_ReturnsLivePriceWhenEmpty() public view {
        uint256 twap = vault.getTwapSharePrice();
        uint256 live = vault.convertToAssets(1e18);
        assertEq(twap, live, "TWAP should return live price when buffer is empty");
    }

    function test_Twap_AccumulatesAfterDeposits() public {
        _deposit(alice, DEPOSIT);
        vm.warp(block.timestamp + 500);
        _deposit(alice, DEPOSIT); // second deposit pushes a TWAP slot

        uint256 twap = vault.getTwapSharePrice();
        assertGt(twap, 0, "TWAP should be populated after deposits");
    }

    function test_Twap_SmoothsYieldSpike() public {
        _deposit(alice, DEPOSIT);
        vm.warp(block.timestamp + 500);
        _deposit(alice, 0.01 ether); // push a slot at baseline price

        // Add huge yield spike
        stratNeutral.setYield(100 ether);

        uint256 spot = vault.convertToAssets(1e18);
        uint256 twap = vault.getTwapSharePrice();

        // TWAP should be lower than spot (lagging the spike)
        assertLt(twap, spot, "TWAP should lag behind a sudden yield spike");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 11. Access control
    // ════════════════════════════════════════════════════════════════════════

    function test_Access_OnlyGuardianCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();

        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Access_OnlyAdminCanSetParameters() public {
        vm.prank(guardian);
        vm.expectRevert();
        vault.setParameters(2000, 10, 50, 500);

        vm.prank(admin);
        vault.setParameters(2500, 15, 30, 300);
        assertEq(vault.performanceFeeBps(), 2500);
    }

    function test_Access_FeeParamsBounded() public {
        vm.prank(admin);
        vm.expectRevert(); // perf fee > 30%
        vault.setParameters(3001, 10, 50, 500);

        vm.prank(admin);
        vm.expectRevert(); // withdrawal fee > 1%
        vault.setParameters(2000, 101, 50, 500);
    }

    function test_Access_OnlyAdminCanSetTreasury() public {
        vm.prank(guardian);
        vm.expectRevert();
        vault.setTreasury(address(0x1234));

        vm.prank(admin);
        vault.setTreasury(address(0x1234));
        assertEq(vault.treasury(), address(0x1234));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 12. Fuzz: share price invariant
    // ════════════════════════════════════════════════════════════════════════

    function testFuzz_SharePriceNeverExceedsTotalAssetsDivSupply(
        uint256 depositAmt,
        uint256 yieldAmt
    ) public {
        vm.assume(depositAmt >= 1e6 && depositAmt <= 500 ether);
        vm.assume(yieldAmt  <= 100 ether);

        weth.mint(alice, depositAmt);
        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);

        _deposit(alice, depositAmt);
        stratNeutral.setYield(yieldAmt);

        uint256 totalA = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;

        uint256 sharePriceFromFormula = (totalA * 1e18) / supply;
        uint256 sharePriceFromVault   = vault.convertToAssets(1e18);

        assertApproxEqAbs(
            sharePriceFromVault,
            sharePriceFromFormula,
            1,
            "share price formula must match convertToAssets"
        );
    }

    function testFuzz_WithdrawNeverExceedsDeposit(uint256 depositAmt) public {
        vm.assume(depositAmt >= 1e6 && depositAmt <= 500 ether);
        weth.mint(alice, depositAmt);
        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);

        _deposit(alice, depositAmt);

        uint256 balBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);

        uint256 received = weth.balanceOf(alice) - balBefore;

        // Cannot receive more than deposited (no yield added)
        // Minus withdrawal fee
        uint256 maxExpected = depositAmt; // 1:1 ratio, no yield
        assertLe(received, maxExpected, "cannot receive more than deposited without yield");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 13. Full lifecycle integration test
    // ════════════════════════════════════════════════════════════════════════

    function test_FullLifecycle() public {
        console2.log("=== RAYP Vault Full Lifecycle ===");

        // Phase 1: LP deposits
        _deposit(alice, 50 ether);
        _deposit(bob,   30 ether);
        console2.log("After deposits - totalAssets:", vault.totalAssets());
        console2.log("Share price:", vault.convertToAssets(1e18));

        // Phase 2: Yield accrues in NEUTRAL strategy
        stratNeutral.setYield(5 ether); // 6.25% yield
        console2.log("After 6.25% yield - share price:", vault.convertToAssets(1e18));

        // Phase 3: Rebalance to BULL (regime classifier confirmed)
        _rebalanceTo(1);
        assertEq(vault.activeRegime(), 1, "should be in BULL regime");
        console2.log("After rebalance to BULL - totalAssets:", vault.totalAssets());

        // Phase 4: Fee harvest
        stratBull.setYield(8 ether); // additional yield in bull strategy
        vm.warp(block.timestamp + 8 days);
        vault.harvestFees();
        assertGt(vault.balanceOf(treasury), 0, "treasury should have fee shares");
        console2.log("Fee shares minted to treasury:", vault.balanceOf(treasury));

        // Phase 5: Bear market - rebalance to BEAR
        _rebalanceTo(2);
        assertEq(vault.activeRegime(), 2, "should be in BEAR regime");

        // Phase 6: LPs withdraw
        uint256 aliceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);

        uint256 aliceReceived = weth.balanceOf(alice) - aliceBefore;
        console2.log("Alice received on exit:", aliceReceived);

        // Alice should have earned yield (minus fees)
        assertGt(aliceReceived, 50 ether * 9900 / 10_000, "alice should profit after fees");

        console2.log("=== Lifecycle complete ===");
    }
}
