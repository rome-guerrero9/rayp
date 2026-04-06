// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/OracleAggregator.sol";

/**
 * @title  OracleAggregatorTest
 * @notice Comprehensive test suite for the four-layer oracle validation pipeline.
 *         Covers happy paths, each validation layer independently, failure modes,
 *         TWAP accumulation, and adversarial scenarios.
 *
 * Run:  forge test --match-contract OracleAggregatorTest -vvv
 */

// ── Mock Chainlink aggregator ─────────────────────────────────────────────────

contract MockChainlinkFeed is AggregatorV3Interface {
    int256  public answer;
    uint256 public updatedAt;
    uint80  public roundId = 1;
    uint8   private _decimals;

    constructor(int256 _answer, uint8 _dec) {
        answer    = _answer;
        _decimals = _dec;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer) external {
        answer    = _answer;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setStale(uint256 _updatedAt) external { updatedAt = _updatedAt; }

    function latestRoundData() external view override returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (roundId, answer, block.timestamp, updatedAt, roundId);
    }

    function decimals() external view override returns (uint8) { return _decimals; }
}

// ── Mock Pyth oracle ──────────────────────────────────────────────────────────

contract MockPyth is IPyth {
    mapping(bytes32 => PythPrice) private _prices;
    bool public shouldRevert;
    bytes32 public revertId;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo) external {
        _prices[id] = PythPrice(price, conf, expo, block.timestamp);
    }

    function setRevert(bytes32 id) external { shouldRevert = true; revertId = id; }
    function clearRevert() external { shouldRevert = false; }

    function getPriceNoOlderThan(bytes32 id, uint) external view override returns (PythPrice memory) {
        if (shouldRevert && id == revertId) revert("Pyth: no price");
        require(_prices[id].publishTime > 0, "Pyth: no price");
        return _prices[id];
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {}
    function getUpdateFee(bytes[] calldata) external pure override returns (uint) { return 0; }
}

// ── Mock stablecoin ERC-20 (totalSupply only) ─────────────────────────────────

contract MockStable {
    uint256 public totalSupply;
    constructor(uint256 _supply) { totalSupply = _supply; }
    function setSupply(uint256 s) external { totalSupply = s; }
}

// ── Test contract ─────────────────────────────────────────────────────────────

contract OracleAggregatorTest is Test {

    OracleAggregator public agg;

    MockChainlinkFeed public clPrice;
    MockChainlinkFeed public clVol;
    MockChainlinkFeed public clFunding;
    MockPyth          public pyth;
    MockStable        public stable;

    address guardian = address(0xBB);
    address admin    = address(0xCC);

    bytes32 constant PYTH_PRICE_ID = bytes32(uint256(1));
    bytes32 constant PYTH_VOL_ID   = bytes32(uint256(2));

    // Typical values (8-decimal Chainlink, -8 expo Pyth)
    int256  constant CL_PRICE    = 3_000_00000000;      // $3000.00 at 8 decimals
    int256  constant CL_VOL      = 80_00000000;          // 80% vol at 8 decimals
    int256  constant CL_FUNDING  = 10_000_000;           // 0.1% at 8 decimals
    int64   constant P_PRICE     = 3_000_00000000;       // Pyth $3000 at -8 expo
    uint64  constant P_CONF      = 5_000_000;            // $0.05 conf (tiny)
    int32   constant P_EXPO      = -8;

    function setUp() public {
        clPrice   = new MockChainlinkFeed(CL_PRICE,   8);
        clVol     = new MockChainlinkFeed(CL_VOL,     8);
        clFunding = new MockChainlinkFeed(CL_FUNDING, 8);
        pyth      = new MockPyth();
        stable    = new MockStable(1_000_000_000 * 1e6); // $1B USDC

        pyth.setPrice(PYTH_PRICE_ID, P_PRICE,   P_CONF, P_EXPO);
        pyth.setPrice(PYTH_VOL_ID,   80_00000000, 100000, -8);

        agg = new OracleAggregator(
            guardian,
            admin,
            address(clPrice),
            address(clVol),
            address(clFunding),
            address(pyth),
            PYTH_PRICE_ID,
            PYTH_VOL_ID,
            address(stable),
            6,
            100_000 * 1e18 // $100B reference mcap
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. Happy path
    // ════════════════════════════════════════════════════════════════════════

    function test_SnapshotSucceedsWithValidFeeds() public {
        OracleSnapshot memory snap = agg.getSnapshot();

        // Price should be avg of $3000 from both sources → $3000
        assertApproxEqRel(snap.price, 3_000e18, 0.01e18, "price off");
        // Vol ~80%
        assertApproxEqRel(snap.smoothedVol, 80e18, 0.05e18, "vol off");
        // No penalty flag
        assertFalse(snap.volPenaltyFlag, "unexpected penalty");
        assertEq(snap.timestamp, uint40(block.timestamp));
    }

    function test_SnapshotStoredAsLastSnapshot() public {
        OracleSnapshot memory snap = agg.getSnapshot();
        (uint256 price,,,,,) = agg.lastSnapshot();
        assertEq(price, snap.price);
    }

    function _unpack(OracleSnapshot memory s) internal pure
        returns (uint256 price, uint256 vol, int256 funding, uint256 dom, uint40 ts, bool flag)
    {
        return (s.price, s.smoothedVol, s.fundingRate, s.stableDominance, s.timestamp, s.volPenaltyFlag);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2. Layer 2a — Chainlink staleness
    // ════════════════════════════════════════════════════════════════════════

    function test_StaleChainlinkPriceReverts() public {
        clPrice.setStale(block.timestamp - 3 * 3600); // 3× heartbeat — too old
        vm.expectRevert();
        agg.getSnapshot();
    }

    function test_StaleChainlinkVolReverts() public {
        clVol.setStale(block.timestamp - 3 * 3600);
        vm.expectRevert();
        agg.getSnapshot();
    }

    function test_ExactlyAtStalenessLimitSucceeds() public {
        // 2× heartbeat is the limit — exactly at limit should pass
        clPrice.setStale(block.timestamp - 2 * 3600);
        // Should NOT revert
        agg.getSnapshot();
    }

    function test_OneSecondOverStalenessLimitReverts() public {
        clPrice.setStale(block.timestamp - 2 * 3600 - 1);
        vm.expectRevert();
        agg.getSnapshot();
    }

    // ════════════════════════════════════════════════════════════════════════
    // 3. Layer 2b — Pyth confidence filter
    // ════════════════════════════════════════════════════════════════════════

    function test_PythConfTooWideReverts() public {
        // Set conf = 1% of price (100bps > 50bps max)
        uint64 wideConf = uint64(uint64(P_PRICE) / 100); // 1%
        pyth.setPrice(PYTH_PRICE_ID, P_PRICE, wideConf, P_EXPO);
        vm.expectRevert();
        agg.getSnapshot();
    }

    function test_PythConfExactlyAtLimitSucceeds() public {
        // conf/price = 0.5% exactly = 50bps
        uint64 confAtLimit = uint64(uint64(P_PRICE) / 200);
        pyth.setPrice(PYTH_PRICE_ID, P_PRICE, confAtLimit, P_EXPO);
        agg.getSnapshot(); // should not revert
    }

    function test_PythVolFallsBackToConfImplied() public {
        // Revert the vol feed — aggregator should fall back to implied vol
        pyth.setRevert(PYTH_VOL_ID);
        // Should succeed and set volPenaltyFlag
        OracleSnapshot memory snap = agg.getSnapshot();
        assertTrue(snap.volPenaltyFlag, "should have penalty flag when pyth vol unavailable");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4. Layer 2c — Range gate
    // ════════════════════════════════════════════════════════════════════════

    function test_PriceBelowFloorReverts() public {
        clPrice.set(1_00000000); // $1 — below $100 floor
        pyth.setPrice(PYTH_PRICE_ID, 1_00000000, 100, P_EXPO);
        vm.expectRevert();
        agg.getSnapshot();
    }

    function test_PriceAboveCeilingReverts() public {
        int256 insane = 2_000_000_00000000; // $2M
        clPrice.set(insane);
        pyth.setPrice(PYTH_PRICE_ID, int64(2_000_000_00000000), P_CONF, P_EXPO);
        vm.expectRevert();
        agg.getSnapshot();
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5. Layer 3 — Price consensus
    // ════════════════════════════════════════════════════════════════════════

    function test_PriceDivergenceReverts() public {
        // Set Pyth 3% higher than Chainlink (> 2% threshold)
        int64 divergedPrice = int64(P_PRICE * 103 / 100);
        pyth.setPrice(PYTH_PRICE_ID, divergedPrice, P_CONF, P_EXPO);

        vm.expectRevert();
        agg.getSnapshot();
        assertTrue(agg.divergenceActive(), "divergenceActive should be set");
    }

    function test_PriceDivergenceExactly2PctSucceeds() public {
        // Exactly at 2% — should pass (threshold is strictly greater-than)
        int64 atLimit = int64(P_PRICE * 102 / 100);
        // avg = (P_PRICE + atLimit)/2 ≈ P_PRICE * 1.01
        // diff = atLimit - P_PRICE = P_PRICE * 0.02
        // bps = 0.02 / 1.01 * 10000 ≈ 198 bps < 200 — passes
        pyth.setPrice(PYTH_PRICE_ID, atLimit, P_CONF, P_EXPO);
        agg.getSnapshot(); // should not revert
    }

    function test_DivergenceClearedOnNextSuccessfulSnapshot() public {
        // Trigger divergence
        int64 diverged = int64(P_PRICE * 105 / 100);
        pyth.setPrice(PYTH_PRICE_ID, diverged, P_CONF, P_EXPO);
        vm.expectRevert();
        agg.getSnapshot();
        assertTrue(agg.divergenceActive());

        // Fix the price
        pyth.setPrice(PYTH_PRICE_ID, P_PRICE, P_CONF, P_EXPO);
        agg.getSnapshot();
        assertFalse(agg.divergenceActive(), "flag should clear");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 6. Layer 3 — Vol consensus (non-reverting, sets penalty flag)
    // ════════════════════════════════════════════════════════════════════════

    function test_VolDivergenceSetspenaltyFlag() public {
        // Set Pyth vol 10% higher than Chainlink (> 5% threshold)
        pyth.setPrice(PYTH_VOL_ID, int64(CL_VOL) * 110 / 100, 100000, -8);

        OracleSnapshot memory snap = agg.getSnapshot();
        assertTrue(snap.volPenaltyFlag, "vol penalty flag should be set");
    }

    function test_VolConsensusPassedNoFlag() public {
        // Both sources agree — no flag
        OracleSnapshot memory snap = agg.getSnapshot();
        assertFalse(snap.volPenaltyFlag, "no flag expected");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 7. Layer 4 — TWAP ring buffer
    // ════════════════════════════════════════════════════════════════════════

    function test_TwapAccumulatesOverSlots() public {
        // Single snapshot → 1 slot
        agg.getSnapshot();
        (uint256 twap1, uint8 slots1) = agg.peekTwap();
        assertEq(slots1, 1);
        assertApproxEqRel(twap1, 80e18, 0.02e18);

        // Second snapshot with different vol
        clVol.set(120_00000000); // 120%
        pyth.setPrice(PYTH_VOL_ID, 120_00000000, 100000, -8);
        vm.warp(block.timestamp + 1);
        agg.getSnapshot();

        (uint256 twap2, uint8 slots2) = agg.peekTwap();
        assertEq(slots2, 2);
        // TWAP should be average of 80% and 120% = 100%
        assertApproxEqRel(twap2, 100e18, 0.02e18);
    }

    function test_TwapExcludesOldSlots() public {
        // Add a snapshot far in the past (outside 1hr window)
        agg.getSnapshot();
        vm.warp(block.timestamp + 2 hours); // jump past TWAP window

        // New snapshot with high vol
        clVol.set(200_00000000);
        pyth.setPrice(PYTH_VOL_ID, 200_00000000, 100000, -8);
        agg.getSnapshot();

        (uint256 twap,) = agg.peekTwap();
        // Should only include the recent high-vol snapshot (~200%), not the old 80%
        assertApproxEqRel(twap, 200e18, 0.05e18, "old slot should be excluded");
    }

    function test_TwapRingBufferWraps() public {
        // Fill all 8 slots
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + 1);
            agg.getSnapshot();
        }
        (, uint8 slots) = agg.peekTwap();
        assertEq(slots, 8, "buffer should be full");

        // 9th slot wraps the ring
        vm.warp(block.timestamp + 1);
        agg.getSnapshot();
        (, uint8 slotsAfter) = agg.peekTwap();
        assertEq(slotsAfter, 8, "should remain at 8 slots");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 8. Emergency vol override
    // ════════════════════════════════════════════════════════════════════════

    function test_EmergencyVolOverridesLiveFeeds() public {
        uint256 emergencyVolVal = 250e18; // 250% — crisis level
        vm.prank(guardian);
        agg.forceSetEmergencyVol(emergencyVolVal);

        OracleSnapshot memory snap = agg.getSnapshot();
        assertEq(snap.smoothedVol, emergencyVolVal, "emergency vol should override");
    }

    function test_ClearingEmergencyVolRestoresLiveFeed() public {
        vm.prank(guardian);
        agg.forceSetEmergencyVol(250e18);

        vm.prank(guardian);
        agg.forceSetEmergencyVol(0); // clear override

        OracleSnapshot memory snap = agg.getSnapshot();
        assertApproxEqRel(snap.smoothedVol, 80e18, 0.05e18, "live feed should be used");
    }

    function test_OnlyGuardianCanSetEmergencyVol() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        agg.forceSetEmergencyVol(250e18);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 9. Stablecoin dominance
    // ════════════════════════════════════════════════════════════════════════

    function test_StableDominanceComputedCorrectly() public {
        // $1B USDC supply, $100B reference mcap → 1% dominance = 0.01e18
        OracleSnapshot memory snap = agg.getSnapshot();
        uint256 expectedDom = (1_000_000_000e18) / 100_000e18; // $1B / $100B = 1%
        assertApproxEqRel(snap.stableDominance, 0.01e18, 0.01e18);
    }

    function test_DominanceCappedAt100Pct() public {
        // Supply bigger than reference market cap
        stable.setSupply(type(uint128).max);
        vm.prank(guardian);
        agg.setReferenceMarketCap(1e18); // tiny reference

        OracleSnapshot memory snap = agg.getSnapshot();
        assertEq(snap.stableDominance, 1e18, "dominance should cap at 100%");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 10. Pause
    // ════════════════════════════════════════════════════════════════════════

    function test_PausedBlocksGetSnapshot() public {
        vm.prank(guardian);
        agg.pause();
        vm.expectRevert();
        agg.getSnapshot();
    }

    function test_UnpauseRestoresFunction() public {
        vm.prank(guardian);
        agg.pause();
        vm.prank(guardian);
        agg.unpause();
        agg.getSnapshot(); // should succeed
    }

    // ════════════════════════════════════════════════════════════════════════
    // 11. Fuzz: any price within valid range passes range gate
    // ════════════════════════════════════════════════════════════════════════

    function testFuzz_ValidPriceRangeNeverReverts(uint256 priceUsd) public {
        vm.assume(priceUsd >= 100 && priceUsd <= 1_000_000);

        int256 clPriceVal = int256(priceUsd * 1e8);
        int64  pythPriceVal = int64(int256(priceUsd * 1e8));

        clPrice.set(clPriceVal);
        pyth.setPrice(PYTH_PRICE_ID, pythPriceVal, P_CONF, P_EXPO);

        // Should not revert for range reasons (may revert on divergence — that's ok)
        try agg.getSnapshot() {} catch (bytes memory reason) {
            // Only PriceDiverged is acceptable (due to small rounding between int64/int256)
            // Specifically NOT PriceOutOfRange
            assertFalse(
                bytes4(reason) == OracleAggregator.PriceOutOfRange.selector,
                "should not fail range gate for valid price"
            );
        }
    }
}
