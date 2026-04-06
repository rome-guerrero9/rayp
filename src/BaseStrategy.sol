// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IStrategy.sol";

/**
 * @title  BaseStrategy
 * @notice Abstract base contract every RAYP strategy inherits.
 *         Implements all boilerplate — access control, state machine,
 *         health check scaffolding, harvest retry logic — so concrete
 *         strategy implementations only write the yield-specific logic.
 *
 * Concrete strategy authors implement FIVE functions:
 * ───────────────────────────────────────────────────
 *   _deploy(assets)          → deploy assets into the underlying protocol
 *   _liquidate(assets)       → withdraw a specific amount from the protocol
 *   _liquidateAll()          → exit the entire position, return net assets
 *   _harvestRewards()        → claim + swap rewards back to underlying
 *   _checkProtocolHealth()   → protocol-specific health assertions
 *
 * Everything else is handled here.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

abstract contract BaseStrategy is IStrategy {

    // ─── Immutables ───────────────────────────────────────────────────────────

    address public immutable override asset;
    address public immutable override vault;
    uint8   public immutable override targetRegime;

    // ─── State ────────────────────────────────────────────────────────────────

    StrategyState public override state;
    address       public guardian;

    uint40  public override lastHarvestTimestamp;
    uint8   private _consecutiveHealthFailures;

    // Auto-emergency: trigger if healthCheck fails this many times in a row.
    uint8 public constant MAX_CONSECUTIVE_HEALTH_FAILURES = 2;

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian(msg.sender);
        _;
    }

    modifier onlyActive() {
        if (state != StrategyState.ACTIVE) revert StrategyNotActive(state);
        _;
    }

    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _asset,
        address _vault,
        address _guardian,
        uint8   _targetRegime
    ) {
        if (_targetRegime > 3) revert InvalidRegime(_targetRegime);
        asset        = _asset;
        vault        = _vault;
        guardian     = _guardian;
        targetRegime = _targetRegime;
        state        = StrategyState.ACTIVE;
    }

    // ─── IStrategy: deposit ───────────────────────────────────────────────────

    /**
     * @inheritdoc IStrategy
     * @dev Enforces: vault-only, active-only, non-zero, slippage check.
     *      Calls _deploy() for protocol-specific logic.
     */
    function deposit(uint256 assets, uint256 minDeployedOut)
        external
        override
        onlyVault
        onlyActive
        nonZero(assets)
        returns (uint256 deployedTotal)
    {
        // Assets already transferred by vault (push pattern)
        uint256 balanceBefore = _underlyingBalance();

        deployedTotal = _deploy(assets);

        // Slippage check: deployed value must meet minimum
        if (deployedTotal < minDeployedOut) {
            revert SlippageExceeded(deployedTotal, minDeployedOut);
        }

        emit Deposited(assets, deployedTotal);
    }

    // ─── IStrategy: withdraw ──────────────────────────────────────────────────

    /**
     * @inheritdoc IStrategy
     * @dev Enforces: vault-only, sufficient assets, slippage check.
     *      Calls _liquidate() for protocol-specific logic.
     */
    function withdraw(uint256 assets, address recipient, uint256 minAssetsOut)
        external
        override
        onlyVault
        nonZero(assets)
        returns (uint256 assetsOut)
    {
        uint256 available = totalAssets();
        if (assets > available) revert InsufficientAssets(assets, available);

        assetsOut = _liquidate(assets);

        if (assetsOut < minAssetsOut) {
            revert SlippageExceeded(assetsOut, minAssetsOut);
        }

        // Transfer to recipient
        IERC20(asset).transfer(recipient, assetsOut);

        uint256 slippageBps = assets > assetsOut
            ? ((assets - assetsOut) * 10_000) / assets
            : 0;

        emit Withdrawn(assets, assetsOut, slippageBps);
    }

    // ─── IStrategy: withdrawAll ───────────────────────────────────────────────

    /**
     * @inheritdoc IStrategy
     * @dev Enforces: vault-only, slippage check.
     *      Callable even in EMERGENCY_EXIT state (INV-4).
     *      Calls _liquidateAll() for protocol-specific logic.
     */
    function withdrawAll(address recipient, uint256 minAssetsOut)
        external
        override
        onlyVault
        returns (uint256 assetsOut)
    {
        // Allow withdrawAll even in EMERGENCY_EXIT — it's the escape hatch
        if (state == StrategyState.ACTIVE || state == StrategyState.WIND_DOWN ||
            state == StrategyState.EMERGENCY_EXIT) {
            assetsOut = _liquidateAll();
        } else {
            return 0;
        }

        if (assetsOut < minAssetsOut) {
            revert SlippageExceeded(assetsOut, minAssetsOut);
        }

        // Transfer all assets to recipient
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal > 0) IERC20(asset).transfer(recipient, bal);
        assetsOut = bal;

        uint256 reported = totalAssets();
        // INV-3: totalAssets() must be 0 after full exit
        // (implementations must ensure _liquidateAll leaves nothing behind)

        emit Withdrawn(type(uint256).max, assetsOut, 0);
    }

    // ─── IStrategy: harvestAndReport ──────────────────────────────────────────

    /**
     * @inheritdoc IStrategy
     * @dev INV-5: never reverts. Harvest failures are caught and emitted.
     *      Calls _harvestRewards() for protocol-specific reward logic.
     */
    function harvestAndReport()
        external
        override
        onlyVault
        returns (uint256 assetsAfterHarvest)
    {
        try this._harvestRewardsExternal() returns (uint256 yieldHarvested) {
            lastHarvestTimestamp = uint40(block.timestamp);
            assetsAfterHarvest   = totalAssets();
            emit Harvested(yieldHarvested, assetsAfterHarvest, uint40(block.timestamp));
        } catch (bytes memory reason) {
            // Harvest failed — report current state without updating timestamp
            assetsAfterHarvest = totalAssets();
            emit HarvestFailed(reason);
        }
    }

    /**
     * @notice External wrapper for _harvestRewards — enables try/catch in
     *         harvestAndReport(). Not callable externally (enforced by access
     *         control in the implementing contract or via onlySelf).
     */
    function _harvestRewardsExternal() external returns (uint256 yieldHarvested) {
        require(msg.sender == address(this), "only self");
        return _harvestRewards();
    }

    // ─── IStrategy: healthCheck ───────────────────────────────────────────────

    /**
     * @inheritdoc IStrategy
     * @dev Runs base checks then delegates to _checkProtocolHealth().
     *      Tracks consecutive failures and auto-triggers EMERGENCY_EXIT.
     */
    function healthCheck()
        external
        override
        returns (bool healthy, string memory reason)
    {
        // Base check 1: state machine sanity
        if (state == StrategyState.EMERGENCY_EXIT) {
            return (false, "strategy in emergency exit");
        }

        // Base check 2: totalAssets() is callable and non-reverting
        uint256 assets;
        try this._safeTotalAssets() returns (uint256 a) {
            assets = a;
        } catch {
            _recordHealthFailure("totalAssets() reverted");
            return (false, "totalAssets() reverted");
        }

        // Protocol-specific health checks
        (healthy, reason) = _checkProtocolHealth();

        if (!healthy) {
            _recordHealthFailure(reason);
            emit HealthWarning(reason, assets, uint40(block.timestamp));
            return (false, reason);
        }

        // All passed — reset failure counter
        _consecutiveHealthFailures = 0;
        return (true, "");
    }

    // Public wrapper for try/catch
    function _safeTotalAssets() external view returns (uint256) {
        return totalAssets();
    }

    function _recordHealthFailure(string memory reason) private {
        _consecutiveHealthFailures++;
        emit HealthWarning(reason, 0, uint40(block.timestamp));

        if (_consecutiveHealthFailures >= MAX_CONSECUTIVE_HEALTH_FAILURES) {
            _transitionState(StrategyState.EMERGENCY_EXIT);
        }
    }

    // ─── IStrategy: guardian controls ────────────────────────────────────────

    /// @inheritdoc IStrategy
    function triggerEmergencyExit() external override onlyGuardian {
        _transitionState(StrategyState.EMERGENCY_EXIT);
    }

    /// @inheritdoc IStrategy
    function windDown() external override onlyGuardian {
        if (state == StrategyState.ACTIVE) {
            _transitionState(StrategyState.WIND_DOWN);
        }
    }

    // ─── IStrategy: default metadata implementations ──────────────────────────

    function targetLeverage() external view virtual override returns (uint256) {
        return 1e4; // 1x — override in leveraged strategies
    }

    function estimatedWithdrawalSlippageBps() external view virtual override returns (uint256) {
        return 30; // 0.30% default — override per strategy
    }

    function estimatedNetAssets() external view virtual override returns (uint256) {
        uint256 total = totalAssets();
        uint256 slippageBps = this.estimatedWithdrawalSlippageBps();
        return total - (total * slippageBps / 10_000);
    }

    function accruedYield() external view virtual override returns (uint256) {
        return 0; // Override in strategies that can estimate unrealised yield
    }

    // ─── Abstract: totalAssets (must be implemented by each strategy) ─────────

    function totalAssets() public view virtual override returns (uint256);

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _underlyingBalance() internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function _transitionState(StrategyState newState) internal {
        StrategyState old = state;
        state = newState;
        emit StateChanged(old, newState);
    }

    // ─── Abstract: implement in each strategy ─────────────────────────────────

    /**
     * @notice Deploy `assets` (already in this contract) into the yield protocol.
     * @return deployedTotal  Total value now deployed (previous + newly added).
     */
    function _deploy(uint256 assets) internal virtual returns (uint256 deployedTotal);

    /**
     * @notice Withdraw exactly `assets` worth from the protocol.
     *         Transfer the proceeds to address(this) (not to recipient yet —
     *         the base class handles the transfer).
     * @return assetsOut  Actual amount withdrawn (may differ from `assets`
     *                    due to slippage or rounding).
     */
    function _liquidate(uint256 assets) internal virtual returns (uint256 assetsOut);

    /**
     * @notice Fully exit all positions. Transfer everything back to
     *         address(this). Must leave totalAssets() == 0 afterward (INV-3).
     * @return assetsOut  Total underlying recovered from the position.
     */
    function _liquidateAll() internal virtual returns (uint256 assetsOut);

    /**
     * @notice Claim and compound all pending rewards back into the underlying.
     * @return yieldHarvested  Amount of underlying added from rewards.
     */
    function _harvestRewards() internal virtual returns (uint256 yieldHarvested);

    /**
     * @notice Protocol-specific health assertions.
     *         Return (false, reason) on any failure — never revert.
     */
    function _checkProtocolHealth() internal virtual returns (bool healthy, string memory reason);
}
