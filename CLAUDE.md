# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
export PATH="$PATH:/home/romex/.config/.foundry/bin"

forge build                                          # compile all contracts
forge test                                           # run all tests (214 pass, 1 skipped)
forge test --match-contract BullStrategyTest -vvv    # run single test contract with traces
forge test --match-test test_Bull_DeployCreates -vvv # run single test function
forge test --match-path "test/BearStrategy.t.sol"    # run single test file
forge test --gas-report                              # gas usage report
```

The fork test (`RAYPRebalanceForkTest`) requires `ARBITRUM_RPC` env var and auto-skips without it.

## Architecture

RAYP is an ERC-4626 vault on Arbitrum that rotates capital between four yield strategies based on on-chain market regime detection.

### Protocol Flow

```
OracleAggregator (Chainlink + Pyth) → RegimeDampener (3-epoch confirmation)
    → RAYPVault.onRegimeConfirmed() → KeeperRegistry.executeRebalance()
    → Vault: withdrawAll(old strategy) → deposit(new strategy)
```

### Contract Dependency Chain

**Vault** (`RAYPVault.sol`): ERC-4626 vault with HWM fees, TWAP oracle, circuit breakers. Routes capital to one active strategy at a time. Uses OpenZeppelin AccessControl (KEEPER_ROLE, GUARDIAN_ROLE).

**Strategies** — one per regime, all inherit `BaseStrategy`:
- Regime 0 (NEUTRAL) + Regime 3 (CRISIS): Both extend `AaveMoneyMarketStrategy` → simple Aave v3 WETH supply
- Regime 1 (BULL): `BullStrategy` → flash-loan leveraged WETH loop on Aave (supply WETH, borrow USDC, swap back, re-supply)
- Regime 2 (BEAR): `BearStrategy` → swaps WETH→USDC, supplies USDC to Aave for capital preservation. Uses Chainlink ETH/USD for WETH-denominated `totalAssets()`.

**Oracle pipeline** (`OracleAggregator.sol`): 4-layer validation — raw feeds → per-source validation → cross-source consensus → TWAP smoothing. Outputs `OracleSnapshot` struct.

**Dampener** (`RegimeDampener.sol`): Requires 3 consecutive identical regime labels before confirming. Vol floor at 250% auto-confirms CRISIS bypassing the dampener.

**Keepers** (`KeeperRegistry.sol`): Permissionless registration with ETH stake. Anti-sandwich: per-block cooldown + global MIN_REBALANCE_INTERVAL.

### Strategy Pattern

Every strategy implements 5 internal functions via `BaseStrategy`:
```
_deploy(assets) → uint256        // deploy into yield protocol
_liquidate(assets) → uint256     // partial exit
_liquidateAll() → uint256        // full exit, MUST leave totalAssets() == 0 (INV-3)
_harvestRewards() → uint256      // claim + compound rewards
_checkProtocolHealth() → (bool, string)  // never revert, return (false, reason)
```

`BaseStrategy` handles all boilerplate: access control (onlyVault/onlyGuardian), state machine (ACTIVE/WIND_DOWN/EMERGENCY_EXIT), health check auto-emergency after 2 consecutive failures, harvest try/catch (INV-5: never reverts).

### Key Invariants

- **INV-1**: `totalAssets()` monotonically non-decreasing between vault interactions
- **INV-2**: `withdraw()` delivers exact amount in same transaction
- **INV-3**: `withdrawAll()` leaves `totalAssets() == 0`
- **INV-4**: EMERGENCY_EXIT rejects `deposit()`, accepts `withdrawAll()`
- **INV-5**: `harvestAndReport()` never reverts

### Shared Interfaces

`src/interfaces/` contains `IAavePool.sol`, `IAaveRewards.sol`, `ISwapRouter.sol`, `AggregatorV3Interface.sol` — shared across all strategies. `IAavePool` is a superset including flash loan and borrow functions used only by BullStrategy.

### Price Conversion (Bear + Bull)

Both use Chainlink ETH/USD with `_getEthPrice18()` that **reverts** (not returns 0) on stale feeds. Pre-computed `_usdcScale` and `_feedScale` immutables avoid runtime exponentiation. `STALENESS_THRESHOLD = 7200` seconds.

## Deployment

Two deploy scripts in `script/`:
- `DeployStrategies.s.sol` — mainnet strategy deployment (hardcoded Arbitrum addresses)
- `DeployRAYPSepolia.s.sol` — full protocol stack for Arbitrum Sepolia with mock dependencies

Required env vars in `.env.example`: `DEPLOYER_PRIVATE_KEY`, `ARBITRUM_SEPOLIA_RPC`, `ARBITRUM_RPC`.

## Solidity Conventions

- Pragma: `^0.8.24`, compiled with `via_ir = true` (required for stack-too-deep in `getReserveData`)
- Assets pushed to strategies before `deposit()` (push pattern, not pull)
- CEI (Checks-Effects-Interactions) throughout vault rebalance
- Custom errors preferred over require strings
- `_underscorePrefix` for internal/private, no prefix for public
