// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  KeeperRegistry
 * @notice Permissionless keeper authorization layer for RAYP.
 *         Any address may register as a keeper by staking ETH collateral.
 *         Only registered, active keepers may trigger vault rebalances.
 *         Misbehaving keepers are slashed; keepers who miss their window
 *         are flagged and can be ejected by governance.
 *
 * Architecture
 * ────────────
 *
 *   ┌────────────────┐  executeRebalance()  ┌──────────────────┐
 *   │     Keeper     │ ───────────────────► │  KeeperRegistry  │
 *   └────────────────┘                      └────────┬─────────┘
 *          ▲  earns keeperFee                        │ authorised?
 *          │                                         ▼
 *   ┌──────┴─────────┐                      ┌──────────────────┐
 *   │ Protocol Treas.│ ◄─────────────────── │   RAYP Vault     │
 *   └────────────────┘   onRebalance()      └──────────────────┘
 *
 * Keeper lifecycle
 * ────────────────
 *   register()       — stake ≥ MIN_STAKE, status = ACTIVE
 *   executeRebalance()— keeper calls this; registry validates, calls vault,
 *                       pays keeper fee from treasury, records last activity
 *   slash()          — guardian slashes a misbehaving keeper's stake
 *   deregister()     — keeper withdraws stake after UNBONDING_PERIOD
 *   ejectInactive()  — anyone can eject a keeper silent for > MAX_INACTIVITY
 *
 * MEV / sandwich protection
 * ─────────────────────────
 *   • Rebalances carry a `minSharesOut` slippage parameter the keeper must
 *     supply. The vault enforces it. If the rebalance is sandwiched and
 *     slippage exceeds the limit, the tx reverts — not the keeper's fault.
 *   • A per-block cooldown prevents multiple rebalance attempts in one block.
 *   • A global cooldown (MIN_REBALANCE_INTERVAL) prevents keeper spam.
 *
 * Roles
 * ─────
 *   GUARDIAN_ROLE  — can slash, pause, set fee parameters
 *   DEFAULT_ADMIN  — can set vault/treasury addresses (timelock)
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRAYPVault {
    /// @notice Called by the registry to execute a regime rebalance.
    /// @param minSharesOut Slippage floor — vault reverts if output < this.
    function executeRebalance(uint256 minSharesOut) external;
}

interface IProtocolTreasury {
    /// @notice Pay a keeper fee denominated in ETH from the treasury.
    function payKeeperFee(address keeper, uint256 amount) external;
}

contract KeeperRegistry is AccessControl, Pausable, ReentrancyGuard {

    // ─── Roles ───────────────────────────────────────────────────────────────

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ─── Keeper status enum ───────────────────────────────────────────────────

    enum KeeperStatus { UNREGISTERED, ACTIVE, UNBONDING, EJECTED }

    // ─── Parameters (immutable after construction, tunable via setters) ───────

    /// @notice Minimum ETH stake to register as a keeper.
    uint256 public minStake = 0.1 ether;

    /// @notice Fee paid to the keeper per successful rebalance (from treasury).
    uint256 public keeperFee = 0.005 ether;

    /// @notice Fraction of stake slashed on misbehaviour (basis points, 10000 = 100%).
    uint16 public slashBps = 5000; // 50%

    /// @notice Seconds a keeper must wait after requesting deregistration.
    uint40 public constant UNBONDING_PERIOD = 7 days;

    /// @notice Minimum seconds between any two successful rebalances globally.
    uint40 public constant MIN_REBALANCE_INTERVAL = 1 hours;

    /// @notice Seconds of silence after which a keeper can be ejected.
    uint40 public constant MAX_INACTIVITY = 30 days;

    /// @notice Maximum keepers in the active set (gas bound on iteration).
    uint16 public constant MAX_KEEPERS = 50;

    // ─── Keeper record ────────────────────────────────────────────────────────

    struct Keeper {
        uint256      stake;               // ETH staked (wei)
        uint256      totalRebalances;     // lifetime successful rebalances
        uint40       registeredAt;        // block.timestamp of registration
        uint40       lastRebalanceAt;     // timestamp of last successful rebalance
        uint40       unbondingStartedAt;  // timestamp of deregister() call
        KeeperStatus status;
    }

    // ─── State ───────────────────────────────────────────────────────────────

    mapping(address => Keeper) public keepers;
    address[]                  public keeperList;         // active keeper addresses

    IRAYPVault        public vault;
    IProtocolTreasury public treasury;

    /// @notice Timestamp of the last globally successful rebalance.
    uint40  public lastRebalanceAt;

    /// @notice Block number of the last rebalance attempt (anti-sandwich).
    uint256 public lastRebalanceBlock;

    /// @notice Running total of ETH held as keeper stakes.
    uint256 public totalStaked;

    /// @notice Accumulated slashed ETH available for guardian to sweep.
    uint256 public slashedFunds;

    // ─── Events ──────────────────────────────────────────────────────────────

    event KeeperRegistered(address indexed keeper, uint256 stake);
    event KeeperDeregisterRequested(address indexed keeper, uint40 unbondingEndsAt);
    event KeeperWithdrawn(address indexed keeper, uint256 stakeReturned);
    event KeeperSlashed(address indexed keeper, uint256 slashAmount, string reason);
    event KeeperEjected(address indexed keeper, string reason);
    event RebalanceExecuted(address indexed keeper, uint256 keeperFee, uint256 blockNumber);
    event RebalanceFailed(address indexed keeper, bytes reason);
    event ParametersUpdated(uint256 minStake, uint256 keeperFee, uint16 slashBps);
    event SlashedFundsSwept(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotActiveKeeper(address caller);
    error InsufficientStake(uint256 sent, uint256 required);
    error KeeperAlreadyRegistered(address keeper);
    error RegistryFull();
    error StillUnbonding(uint40 unbondingEndsAt);
    error NotUnbonding();
    error RebalanceCooldownActive(uint40 availableAt);
    error SameBlockRebalance(uint256 blockNumber);
    error ZeroAddress();
    error InvalidSlashBps();
    error WithdrawFailed();
    error NothingToSweep();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _vault,
        address _treasury,
        address _guardian,
        address _admin
    ) {
        if (_vault    == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        vault    = IRAYPVault(_vault);
        treasury = IProtocolTreasury(_treasury);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE,      _guardian);
    }

    // ─── Keeper registration ──────────────────────────────────────────────────

    /**
     * @notice Register as a keeper by staking ETH.
     *         msg.value must be ≥ minStake.
     *         Permissionless — anyone can become a keeper.
     */
    function register() external payable whenNotPaused nonReentrant {
        if (msg.value < minStake) revert InsufficientStake(msg.value, minStake);
        if (keepers[msg.sender].status == KeeperStatus.ACTIVE) {
            revert KeeperAlreadyRegistered(msg.sender);
        }
        if (keeperList.length >= MAX_KEEPERS) revert RegistryFull();

        keepers[msg.sender] = Keeper({
            stake:              msg.value,
            totalRebalances:    0,
            registeredAt:       uint40(block.timestamp),
            lastRebalanceAt:    0,
            unbondingStartedAt: 0,
            status:             KeeperStatus.ACTIVE
        });

        keeperList.push(msg.sender);
        totalStaked += msg.value;

        emit KeeperRegistered(msg.sender, msg.value);
    }

    /**
     * @notice Begin the unbonding process. After UNBONDING_PERIOD the keeper
     *         may call withdraw() to recover their stake.
     *         Status changes to UNBONDING and the keeper can no longer
     *         trigger rebalances.
     */
    function deregister() external nonReentrant {
        Keeper storage k = keepers[msg.sender];
        if (k.status != KeeperStatus.ACTIVE) revert NotActiveKeeper(msg.sender);

        k.status             = KeeperStatus.UNBONDING;
        k.unbondingStartedAt = uint40(block.timestamp);

        _removeFromList(msg.sender);

        emit KeeperDeregisterRequested(
            msg.sender,
            uint40(block.timestamp) + UNBONDING_PERIOD
        );
    }

    /**
     * @notice Withdraw staked ETH after UNBONDING_PERIOD has elapsed.
     */
    function withdraw() external nonReentrant {
        Keeper storage k = keepers[msg.sender];
        if (k.status != KeeperStatus.UNBONDING) revert NotUnbonding();

        uint40 unbondingEndsAt = k.unbondingStartedAt + UNBONDING_PERIOD;
        if (block.timestamp < unbondingEndsAt) revert StillUnbonding(unbondingEndsAt);

        uint256 stakeToReturn = k.stake;
        totalStaked          -= stakeToReturn;

        // Clear record before transfer (CEI).
        delete keepers[msg.sender];

        (bool ok,) = msg.sender.call{value: stakeToReturn}("");
        if (!ok) revert WithdrawFailed();

        emit KeeperWithdrawn(msg.sender, stakeToReturn);
    }

    // ─── Rebalance execution ──────────────────────────────────────────────────

    /**
     * @notice Execute a vault rebalance. Only callable by ACTIVE keepers.
     *
     * @param minSharesOut  Slippage protection — passed through to the vault.
     *                      Keeper is responsible for computing a safe value
     *                      off-chain. If the vault reverts (slippage exceeded),
     *                      the keeper is NOT penalised — that's expected behaviour.
     *
     * Guards applied in order:
     *   1. Caller must be ACTIVE keeper.
     *   2. Not paused.
     *   3. Global rebalance cooldown (MIN_REBALANCE_INTERVAL).
     *   4. Same-block guard (anti-sandwich: only one attempt per block).
     *   5. Vault call (may revert on slippage — not a keeper fault).
     *   6. Pay keeper fee from treasury.
     *   7. Record state.
     */
    function executeRebalance(uint256 minSharesOut)
        external
        whenNotPaused
        nonReentrant
    {
        // ── Guard 1: active keeper only ───────────────────────────────────
        if (keepers[msg.sender].status != KeeperStatus.ACTIVE) {
            revert NotActiveKeeper(msg.sender);
        }

        // ── Guard 2: global cooldown ──────────────────────────────────────
        uint40 availableAt = lastRebalanceAt + MIN_REBALANCE_INTERVAL;
        if (block.timestamp < availableAt) {
            revert RebalanceCooldownActive(availableAt);
        }

        // ── Guard 3: same-block anti-sandwich ─────────────────────────────
        if (block.number == lastRebalanceBlock) {
            revert SameBlockRebalance(block.number);
        }

        // ── Record block before external call (CEI) ───────────────────────
        lastRebalanceBlock = block.number;
        lastRebalanceAt    = uint40(block.timestamp);

        keepers[msg.sender].lastRebalanceAt   = uint40(block.timestamp);
        keepers[msg.sender].totalRebalances  += 1;

        // ── Execute vault rebalance (slippage revert is expected, not a slash) ─
        try vault.executeRebalance(minSharesOut) {
            // ── Pay keeper fee from treasury ──────────────────────────────
            try treasury.payKeeperFee(msg.sender, keeperFee) {} catch {}

            emit RebalanceExecuted(msg.sender, keeperFee, block.number);
        } catch (bytes memory reason) {
            // Revert cooldown and block guard on vault failure so keepers
            // can retry (e.g. with adjusted slippage) without waiting.
            lastRebalanceAt    = 0;
            lastRebalanceBlock = 0;
            keepers[msg.sender].totalRebalances -= 1;

            emit RebalanceFailed(msg.sender, reason);
            // Bubble the revert up so the keeper's tx shows the real error.
            assembly { revert(add(reason, 32), mload(reason)) }
        }
    }

    // ─── Guardian: slash and eject ────────────────────────────────────────────

    /**
     * @notice Slash a fraction of a keeper's stake for misbehaviour.
     *         Slashed ETH is held in `slashedFunds` for guardian to sweep.
     *         Keeper status is NOT changed — guardian decides next action.
     *
     * @param keeper  Address to slash.
     * @param reason  Human-readable reason (emitted, aids off-chain monitoring).
     */
    function slash(address keeper, string calldata reason)
        external
        onlyRole(GUARDIAN_ROLE)
        nonReentrant
    {
        Keeper storage k = keepers[keeper];
        if (k.status == KeeperStatus.UNREGISTERED) revert NotActiveKeeper(keeper);

        uint256 slashAmount = (k.stake * slashBps) / 10_000;
        k.stake      -= slashAmount;
        totalStaked  -= slashAmount;
        slashedFunds += slashAmount;

        emit KeeperSlashed(keeper, slashAmount, reason);
    }

    /**
     * @notice Eject a keeper whose stake has dropped below minStake after
     *         slashing, or who has been inactive for > MAX_INACTIVITY.
     *         Remaining stake is added to slashedFunds.
     *         Callable by anyone for inactive ejection; guardian only for
     *         under-staked ejection.
     *
     * @param keeper  Keeper to eject.
     */
    function ejectInactive(address keeper) external nonReentrant {
        Keeper storage k = keepers[keeper];
        if (k.status != KeeperStatus.ACTIVE) revert NotActiveKeeper(keeper);

        bool inactivityBreach = (
            k.lastRebalanceAt > 0 &&
            block.timestamp - k.lastRebalanceAt > MAX_INACTIVITY
        ) || (
            k.lastRebalanceAt == 0 &&
            block.timestamp - k.registeredAt > MAX_INACTIVITY
        );

        bool underStaked = k.stake < minStake;

        // Non-guardian can only eject for inactivity.
        if (!inactivityBreach) {
            if (!underStaked) revert NotActiveKeeper(keeper); // no valid reason
            _checkRole(GUARDIAN_ROLE);                        // under-staked: guardian only
        }

        uint256 remaining = k.stake;
        totalStaked  -= remaining;
        slashedFunds += remaining;

        k.stake  = 0;
        k.status = KeeperStatus.EJECTED;
        _removeFromList(keeper);

        emit KeeperEjected(keeper, inactivityBreach ? "inactivity" : "under-staked");
    }

    /**
     * @notice Sweep accumulated slashed ETH to a recipient.
     *         Guardian only.
     */
    function sweepSlashedFunds(address to)
        external
        onlyRole(GUARDIAN_ROLE)
        nonReentrant
    {
        if (slashedFunds == 0) revert NothingToSweep();
        if (to == address(0))  revert ZeroAddress();

        uint256 amount = slashedFunds;
        slashedFunds   = 0;

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();

        emit SlashedFundsSwept(to, amount);
    }

    // ─── Parameter setters (guardian) ─────────────────────────────────────────

    /**
     * @notice Update fee and stake parameters.
     * @param _minStake   New minimum stake in wei.
     * @param _keeperFee  New per-rebalance fee in wei.
     * @param _slashBps   New slash fraction in basis points (max 10000).
     */
    function setParameters(
        uint256 _minStake,
        uint256 _keeperFee,
        uint16  _slashBps
    ) external onlyRole(GUARDIAN_ROLE) {
        if (_slashBps > 10_000) revert InvalidSlashBps();
        minStake  = _minStake;
        keeperFee = _keeperFee;
        slashBps  = _slashBps;
        emit ParametersUpdated(_minStake, _keeperFee, _slashBps);
    }

    function pause()   external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(GUARDIAN_ROLE) { _unpause(); }

    // ─── Admin setters (timelock) ─────────────────────────────────────────────

    function setVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        vault = IRAYPVault(_vault);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = IProtocolTreasury(_treasury);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Returns all currently active keeper addresses.
    function activeKeepers() external view returns (address[] memory) {
        return keeperList;
    }

    /// @notice Returns true if address is an active, sufficiently-staked keeper.
    function isAuthorizedKeeper(address addr) external view returns (bool) {
        Keeper storage k = keepers[addr];
        return k.status == KeeperStatus.ACTIVE && k.stake >= minStake;
    }

    /// @notice Seconds until the global rebalance cooldown expires.
    function cooldownRemaining() external view returns (uint40) {
        uint40 available = lastRebalanceAt + MIN_REBALANCE_INTERVAL;
        if (block.timestamp >= available) return 0;
        return available - uint40(block.timestamp);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @dev O(n) removal from keeperList. MAX_KEEPERS = 50 keeps this safe.
    function _removeFromList(address keeper) internal {
        uint256 len = keeperList.length;
        for (uint256 i = 0; i < len; i++) {
            if (keeperList[i] == keeper) {
                keeperList[i] = keeperList[len - 1];
                keeperList.pop();
                return;
            }
        }
    }

    /// @dev Accept ETH from treasury fee-payouts and stake deposits.
    receive() external payable {}
}
