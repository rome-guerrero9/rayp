// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/KeeperRegistry.sol";

/**
 * @title  KeeperRegistryTest
 * @notice Full Foundry test suite for keeper authorization, rebalance
 *         execution, slash/eject mechanics, and all access-control paths.
 *
 * Run:  forge test --match-contract KeeperRegistryTest -vvv
 */

// ── Mock vault ────────────────────────────────────────────────────────────────

contract MockVault is IRAYPVault {
    bool    public shouldRevert;
    uint256 public callCount;
    uint256 public lastMinSharesOut;
    bytes   public revertReason;

    function setRevert(bool _r, bytes memory _reason) external {
        shouldRevert = _r;
        revertReason = _reason;
    }

    function executeRebalance(uint256 minSharesOut) external override {
        lastMinSharesOut = minSharesOut;
        if (shouldRevert) {
            bytes memory r = revertReason;
            assembly { revert(add(r, 32), mload(r)) }
        }
        callCount++;
    }
}

// ── Mock treasury ─────────────────────────────────────────────────────────────

contract MockTreasury is IProtocolTreasury {
    bool    public shouldRevert;
    uint256 public callCount;
    mapping(address => uint256) public paid;

    receive() external payable {}

    function setRevert(bool _r) external { shouldRevert = _r; }

    function payKeeperFee(address keeper, uint256 amount) external override {
        if (shouldRevert) revert("treasury: no funds");
        paid[keeper] += amount;
        callCount++;
    }
}

// ── Attacker contracts ────────────────────────────────────────────────────────

/// @dev Attempts to reenter executeRebalance inside onRegimeConfirmed.
contract ReentrantKeeper {
    KeeperRegistry public registry;
    bool public attacked;

    constructor(address _registry) { registry = KeeperRegistry(payable(_registry)); }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            registry.executeRebalance(0);
        }
    }

    function tryReenter() external {
        registry.executeRebalance(0);
    }
}

// ── Test contract ─────────────────────────────────────────────────────────────

contract KeeperRegistryTest is Test {

    KeeperRegistry public registry;
    MockVault      public vault;
    MockTreasury   public treasury;

    address guardian = address(0xBB);
    address admin    = address(0xCC);

    address alice = address(0x01);
    address bob   = address(0x02);
    address carol = address(0x03);

    uint256 constant STAKE = 0.1 ether;
    uint256 constant FEE   = 0.005 ether;

    function setUp() public {
        vault    = new MockVault();
        treasury = new MockTreasury();

        vm.deal(address(treasury), 100 ether);

        registry = new KeeperRegistry(
            address(vault),
            address(treasury),
            guardian,
            admin
        );

        // Fund test addresses
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _register(address who) internal {
        vm.prank(who);
        registry.register{value: STAKE}();
    }

    function _tick() internal {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. Registration
    // ════════════════════════════════════════════════════════════════════════

    function test_RegisterSucceeds() public {
        _register(alice);

        (uint256 stake,,,,,KeeperRegistry.KeeperStatus status) = registry.keepers(alice);
        assertEq(stake, STAKE);
        assertEq(uint8(status), uint8(KeeperRegistry.KeeperStatus.ACTIVE));
        assertEq(registry.keeperList(0), alice);
        assertEq(registry.totalStaked(), STAKE);
    }

    function test_RegisterBelowMinStakeReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.register{value: 0.01 ether}();
    }

    function test_RegisterTwiceReverts() public {
        _register(alice);
        vm.prank(alice);
        vm.expectRevert();
        registry.register{value: STAKE}();
    }

    function test_MaxKeepersEnforced() public {
        uint16 max = registry.MAX_KEEPERS();
        for (uint160 i = 1; i <= max; i++) {
            address k = address(i * 1000);
            vm.deal(k, 1 ether);
            vm.prank(k);
            registry.register{value: STAKE}();
        }
        // 51st registration should revert
        address overflow = address(uint160(max) * 1000 + 1000);
        vm.deal(overflow, 1 ether);
        vm.prank(overflow);
        vm.expectRevert();
        registry.register{value: STAKE}();
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2. Deregistration and withdrawal
    // ════════════════════════════════════════════════════════════════════════

    function test_DeregisterMovesToUnbonding() public {
        _register(alice);
        vm.prank(alice);
        registry.deregister();

        (,,,,,KeeperRegistry.KeeperStatus status) = registry.keepers(alice);
        assertEq(uint8(status), uint8(KeeperRegistry.KeeperStatus.UNBONDING));
        assertEq(registry.activeKeepers().length, 0, "should be removed from active list");
    }

    function test_WithdrawBeforeUnbondingReverts() public {
        _register(alice);
        vm.prank(alice);
        registry.deregister();

        vm.prank(alice);
        vm.expectRevert();
        registry.withdraw();
    }

    function test_WithdrawAfterUnbondingSucceeds() public {
        _register(alice);
        vm.prank(alice);
        registry.deregister();

        vm.warp(block.timestamp + 7 days + 1);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        registry.withdraw();

        assertEq(alice.balance, balBefore + STAKE, "stake not returned");
        assertEq(registry.totalStaked(), 0);

        // Record should be deleted
        (uint256 stake,,,,,) = registry.keepers(alice);
        assertEq(stake, 0);
    }

    function test_WithdrawAfterUnbondingRemovesTotalStaked() public {
        _register(alice);
        _register(bob);

        vm.prank(alice);
        registry.deregister();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        registry.withdraw();

        assertEq(registry.totalStaked(), STAKE, "bob stake should remain");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 3. Rebalance execution — happy path
    // ════════════════════════════════════════════════════════════════════════

    function test_ActiveKeeperCanRebalance() public {
        _register(alice);
        _tick();

        vm.prank(alice);
        registry.executeRebalance(1000);

        assertEq(vault.callCount(), 1);
        assertEq(vault.lastMinSharesOut(), 1000);

        (,uint256 total,,uint40 lastAt,,) = registry.keepers(alice);
        assertEq(total, 1);
        assertGt(lastAt, 0);
    }

    function test_KeeperFeeRecordedInTreasury() public {
        _register(alice);
        _tick();

        vm.prank(alice);
        registry.executeRebalance(0);

        assertEq(treasury.paid(alice), FEE);
        assertEq(treasury.callCount(), 1);
    }

    function test_RebalanceCountIncrements() public {
        _register(alice);
        _register(bob);

        _tick();
        vm.prank(alice);
        registry.executeRebalance(0);

        _tick();
        vm.prank(bob);
        registry.executeRebalance(0);

        (,uint256 aliceTotal,,,,) = registry.keepers(alice);
        (,uint256 bobTotal,,,,)   = registry.keepers(bob);
        assertEq(aliceTotal, 1);
        assertEq(bobTotal,   1);
        assertEq(vault.callCount(), 2);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4. Rebalance guards
    // ════════════════════════════════════════════════════════════════════════

    function test_UnregisteredCannotRebalance() public {
        _tick();
        vm.prank(alice);
        vm.expectRevert();
        registry.executeRebalance(0);
    }

    function test_UnbondingKeeperCannotRebalance() public {
        _register(alice);
        vm.prank(alice);
        registry.deregister();

        _tick();
        vm.prank(alice);
        vm.expectRevert();
        registry.executeRebalance(0);
    }

    function test_GlobalCooldownPreventsDoubleRebalance() public {
        _register(alice);
        _register(bob);

        _tick();
        vm.prank(alice);
        registry.executeRebalance(0);

        // Bob tries immediately — still in cooldown
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert();
        registry.executeRebalance(0);
    }

    function test_CooldownExpiresCorrectly() public {
        _register(alice);

        _tick();
        vm.prank(alice);
        registry.executeRebalance(0);

        _tick(); // advance past cooldown

        vm.prank(alice);
        registry.executeRebalance(0); // should succeed
        assertEq(vault.callCount(), 2);
    }

    function test_SameBlockReverts() public {
        _register(alice);
        _register(bob);

        _tick();
        vm.prank(alice);
        registry.executeRebalance(0);

        // Same block — do NOT roll
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bob);
        vm.expectRevert();
        registry.executeRebalance(0);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5. Vault revert handling
    // ════════════════════════════════════════════════════════════════════════

    function test_VaultRevertRollsBackCooldown() public {
        vault.setRevert(true, abi.encodePacked("slippage exceeded"));

        _register(alice);
        _tick();

        vm.prank(alice);
        vm.expectRevert();
        registry.executeRebalance(0);

        // Cooldown should be rolled back — alice can retry
        assertEq(registry.lastRebalanceAt(), 0);
        assertEq(registry.lastRebalanceBlock(), 0);

        // Retry without vault revert
        vault.setRevert(false, "");
        vm.roll(block.number + 1);
        vm.prank(alice);
        registry.executeRebalance(0); // should succeed
        assertEq(vault.callCount(), 1);
    }

    function test_VaultRevertDoesNotIncrementKeeperCount() public {
        vault.setRevert(true, abi.encodePacked("err"));

        _register(alice);
        _tick();

        vm.prank(alice);
        vm.expectRevert();
        registry.executeRebalance(0);

        (,uint256 total,,,,) = registry.keepers(alice);
        assertEq(total, 0, "rebalance count should not increment on vault revert");
    }

    function test_TreasuryRevertDoesNotBrickRebalance() public {
        treasury.setRevert(true);

        _register(alice);
        _tick();

        vm.prank(alice);
        registry.executeRebalance(0); // should succeed even if treasury fails

        assertEq(vault.callCount(), 1, "vault should have been called");
    }

    // ════════════════════════════════════════════════════════════════════════
    // 6. Slash mechanics
    // ════════════════════════════════════════════════════════════════════════

    function test_SlashReducesStake() public {
        _register(alice);

        vm.prank(guardian);
        registry.slash(alice, "misbehaviour");

        (uint256 stake,,,,,) = registry.keepers(alice);
        assertEq(stake, STAKE / 2, "50% slash should halve stake");
        assertEq(registry.slashedFunds(), STAKE / 2);
        assertEq(registry.totalStaked(), STAKE / 2);
    }

    function test_OnlyGuardianCanSlash() public {
        _register(alice);
        vm.prank(alice);
        vm.expectRevert();
        registry.slash(alice, "self-slash");
    }

    function test_SlashDoesNotChangeStatus() public {
        _register(alice);
        vm.prank(guardian);
        registry.slash(alice, "test");

        (,,,,,KeeperRegistry.KeeperStatus status) = registry.keepers(alice);
        assertEq(uint8(status), uint8(KeeperRegistry.KeeperStatus.ACTIVE));
    }

    function test_SweepSlashedFunds() public {
        _register(alice);
        vm.prank(guardian);
        registry.slash(alice, "test");

        uint256 balBefore = carol.balance;
        vm.prank(guardian);
        registry.sweepSlashedFunds(carol);

        assertEq(carol.balance, balBefore + STAKE / 2);
        assertEq(registry.slashedFunds(), 0);
    }

    function test_SweepEmptyReverts() public {
        vm.prank(guardian);
        vm.expectRevert();
        registry.sweepSlashedFunds(carol);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 7. Eject mechanics
    // ════════════════════════════════════════════════════════════════════════

    function test_AnyoneCanEjectInactiveKeeper() public {
        _register(alice);

        // Simulate activity then go silent
        _tick();
        vm.prank(alice);
        registry.executeRebalance(0);

        // Advance past MAX_INACTIVITY
        vm.warp(block.timestamp + 31 days);

        vm.prank(carol); // not guardian
        registry.ejectInactive(alice);

        (,,,,,KeeperRegistry.KeeperStatus status) = registry.keepers(alice);
        assertEq(uint8(status), uint8(KeeperRegistry.KeeperStatus.EJECTED));
        assertEq(registry.slashedFunds(), STAKE, "remaining stake should go to slashedFunds");
    }

    function test_NeverRebalancedKeeperEjectedByInactivity() public {
        _register(alice);
        vm.warp(block.timestamp + 31 days);

        vm.prank(carol);
        registry.ejectInactive(alice);

        (,,,,,KeeperRegistry.KeeperStatus status) = registry.keepers(alice);
        assertEq(uint8(status), uint8(KeeperRegistry.KeeperStatus.EJECTED));
    }

    function test_ActiveKeeperCannotBeEjectedEarly() public {
        _register(alice);
        _tick();
        vm.prank(alice);
        registry.executeRebalance(0);

        // Only 1 day has passed
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        vm.expectRevert();
        registry.ejectInactive(alice);
    }

    function test_OnlyGuardianCanEjectUnderStaked() public {
        _register(alice);

        // Slash to below minStake
        vm.prank(guardian);
        registry.slash(alice, "slash down");
        // Alice now has STAKE/2 which may equal minStake — slash again
        vm.prank(guardian);
        registry.slash(alice, "slash more");

        // Non-guardian ejection of under-staked should revert
        vm.prank(carol);
        vm.expectRevert();
        registry.ejectInactive(alice);

        // Guardian succeeds
        vm.prank(guardian);
        registry.ejectInactive(alice);

        (,,,,,KeeperRegistry.KeeperStatus status) = registry.keepers(alice);
        assertEq(uint8(status), uint8(KeeperRegistry.KeeperStatus.EJECTED));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 8. Pause
    // ════════════════════════════════════════════════════════════════════════

    function test_PausedBlocksRegistrationAndRebalance() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(alice);
        vm.expectRevert();
        registry.register{value: STAKE}();

        // Register before pause — still can't rebalance
        vm.prank(guardian);
        registry.unpause();
        _register(alice);
        vm.prank(guardian);
        registry.pause();

        _tick();
        vm.prank(alice);
        vm.expectRevert();
        registry.executeRebalance(0);
    }

    function test_OnlyGuardianCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.pause();
    }

    // ════════════════════════════════════════════════════════════════════════
    // 9. View helpers
    // ════════════════════════════════════════════════════════════════════════

    function test_IsAuthorizedKeeper() public {
        assertFalse(registry.isAuthorizedKeeper(alice));
        _register(alice);
        assertTrue(registry.isAuthorizedKeeper(alice));

        vm.prank(alice);
        registry.deregister();
        assertFalse(registry.isAuthorizedKeeper(alice));
    }

    function test_CooldownRemainingDecrements() public {
        _register(alice);
        _tick();
        vm.prank(alice);
        registry.executeRebalance(0);

        uint40 remaining = registry.cooldownRemaining();
        assertGt(remaining, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(registry.cooldownRemaining(), 0);
    }

    function test_ActiveKeepersListUpdatesOnDeregister() public {
        _register(alice);
        _register(bob);
        assertEq(registry.activeKeepers().length, 2);

        vm.prank(alice);
        registry.deregister();
        assertEq(registry.activeKeepers().length, 1);
        assertEq(registry.activeKeepers()[0], bob);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 10. Parameter governance
    // ════════════════════════════════════════════════════════════════════════

    function test_GuardianCanUpdateParameters() public {
        vm.prank(guardian);
        registry.setParameters(0.2 ether, 0.01 ether, 3000);

        assertEq(registry.minStake(),  0.2 ether);
        assertEq(registry.keeperFee(), 0.01 ether);
        assertEq(registry.slashBps(),  3000);
    }

    function test_SlashBpsOver10000Reverts() public {
        vm.prank(guardian);
        vm.expectRevert();
        registry.setParameters(0.1 ether, 0.005 ether, 10_001);
    }

    function test_AdminCanSetVaultAndTreasury() public {
        address newVault    = address(new MockVault());
        address newTreasury = address(new MockTreasury());

        vm.prank(admin);
        registry.setVault(newVault);
        vm.prank(admin);
        registry.setTreasury(newTreasury);

        assertEq(address(registry.vault()),    newVault);
        assertEq(address(registry.treasury()), newTreasury);
    }

    function test_OnlyAdminCanSetAddresses() public {
        vm.prank(guardian);
        vm.expectRevert();
        registry.setVault(address(new MockVault()));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 11. Reentrancy guard
    // ════════════════════════════════════════════════════════════════════════

    function test_ReentrancyOnExecuteRebalanceReverts() public {
        ReentrantKeeper attacker = new ReentrantKeeper(address(registry));
        vm.deal(address(attacker), 1 ether);

        // Register the attacker contract as a keeper
        vm.prank(address(attacker));
        registry.register{value: STAKE}();

        _tick();

        vm.prank(address(attacker));
        vm.expectRevert();
        attacker.tryReenter();
    }

    // ════════════════════════════════════════════════════════════════════════
    // 12. Fuzz: any stake above minimum registers successfully
    // ════════════════════════════════════════════════════════════════════════

    function testFuzz_RegisterWithAnyValidStake(uint256 amount) public {
        vm.assume(amount >= registry.minStake());
        vm.assume(amount <= 100 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        registry.register{value: amount}();

        (uint256 stake,,,,,KeeperRegistry.KeeperStatus status) = registry.keepers(alice);
        assertEq(stake, amount);
        assertEq(uint8(status), uint8(KeeperRegistry.KeeperStatus.ACTIVE));
    }
}
