# RAYP — Audit Scope

Prepared for a Code4rena audit of the Regime-Adaptive Yield Protocol.

## Overview

RAYP is an ERC-4626 yield vault on Arbitrum that rotates capital between four
strategies based on on-chain market-regime detection. Depositors supply WETH and
receive shares. An oracle layer reads the market hourly, a dampener confirms a
regime only after three consecutive identical readings, and an authorized keeper
then triggers the vault to move all assets from the old strategy to the new one.

| Regime | Strategy | Protocol | Purpose |
|--------|----------|----------|---------|
| NEUTRAL (0) | Aave WETH supply | Aave v3 | Moderate lending yield |
| BULL (1) | Leveraged WETH loop | Aave v3 + Uniswap V3 | 2x leveraged long ETH via flash loans |
| BEAR (2) | Stablecoin supply | Aave v3 + Uniswap V3 | Swap to USDC, preserve capital |
| CRISIS (3) | Safe harbor | Aave v3 | Park assets safe |

## Contracts in scope

| Contract | Lines | Description |
|----------|------:|-------------|
| `src/RAYPVault.sol` | 789 | ERC-4626 vault: regime-based routing, high-water-mark fees, TWAP share-price oracle, circuit breakers |
| `src/OracleAggregator.sol` | 592 | 4-layer validated oracle — Chainlink + Pyth consensus, staleness/confidence checks |
| `src/KeeperRegistry.sol` | 467 | Permissionless keeper authorization with staking and slashing |
| `src/BaseStrategy.sol` | 360 | Shared strategy base (`_deploy`/`_liquidate`/`_liquidateAll`/`_harvestRewards`/`_checkProtocolHealth`) |
| `src/BullStrategy.sol` | 355 | Flash-loan 2x leveraged WETH on Aave v3 |
| `src/IStrategy.sol` | 327 | Strategy interface and shared types |
| `src/RegimeDampener.sol` | 319 | Epoch-based regime classifier with 3-epoch confirmation + vol-floor CRISIS bypass |
| `src/BearStrategy.sol` | 246 | WETH→USDC capital-preservation strategy |
| `src/AaveMoneyMarketStrategy.sol` | 145 | Shared base for Neutral + Crisis strategies |
| `src/NeutralStrategy.sol` | 26 | Aave WETH supply (thin wrapper over `AaveMoneyMarketStrategy`) |
| `src/CrisisStrategy.sol` | 26 | Safe-harbor Aave supply (thin wrapper) |
| **Total** | **3,652** | 11 contracts |

## Out of scope

- `src/interfaces/` — external-protocol interfaces (Aave, Uniswap, Chainlink, Pyth); 72 lines, no logic.
- `lib/` — dependencies (`forge-std`, OpenZeppelin).
- `test/`, `script/` — test and deployment code.
- `bot/` — off-chain TypeScript regime-signal bot.
- Third-party protocol risk (Aave v3, Uniswap V3, Chainlink, Pyth) is assumed sound.

## Areas of concern (where to focus)

1. **Oracle manipulation** — `OracleAggregator` cross-checks Chainlink vs Pyth. Review consensus-divergence handling, staleness reverts, and Pyth confidence-interval bounds.
2. **Rebalance atomicity** — during a rebalance, assets are transiently "in flight" and the vault's spot share price dips. The vault locks deposits/withdrawals and exposes a TWAP price for integrators. Verify the lock fully blocks external reads of mid-rebalance state (see `test/RAYPRebalanceForkTest.t.sol`).
3. **Keeper trust model** — `KeeperRegistry` is permissionless with staking/slashing. Review who can rebalance, slashing conditions, and `sweepSlashedFunds` authorization.
4. **Flash-loan callback auth** — `BullStrategy` uses Aave flash loans; callback must enforce `msg.sender == aavePool` and `initiator == address(this)`.
5. **ERC-4626 inflation / first-depositor attack** — review share/asset rounding and initial-deposit handling in `RAYPVault`.
6. **Fee accounting** — high-water-mark performance fees in `harvestFees()`; check for precision loss and fee-on-loss scenarios.
7. **Circuit breaker** — vault pauses if share price drops >5% during a rebalance; verify it cannot be bricked or bypassed.

## Build & test

```bash
forge build
forge test                                   # 214 unit + invariant tests
ARBITRUM_RPC=<archive-rpc> forge test \
  --match-contract RAYPRebalanceForkTest      # 12 fork tests (needs an Arbitrum archive RPC)
```

Compiler: `solc ^0.8.24`, `evm_version = shanghai`, `via_ir = true`, optimizer 200 runs.

## Test coverage

226 tests across 10 suites, all passing:

| Suite | Tests |
|-------|------:|
| RAYPVaultTest | 47 |
| KeeperRegistryTest | 39 |
| OracleAggregatorTest | 27 |
| StrategyInvariantTest | 20 |
| RegimeDampenerTest | 20 |
| CrisisStrategyTest | 18 |
| BearStrategyTest | 16 |
| BullStrategyTest | 16 |
| NeutralStrategyTest | 11 |
| RAYPRebalanceForkTest | 12 (Arbitrum mainnet fork) |

## Known issues

See [`known-issues.md`](known-issues.md) — triaged static-analysis (slither) findings.
