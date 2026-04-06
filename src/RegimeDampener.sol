// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  RegimeDampener
 * @notice Epoch-based circuit breaker that requires CONFIRMATION_THRESHOLD
 *         consecutive epochs of the same regime label before emitting a
 *         confirmed regime change and allowing the vault to rebalance.
 *
 * Architecture
 * ────────────
 * ┌─────────────────┐   pushRegime()   ┌──────────────────┐   onRegimeConfirmed()
 * │  Regime Oracle  │ ───────────────► │  RegimeDampener  │ ──────────────────────► Vault
 * └─────────────────┘                  └──────────────────┘
 *
 * The oracle calls pushRegime() every epoch. The dampener accumulates
 * confirmations. Only after CONFIRMATION_THRESHOLD consecutive identical
 * labels does it call the vault's rebalance hook and update confirmedRegime.
 *
 * Circuit breaker overrides
 * ─────────────────────────
 * Two hard overrides bypass the dampener entirely:
 *   1. forceConfirm()   — guardian multisig can force any regime immediately
 *   2. Volatility floor — if raw volatility feed exceeds CRISIS_VOL_THRESHOLD,
 *      the contract auto-confirms CRISIS regardless of epoch count.
 *
 * Roles
 * ─────
 *   ORACLE_ROLE   — address(es) authorised to call pushRegime()
 *   GUARDIAN_ROLE — multisig that can call forceConfirm() and pause/unpause
 *   DEFAULT_ADMIN — can grant/revoke roles (should be timelock)
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Interface the vault must implement to receive rebalance triggers.
interface IRAYPVault {
    function onRegimeConfirmed(uint8 newRegime, uint8 oldRegime) external;
}

contract RegimeDampener is AccessControl, Pausable {

    // ─── Roles ───────────────────────────────────────────────────────────────

    bytes32 public constant ORACLE_ROLE   = keccak256("ORACLE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ─── Regime enum ─────────────────────────────────────────────────────────

    uint8 public constant REGIME_NEUTRAL = 0;
    uint8 public constant REGIME_BULL    = 1;
    uint8 public constant REGIME_BEAR    = 2;
    uint8 public constant REGIME_CRISIS  = 3;

    uint8 public constant REGIME_COUNT   = 4;   // update if enum grows

    // ─── Dampening parameters ────────────────────────────────────────────────

    /// @notice Consecutive confirmations required before a regime change fires.
    uint8 public constant CONFIRMATION_THRESHOLD = 3;

    /// @notice Minimum seconds between any two epoch pushes (anti-spam).
    uint32 public constant MIN_EPOCH_INTERVAL = 1 hours;

    /// @notice Annualised-volatility scaled integer above which CRISIS is
    ///         auto-confirmed regardless of confirmation count.
    ///         Units: 1e18 == 100% annualised vol. Set to 2.5e18 == 250% vol.
    uint256 public constant CRISIS_VOL_THRESHOLD = 2.5e18;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice The last regime label the vault has been told to act on.
    uint8 public confirmedRegime;

    /// @notice The latest pending label pushed by the oracle.
    uint8 public pendingRegime;

    /// @notice How many consecutive epochs the pending label has appeared.
    uint8 public confirmationCount;

    /// @notice Timestamp of the last accepted pushRegime() call.
    uint40 public lastEpochTimestamp;

    /// @notice Total number of rebalances triggered (useful for monitoring).
    uint64 public rebalanceCount;

    /// @notice Vault contract that receives onRegimeConfirmed() callbacks.
    IRAYPVault public vault;

    // ─── Events ──────────────────────────────────────────────────────────────

    event RegimePushed(
        uint8 indexed label,
        uint8  confirmationCount,
        uint256 volatility,
        uint40  timestamp
    );

    event RegimeConfirmed(
        uint8 indexed newRegime,
        uint8 indexed oldRegime,
        uint8  confirmationsRequired,
        bool   forcedByGuardian,
        bool   triggeredByVolFloor
    );

    event PendingRegimeReset(
        uint8 stalePending,
        uint8 newPending
    );

    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error EpochTooSoon(uint40 nextAllowedAt);
    error InvalidRegimeLabel(uint8 label);
    error ZeroAddressVault();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _vault        Address of the RAYP vault (receives callbacks).
     * @param _oracle       Initial oracle address (granted ORACLE_ROLE).
     * @param _guardian     Multisig guardian (granted GUARDIAN_ROLE).
     * @param _admin        Timelock admin (granted DEFAULT_ADMIN_ROLE).
     * @param _initialRegime Starting confirmed regime label.
     */
    constructor(
        address _vault,
        address _oracle,
        address _guardian,
        address _admin,
        uint8   _initialRegime
    ) {
        if (_vault == address(0)) revert ZeroAddressVault();
        _validateLabel(_initialRegime);

        vault            = IRAYPVault(_vault);
        confirmedRegime  = _initialRegime;
        pendingRegime    = _initialRegime;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORACLE_ROLE,        _oracle);
        _grantRole(GUARDIAN_ROLE,      _guardian);
    }

    // ─── Oracle-facing ───────────────────────────────────────────────────────

    /**
     * @notice Called by the regime oracle once per epoch to report the current
     *         market regime label and the raw volatility reading.
     *
     * @param label      Regime enum value (0–3).
     * @param volatility Raw annualised-vol integer (1e18 == 100%).
     *
     * Behaviour
     * ─────────
     *  • Enforces MIN_EPOCH_INTERVAL to prevent oracle spam / replay.
     *  • If volatility ≥ CRISIS_VOL_THRESHOLD, instantly confirms CRISIS
     *    regardless of confirmation count (hard floor).
     *  • Otherwise accumulates confirmations for `label`:
     *      – If label matches pendingRegime, increment confirmationCount.
     *      – If label differs from pendingRegime, reset count to 1 and log
     *        PendingRegimeReset (signal to off-chain monitors).
     *  • Once confirmationCount reaches CONFIRMATION_THRESHOLD and label ≠
     *    confirmedRegime, emit RegimeConfirmed and call vault.onRegimeConfirmed.
     *  • No-op if the new confirmed label equals the current confirmedRegime.
     */
    function pushRegime(uint8 label, uint256 volatility)
        external
        onlyRole(ORACLE_ROLE)
        whenNotPaused
    {
        _validateLabel(label);

        // ── Rate-limit epochs ─────────────────────────────────────────────
        uint40 nextAllowed = lastEpochTimestamp + MIN_EPOCH_INTERVAL;
        if (block.timestamp < nextAllowed) {
            revert EpochTooSoon(nextAllowed);
        }
        lastEpochTimestamp = uint40(block.timestamp);

        // ── Hard volatility floor: auto-confirm CRISIS ────────────────────
        if (volatility >= CRISIS_VOL_THRESHOLD) {
            _confirmRegime(REGIME_CRISIS, false, true);
            emit RegimePushed(label, confirmationCount, volatility, uint40(block.timestamp));
            return;
        }

        // ── Accumulate confirmations ──────────────────────────────────────
        if (label == pendingRegime) {
            // Same label as last epoch — increment counter, guard overflow.
            if (confirmationCount < CONFIRMATION_THRESHOLD) {
                confirmationCount += 1;
            }
        } else {
            // Different label — reset and start fresh accumulation.
            emit PendingRegimeReset(pendingRegime, label);
            pendingRegime     = label;
            confirmationCount = 1;
        }

        emit RegimePushed(label, confirmationCount, volatility, uint40(block.timestamp));

        // ── Fire rebalance if threshold reached and regime actually changed ─
        if (
            confirmationCount >= CONFIRMATION_THRESHOLD &&
            pendingRegime     != confirmedRegime
        ) {
            _confirmRegime(pendingRegime, false, false);
        }
    }

    // ─── Guardian-facing ─────────────────────────────────────────────────────

    /**
     * @notice Force-confirm a regime immediately, bypassing the dampener.
     *         Restricted to GUARDIAN_ROLE (multisig).
     *         Intended for genuine emergencies — e.g. oracle is lagging
     *         during a fast-moving crisis.
     *
     * @param label Regime to force-confirm.
     */
    function forceConfirm(uint8 label)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        _validateLabel(label);
        _confirmRegime(label, true, false);
    }

    /**
     * @notice Pause the dampener — halts pushRegime() calls.
     *         Does NOT halt forceConfirm() so guardians retain emergency power.
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpause the dampener.
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /**
     * @notice Update the vault address. Restricted to DEFAULT_ADMIN_ROLE.
     * @param _vault New vault address.
     */
    function setVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddressVault();
        emit VaultUpdated(address(vault), _vault);
        vault = IRAYPVault(_vault);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Returns how many more confirmations are needed before the
     *         current pending regime would trigger a rebalance.
     */
    function confirmationsRemaining() external view returns (uint8) {
        if (pendingRegime == confirmedRegime) return 0;
        if (confirmationCount >= CONFIRMATION_THRESHOLD) return 0;
        return CONFIRMATION_THRESHOLD - confirmationCount;
    }

    /**
     * @notice Human-readable label for a regime uint.
     */
    function regimeLabel(uint8 r) external pure returns (string memory) {
        if (r == REGIME_NEUTRAL) return "NEUTRAL";
        if (r == REGIME_BULL)    return "BULL";
        if (r == REGIME_BEAR)    return "BEAR";
        if (r == REGIME_CRISIS)  return "CRISIS";
        return "UNKNOWN";
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /**
     * @dev Executes a confirmed regime transition:
     *      1. Updates confirmedRegime.
     *      2. Resets confirmationCount and aligns pendingRegime.
     *      3. Increments rebalanceCount.
     *      4. Emits RegimeConfirmed.
     *      5. Calls vault.onRegimeConfirmed() — external call last (CEI pattern).
     */
    function _confirmRegime(
        uint8 newRegime,
        bool  forcedByGuardian,
        bool  triggeredByVolFloor
    ) internal {
        uint8 oldRegime  = confirmedRegime;

        // Update state before external call (CEI).
        confirmedRegime   = newRegime;
        pendingRegime     = newRegime;
        confirmationCount = CONFIRMATION_THRESHOLD; // saturate — already confirmed
        rebalanceCount   += 1;

        emit RegimeConfirmed(
            newRegime,
            oldRegime,
            CONFIRMATION_THRESHOLD,
            forcedByGuardian,
            triggeredByVolFloor
        );

        // External call — vault must not reenter pushRegime().
        vault.onRegimeConfirmed(newRegime, oldRegime);
    }

    /// @dev Reverts on any label outside the valid enum range.
    function _validateLabel(uint8 label) internal pure {
        if (label >= REGIME_COUNT) revert InvalidRegimeLabel(label);
    }
}
