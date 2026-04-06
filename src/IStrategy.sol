// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IStrategy
 * @notice The canonical interface every RAYP yield strategy must implement.
 *
 * @dev    Design philosophy
 *         ─────────────────
 *         The vault is a router. It holds assets and delegates all yield logic
 *         to pluggable strategy contracts - one per regime. The vault never
 *         knows HOW a strategy earns yield, only:
 *           1. How to move assets in  → deposit()
 *           2. How to move assets out → withdraw() / withdrawAll()
 *           3. What those assets are worth now → totalAssets()
 *           4. Whether this strategy is healthy → healthCheck()
 *
 *         Everything else - leverage, LP positions, staking mechanics,
 *         reward compounding - is the strategy's private concern.
 *
 *         Invariants the vault relies on (must never be violated)
 *         ─────────────────────────────────────────────────────────
 *         INV-1: totalAssets() is monotonically non-decreasing between
 *                vault interactions in normal operation (yield accrual only
 *                increases it; slippage on deposit/withdraw is the exception).
 *
 *         INV-2: withdraw(n) delivers exactly `assetsOut` assets to the vault
 *                in the same transaction - no async settlement.
 *
 *         INV-3: withdrawAll() empties the strategy completely. After a
 *                successful withdrawAll(), totalAssets() MUST return 0.
 *
 *         INV-4: A strategy in EMERGENCY_EXIT state MUST accept withdrawAll()
 *                and MUST reject deposit().
 *
 *         INV-5: harvestAndReport() must never revert in normal operation.
 *                Harvest failures are swallowed and reported via HarvestFailed.
 *
 *         Regime labels (must match RegimeDampener constants)
 *         ────────────────────────────────────────────────────
 *         0 = NEUTRAL   Balanced / ranging market
 *         1 = BULL      Risk-on, trending upward
 *         2 = BEAR      Capital preservation
 *         3 = CRISIS    Stablecoin-only, maximum safety
 */
interface IStrategy {

    // ─── Enums ────────────────────────────────────────────────────────────────

    /**
     * @notice Lifecycle state of the strategy.
     *
     *   ACTIVE        Normal operation. Accepts deposits, earns yield.
     *   WIND_DOWN     Governance deprecated this strategy. Rejects new deposits
     *                 but processes withdrawals. Vault will migrate away on
     *                 next rebalance.
     *   EMERGENCY_EXIT All new deposits rejected. withdrawAll() must succeed.
     *                 Triggered automatically if healthCheck() fails twice
     *                 consecutively, or manually by guardian.
     */
    enum StrategyState { ACTIVE, WIND_DOWN, EMERGENCY_EXIT }

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotVault(address caller);
    error NotGuardian(address caller);
    error StrategyNotActive(StrategyState current);
    error InsufficientAssets(uint256 requested, uint256 available);
    error SlippageExceeded(uint256 received, uint256 minimum);
    error HealthCheckFailed(string reason);
    error ZeroAmount();
    error InvalidRegime(uint8 regime);

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when the vault deposits assets into this strategy.
    event Deposited(uint256 assets, uint256 deployedTotal);

    /// @notice Emitted when the vault withdraws assets from this strategy.
    event Withdrawn(uint256 assetsRequested, uint256 assetsDelivered, uint256 slippageBps);

    /// @notice Emitted on a successful harvest - reports yield generated.
    event Harvested(uint256 yieldAssets, uint256 totalAssetsAfter, uint40 timestamp);

    /// @notice Emitted when harvest fails - vault continues normally.
    event HarvestFailed(bytes reason);

    /// @notice Emitted when the strategy's lifecycle state changes.
    event StateChanged(StrategyState oldState, StrategyState newState);

    /// @notice Emitted when healthCheck() detects an anomaly (non-reverting).
    event HealthWarning(string reason, uint256 totalAssets, uint40 timestamp);

    // ─── Metadata (view, no state change) ────────────────────────────────────

    /**
     * @notice Human-readable strategy name for monitoring dashboards.
     * @return e.g. "RAYP Bull Strategy - stETH leveraged yield"
     */
    function name() external view returns (string memory);

    /**
     * @notice The regime label this strategy is designed for.
     *         Must match one of the RegimeDampener regime constants.
     * @return regime 0=NEUTRAL, 1=BULL, 2=BEAR, 3=CRISIS
     */
    function targetRegime() external view returns (uint8 regime);

    /**
     * @notice The ERC-20 token this strategy accepts as input and returns
     *         on withdrawal. Must match RAYPVault.asset().
     * @return The underlying asset address (e.g. WETH, USDC).
     */
    function asset() external view returns (address);

    /**
     * @notice The RAYPVault contract address. Only the vault may call
     *         deposit(), withdraw(), withdrawAll(), and harvestAndReport().
     */
    function vault() external view returns (address);

    /**
     * @notice Current lifecycle state of the strategy.
     */
    function state() external view returns (StrategyState);

    /**
     * @notice Target leverage ratio, expressed as 1e4 = 1x.
     *         Non-leveraged strategies return 1e4.
     *         Leveraged strategies return e.g. 3e4 for 3x.
     *         Used by the vault to model drawdown risk during crisis transitions.
     */
    function targetLeverage() external view returns (uint256);

    /**
     * @notice Expected slippage on a full withdrawal, in basis points.
     *         The vault uses this to set minAssetsOut on withdrawAll().
     *         Must be a conservative (high) estimate - better to over-estimate
     *         than to have a withdrawal revert mid-rebalance.
     * @return bps  e.g. 30 = 0.30% expected slippage on exit
     */
    function estimatedWithdrawalSlippageBps() external view returns (uint256 bps);

    // ─── Accounting (view, no state change) ──────────────────────────────────

    /**
     * @notice Total value of assets deployed in this strategy, denominated
     *         in the underlying asset (1e18 = 1 token).
     *
     * @dev    This is the most-called function in the system. It must be:
     *           - Accurate: reflects unrealised P&L from underlying positions
     *           - Cheap: avoid redundant external calls; cache where safe
     *           - Non-reverting: returns 0 if underlying protocol is bricked,
     *             never throws (the vault handles 0 gracefully via healthCheck)
     *
     *         For strategies with on-chain pricing (e.g. Aave aTokens),
     *         this is a simple balance read. For strategies with off-chain
     *         pricing (e.g. Uniswap v3 positions), use the on-chain TWAP.
     *         Never use spot price from a single low-liquidity pool.
     *
     * @return assets  Current fair value of all deployed assets.
     */
    function totalAssets() external view returns (uint256 assets);

    /**
     * @notice Estimated assets returned if the entire strategy was exited
     *         right now, net of slippage and exit fees.
     *         Must be ≤ totalAssets() by definition.
     *         Used by the vault for pre-rebalance slippage modelling.
     * @return netAssets  totalAssets() minus estimated exit costs.
     */
    function estimatedNetAssets() external view returns (uint256 netAssets);

    /**
     * @notice Unrealised yield accrued since the last harvest, denominated
     *         in the underlying asset.
     *         Returns 0 if no yield has accrued or if estimation is not
     *         feasible (the vault does not rely on this for accounting).
     * @return yield  Accrued but unharvested yield.
     */
    function accruedYield() external view returns (uint256 yield);

    /**
     * @notice Unix timestamp of the most recent successful harvest.
     *         Returns 0 if the strategy has never been harvested.
     */
    function lastHarvestTimestamp() external view returns (uint40);

    // ─── Vault-only actions ───────────────────────────────────────────────────

    /**
     * @notice Deposit `assets` into this strategy and begin earning yield.
     *         Called by the vault during a rebalance into this strategy's regime.
     *
     * @dev    Guards required in implementation:
     *           - msg.sender == vault
     *           - state == ACTIVE (revert if WIND_DOWN or EMERGENCY_EXIT)
     *           - assets > 0
     *           - Asset transfer must have already occurred (vault sends
     *             assets before calling deposit, pull-pattern not supported)
     *
     * @param  assets        Amount of underlying asset already transferred
     *                       to this contract before this call.
     * @param  minDeployedOut Minimum acceptable deployed value after entry
     *                       (slippage protection for entry costs / LP fees).
     *                       Revert if actualDeployed < minDeployedOut.
     * @return deployedTotal  Total assets now deployed in the strategy
     *                       (previous balance + newly deployed, net of entry costs).
     */
    function deposit(uint256 assets, uint256 minDeployedOut)
        external
        returns (uint256 deployedTotal);

    /**
     * @notice Withdraw exactly `assets` worth of underlying from the strategy
     *         and transfer them to `recipient`.
     *         Called by the vault for partial withdrawals (LP exits, partial
     *         regime shifts) where a precise amount is needed.
     *
     * @dev    Guards required in implementation:
     *           - msg.sender == vault
     *           - assets <= totalAssets() (revert InsufficientAssets if not)
     *           - Slippage check: assetsOut >= minAssetsOut
     *           - Transfer underlying to recipient before returning
     *
     *         Note: `assets` is a target, not a guarantee. The strategy withdraws
     *         the closest feasible amount and reports what was actually delivered.
     *         The vault reconciles via `assetsOut`.
     *
     * @param  assets       Target withdrawal amount in underlying.
     * @param  recipient    Address to receive the withdrawn underlying.
     * @param  minAssetsOut Minimum acceptable delivery (slippage floor).
     *                      Revert if actual delivery < minAssetsOut.
     * @return assetsOut    Actual underlying amount transferred to recipient.
     */
    function withdraw(uint256 assets, address recipient, uint256 minAssetsOut)
        external
        returns (uint256 assetsOut);

    /**
     * @notice Exit the strategy completely. Liquidate all positions, convert
     *         all holdings to the underlying asset, and transfer everything
     *         to `recipient`.
     *         Called by the vault during a full regime rebalance or emergency.
     *
     * @dev    Guards required in implementation:
     *           - msg.sender == vault
     *           - Slippage check: assetsOut >= minAssetsOut
     *           - After this call, totalAssets() MUST return 0 (INV-3)
     *           - Must succeed even in EMERGENCY_EXIT state (INV-4)
     *           - For leveraged strategies: unwind leverage before liquidating
     *
     *         The `minAssetsOut` passed by the vault is computed as:
     *           estimatedNetAssets() × (10000 - maxSlippageBps) / 10000
     *         where maxSlippageBps comes from the registry + guardian config.
     *
     * @param  recipient    Address to receive all withdrawn underlying.
     * @param  minAssetsOut Slippage floor for the full exit.
     * @return assetsOut    Total underlying transferred to recipient.
     */
    function withdrawAll(address recipient, uint256 minAssetsOut)
        external
        returns (uint256 assetsOut);

    /**
     * @notice Compound all accrued yield back into the strategy position and
     *         report the current totalAssets() to the vault.
     *         Called by the vault (or an authorised keeper) on a regular schedule.
     *
     * @dev    Implementation requirements:
     *           - msg.sender == vault OR has HARVESTER_ROLE
     *           - Must NOT revert on harvest failure - catch internally and
     *             emit HarvestFailed(reason). Return current totalAssets() even
     *             if harvest failed (INV-5).
     *           - Update lastHarvestTimestamp on success
     *           - Emit Harvested on success, HarvestFailed on failure
     *
     * @return assetsAfterHarvest  totalAssets() after compounding.
     *                             Equals pre-harvest value if harvest failed.
     */
    function harvestAndReport() external returns (uint256 assetsAfterHarvest);

    // ─── Health and safety ────────────────────────────────────────────────────

    /**
     * @notice Run a suite of internal health checks and return a pass/fail.
     *         Called by the vault before every rebalance to confirm the
     *         strategy being exited is in a withdrawable state.
     *         Also called by off-chain monitoring on a regular schedule.
     *
     * @dev    Checks to implement (strategy-specific; include all that apply):
     *           - Position LTV is within safe bounds (leveraged strategies)
     *           - Underlying protocol (Aave, Curve) is not paused
     *           - totalAssets() > 0 if assets were deposited
     *           - No unexpected token shortfalls (balance vs accounting)
     *           - Oracle price is not stale / circuit-broken
     *
     *         Must NOT revert - return (false, reason) instead.
     *         Emits HealthWarning on failure.
     *
     * @return healthy  True if all checks pass; false if any check fails.
     * @return reason   Human-readable failure description, empty if healthy.
     */
    function healthCheck() external returns (bool healthy, string memory reason);

    // ─── Guardian controls ────────────────────────────────────────────────────

    /**
     * @notice Transition the strategy to EMERGENCY_EXIT state.
     *         Callable only by the guardian multisig.
     *         After this call:
     *           - deposit() reverts
     *           - withdrawAll() remains callable by vault
     *           - state() returns EMERGENCY_EXIT
     *
     *         The vault detects EMERGENCY_EXIT via state() and immediately
     *         triggers an emergency rebalance to the crisis strategy.
     */
    function triggerEmergencyExit() external;

    /**
     * @notice Wind down the strategy gracefully (no new deposits, drain on
     *         next rebalance). Softer than EMERGENCY_EXIT - used when
     *         governance deprecates a strategy after a governance vote.
     */
    function windDown() external;
}
