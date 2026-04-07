// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  OracleAggregator
 * @notice Four-layer validated oracle pipeline that feeds the RAYP regime
 *         classifier. Reads Chainlink and Pyth in parallel, validates each
 *         source independently, enforces cross-source consensus, and outputs
 *         TWAP-smoothed composite data.
 *
 * Data flow (matches architecture diagram)
 * ─────────────────────────────────────────
 *  Layer 1 — Raw feeds
 *    Chainlink: AggregatorV3 (price, realised vol, funding rate)
 *    Pyth:      IPyth pull oracle (price + confidence interval)
 *    Stablecoin: on-chain dominance ratio via a simple ERC-20 supply reader
 *
 *  Layer 2 — Per-source validation
 *    Chainlink: staleness check (updatedAt ≤ 2× heartbeat)
 *    Pyth:      conf/price ratio ≤ MAX_PYTH_CONF_BPS (0.5%)
 *    Both:      sanity range gate (price between floor and ceiling)
 *
 *  Layer 3 — Cross-source consensus
 *    Price divergence:   |chainlinkPrice - pythPrice| / avg ≤ PRICE_DIVERGE_BPS (2%)
 *    Vol divergence:     |chainlinkVol - pythVol|   / avg ≤ VOL_DIVERGE_BPS   (5%)
 *    On failure: pause rebalances, emit OracleDiverged for off-chain monitoring
 *
 *  Layer 4 — TWAP ring buffer + output
 *    8-slot circular buffer accumulates validated vol readings each epoch
 *    Outputs a 1-hour smoothed vol to protect against single-block manipulation
 *    Final composite struct passed to RegimeDampener.pushRegime()
 *
 * Failure modes and their handling
 * ──────────────────────────────────
 *   Stale Chainlink      → revert; rebalances cannot proceed
 *   Pyth conf too wide   → revert; treat as stale
 *   Price divergence     → revert + emit + set divergenceActive flag
 *   Vol divergence       → emit warning; use Chainlink vol with penalty flag
 *   Range gate breach    → revert; implausible data rejected
 *   Full oracle failure  → guardian can forceSetEmergencyVol for manual override
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// ── Chainlink interfaces ──────────────────────────────────────────────────────

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    );
    function decimals() external view returns (uint8);
}

// ── Pyth interface (minimal) ──────────────────────────────────────────────────

struct PythPrice {
    int64  price;       // price with `expo` decimal places
    uint64 conf;        // confidence interval (same exponent)
    int32  expo;        // 10^expo scaling factor
    uint   publishTime; // unix timestamp
}

interface IPyth {
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (PythPrice memory);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);
}

// ── Output struct passed to the regime classifier ─────────────────────────────

struct OracleSnapshot {
    uint256 price;          // ETH/USD spot, 18 decimals (1e18 == $1)
    uint256 smoothedVol;    // 1-hr TWAP annualised vol, 1e18 == 100%
    int256  fundingRate;    // perp funding rate, 1e18 == 100% (can be negative)
    uint256 stableDominance;// stablecoin dominance ratio, 1e18 == 100%
    uint40  timestamp;      // block.timestamp of this snapshot
    bool    volPenaltyFlag; // true if vol consensus failed; classifier should widen thresholds
}

contract OracleAggregator is AccessControl, Pausable {

    // ─── Roles ────────────────────────────────────────────────────────────────

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant UPDATER_ROLE  = keccak256("UPDATER_ROLE");  // can push Pyth updates

    // ─── Consensus thresholds ─────────────────────────────────────────────────

    uint256 public constant PRICE_DIVERGE_BPS   = 200;   // 2%
    uint256 public constant VOL_DIVERGE_BPS      = 500;   // 5%
    uint256 public constant MAX_PYTH_CONF_BPS    = 50;    // 0.5% max conf/price ratio
    uint256 public constant FUNDING_DIVERGE_BPS  = 1000;  // 10% — wider tolerance for funding

    // ─── Staleness parameters ─────────────────────────────────────────────────

    uint256 public constant CHAINLINK_PRICE_HEARTBEAT = 3600;  // 1 hr
    uint256 public constant CHAINLINK_VOL_HEARTBEAT   = 3600;
    uint256 public constant CHAINLINK_FUNDING_HEARTBEAT = 3600;
    uint256 public constant PYTH_MAX_AGE              = 120;   // 2 min (Pyth is push-model)
    uint256 public constant STALENESS_MULTIPLIER      = 2;     // allow up to 2× heartbeat

    // ─── Sanity range gates (ETH/USD) ─────────────────────────────────────────

    uint256 public constant PRICE_FLOOR   = 100e18;       // $100
    uint256 public constant PRICE_CEILING = 1_000_000e18; // $1,000,000
    uint256 public constant VOL_FLOOR     = 1e16;          // 1% min (not zero)
    uint256 public constant VOL_CEILING   = 100e18;        // 10000% max

    // ─── TWAP ring buffer ─────────────────────────────────────────────────────

    uint8  public constant TWAP_SLOTS  = 8;
    uint40 public constant TWAP_WINDOW = 1 hours;

    struct TwapSlot {
        uint256 vol;
        uint40  timestamp;
    }

    TwapSlot[8] private _volBuffer;
    uint8       private _bufHead;      // index of next write slot
    uint8       private _bufCount;     // how many slots are populated

    // ─── Chainlink feed config ────────────────────────────────────────────────

    struct ChainlinkFeed {
        AggregatorV3Interface feed;
        uint256 heartbeat;       // expected update interval in seconds
        uint8   feedDecimals;    // cached from feed.decimals()
    }

    ChainlinkFeed public clPrice;
    ChainlinkFeed public clVol;
    ChainlinkFeed public clFunding;

    // ─── Pyth feed config ─────────────────────────────────────────────────────

    IPyth   public pyth;
    bytes32 public pythPriceId;   // e.g. ETH/USD price feed ID
    bytes32 public pythVolId;     // e.g. ETH realised vol feed ID (if available)

    // ─── Stablecoin dominance config ──────────────────────────────────────────

    // Simple approach: track total supply of USDC+USDT vs a reference (ETH mcap proxy)
    // In production replace with a proper on-chain dominance oracle
    address public stableToken;          // e.g. USDC
    uint256 public referenceMarketCapE18; // manually updated by guardian (e.g. ETH mcap $bn × 1e18)
    uint8   public stableDecimals;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Populated on the most recent successful getSnapshot() call.
    OracleSnapshot public lastSnapshot;

    /// @notice Set to true when the last price consensus check failed.
    ///         Cleared on next successful snapshot.
    bool public divergenceActive;

    /// @notice Guardian-set emergency vol override (1e18 scaled).
    ///         Used when both oracles fail — non-zero enables the override.
    uint256 public emergencyVol;

    // ─── Events ───────────────────────────────────────────────────────────────

    event SnapshotUpdated(
        uint256 price,
        uint256 smoothedVol,
        int256  fundingRate,
        uint256 stableDominance,
        bool    volPenaltyFlag,
        uint40  timestamp
    );

    event OracleDiverged(
        string  feed,
        uint256 sourceA,
        uint256 sourceB,
        uint256 divergeBps
    );

    event StalenessBreach(
        string  source,
        uint256 updatedAt,
        uint256 maxAllowedAge
    );

    event PythConfTooWide(uint256 confBps);
    event EmergencyVolSet(uint256 vol);
    event DivergenceCleared();

    // ─── Errors ───────────────────────────────────────────────────────────────

    error StaleOracle(string source);
    error PythConfidenceTooWide(uint256 confBps, uint256 maxBps);
    error PriceDiverged(uint256 divergeBps);
    error PriceOutOfRange(uint256 price);
    error VolOutOfRange(uint256 vol);
    error ZeroAddress();
    error InsufficientValue();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _guardian,
        address _admin,
        // Chainlink feeds
        address _clPrice,
        address _clVol,
        address _clFunding,
        // Pyth
        address _pyth,
        bytes32 _pythPriceId,
        bytes32 _pythVolId,
        // Stablecoin dominance
        address _stableToken,
        uint8   _stableDecimals,
        uint256 _referenceMarketCapE18
    ) {
        if (_guardian == address(0) || _admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE,      _guardian);
        _grantRole(UPDATER_ROLE,       _guardian);

        clPrice   = ChainlinkFeed(AggregatorV3Interface(_clPrice),   CHAINLINK_PRICE_HEARTBEAT,   0);
        clVol     = ChainlinkFeed(AggregatorV3Interface(_clVol),     CHAINLINK_VOL_HEARTBEAT,     0);
        clFunding = ChainlinkFeed(AggregatorV3Interface(_clFunding), CHAINLINK_FUNDING_HEARTBEAT, 0);

        // Cache decimals to avoid repeated external calls
        clPrice.feedDecimals   = AggregatorV3Interface(_clPrice).decimals();
        clVol.feedDecimals     = AggregatorV3Interface(_clVol).decimals();
        clFunding.feedDecimals = AggregatorV3Interface(_clFunding).decimals();

        pyth          = IPyth(_pyth);
        pythPriceId   = _pythPriceId;
        pythVolId     = _pythVolId;

        stableToken             = _stableToken;
        stableDecimals          = _stableDecimals;
        referenceMarketCapE18   = _referenceMarketCapE18;
    }

    // ─── Primary: get validated snapshot ──────────────────────────────────────

    /**
     * @notice Runs the full four-layer validation pipeline and returns a
     *         validated OracleSnapshot ready for the regime classifier.
     *
     *         Reverts if price divergence is detected or any critical feed is stale.
     *         Vol divergence is non-reverting but sets volPenaltyFlag on the snapshot.
     *
     * @return snap  Validated composite oracle snapshot.
     */
    function getSnapshot()
        external
        whenNotPaused
        returns (OracleSnapshot memory snap)
    {
        // ── Layer 2a: validate + read Chainlink ───────────────────────────
        (uint256 clPriceRaw, uint256 clVolRaw, int256 clFundingRaw) = _readChainlink();

        // ── Layer 2b: validate + read Pyth ───────────────────────────────
        (uint256 pythPriceRaw, uint256 pythVolRaw) = _readPyth();

        // ── Layer 2c: range gate both sources ─────────────────────────────
        _rangeGate(clPriceRaw, clVolRaw);
        _rangeGate(pythPriceRaw, pythVolRaw);

        // ── Layer 3: cross-source consensus ───────────────────────────────
        _checkPriceConsensus(clPriceRaw, pythPriceRaw);

        bool volPenalty = _checkVolConsensus(clVolRaw, pythVolRaw);

        // Consensus passed — clear any prior divergence flag
        if (divergenceActive) {
            divergenceActive = false;
            emit DivergenceCleared();
        }

        // ── Price: average of both sources ────────────────────────────────
        uint256 consensusPrice = (clPriceRaw + pythPriceRaw) / 2;

        // ── Vol: Chainlink is primary; fall back to Pyth if CL unavailable ─
        uint256 rawVol = volPenalty ? clVolRaw : (clVolRaw + pythVolRaw) / 2;

        // ── Layer 4a: push to TWAP ring buffer ────────────────────────────
        _pushTwap(rawVol);

        // ── Layer 4b: emergency vol override ─────────────────────────────
        uint256 smoothedVol = emergencyVol > 0 ? emergencyVol : _computeTwap();

        // ── Layer 4c: stablecoin dominance ────────────────────────────────
        uint256 stableDom = _readStableDominance();

        // ── Compose snapshot ──────────────────────────────────────────────
        snap = OracleSnapshot({
            price:           consensusPrice,
            smoothedVol:     smoothedVol,
            fundingRate:     clFundingRaw,
            stableDominance: stableDom,
            timestamp:       uint40(block.timestamp),
            volPenaltyFlag:  volPenalty
        });

        lastSnapshot = snap;

        emit SnapshotUpdated(
            snap.price,
            snap.smoothedVol,
            snap.fundingRate,
            snap.stableDominance,
            snap.volPenaltyFlag,
            snap.timestamp
        );
    }

    // ─── Pyth update helper ────────────────────────────────────────────────────

    /**
     * @notice Push fresh Pyth price data on-chain before calling getSnapshot().
     *         Pyth is pull-based — someone must pay the update fee each epoch.
     *         Called by keepers or an Updater-role automation bot.
     *
     * @param updateData  Signed VAA bytes fetched from Pyth's Hermes API.
     */
    function updatePythFeeds(bytes[] calldata updateData)
        external
        payable
        onlyRole(UPDATER_ROLE)
    {
        uint fee = pyth.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientValue();
        pyth.updatePriceFeeds{value: fee}(updateData);
        // Refund excess ETH
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
    }

    // ─── Guardian overrides ────────────────────────────────────────────────────

    /**
     * @notice Set an emergency volatility override when both oracle sources fail.
     *         Set to 0 to disable the override and return to live feed.
     */
    function forceSetEmergencyVol(uint256 vol)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        emergencyVol = vol;
        emit EmergencyVolSet(vol);
    }

    function setReferenceMarketCap(uint256 capE18)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        referenceMarketCapE18 = capE18;
    }

    function pause()   external onlyRole(GUARDIAN_ROLE) { _pause();   }
    function unpause() external onlyRole(GUARDIAN_ROLE) { _unpause(); }

    // ─── View: TWAP snapshot without writing state ─────────────────────────────

    function peekTwap() external view returns (uint256 smoothedVol, uint8 slotsPopulated) {
        return (_computeTwap(), _bufCount);
    }

    // ─── Internal: Layer 2a — Chainlink read + staleness ──────────────────────

    function _readChainlink()
        internal
        returns (uint256 price18, uint256 vol18, int256 funding18)
    {
        price18   = _clRead(clPrice);
        vol18     = _clRead(clVol);
        funding18 = _clReadSigned(clFunding);
    }

    function _clRead(ChainlinkFeed storage f) internal returns (uint256 value18) {
        (
            uint80  roundId,
            int256  answer,
            ,
            uint256 updatedAt,
            uint80  answeredInRound
        ) = f.feed.latestRoundData();

        // Guard: stale round
        require(answeredInRound >= roundId, "CL: incomplete round");

        uint256 maxAge = f.heartbeat * STALENESS_MULTIPLIER;
        if (updatedAt > block.timestamp) {
            emit StalenessBreach("chainlink", updatedAt, maxAge);
            revert StaleOracle("chainlink");
        }
        if (block.timestamp - updatedAt > maxAge) {
            emit StalenessBreach("chainlink", updatedAt, maxAge);
            revert StaleOracle("chainlink");
        }

        require(answer > 0, "CL: non-positive answer");

        // Normalise to 1e18
        value18 = _normalise(uint256(answer), f.feedDecimals);
    }

    function _clReadSigned(ChainlinkFeed storage f) internal returns (int256 value18) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = f.feed.latestRoundData();

        require(answeredInRound >= roundId, "CL: incomplete round");

        uint256 maxAge = f.heartbeat * STALENESS_MULTIPLIER;
        if (updatedAt > block.timestamp) {
            emit StalenessBreach("chainlink-funding", updatedAt, maxAge);
            revert StaleOracle("chainlink-funding");
        }
        if (block.timestamp - updatedAt > maxAge) {
            emit StalenessBreach("chainlink-funding", updatedAt, maxAge);
            revert StaleOracle("chainlink-funding");
        }

        // Normalise signed value to 1e18
        if (answer >= 0) {
            value18 = int256(_normalise(uint256(answer), f.feedDecimals));
        } else {
            value18 = -int256(_normalise(uint256(-answer), f.feedDecimals));
        }
    }

    // ─── Internal: Layer 2b — Pyth read + conf filter ─────────────────────────

    function _readPyth()
        internal
        returns (uint256 price18, uint256 vol18)
    {
        PythPrice memory pp = pyth.getPriceNoOlderThan(pythPriceId, PYTH_MAX_AGE);

        // Confidence ratio check: conf / |price| ≤ MAX_PYTH_CONF_BPS
        require(pp.price > 0, "Pyth: non-positive price");
        uint256 confBps = (uint256(pp.conf) * 10_000) / uint256(uint64(pp.price));
        if (confBps > MAX_PYTH_CONF_BPS) {
            emit PythConfTooWide(confBps);
            revert PythConfidenceTooWide(confBps, MAX_PYTH_CONF_BPS);
        }

        price18 = _normalisePyth(uint256(uint64(pp.price)), pp.expo);

        // Vol from Pyth (if feed exists; fallback to implied vol from conf interval)
        try pyth.getPriceNoOlderThan(pythVolId, PYTH_MAX_AGE) returns (PythPrice memory pv) {
            vol18 = _normalisePyth(uint256(uint64(pv.price)), pv.expo);
        } catch {
            // Fallback: estimate annualised vol from confidence interval
            // conf ≈ 1σ daily price range; annualise: vol ≈ conf/price × sqrt(365)
            // sqrt(365) ≈ 19.1 (scaled by 1e9 for integer math)
            uint256 dailySigma = (uint256(pp.conf) * 1e18) / uint256(uint64(pp.price));
            vol18 = (dailySigma * 191_000_000) / 1e7; // × sqrt(365) × 1e18
            if (vol18 > VOL_CEILING) vol18 = VOL_CEILING;
            if (vol18 < VOL_FLOOR) vol18 = VOL_FLOOR;
        }
    }

    // ─── Internal: Layer 2c — Range gate ──────────────────────────────────────

    function _rangeGate(uint256 price18, uint256 vol18) internal pure {
        if (price18 < PRICE_FLOOR || price18 > PRICE_CEILING) {
            revert PriceOutOfRange(price18);
        }
        if (vol18 < VOL_FLOOR || vol18 > VOL_CEILING) {
            revert VolOutOfRange(vol18);
        }
    }

    // ─── Internal: Layer 3 — Consensus checks ─────────────────────────────────

    function _checkPriceConsensus(uint256 a, uint256 b) internal {
        uint256 avg = (a + b) / 2;
        uint256 diff = a > b ? a - b : b - a;
        uint256 bps = (diff * 10_000) / avg;

        if (bps > PRICE_DIVERGE_BPS) {
            divergenceActive = true;
            emit OracleDiverged("price", a, b, bps);
            revert PriceDiverged(bps);
        }
    }

    function _checkVolConsensus(uint256 a, uint256 b) internal returns (bool penalty) {
        if (a == 0 || b == 0) return true; // missing vol source → penalty

        uint256 avg = (a + b) / 2;
        uint256 diff = a > b ? a - b : b - a;
        uint256 bps = (diff * 10_000) / avg;

        if (bps > VOL_DIVERGE_BPS) {
            emit OracleDiverged("vol", a, b, bps);
            return true; // non-reverting; classifier widens thresholds
        }
        return false;
    }

    // ─── Internal: Layer 4 — TWAP ring buffer ─────────────────────────────────

    function _pushTwap(uint256 vol) internal {
        _volBuffer[_bufHead] = TwapSlot(vol, uint40(block.timestamp));
        _bufHead = (_bufHead + 1) % TWAP_SLOTS;
        if (_bufCount < TWAP_SLOTS) _bufCount++;
    }

    function _computeTwap() internal view returns (uint256) {
        if (_bufCount == 0) return 0;

        uint256 cutoff = block.timestamp > TWAP_WINDOW
            ? block.timestamp - TWAP_WINDOW
            : 0;

        uint256 sum;
        uint256 count;

        for (uint8 i = 0; i < _bufCount; i++) {
            uint8 idx = (_bufHead + TWAP_SLOTS - 1 - i) % TWAP_SLOTS;
            TwapSlot storage slot = _volBuffer[idx];
            if (slot.timestamp >= cutoff) {
                sum   += slot.vol;
                count += 1;
            }
        }

        if (count == 0) {
            // All slots outside window — return most recent as fallback
            uint8 latest = (_bufHead + TWAP_SLOTS - 1) % TWAP_SLOTS;
            return _volBuffer[latest].vol;
        }

        return sum / count;
    }

    // ─── Internal: stablecoin dominance ───────────────────────────────────────

    function _readStableDominance() internal view returns (uint256) {
        if (referenceMarketCapE18 == 0) return 0;

        // Read on-chain USDC/USDT total supply as a dominance proxy
        // In production use a dedicated dominance oracle
        (bool ok, bytes memory data) = stableToken.staticcall(
            abi.encodeWithSignature("totalSupply()")
        );
        if (!ok || data.length < 32) return 0;

        uint256 rawSupply = abi.decode(data, (uint256));

        // Normalise supply to 1e18 (USDC is 6 decimals)
        uint256 supply18 = rawSupply * (10 ** (18 - stableDecimals));

        // dominance = supply / referenceMarketCap, capped at 1e18 (100%)
        uint256 dom = (supply18 * 1e18) / referenceMarketCapE18;
        return dom > 1e18 ? 1e18 : dom;
    }

    // ─── Internal: normalisation helpers ──────────────────────────────────────

    /// @dev Scale a Chainlink answer (feedDecimals) to 1e18.
    function _normalise(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18)  return value * (10 ** (18 - decimals));
        return value / (10 ** (decimals - 18));
    }

    /// @dev Scale a Pyth price (expo < 0 typical, e.g. -8) to 1e18.
    function _normalisePyth(uint256 value, int32 expo) internal pure returns (uint256) {
        // Pyth expo is typically -8, meaning value × 10^expo = value / 1e8
        // We want value × 10^expo × 1e18 = value × 10^(18+expo)
        int256 targetExp = 18 + int256(expo);
        if (targetExp >= 0) {
            return value * (10 ** uint256(targetExp));
        } else {
            return value / (10 ** uint256(-targetExp));
        }
    }
}
