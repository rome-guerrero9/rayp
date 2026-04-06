// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RegimeDampener.sol";

/**
 * @title  RegimeDampenerTest
 * @notice Full Foundry test suite covering the happy path, all edge cases,
 *         and adversarial scenarios for the epoch dampening circuit breaker.
 *
 * Run with:  forge test --match-contract RegimeDampenerTest -vvv
 */
contract MockVault is IRAYPVault {
    uint8  public lastNewRegime;
    uint8  public lastOldRegime;
    uint256 public callCount;

    function onRegimeConfirmed(uint8 newRegime, uint8 oldRegime) external override {
        lastNewRegime = newRegime;
        lastOldRegime = oldRegime;
        callCount    += 1;
    }
}

contract RegimeDampenerTest is Test {

    RegimeDampener public dampener;
    MockVault      public vault;

    address oracle   = address(0xAA);
    address guardian = address(0xBB);
    address admin    = address(0xCC);

    uint8 constant NEUTRAL = 0;
    uint8 constant BULL    = 1;
    uint8 constant BEAR    = 2;
    uint8 constant CRISIS  = 3;

    uint256 constant NORMAL_VOL = 0.5e18;   // 50% ann vol — below threshold
    uint256 constant CRISIS_VOL = 3e18;     // 300% ann vol — above threshold

    function setUp() public {
        vault    = new MockVault();
        dampener = new RegimeDampener(
            address(vault),
            oracle,
            guardian,
            admin,
            NEUTRAL   // start in neutral
        );
    }

    // ── Helper: advance time by MIN_EPOCH_INTERVAL ────────────────────────

    function _tick() internal {
        vm.warp(block.timestamp + 1 hours + 1);
    }

    // ── Helper: push n identical epochs from oracle ───────────────────────

    function _pushN(uint8 label, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _tick();
            vm.prank(oracle);
            dampener.pushRegime(label, NORMAL_VOL);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // 1. Happy path — three confirmations trigger rebalance
    // ══════════════════════════════════════════════════════════════════════

    function test_ThreeConfirmationsTriggersRebalance() public {
        // First two pushes: accumulate but do NOT fire
        _pushN(BULL, 2);
        assertEq(vault.callCount(), 0, "vault called too early");
        assertEq(dampener.confirmedRegime(), NEUTRAL, "confirmed changed early");
        assertEq(dampener.confirmationCount(), 2);

        // Third push: fires
        _tick();
        vm.prank(oracle);
        dampener.pushRegime(BULL, NORMAL_VOL);

        assertEq(vault.callCount(), 1, "vault not called after 3 confirmations");
        assertEq(dampener.confirmedRegime(), BULL);
        assertEq(vault.lastNewRegime(), BULL);
        assertEq(vault.lastOldRegime(), NEUTRAL);
    }

    function test_ConfirmationsRemainingDecrementsCorrectly() public {
        assertEq(dampener.confirmationsRemaining(), 0); // pending == confirmed

        _tick(); vm.prank(oracle); dampener.pushRegime(BULL, NORMAL_VOL);
        assertEq(dampener.confirmationsRemaining(), 2);

        _tick(); vm.prank(oracle); dampener.pushRegime(BULL, NORMAL_VOL);
        assertEq(dampener.confirmationsRemaining(), 1);

        _tick(); vm.prank(oracle); dampener.pushRegime(BULL, NORMAL_VOL);
        assertEq(dampener.confirmationsRemaining(), 0); // confirmed, vault called
    }

    // ══════════════════════════════════════════════════════════════════════
    // 2. Interruption resets the counter
    // ══════════════════════════════════════════════════════════════════════

    function test_InterruptedSequenceResetsCount() public {
        // Two epochs of BULL
        _pushN(BULL, 2);
        assertEq(dampener.confirmationCount(), 2);

        // One epoch of BEAR interrupts
        _tick(); vm.prank(oracle); dampener.pushRegime(BEAR, NORMAL_VOL);
        assertEq(dampener.confirmationCount(), 1, "count should reset to 1");
        assertEq(dampener.pendingRegime(), BEAR);
        assertEq(vault.callCount(), 0, "no rebalance on interrupted sequence");

        // Now need two more BEAR epochs to confirm (total 3)
        _pushN(BEAR, 2);
        assertEq(vault.callCount(), 1);
        assertEq(dampener.confirmedRegime(), BEAR);
    }

    function test_MultipleInterruptionsNeverFire() public {
        // Alternating BULL / BEAR — never reaches threshold
        for (uint8 i = 0; i < 6; i++) {
            _tick();
            vm.prank(oracle);
            dampener.pushRegime(i % 2 == 0 ? BULL : BEAR, NORMAL_VOL);
        }
        assertEq(vault.callCount(), 0, "alternating regimes should never confirm");
        assertEq(dampener.confirmedRegime(), NEUTRAL, "confirmed should stay NEUTRAL");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 3. Volatility floor auto-confirms CRISIS
    // ══════════════════════════════════════════════════════════════════════

    function test_VolFloorAutoConfirmsCrisis() public {
        // Push BULL twice (not yet confirmed)
        _pushN(BULL, 2);
        assertEq(dampener.confirmedRegime(), NEUTRAL);

        // Single high-vol push — regardless of label, CRISIS fires immediately
        _tick();
        vm.prank(oracle);
        dampener.pushRegime(BULL, CRISIS_VOL);   // label says BULL but vol overrides

        assertEq(dampener.confirmedRegime(), CRISIS, "vol floor should force CRISIS");
        assertEq(vault.lastNewRegime(), CRISIS);
        assertEq(vault.callCount(), 1);
    }

    function test_VolFloorAtExactThresholdFires() public {
        _tick();
        vm.prank(oracle);
        dampener.pushRegime(NEUTRAL, 2.5e18); // exactly at threshold
        assertEq(dampener.confirmedRegime(), CRISIS);
    }

    function test_VolJustBelowThresholdDoesNotFire() public {
        _tick();
        vm.prank(oracle);
        dampener.pushRegime(NEUTRAL, 2.5e18 - 1); // one below threshold
        assertEq(dampener.confirmedRegime(), NEUTRAL);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 4. Guardian forceConfirm bypasses dampener
    // ══════════════════════════════════════════════════════════════════════

    function test_GuardianForceConfirmsBear() public {
        vm.prank(guardian);
        dampener.forceConfirm(BEAR);

        assertEq(dampener.confirmedRegime(), BEAR);
        assertEq(vault.callCount(), 1);
        assertEq(vault.lastNewRegime(), BEAR);
    }

    function test_OnlyGuardianCanForceConfirm() public {
        vm.expectRevert();
        vm.prank(oracle);
        dampener.forceConfirm(BEAR);

        vm.expectRevert();
        vm.prank(address(0xDEAD));
        dampener.forceConfirm(CRISIS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 5. Rate limiting — MIN_EPOCH_INTERVAL enforced
    // ══════════════════════════════════════════════════════════════════════

    function test_EpochTooSoonReverts() public {
        _tick();
        vm.prank(oracle);
        dampener.pushRegime(BULL, NORMAL_VOL);

        // Second push without advancing time
        vm.prank(oracle);
        vm.expectRevert();
        dampener.pushRegime(BULL, NORMAL_VOL);
    }

    function test_EpochExactlyAtIntervalSucceeds() public {
        _tick();
        vm.prank(oracle);
        dampener.pushRegime(BULL, NORMAL_VOL);

        vm.warp(block.timestamp + 1 hours); // exactly MIN_EPOCH_INTERVAL
        vm.prank(oracle);
        dampener.pushRegime(BULL, NORMAL_VOL); // should not revert
        assertEq(dampener.confirmationCount(), 2);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 6. Access control
    // ══════════════════════════════════════════════════════════════════════

    function test_OnlyOracleCanPushRegime() public {
        _tick();
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        dampener.pushRegime(BULL, NORMAL_VOL);
    }

    function test_OnlyGuardianCanPauseUnpause() public {
        vm.expectRevert();
        vm.prank(oracle);
        dampener.pause();

        vm.prank(guardian);
        dampener.pause();
        assertTrue(dampener.paused());

        vm.prank(guardian);
        dampener.unpause();
        assertFalse(dampener.paused());
    }

    function test_OnlyAdminCanSetVault() public {
        address newVault = address(new MockVault());
        vm.expectRevert();
        vm.prank(oracle);
        dampener.setVault(newVault);

        vm.prank(admin);
        dampener.setVault(newVault);
        assertEq(address(dampener.vault()), newVault);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 7. Pause blocks oracle pushes but not guardian forceConfirm
    // ══════════════════════════════════════════════════════════════════════

    function test_PausedBlocksPushRegime() public {
        vm.prank(guardian);
        dampener.pause();

        _tick();
        vm.prank(oracle);
        vm.expectRevert();
        dampener.pushRegime(BULL, NORMAL_VOL);
    }

    function test_PausedDoesNotBlockForceConfirm() public {
        vm.prank(guardian);
        dampener.pause();

        vm.prank(guardian);
        dampener.forceConfirm(CRISIS); // should still work
        assertEq(dampener.confirmedRegime(), CRISIS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 8. No duplicate rebalance if regime unchanged
    // ══════════════════════════════════════════════════════════════════════

    function test_NoRebalanceIfRegimeUnchanged() public {
        // Confirm BULL
        _pushN(BULL, 3);
        assertEq(vault.callCount(), 1);

        // Push BULL again — already confirmed, no re-trigger
        _pushN(BULL, 5);
        assertEq(vault.callCount(), 1, "should not re-trigger confirmed regime");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 9. Invalid label reverts
    // ══════════════════════════════════════════════════════════════════════

    function test_InvalidLabelReverts() public {
        _tick();
        vm.prank(oracle);
        vm.expectRevert();
        dampener.pushRegime(99, NORMAL_VOL); // out of range
    }

    // ══════════════════════════════════════════════════════════════════════
    // 10. rebalanceCount increments on every confirmation
    // ══════════════════════════════════════════════════════════════════════

    function test_RebalanceCountIncrements() public {
        _pushN(BULL, 3);   // NEUTRAL → BULL
        _pushN(BEAR, 3);   // BULL → BEAR
        _pushN(CRISIS, 3); // BEAR → CRISIS
        assertEq(dampener.rebalanceCount(), 3);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 11. Fuzz: any valid label reaching threshold triggers exactly once
    // ══════════════════════════════════════════════════════════════════════

    function testFuzz_ThresholdAlwaysTriggersOnce(uint8 label) public {
        vm.assume(label < 4);
        vm.assume(label != NEUTRAL); // start != confirmedRegime

        _pushN(label, 3);
        assertEq(vault.callCount(), 1);
        assertEq(dampener.confirmedRegime(), label);
    }
}
