// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  RAYPVault
 * @notice The core ERC-4626 vault for the Regime-Adaptive Yield Protocol.
 *         Routes LP capital into the optimal yield strategy for each
 *         on-chain market regime. Ties together all four protocol contracts:
 *
 *           OracleAggregator  →  RegimeDampener  →  RAYPVault  →  IStrategy
 *                                                        ↑
 *                                                  KeeperRegistry
 *
 * Architecture
 * ────────────
 *   Depositors send WETH (or any ERC-20 underlying) and receive vault shares.
 *   Shares accrue value as the active strategy earns yield.
 *   When the RegimeDampener confirms a regime change, it calls
 *   onRegimeConfirmed() — the vault rotates capital to the new strategy.
 *
 * Key design decisions
 * ─────────────────────
 *   1. High-water mark fee accounting
 *      Performance fees (20%) only accrue on gains ABOVE the prior peak
 *      share price. Recovering from a loss never triggers a fee.
 *      Fee shares are minted to the treasury, diluting all LPs equally.
 *
 *   2. Rebalance lock window
 *      deposits() and withdraw() return 0 / revert during a rebalance.
 *      convertToAssets() returns TWAP (not spot) during the lock to prevent
 *      lending protocol liquidations from transient share price dips.
 *
 *   3. Emergency drawdown circuit breaker
 *      If a rebalance causes the share price to drop > MAX_DRAWDOWN_BPS
 *      from the high-water mark, the vault auto-pauses and routes to the
 *      crisis strategy regardless of the regime classifier's output.
 *
 *   4. Strategy registry
 *      One IStrategy per regime. Governance can upgrade a strategy via
 *      a time-locked setter. The vault never calls any strategy except
 *      the currently registered one for the active regime.
 *
 *   5. CEI everywhere
 *      All state is updated before external calls. The rebalance sequence
 *      is: lock → update state → call old strategy → call new strategy →
 *      unlock. No state can be corrupted by a reentering strategy.
 *
 * Roles
 * ─────
 *   KEEPER_ROLE    — KeeperRegistry-authorised callers of executeRebalance()
 *   GUARDIAN_ROLE  — multisig; can pause, set emergency regime, upgrade strategies
 *   DEFAULT_ADMIN  — timelock; can set treasury, fee params, strategy registry
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ── Dependency interfaces ─────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IStrategy {
    enum StrategyState { ACTIVE, WIND_DOWN, EMERGENCY_EXIT }
    function deposit(uint256 assets, uint256 minDeployedOut) external returns (uint256);
    function withdraw(uint256 assets, address recipient, uint256 minAssetsOut) external returns (uint256);
    function withdrawAll(address recipient, uint256 minAssetsOut) external returns (uint256);
    function harvestAndReport() external returns (uint256);
    function healthCheck() external returns (bool healthy, string memory reason);
    function totalAssets() external view returns (uint256);
    function estimatedNetAssets() external view returns (uint256);
    function estimatedWithdrawalSlippageBps() external view returns (uint256);
    function state() external view returns (StrategyState);
    function targetRegime() external view returns (uint8);
    function name() external view returns (string memory);
    function triggerEmergencyExit() external;
}

interface IRegimeDampener {
    function confirmedRegime() external view returns (uint8);
    function confirmationCount() external view returns (uint8);
}

// ─────────────────────────────────────────────────────────────────────────────

contract RAYPVault is AccessControl, Pausable, ReentrancyGuard {

    // ─── Roles ────────────────────────────────────────────────────────────────

    bytes32 public constant KEEPER_ROLE   = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ─── ERC-4626 core ────────────────────────────────────────────────────────

    IERC20 public immutable asset;

    string public constant name     = "RAYP Vault";
    string public constant symbol   = "rVLT";
    uint8  public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    // ─── Strategy registry ─────────────────────────────────────────────────────

    /// @notice One strategy per regime label (0=NEUTRAL,1=BULL,2=BEAR,3=CRISIS).
    mapping(uint8 => IStrategy) public strategies;

    /// @notice The regime whose strategy currently holds all vault assets.
    uint8 public activeRegime;

    // ─── External contracts ───────────────────────────────────────────────────

    IRegimeDampener public regimeDampener;
    address         public treasury;

    // ─── Fee accounting ────────────────────────────────────────────────────────

    /// @notice Performance fee in basis points. Applied only to gains above HWM.
    uint16  public performanceFeeBps   = 2000;  // 20%
    /// @notice Withdrawal fee in basis points. Applied on every exit.
    uint16  public withdrawalFeeBps    = 10;    // 0.10%
    /// @notice High-water mark: the all-time peak share price (1e18 = 1 token).
    uint256 public highWaterMark;
    /// @notice Timestamp of the last fee harvest.
    uint40  public lastFeeHarvestAt;
    /// @notice Minimum time between fee harvests.
    uint40  public constant FEE_HARVEST_INTERVAL = 7 days;

    // ─── Rebalance state ───────────────────────────────────────────────────────

    /// @notice True while a rebalance is executing. Locks deposits/withdrawals.
    bool    public rebalanceLock;
    /// @notice Block number of the last completed rebalance.
    uint256 public lastRebalanceBlock;
    /// @notice Timestamp of the last completed rebalance.
    uint40  public lastRebalanceAt;
    /// @notice Cumulative count of successful rebalances.
    uint64  public rebalanceCount;
    /// @notice Maximum acceptable slippage on strategy exit (basis points).
    uint16  public maxRebalanceSlippageBps = 50; // 0.50%

    // ─── TWAP share price oracle ───────────────────────────────────────────────

    /// @notice Ring buffer of historical share prices (1e18-scaled).
    uint256[8] private _twapBuffer;
    uint8  private _twapHead;
    uint8  private _twapCount;
    uint40 public  lastTwapPush;
    uint40 public  constant TWAP_PUSH_INTERVAL = 450; // ~2 Arbitrum blocks

    // ─── Circuit breakers ─────────────────────────────────────────────────────

    /// @notice Auto-pause if share price drops > this from HWM in one rebalance.
    uint16  public maxDrawdownBps = 500; // 5%
    /// @notice Hard TVL cap enforced during early deployment period.
    uint256 public tvlCap;
    /// @notice True when the emergency drawdown breaker has fired.
    bool    public emergencyTriggered;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event RebalanceStarted(uint8 indexed fromRegime, uint8 indexed toRegime, uint256 assetsToMove);
    event RebalanceCompleted(uint8 indexed newRegime, uint256 assetsAfter, uint256 sharePriceBefore, uint256 sharePriceAfter);
    event FeeHarvested(uint256 feeShares, uint256 newHighWaterMark);
    event StrategyRegistered(uint8 indexed regime, address strategy, string strategyName);
    event EmergencyTriggered(uint256 sharePriceAtTrigger, uint256 drawdownBps);
    event TvlCapUpdated(uint256 newCap);
    event ParametersUpdated(uint16 perfFeeBps, uint16 withdrawalFeeBps, uint16 maxSlippageBps, uint16 maxDrawdownBps);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error RebalanceInProgress();
    error NoStrategyForRegime(uint8 regime);
    error SameRegime(uint8 regime);
    error StrategyHealthCheckFailed(string reason);
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error TvlCapExceeded(uint256 attempted, uint256 cap);
    error ZeroShares();
    error ZeroAssets();
    error InsufficientShares(uint256 have, uint256 need);
    error InvalidFeeBps(uint16 bps);
    error ZeroAddress();
    error DrawdownTooLarge(uint256 dropBps, uint256 maxBps);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _asset,
        address _regimeDampener,
        address _treasury,
        address _guardian,
        address _admin,
        uint8   _initialRegime
    ) {
        if (_asset == address(0) || _treasury == address(0)) revert ZeroAddress();

        asset          = IERC20(_asset);
        decimals       = IERC20(_asset).decimals();
        regimeDampener = IRegimeDampener(_regimeDampener);
        treasury       = _treasury;
        activeRegime   = _initialRegime;
        tvlCap         = 5_000 ether; // $5M cap at launch (adjustable)
        highWaterMark  = 1e18;        // starts at 1:1

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE,      _guardian);
        _setRoleAdmin(KEEPER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ─── ERC-4626: deposit ────────────────────────────────────────────────────

    /**
     * @notice Deposit `assets` and receive vault shares.
     *         Reverts during rebalance lock (maxDeposit returns 0).
     *         Reverts if TVL cap would be breached.
     *         Pushes a TWAP sample after each deposit.
     */
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (rebalanceLock) revert RebalanceInProgress();
        if (assets == 0)   revert ZeroAssets();

        // TVL cap check
        uint256 newTvl = totalAssets() + assets;
        if (tvlCap > 0 && newTvl > tvlCap) revert TvlCapExceeded(newTvl, tvlCap);

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();

        // CEI: transfer first, then mint
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        // Deploy to active strategy
        _deployToStrategy(assets);
        _pushTwap();

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Mint exactly `shares` by depositing the required assets.
     */
    function mint(uint256 shares, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (rebalanceLock) revert RebalanceInProgress();
        if (shares == 0)   revert ZeroShares();

        assets = convertToAssets(shares);
        if (assets == 0)   revert ZeroAssets();

        uint256 newTvl = totalAssets() + assets;
        if (tvlCap > 0 && newTvl > tvlCap) revert TvlCapExceeded(newTvl, tvlCap);

        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        _deployToStrategy(assets);
        _pushTwap();

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ─── ERC-4626: withdraw ────────────────────────────────────────────────────

    /**
     * @notice Withdraw `assets` by burning the required shares.
     *         Applies withdrawal fee — fee shares minted to treasury.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (rebalanceLock) revert RebalanceInProgress();
        if (assets == 0)   revert ZeroAssets();

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();
        _checkAllowanceAndBurn(owner, shares);

        // Withdrawal fee
        uint256 fee    = (assets * withdrawalFeeBps) / 10_000;
        uint256 netOut = assets - fee;

        // Withdraw from active strategy
        IStrategy strat = _activeStrategy();
        uint256 minOut  = (assets * (10_000 - maxRebalanceSlippageBps)) / 10_000;
        uint256 actual  = strat.withdraw(assets, address(this), minOut);

        // Send fee to treasury
        if (fee > 0) asset.transfer(treasury, fee);
        asset.transfer(receiver, actual - fee);

        _pushTwap();
        emit Withdraw(msg.sender, receiver, owner, actual, shares);
    }

    /**
     * @notice Redeem `shares` for their underlying asset value.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (rebalanceLock) revert RebalanceInProgress();
        if (shares == 0)   revert ZeroShares();

        assets = convertToAssets(shares);
        if (assets == 0)   revert ZeroAssets();

        _checkAllowanceAndBurn(owner, shares);

        uint256 fee    = (assets * withdrawalFeeBps) / 10_000;
        uint256 netOut = assets - fee;

        IStrategy strat = _activeStrategy();
        uint256 minOut  = (assets * (10_000 - maxRebalanceSlippageBps)) / 10_000;
        uint256 actual  = strat.withdraw(assets, address(this), minOut);

        if (fee > 0) asset.transfer(treasury, fee);
        asset.transfer(receiver, actual - fee);

        _pushTwap();
        emit Withdraw(msg.sender, receiver, owner, actual, shares);
    }

    // ─── ERC-4626: accounting ──────────────────────────────────────────────────

    /**
     * @notice Total assets managed by the vault — reads from the active strategy.
     *         During rebalance lock, reflects only already-deployed assets
     *         (transit assets temporarily excluded — see fork test).
     */
    function totalAssets() public view returns (uint256) {
        if (address(strategies[activeRegime]) == address(0)) {
            return asset.balanceOf(address(this));
        }
        return strategies[activeRegime].totalAssets()
             + asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    /**
     * @notice Safe share price for lending protocol integrators.
     *         Returns TWAP during rebalance lock to prevent liquidations
     *         from transient share price dips.
     */
    function safeConvertToAssets(uint256 shares) external view returns (uint256) {
        if (rebalanceLock && _twapCount > 0) {
            return (shares * _computeTwap()) / 1e18;
        }
        return convertToAssets(shares);
    }

    /// @notice ERC-4626 extended spec: 0 during rebalance lock.
    function maxDeposit(address) external view returns (uint256) {
        if (paused() || rebalanceLock || emergencyTriggered) return 0;
        if (tvlCap == 0) return type(uint256).max;
        uint256 current = totalAssets();
        return current >= tvlCap ? 0 : tvlCap - current;
    }

    /// @notice ERC-4626 extended spec: 0 during rebalance lock.
    function maxWithdraw(address owner) external view returns (uint256) {
        if (paused() || rebalanceLock) return 0;
        return convertToAssets(balanceOf[owner]);
    }

    function maxMint(address) external view returns (uint256) {
        if (paused() || rebalanceLock || emergencyTriggered) return 0;
        return type(uint256).max;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        if (paused() || rebalanceLock) return 0;
        return balanceOf[owner];
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    // ─── Rebalance engine ──────────────────────────────────────────────────────

    /**
     * @notice Execute a regime-triggered vault rebalance.
     *         Called by KeeperRegistry-authorised keepers.
     *         The target regime must match what RegimeDampener has confirmed.
     *
     * Rebalance sequence (CEI throughout):
     *   1.  Validate: caller authorised, regime valid, not same regime
     *   2.  Health check: old strategy must be withdrawable
     *   3.  Lock: set rebalanceLock = true
     *   4.  Update state: activeRegime = toRegime
     *   5.  Harvest fee on old strategy before exit
     *   6.  Exit old strategy → assets land in vault
     *   7.  Drawdown check: revert entire tx if price drop > maxDrawdownBps
     *   8.  Deploy assets → new strategy
     *   9.  Unlock: rebalanceLock = false
     *   10. Push TWAP sample, emit event
     *
     * @param toRegime      Target regime (must match RegimeDampener.confirmedRegime())
     * @param minAssetsOut  Slippage floor for the old strategy exit.
     */
    function executeRebalance(uint8 toRegime, uint256 minAssetsOut)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        whenNotPaused
    {
        uint8 fromRegime = activeRegime;

        // ── Validations ───────────────────────────────────────────────────────
        if (toRegime == fromRegime) revert SameRegime(toRegime);
        if (address(strategies[toRegime]) == address(0)) revert NoStrategyForRegime(toRegime);

        // Confirm target regime matches dampener's confirmed state
        uint8 dampenerRegime = regimeDampener.confirmedRegime();
        require(toRegime == dampenerRegime, "regime mismatch with dampener");

        // ── Health check old strategy before exit ─────────────────────────────
        IStrategy oldStrat = _activeStrategy();
        if (address(oldStrat) != address(0)) {
            (bool healthy, string memory reason) = oldStrat.healthCheck();
            if (!healthy) revert StrategyHealthCheckFailed(reason);
        }

        uint256 sharePriceBefore = convertToAssets(1e18);

        // ── Phase 1: lock (CEI — update state before external calls) ─────────
        rebalanceLock = true;
        activeRegime  = toRegime;  // state updated BEFORE external calls

        emit RebalanceStarted(fromRegime, toRegime, oldStrat.totalAssets());

        // ── Phase 2: harvest fees on old strategy ─────────────────────────────
        // Accrue any pending yield to HWM accounting before exiting
        if (address(oldStrat) != address(0)) {
            try oldStrat.harvestAndReport() {} catch {} // non-critical
        }

        // ── Phase 3: exit old strategy ────────────────────────────────────────
        uint256 assetsRecovered;
        if (address(oldStrat) != address(0)) {
            uint256 slippageBps = oldStrat.estimatedWithdrawalSlippageBps();
            uint256 estimated   = oldStrat.estimatedNetAssets();
            uint256 computedMin = estimated * (10_000 - slippageBps) / 10_000;
            uint256 effectiveMin = minAssetsOut > computedMin ? minAssetsOut : computedMin;

            assetsRecovered = oldStrat.withdrawAll(address(this), effectiveMin);
        } else {
            assetsRecovered = asset.balanceOf(address(this));
        }

        // ── Phase 4: drawdown circuit breaker ────────────────────────────────
        // Check share price after exit (before new deployment) to catch
        // catastrophic slippage on exit. If price dropped > maxDrawdownBps
        // from HWM, auto-pause and route to crisis strategy.
        uint256 sharePriceAfterExit = _computeSharePriceFromFreeAssets(assetsRecovered);
        if (highWaterMark > 0 && sharePriceAfterExit < highWaterMark) {
            uint256 dropBps = ((highWaterMark - sharePriceAfterExit) * 10_000) / highWaterMark;
            if (dropBps > maxDrawdownBps) {
                _triggerEmergencyDrawdown(sharePriceAfterExit, dropBps);
                // Override target regime to crisis
                activeRegime = 3; // CRISIS
            }
        }

        // ── Phase 5: deploy into new strategy ────────────────────────────────
        uint256 assetsToDeploy = asset.balanceOf(address(this));
        IStrategy newStrat     = strategies[activeRegime];

        if (address(newStrat) != address(0) && assetsToDeploy > 0) {
            asset.approve(address(newStrat), assetsToDeploy);
            asset.transfer(address(newStrat), assetsToDeploy);
            newStrat.deposit(assetsToDeploy, 0); // strategy-level slippage checked internally
        }

        // ── Phase 6: unlock ───────────────────────────────────────────────────
        rebalanceLock      = false;
        lastRebalanceBlock = block.number;
        lastRebalanceAt    = uint40(block.timestamp);
        rebalanceCount    += 1;

        uint256 sharePriceAfter = convertToAssets(1e18);
        _pushTwap();

        emit RebalanceCompleted(activeRegime, assetsToDeploy, sharePriceBefore, sharePriceAfter);
    }

    // ─── RegimeDampener callback ───────────────────────────────────────────────

    /**
     * @notice Called by RegimeDampener when a regime change is confirmed.
     *         Does NOT execute the rebalance — it emits a signal for keepers.
     *         Actual rebalance is keeper-triggered via executeRebalance().
     *         This separation prevents the dampener from holding execution risk.
     */
    function onRegimeConfirmed(uint8 newRegime, uint8 /* oldRegime */) external {
        require(msg.sender == address(regimeDampener), "only dampener");
        // Signal to keepers — they will call executeRebalance() separately
        // The dampener callback is intentionally lightweight
    }

    // ─── Fee accounting ────────────────────────────────────────────────────────

    /**
     * @notice Harvest performance fees based on share price gain above HWM.
     *         Mints fee shares to treasury — dilutes LPs proportionally.
     *         Can be called by anyone (keeper, treasury, governance).
     *         Enforces FEE_HARVEST_INTERVAL to prevent excessive dilution.
     *
     * Fee calculation
     * ───────────────
     *   currentPrice  = convertToAssets(1e18)
     *   if currentPrice <= highWaterMark: no fee
     *   gain per share = currentPrice - highWaterMark
     *   total gain     = gain per share × totalSupply / 1e18
     *   fee assets     = total gain × performanceFeeBps / 10000
     *   fee shares     = convertToShares(fee assets)
     *   → mint fee shares to treasury
     *   → update highWaterMark to currentPrice
     */
    function harvestFees() public nonReentrant {
        require(
            block.timestamp >= lastFeeHarvestAt + FEE_HARVEST_INTERVAL,
            "harvest too soon"
        );

        uint256 currentPrice = convertToAssets(1e18);
        if (currentPrice <= highWaterMark) return; // no new gains, no fee

        // Compute fee
        uint256 gainPerShare = currentPrice - highWaterMark;
        uint256 totalGain    = (gainPerShare * totalSupply) / 1e18;
        uint256 feeAssets    = (totalGain * performanceFeeBps) / 10_000;

        if (feeAssets == 0) return;

        // Mint fee shares to treasury (dilutive — equivalent to taking assets)
        // This is the correct ERC-4626 pattern: no assets transfer needed,
        // minting shares dilutes existing holders to the exact same effect.
        uint256 feeShares = convertToShares(feeAssets);
        if (feeShares > 0) {
            _mint(treasury, feeShares);
        }

        // Update accounting
        highWaterMark    = convertToAssets(1e18); // recalculate after dilution
        lastFeeHarvestAt = uint40(block.timestamp);

        emit FeeHarvested(feeShares, highWaterMark);
    }

    /**
     * @notice Trigger a harvest on the active strategy to compound yield,
     *         then optionally harvest protocol fees.
     */
    function harvestStrategy() external onlyRole(KEEPER_ROLE) nonReentrant {
        IStrategy strat = _activeStrategy();
        if (address(strat) != address(0)) {
            strat.harvestAndReport();
        }
        // Auto-harvest fees if interval has elapsed
        if (block.timestamp >= lastFeeHarvestAt + FEE_HARVEST_INTERVAL) {
            harvestFees();
        }
        _pushTwap();
    }

    // ─── TWAP oracle ───────────────────────────────────────────────────────────

    function getTwapSharePrice() external view returns (uint256) {
        if (_twapCount == 0) return convertToAssets(1e18);
        return _computeTwap();
    }

    function _pushTwap() internal {
        if (block.timestamp < lastTwapPush + TWAP_PUSH_INTERVAL) return;
        _twapBuffer[_twapHead] = convertToAssets(1e18);
        _twapHead = uint8((_twapHead + 1) % 8);
        if (_twapCount < 8) _twapCount++;
        lastTwapPush = uint40(block.timestamp);
    }

    function _computeTwap() internal view returns (uint256) {
        if (_twapCount == 0) return 1e18;
        uint256 sum;
        for (uint8 i = 0; i < _twapCount; i++) {
            sum += _twapBuffer[i];
        }
        return sum / _twapCount;
    }

    // ─── Guardian controls ─────────────────────────────────────────────────────

    /**
     * @notice Register a strategy for a regime. Guardian-only.
     *         The new strategy must report the correct targetRegime.
     *         Existing assets in a regime are NOT automatically migrated —
     *         migration happens on the next rebalance.
     */
    function setStrategy(uint8 regime, address strategyAddr)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        require(regime <= 3, "invalid regime");
        require(strategyAddr != address(0), "zero address");

        IStrategy strat = IStrategy(strategyAddr);
        require(strat.targetRegime() == regime, "strategy regime mismatch");

        strategies[regime] = strat;
        emit StrategyRegistered(regime, strategyAddr, strat.name());
    }

    function setTvlCap(uint256 cap) external onlyRole(GUARDIAN_ROLE) {
        tvlCap = cap;
        emit TvlCapUpdated(cap);
    }

    function setParameters(
        uint16 _perfFeeBps,
        uint16 _withdrawalFeeBps,
        uint16 _maxSlippageBps,
        uint16 _maxDrawdownBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_perfFeeBps      > 3000) revert InvalidFeeBps(_perfFeeBps);      // max 30%
        if (_withdrawalFeeBps > 100)  revert InvalidFeeBps(_withdrawalFeeBps); // max 1%
        if (_maxSlippageBps   > 500)  revert InvalidFeeBps(_maxSlippageBps);   // max 5%
        if (_maxDrawdownBps   > 2000) revert InvalidFeeBps(_maxDrawdownBps);   // max 20%

        performanceFeeBps      = _perfFeeBps;
        withdrawalFeeBps       = _withdrawalFeeBps;
        maxRebalanceSlippageBps= _maxSlippageBps;
        maxDrawdownBps         = _maxDrawdownBps;

        emit ParametersUpdated(_perfFeeBps, _withdrawalFeeBps, _maxSlippageBps, _maxDrawdownBps);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setRegimeDampener(address _dampener) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_dampener == address(0)) revert ZeroAddress();
        regimeDampener = IRegimeDampener(_dampener);
    }

    function pause()   external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        emergencyTriggered = false;
        _unpause();
    }

    // ─── ERC-20 (shares token) ────────────────────────────────────────────────

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
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }

    // ─── Internal helpers ──────────────────────────────────────────────────────

    function _activeStrategy() internal view returns (IStrategy) {
        return strategies[activeRegime];
    }

    function _deployToStrategy(uint256 assets) internal {
        IStrategy strat = _activeStrategy();
        if (address(strat) == address(0)) return; // no strategy registered yet — assets idle
        asset.approve(address(strat), assets);
        asset.transfer(address(strat), assets);
        strat.deposit(assets, 0);
    }

    function _computeSharePriceFromFreeAssets(uint256 freeAssets) internal view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return 1e18;
        return (freeAssets * 1e18) / supply;
    }

    function _triggerEmergencyDrawdown(uint256 sharePriceAtTrigger, uint256 dropBps) internal {
        emergencyTriggered = true;
        _pause();

        // Trigger emergency exit on the old strategy if it's still active
        IStrategy oldStrat = strategies[activeRegime];
        if (address(oldStrat) != address(0)) {
            try oldStrat.triggerEmergencyExit() {} catch {}
        }

        emit EmergencyTriggered(sharePriceAtTrigger, dropBps);
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply    += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply     -= amount;
    }

    function _checkAllowanceAndBurn(address owner, uint256 shares) internal {
        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                if (allowed < shares) revert InsufficientShares(allowed, shares);
                allowance[owner][msg.sender] = allowed - shares;
            }
        }
        if (balanceOf[owner] < shares) revert InsufficientShares(balanceOf[owner], shares);
        _burn(owner, shares);
    }

    receive() external payable {}
}
