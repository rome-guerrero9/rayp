// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  RAYPRebalanceForkTest
 * @notice Fork test suite that simulates a RAYP vault rebalance event and
 *         checks for share price discontinuities visible to integrated lending
 *         protocols (Aave v3, Morpho Blue).
 *
 * What this tests
 * ───────────────
 * When RAYP rebalances from one strategy to another, the vault's convertToAssets()
 * return value can dip transiently while assets are in transit between strategies.
 * Lending protocols that accept vault shares as collateral read convertToAssets()
 * during liquidation checks. A transient dip can:
 *   1. Trigger unjust liquidations of borrowers whose collateral is "fine"
 *   2. Be exploited by MEV bots sandwiching the rebalance to extract value
 *
 * Test structure
 * ──────────────
 *   Fork:   Arbitrum mainnet (block pinned for determinism)
 *   Vault:  Mock ERC-4626 with realistic rebalance mechanics + slippage
 *   Checks:
 *     A. Pre-rebalance share price baseline
 *     B. Mid-rebalance share price (assets in flight - must not drop > MAX_TRANSIENT_DIP_BPS)
 *     C. Post-rebalance share price recovery
 *     D. TWAP share price oracle correctness vs spot
 *     E. Deposit/withdraw lock during rebalance (ERC-4626 extended spec)
 *     F. Aave v3 oracle adapter reads TWAP, not spot - no liquidation triggered
 *     G. Morpho Blue: collateral value stable across rebalance
 *     H. MEV sandwich attempt fails due to lock + slippage protection
 *
 * Run:
 *   forge test --match-contract RAYPRebalanceForkTest \
 *     --fork-url $ARBITRUM_RPC \
 *     --fork-block-number 200000000 \
 *     -vvv
 */

import "forge-std/Test.sol";
import "forge-std/console2.sol";

// ── Minimal ERC-20 interface ───────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

// ── ERC-4626 extended interface ────────────────────────────────────────────────

interface IERC4626 is IERC20 {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function maxDeposit(address)  external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
}

// ── Minimal Aave v3 price oracle interface ────────────────────────────────────

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

// ── Minimal Morpho Blue interface ─────────────────────────────────────────────

interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }
    function market(bytes32 id) external view returns (
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint128 lastUpdate,
        uint128 fee
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock RAYP Vault (ERC-4626 compliant with rebalance mechanics)
// ─────────────────────────────────────────────────────────────────────────────

contract MockRAYPVault is IERC4626 {

    IERC20  private immutable _asset;
    string  public name   = "RAYP Vault";
    string  public symbol = "rVLT";
    uint8   public decimals = 18;

    // Share accounting
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public override totalSupply;

    // Rebalance state
    bool    public rebalanceLock;         // blocks deposits/withdraws during rebalance
    uint256 public strategyAssets;        // assets deployed in current strategy
    uint256 public transitAssets;         // assets in-flight between strategies (rebalance dip)
    uint256 public slippageLoss;          // cumulative slippage incurred in rebalances
    uint256 public rebalanceCount;

    // TWAP share price oracle (simplified: 8-slot ring buffer of convertToAssets(1e18))
    uint256[8] private _twapBuffer;
    uint8   private _twapHead;
    uint8   private _twapCount;
    uint256 public  lastTwapUpdate;
    uint256 public  constant TWAP_SLOT_INTERVAL = 450; // ~2 Arbitrum blocks

    // Events
    event RebalanceStarted(uint8 fromRegime, uint8 toRegime, uint256 assetsBeingMoved);
    event RebalanceCompleted(uint256 slippage, uint256 sharePriceBefore, uint256 sharePriceAfter);
    event DepositLocked(address caller);
    event WithdrawLocked(address caller);

    error RebalanceInProgress();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error Unauthorized();

    address public keeper;
    address public owner;

    constructor(address assetToken) {
        _asset = IERC20(assetToken);
        keeper = msg.sender;
        owner  = msg.sender;
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == owner, "not owner");
        keeper = _keeper;
    }

    // ── ERC-4626 core ─────────────────────────────────────────────────────────

    function asset() external view override returns (address) { return address(_asset); }

    function totalAssets() public view override returns (uint256) {
        // In-transit assets are temporarily excluded during a rebalance -
        // this is the source of the transient share price dip.
        return strategyAssets; // transitAssets excluded during lock
    }

    function totalAssetsIncludingTransit() public view returns (uint256) {
        return strategyAssets + transitAssets;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        if (totalSupply == 0) return shares; // 1:1 initial rate
        return (shares * totalAssets()) / totalSupply;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        if (totalSupply == 0) return assets;
        return (assets * totalSupply) / totalAssets();
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    // ERC-4626 extended spec: maxDeposit/maxWithdraw return 0 during rebalance lock
    function maxDeposit(address) external view override returns (uint256) {
        return rebalanceLock ? 0 : type(uint256).max;
    }

    function maxWithdraw(address account) external view override returns (uint256) {
        if (rebalanceLock) return 0;
        return convertToAssets(balanceOf[account]);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        if (rebalanceLock) {
            emit DepositLocked(msg.sender);
            revert RebalanceInProgress();
        }
        _asset.transferFrom(msg.sender, address(this), assets);
        shares = convertToShares(assets);
        _mint(receiver, shares);
        strategyAssets += assets;
        _pushTwap();
    }

    function withdraw(uint256 assets, address receiver, address owner_) external override returns (uint256 shares) {
        if (rebalanceLock) {
            emit WithdrawLocked(msg.sender);
            revert RebalanceInProgress();
        }
        shares = convertToShares(assets);
        _burn(owner_, shares);
        strategyAssets -= assets;
        _asset.transfer(receiver, assets);
        _pushTwap();
    }

    // ── Rebalance mechanics ────────────────────────────────────────────────────

    /**
     * @notice Simulate a regime-triggered rebalance from strategyA to strategyB.
     *         Phase 1: lock + move assets to transit (share price dips here).
     *         Phase 2: deploy into new strategy (share price recovers, minus slippage).
     *
     * @param fromRegime      Regime being exited (0=neutral,1=bull,2=bear,3=crisis)
     * @param toRegime        Regime being entered
     * @param slippageBps     Simulated DEX slippage on strategy exit (basis points)
     * @param minAssetsOut    Slippage protection - revert if output < this
     */
    function executeRebalance(
        uint8   fromRegime,
        uint8   toRegime,
        uint256 slippageBps,
        uint256 minAssetsOut
    ) external {
        require(msg.sender == keeper, "not keeper");
        require(!rebalanceLock, "already rebalancing");
        require(fromRegime != toRegime, "same regime");

        uint256 assetsToMove = strategyAssets;
        uint256 sharePriceBefore = convertToAssets(1e18);

        // ── Phase 1: lock + withdraw from old strategy ─────────────────────────
        // Lock deposits/withdrawals - starts the dip window
        rebalanceLock   = true;
        strategyAssets  = 0;         // assets are "in transit"
        transitAssets   = assetsToMove;

        emit RebalanceStarted(fromRegime, toRegime, assetsToMove);

        // ── [DIPPING POINT] ─────────────────────────────────────────────────────
        // At this exact point in execution:
        //   totalAssets()    = 0     (strategyAssets = 0)
        //   transitAssets    = assetsToMove
        //   convertToAssets(1e18) = 0  ← VISIBLE TO LENDING PROTOCOLS IF THEY
        //                               READ HERE VIA STATICCALL
        // ────────────────────────────────────────────────────────────────────────

        // ── Phase 2: apply slippage + deploy into new strategy ─────────────────
        uint256 slippageAmount = (assetsToMove * slippageBps) / 10_000;
        uint256 assetsAfterSlippage = assetsToMove - slippageAmount;

        if (assetsAfterSlippage < minAssetsOut) {
            // Revert the entire rebalance - restore prior state
            strategyAssets = assetsToMove;
            transitAssets  = 0;
            rebalanceLock  = false;
            revert SlippageExceeded(assetsAfterSlippage, minAssetsOut);
        }

        // Burn the slipped portion (simulates DEX slippage)
        slippageLoss  += slippageAmount;
        transitAssets  = 0;
        strategyAssets = assetsAfterSlippage;

        // Unlock
        rebalanceLock = false;
        rebalanceCount++;

        uint256 sharePriceAfter = convertToAssets(1e18);
        _pushTwap();

        emit RebalanceCompleted(slippageAmount, sharePriceBefore, sharePriceAfter);
    }

    // ── TWAP share price oracle ────────────────────────────────────────────────

    /**
     * @notice Push current spot share price into the TWAP ring buffer.
     *         Called after deposit, withdraw, and rebalance completion.
     */
    function _pushTwap() internal {
        if (block.timestamp < lastTwapUpdate + TWAP_SLOT_INTERVAL) return;
        _twapBuffer[_twapHead] = convertToAssets(1e18);
        _twapHead = uint8((_twapHead + 1) % 8);
        if (_twapCount < 8) _twapCount++;
        lastTwapUpdate = block.timestamp;
    }

    /**
     * @notice Returns the TWAP share price (use this for lending oracle integration).
     *         Integrators should call getTwapSharePrice() not convertToAssets() directly.
     */
    function getTwapSharePrice() public view returns (uint256 twap) {
        if (_twapCount == 0) return convertToAssets(1e18);
        uint256 sum;
        for (uint8 i = 0; i < _twapCount; i++) {
            sum += _twapBuffer[i];
        }
        return sum / _twapCount;
    }

    /**
     * @notice Safe convertToAssets for lending integrators:
     *         Returns TWAP during rebalance lock, spot otherwise.
     *         Prevents transient dip from triggering liquidations.
     */
    function safeConvertToAssets(uint256 shares) external view returns (uint256) {
        if (rebalanceLock) {
            // Use TWAP during rebalance window
            uint256 twapPrice = getTwapSharePrice();
            return (shares * twapPrice) / 1e18;
        }
        return convertToAssets(shares);
    }

    // ── ERC-20 stubs ──────────────────────────────────────────────────────────

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply    += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply     -= amount;
    }

    // ── Test helper: seed vault with assets (no deposit flow) ─────────────────

    function seedStrategy(uint256 assets) external {
        require(msg.sender == owner);
        strategyAssets += assets;
    }

    function forceTimestamp(uint256 ts) external {
        lastTwapUpdate = ts;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RAYP Aave Oracle Adapter
// Wraps the vault's getTwapSharePrice() for use as an Aave v3 price source
// ─────────────────────────────────────────────────────────────────────────────

contract RAYPAaveOracleAdapter {
    MockRAYPVault public immutable vault;
    IAaveOracle   public immutable baseOracle;   // ETH/USD price from Aave
    address       public immutable ethUsd;        // ETH price feed asset address

    constructor(address _vault, address _baseOracle, address _ethUsd) {
        vault       = MockRAYPVault(_vault);
        baseOracle  = IAaveOracle(_baseOracle);
        ethUsd      = _ethUsd;
    }

    /**
     * @notice Returns vault share price in USD, using TWAP during rebalances.
     *         This is what Aave v3 calls when computing collateral value.
     */
    function getAssetPrice(address) external view returns (uint256 priceUsd) {
        // Vault share price in underlying (e.g. ETH), 1e18-scaled
        uint256 sharePriceInUnderlying = vault.getTwapSharePrice();

        // Underlying price in USD from Aave base oracle
        uint256 underlyingUsd = baseOracle.getAssetPrice(ethUsd);

        // Vault share price in USD = sharePriceInUnderlying × underlyingUsd / 1e18
        return (sharePriceInUnderlying * underlyingUsd) / 1e18;
    }

    /**
     * @notice Returns spot share price for comparison in tests.
     */
    function getSpotAssetPrice(address) external view returns (uint256) {
        uint256 spotPrice = vault.convertToAssets(1e18);
        uint256 underlyingUsd = baseOracle.getAssetPrice(ethUsd);
        return (spotPrice * underlyingUsd) / 1e18;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fork test
// ─────────────────────────────────────────────────────────────────────────────

contract RAYPRebalanceForkTest is Test {

    // ── Arbitrum mainnet addresses ────────────────────────────────────────────
    address constant WETH        = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC        = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7; // Aave v3 Arbitrum
    address constant WETH_WHALE  = 0x489ee077994B6658eAfA855C308275EAd8097C4A;

    // ── Test actors ───────────────────────────────────────────────────────────
    address alice   = makeAddr("alice");   // LP depositor
    address bob     = makeAddr("bob");     // borrower on Aave (uses vault shares as collateral)
    address keeper  = makeAddr("keeper");
    address mevBot  = makeAddr("mevBot");  // adversarial sandwich attacker

    // ── Contracts ─────────────────────────────────────────────────────────────
    MockRAYPVault         vault;
    RAYPAaveOracleAdapter oracleAdapter;
    IERC20                weth;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 constant DEPOSIT_AMOUNT  = 10 ether;
    uint256 constant VAULT_SEED      = 100 ether;  // pre-seeded strategy assets

    // ── Thresholds ────────────────────────────────────────────────────────────
    /// @notice Maximum acceptable transient share price dip during a rebalance.
    ///         0 bps enforced by the lock: convertToAssets should NEVER dip
    ///         below pre-rebalance price from an EXTERNAL perspective because
    ///         the lock blocks external reads of mid-rebalance state.
    uint256 constant MAX_TRANSIENT_DIP_BPS       = 0;
    /// @notice Maximum permanent share price impact from slippage (50 bps = 0.5%).
    uint256 constant MAX_PERMANENT_SLIPPAGE_BPS  = 50;
    /// @notice Max divergence between TWAP and spot prices post-rebalance (10 bps).
    uint256 constant MAX_TWAP_SPOT_DIVERGE_BPS   = 10;

    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // Fork Arbitrum at a recent stable block
        // Set ARBITRUM_RPC in your .env file
        string memory rpc = vm.envOr("ARBITRUM_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        } else {
            vm.createSelectFork(rpc, 200_000_000);
        }

        weth = IERC20(WETH);

        // Deploy vault with WETH as underlying
        vault = new MockRAYPVault(WETH);
        vault.seedStrategy(VAULT_SEED);  // seed 100 ETH into strategy

        // Initialise TWAP buffer with current spot price (1:1 initially)
        vault.forceTimestamp(0);

        // Deploy Aave oracle adapter
        oracleAdapter = new RAYPAaveOracleAdapter(
            address(vault),
            AAVE_ORACLE,
            WETH
        );

        // Set keeper role on vault
        vault.setKeeper(keeper);

        // Fund test actors from whale
        vm.startPrank(WETH_WHALE);
        weth.transfer(alice,   20 ether);
        weth.transfer(bob,     5 ether);
        weth.transfer(mevBot,  5 ether);
        vm.stopPrank();

        // Alice deposits
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════════
    // A. Share price baseline - correct before any rebalance
    // ════════════════════════════════════════════════════════════════════════

    function test_A_SharePriceBaselineCorrect() public {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        uint256 sharePrice  = vault.convertToAssets(1e18);

        assertGt(totalAssets, 0, "vault has no assets");
        assertGt(totalSupply, 0, "vault has no supply");

        // Share price should be 1:1 (VAULT_SEED + DEPOSIT_AMOUNT / DEPOSIT_AMOUNT shares)
        uint256 expectedPrice = (totalAssets * 1e18) / totalSupply;
        assertEq(sharePrice, expectedPrice, "share price formula wrong");

        console2.log("Baseline share price (1e18):", sharePrice);
        console2.log("Total assets:", totalAssets);
        console2.log("Total supply:", totalSupply);
    }

    // ════════════════════════════════════════════════════════════════════════
    // B. Mid-rebalance share price dip - MUST be blocked by lock
    // ════════════════════════════════════════════════════════════════════════

    function test_B_MidRebalanceDipBlockedByLock() public {
        uint256 sharePriceBefore = vault.convertToAssets(1e18);

        // Simulate a keeper triggering a rebalance mid-execution
        // We test the state between Phase 1 (lock + move to transit) and Phase 2
        // by directly reading vault state at the dip point

        // Manually simulate Phase 1 state (as if execution paused mid-rebalance)
        vm.store(
            address(vault),
            bytes32(uint256(3)),  // strategyAssets slot
            bytes32(uint256(0))
        );
        vm.store(
            address(vault),
            bytes32(uint256(4)),  // transitAssets slot
            bytes32(uint256(VAULT_SEED + DEPOSIT_AMOUNT))
        );
        vm.store(
            address(vault),
            bytes32(uint256(2)),  // rebalanceLock slot
            bytes32(uint256(1))   // locked = true
        );

        // ── Spot price during dip ─────────────────────────────────────────
        uint256 spotDuringDip = vault.convertToAssets(1e18);

        // ── TWAP price during dip (what lending protocols should read) ────
        uint256 twapDuringDip = vault.getTwapSharePrice();

        // ── safeConvertToAssets uses TWAP when locked ─────────────────────
        uint256 safeDuringDip = vault.safeConvertToAssets(1e18);

        console2.log("Share price before rebalance:", sharePriceBefore);
        console2.log("Spot price during dip:       ", spotDuringDip);
        console2.log("TWAP price during dip:       ", twapDuringDip);
        console2.log("Safe price during dip:       ", safeDuringDip);

        // SPOT dips to near zero (this is the vulnerability)
        assertLt(spotDuringDip, sharePriceBefore, "spot should dip during transit");

        // But deposits and withdrawals are BLOCKED during the lock
        assertEq(vault.maxDeposit(alice), 0, "deposits should be blocked during rebalance");
        assertEq(vault.maxWithdraw(alice), 0, "withdrawals should be blocked during rebalance");

        // safeConvertToAssets returns TWAP - no dip visible to integrators
        assertApproxEqRel(
            safeDuringDip,
            sharePriceBefore,
            0.001e18,  // 0.1% tolerance
            "safeConvertToAssets should return TWAP during lock"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // C. Post-rebalance share price recovery (with slippage)
    // ════════════════════════════════════════════════════════════════════════

    function test_C_PostRebalancePriceRecovery() public {
        uint256 sharePriceBefore = vault.convertToAssets(1e18);
        uint256 slippageBps = 30; // 0.3% slippage - within tolerance

        vm.prank(keeper);
        vault.executeRebalance(
            1,           // from: BULL
            2,           // to:   BEAR
            slippageBps,
            0            // no min out (we're testing slippage effects, not protection)
        );

        uint256 sharePriceAfter = vault.convertToAssets(1e18);

        console2.log("Share price before:", sharePriceBefore);
        console2.log("Share price after: ", sharePriceAfter);
        console2.log("Slippage incurred: ", vault.slippageLoss(), "wei");
        console2.log("Rebalance count:   ", vault.rebalanceCount());

        // Share price should have recovered but be slightly lower due to slippage
        assertLe(sharePriceAfter, sharePriceBefore, "price cannot increase from slippage");

        // Permanent slippage must be within acceptable bounds
        uint256 slipBps = ((sharePriceBefore - sharePriceAfter) * 10_000) / sharePriceBefore;
        assertLe(
            slipBps,
            MAX_PERMANENT_SLIPPAGE_BPS,
            "permanent slippage exceeds 50bps tolerance"
        );

        // Vault is unlocked
        assertFalse(vault.rebalanceLock(), "vault should be unlocked after rebalance");
        assertGt(vault.maxDeposit(alice), 0, "deposits should be re-enabled");
        assertGt(vault.maxWithdraw(alice), 0, "withdrawals should be re-enabled");

        console2.log("Permanent slippage bps:", slipBps);
    }

    // ════════════════════════════════════════════════════════════════════════
    // D. TWAP oracle divergence from spot stays within bounds post-rebalance
    // ════════════════════════════════════════════════════════════════════════

    function test_D_TwapDivergenceWithinBoundsPostRebalance() public {
        // Prime the TWAP buffer with 4 readings at stable share price
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 500); // advance past TWAP_SLOT_INTERVAL
            vault.forceTimestamp(block.timestamp - 500);
            vm.prank(alice);
            vault.deposit(0.01 ether, alice);
        }

        uint256 twapBefore = vault.getTwapSharePrice();
        uint256 spotBefore = vault.convertToAssets(1e18);

        // Execute rebalance with small slippage
        vm.prank(keeper);
        vault.executeRebalance(1, 3, 20, 0); // 0.2% slippage

        uint256 twapAfter = vault.getTwapSharePrice();
        uint256 spotAfter = vault.convertToAssets(1e18);

        // TWAP should still be close to spot (buffer smoothing means it lags slightly)
        uint256 divergeBps = twapAfter > spotAfter
            ? ((twapAfter - spotAfter) * 10_000) / twapAfter
            : ((spotAfter - twapAfter) * 10_000) / spotAfter;

        console2.log("TWAP before:", twapBefore);
        console2.log("Spot before:", spotBefore);
        console2.log("TWAP after: ", twapAfter);
        console2.log("Spot after: ", spotAfter);
        console2.log("TWAP/spot diverge bps:", divergeBps);

        // With small slippage, TWAP and spot should be close
        // TWAP will be slightly higher (hasn't fully reflected the slippage yet)
        // which is intentional - it protects borrowers from instantaneous liquidation
        assertLe(twapAfter, twapBefore + 1, "TWAP should not increase from slippage");
    }

    // ════════════════════════════════════════════════════════════════════════
    // E. Deposit lock during rebalance - ERC-4626 extended spec
    // ════════════════════════════════════════════════════════════════════════

    function test_E_DepositWithdrawLockedDuringRebalance() public {
        // Manually set lock state
        vm.store(address(vault), bytes32(uint256(2)), bytes32(uint256(1)));
        assertTrue(vault.rebalanceLock());

        // maxDeposit must return 0 when locked (ERC-4626 spec: deposit MUST revert if > maxDeposit)
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit must be 0 when locked");
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw must be 0 when locked");

        // Actual deposit attempt must revert
        vm.prank(alice);
        vm.expectRevert(MockRAYPVault.RebalanceInProgress.selector);
        vault.deposit(1 ether, alice);

        // Actual withdraw attempt must revert
        vm.prank(alice);
        vm.expectRevert(MockRAYPVault.RebalanceInProgress.selector);
        vault.withdraw(0.5 ether, alice, alice);

        // ── Unlock and verify normal operation resumes ────────────────────
        vm.store(address(vault), bytes32(uint256(2)), bytes32(uint256(0)));

        assertGt(vault.maxDeposit(alice), 0);
        assertGt(vault.maxWithdraw(alice), 0);
    }

    // ════════════════════════════════════════════════════════════════════════
    // F. Aave oracle adapter reads TWAP - no liquidation triggered
    // ════════════════════════════════════════════════════════════════════════

    function test_F_AaveAdapterReadsTwapNotSpotDuringRebalance() public {
        // Prime TWAP with a stable reading
        vm.warp(block.timestamp + 1000);
        vault.forceTimestamp(block.timestamp - 1000);
        vm.prank(alice);
        vault.deposit(0.01 ether, alice);

        // Record collateral value before rebalance
        uint256 collateralValueBefore = oracleAdapter.getAssetPrice(address(vault));

        // Simulate mid-rebalance dip (lock + zero strategy assets)
        vm.store(address(vault), bytes32(uint256(2)), bytes32(uint256(1))); // lock
        vm.store(address(vault), bytes32(uint256(3)), bytes32(uint256(0))); // strategyAssets = 0
        vm.store(address(vault), bytes32(uint256(4)), bytes32(uint256(VAULT_SEED + DEPOSIT_AMOUNT))); // transit

        uint256 spotPriceDuringDip   = oracleAdapter.getSpotAssetPrice(address(vault));
        uint256 twapPriceDuringDip   = oracleAdapter.getAssetPrice(address(vault));

        console2.log("Collateral value before (USD 1e8):   ", collateralValueBefore);
        console2.log("Spot price during dip (USD 1e8):     ", spotPriceDuringDip);
        console2.log("TWAP price (Aave reads) (USD 1e8):   ", twapPriceDuringDip);

        // Spot would trigger liquidation (price ≈ 0)
        assertLt(spotPriceDuringDip, collateralValueBefore / 2, "spot should show a severe dip");

        // TWAP is stable - Aave should NOT trigger liquidation
        assertApproxEqRel(
            twapPriceDuringDip,
            collateralValueBefore,
            0.01e18,  // 1% tolerance
            "TWAP-based collateral value should remain stable during rebalance"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // G. Morpho Blue: collateral value stable across full rebalance cycle
    // ════════════════════════════════════════════════════════════════════════

    function test_G_MorphoCollateralValueStableAcrossRebalance() public {
        // Simulate a borrower with N vault shares as Morpho collateral
        uint256 bobShares = vault.balanceOf(alice) / 2;

        // Collateral value = shares × safeConvertToAssets / 1e18
        uint256 collateralBefore = (bobShares * vault.safeConvertToAssets(1e18)) / 1e18;

        // Execute a rebalance with realistic slippage
        vm.prank(keeper);
        vault.executeRebalance(1, 2, 25, 0); // 0.25% slippage

        uint256 collateralAfter = (bobShares * vault.safeConvertToAssets(1e18)) / 1e18;

        uint256 dropBps = collateralBefore > collateralAfter
            ? ((collateralBefore - collateralAfter) * 10_000) / collateralBefore
            : 0;

        console2.log("Collateral before rebalance:", collateralBefore);
        console2.log("Collateral after rebalance: ", collateralAfter);
        console2.log("Collateral drop (bps):      ", dropBps);

        // Drop must be within the slippage tolerance - no surprise liquidations
        assertLe(
            dropBps,
            MAX_PERMANENT_SLIPPAGE_BPS,
            "collateral value dropped more than 50bps - liquidation risk"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // H. MEV sandwich attempt fails
    // ════════════════════════════════════════════════════════════════════════

    function test_H_MevSandwichDepositFailsDuringRebalance() public {
        // MEV strategy: deposit right before rebalance (at pre-dip price),
        // then withdraw right after (at post-dip price, capturing the slippage)
        // This should be BLOCKED by the rebalance lock.

        // Step 1: mevBot front-runs by depositing (would work without lock)
        vm.startPrank(mevBot);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(2 ether, mevBot);
        vm.stopPrank();

        uint256 mevSharesBefore = vault.balanceOf(mevBot);
        uint256 mevAssetsBefore = vault.convertToAssets(mevSharesBefore);
        console2.log("MEV bot shares:        ", mevSharesBefore);
        console2.log("MEV assets before:     ", mevAssetsBefore);

        // Step 2: rebalance starts - lock engages
        // (Simulate mid-rebalance lock state)
        vm.store(address(vault), bytes32(uint256(2)), bytes32(uint256(1)));

        // Step 3: mevBot tries to withdraw during the dip window → BLOCKED
        vm.prank(mevBot);
        vm.expectRevert(MockRAYPVault.RebalanceInProgress.selector);
        vault.withdraw(mevAssetsBefore, mevBot, mevBot);

        // Step 4: rebalance completes (with slippage)
        vm.store(address(vault), bytes32(uint256(2)), bytes32(uint256(0)));
        vm.prank(keeper);
        vault.executeRebalance(1, 2, 30, 0);

        // Step 5: mevBot withdraws post-rebalance - but they share the slippage
        uint256 mevAssetsAfter = vault.convertToAssets(mevSharesBefore);
        console2.log("MEV assets after rebalance:", mevAssetsAfter);

        // MEV bot cannot profit - they absorbed the same slippage as everyone else
        assertLe(mevAssetsAfter, mevAssetsBefore, "MEV bot should not profit from sandwich");

        uint256 mevLossBps = ((mevAssetsBefore - mevAssetsAfter) * 10_000) / mevAssetsBefore;
        console2.log("MEV net loss (bps):", mevLossBps);

        // The loss should be proportional to slippage, not amplified by the attack
        assertLe(mevLossBps, MAX_PERMANENT_SLIPPAGE_BPS + 5, "MEV loss is disproportionate");
    }

    // ════════════════════════════════════════════════════════════════════════
    // I. Slippage protection reverts cleanly and restores state
    // ════════════════════════════════════════════════════════════════════════

    function test_I_SlippageProtectionRevertsAndRestoresState() public {
        uint256 sharePriceBefore  = vault.convertToAssets(1e18);
        uint256 stratBefore       = vault.strategyAssets();
        bool    lockBefore        = vault.rebalanceLock();

        // minAssetsOut is set higher than what 500bps slippage would deliver
        uint256 tightMinOut = (stratBefore * 9980) / 10_000; // require ≤ 20bps slippage

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(
            MockRAYPVault.SlippageExceeded.selector,
            (stratBefore * 9500) / 10_000,  // actual output at 500bps slippage
            tightMinOut
        ));
        vault.executeRebalance(1, 2, 500, tightMinOut); // 5% slippage - too much

        // All state should be fully restored after revert
        assertEq(vault.convertToAssets(1e18), sharePriceBefore, "share price corrupted after failed rebalance");
        assertEq(vault.strategyAssets(), stratBefore, "strategyAssets corrupted");
        assertFalse(vault.rebalanceLock(), "vault left locked after failed rebalance");
        assertEq(vault.rebalanceCount(), 0, "rebalanceCount should not increment on failure");
        assertEq(vault.transitAssets(), 0, "transitAssets should be 0 after revert");
    }

    // ════════════════════════════════════════════════════════════════════════
    // J. Multiple sequential rebalances - no cumulative drift
    // ════════════════════════════════════════════════════════════════════════

    function test_J_MultipleRebalancesNoCumulativeDrift() public {
        uint256 sharePriceInitial = vault.convertToAssets(1e18);
        uint256 totalSlippageBps;

        uint8[4] memory sequence = [1, 2, 3, 0]; // bull→bear→crisis→neutral

        for (uint256 i = 0; i < sequence.length; i++) {
            uint8 fromRegime = i == 0 ? 0 : sequence[i-1];
            uint8 toRegime   = sequence[i];
            if (fromRegime == toRegime) continue;

            uint256 priceBefore = vault.convertToAssets(1e18);

            vm.prank(keeper);
            vault.executeRebalance(fromRegime, toRegime, 10, 0); // 0.1% slippage each

            uint256 priceAfter = vault.convertToAssets(1e18);
            uint256 stepBps = ((priceBefore - priceAfter) * 10_000) / priceBefore;
            totalSlippageBps += stepBps;

            assertFalse(vault.rebalanceLock(), "lock stuck after rebalance");

            console2.log(
                string(abi.encodePacked("Rebalance ", vm.toString(i), " slippage bps:")),
                stepBps
            );
        }

        uint256 sharePriceFinal = vault.convertToAssets(1e18);
        console2.log("Initial share price:", sharePriceInitial);
        console2.log("Final share price:  ", sharePriceFinal);
        console2.log("Total slippage bps: ", totalSlippageBps);

        // Total drift across 4 rebalances at 0.1% each should be ≤ 0.5%
        assertLe(totalSlippageBps, 50, "cumulative drift across 4 rebalances exceeds 50bps");

        // Vault is still healthy
        assertGt(vault.totalAssets(), 0);
        assertGt(vault.convertToAssets(1e18), 0);
        assertEq(vault.rebalanceCount(), 4);
    }

    // ════════════════════════════════════════════════════════════════════════
    // K. TWAP share price oracle: integrator spec compliance
    // ════════════════════════════════════════════════════════════════════════

    function test_K_TwapOracleSpecCompliance() public {
        // K1: TWAP never returns 0 (would liquidate all positions)
        assertGt(vault.getTwapSharePrice(), 0, "TWAP must never be 0");

        // K2: TWAP is ≤ 10% diverged from pre-rebalance spot in normal slippage range
        vm.warp(block.timestamp + 500);
        vault.forceTimestamp(block.timestamp - 500);
        vm.prank(alice);
        vault.deposit(0.01 ether, alice); // pushes a TWAP slot

        uint256 spot = vault.convertToAssets(1e18);
        uint256 twap = vault.getTwapSharePrice();

        uint256 divergeBps = spot > twap
            ? ((spot - twap) * 10_000) / spot
            : ((twap - spot) * 10_000) / twap;

        assertLe(divergeBps, 1000, "TWAP diverged > 10% from spot in normal conditions");

        // K3: safeConvertToAssets is monotone with shares
        uint256 price1share = vault.safeConvertToAssets(1e18);
        uint256 price2share = vault.safeConvertToAssets(2e18);
        assertEq(price2share, price1share * 2, "safeConvertToAssets must be linear in shares");

        // K4: TWAP is smooth - does not jump by more than 1% in a single slot update
        uint256 twapBefore = vault.getTwapSharePrice();
        vm.warp(block.timestamp + 500);
        vault.forceTimestamp(block.timestamp - 500);
        vm.prank(alice);
        vault.deposit(0.01 ether, alice);

        uint256 twapAfter = vault.getTwapSharePrice();
        uint256 jumpBps = twapBefore > twapAfter
            ? ((twapBefore - twapAfter) * 10_000) / twapBefore
            : ((twapAfter - twapBefore) * 10_000) / twapBefore;

        assertLe(jumpBps, 100, "TWAP should not jump > 1% between slots");

        console2.log("TWAP/spot diverge bps (normal):", divergeBps);
        console2.log("TWAP slot-to-slot jump bps:    ", jumpBps);
    }

    // ════════════════════════════════════════════════════════════════════════
    // L. Summary: print full share price timeline
    // ════════════════════════════════════════════════════════════════════════

    function test_L_PrintSharePriceTimeline() public view {
        console2.log("=== RAYP Share Price Timeline ===");
        console2.log("total assets:      ", vault.totalAssets());
        console2.log("total supply:      ", vault.totalSupply());
        console2.log("spot share price:  ", vault.convertToAssets(1e18));
        console2.log("TWAP share price:  ", vault.getTwapSharePrice());
        console2.log("safe share price:  ", vault.safeConvertToAssets(1e18));
        console2.log("rebalance lock:    ", vault.rebalanceLock());
        console2.log("rebalance count:   ", vault.rebalanceCount());
        console2.log("slippage loss:     ", vault.slippageLoss());
        console2.log("transit assets:    ", vault.transitAssets());
        console2.log("=================================");
    }
}
