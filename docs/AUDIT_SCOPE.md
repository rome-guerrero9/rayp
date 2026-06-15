# RAYP Audit Scope

## Protocol Overview

RAYP is a regime-adaptive ERC-4626 vault on Arbitrum that automatically rotates capital between four yield strategies based on on-chain market regime detection. The vault reads from Chainlink and Pyth oracles, classifies the market regime (Neutral, Bull, Bear, Crisis), and rebalances capital via a permissionless keeper network.

**Repository**: https://github.com/rome-guerrero9/rayp
**Language**: Solidity ^0.8.24
**Framework**: Foundry (forge)
**Compiler settings**: `via_ir = true`, default optimizer
**Chain**: Arbitrum One (L2)
**Test suite**: 214 tests, 0 failures

## Contracts in Scope

| Contract | nSLOC | Description | External Integrations |
|----------|-------|-------------|----------------------|
| `RAYPVault.sol` | 456 | ERC-4626 vault with HWM fees, TWAP oracle, circuit breakers, regime-based strategy routing | OpenZeppelin (AccessControl, Pausable, ReentrancyGuard, ERC4626) |
| `OracleAggregator.sol` | 356 | 4-layer oracle validation: raw feeds, per-source validation, cross-source consensus, TWAP smoothing | Chainlink AggregatorV3, Pyth Network |
| `BullStrategy.sol` | 265 | Flash-loan leveraged WETH loop on Aave v3. Supply WETH, borrow USDC, swap back, re-supply. | Aave v3 Pool (flash loan, supply, borrow, repay), Uniswap V3 Router, Chainlink |
| `KeeperRegistry.sol` | 235 | Permissionless keeper registration with ETH staking, slashing, cooldowns, anti-sandwich guards | None (standalone) |
| `BaseStrategy.sol` | 191 | Abstract base strategy with state machine (ACTIVE/WIND_DOWN/EMERGENCY_EXIT), health check automation | None (abstract) |
| `BearStrategy.sol` | 187 | WETH→USDC capital preservation. Swaps via Uniswap V3, supplies USDC to Aave v3. | Aave v3 Pool, Uniswap V3 Router, Chainlink |
| `RegimeDampener.sol` | 146 | 3-epoch confirmation filter with volatility-floor CRISIS bypass at 250% annualised vol | None (reads OracleAggregator) |
| `AaveMoneyMarketStrategy.sol` | 109 | Shared base for Neutral + Crisis strategies. Simple Aave v3 WETH supply/withdraw. | Aave v3 Pool, Aave Rewards |
| `IStrategy.sol` | 42 | Strategy interface defining the 5-function strategy pattern | None (interface) |
| `NeutralStrategy.sol` | 16 | Thin wrapper over AaveMoneyMarketStrategy, regime 0 | Inherits AaveMoneyMarketStrategy |
| `CrisisStrategy.sol` | 16 | Thin wrapper over AaveMoneyMarketStrategy, regime 3 | Inherits AaveMoneyMarketStrategy |

**Total nSLOC in scope: ~3,020**

## Contracts Out of Scope

- `src/interfaces/` (IAavePool.sol, IAaveRewards.sol, ISwapRouter.sol, AggregatorV3Interface.sol) — external protocol interfaces, not RAYP code
- `test/` — test contracts and mocks
- `script/` — deployment scripts

## External Dependencies

| Dependency | Version | Usage |
|------------|---------|-------|
| OpenZeppelin Contracts | 5.x | AccessControl, Pausable, ReentrancyGuard, ERC4626, ERC20, SafeERC20 |
| Aave v3 Pool | Production | Supply, withdraw, borrow, repay, flashLoanSimple, getReserveData, getUserAccountData |
| Uniswap V3 SwapRouter | Production | exactInputSingle (WETH↔USDC swaps) |
| Chainlink AggregatorV3 | Production | ETH/USD price, volatility, funding rate feeds |
| Pyth Network | Production | ETH/USD price + confidence interval, volatility |

## Key Areas of Concern

### 1. Flash Loan Security (BullStrategy.sol)
- `executeOperation()` callback receives arbitrary flash loan calls
- Guards: `msg.sender == address(aavePool)` + `initiator == address(this)`
- Concern: reentrancy during flash loan callback, state consistency after partial failures
- Concern: can an attacker manipulate Aave's health factor oracle mid-callback to put the vault in an unhealthy state before `repay()` is called? The flash loan creates a window where the vault holds borrowed USDC and supplied WETH simultaneously — if Aave's on-chain health factor calculation uses a price that can be manipulated within the same block, the vault could be liquidated before the callback completes

### 2. Oracle Manipulation (OracleAggregator.sol)
- Cross-source consensus between Chainlink and Pyth
- TWAP smoothing on volatility inputs
- Concern: can an attacker manipulate regime transitions via oracle price/vol manipulation?
- Concern: stale feed handling — reverts vs returns 0, impact on vault operations

### 3. Vault Rebalance Atomicity (RAYPVault.sol)
- Rebalance: withdrawAll(old strategy) → deposit(new strategy) in single tx
- MEV concern: can keeper sandwich the rebalance for profit?
- Circuit breaker: share price drop >5% during rebalance pauses vault

### 4. Strategy State Machine (BaseStrategy.sol)
- Three states: ACTIVE → WIND_DOWN → EMERGENCY_EXIT
- Health check auto-triggers EMERGENCY_EXIT after 2 consecutive failures
- Concern: can health check be manipulated to force emergency exit?
- INV-5: harvestAndReport() must never revert — uses try/catch internally

### 5. Price Conversion Accuracy (BearStrategy + BullStrategy)
- Both convert between WETH and USDC denominations using Chainlink ETH/USD
- Pre-computed scaling factors: `_usdcScale = 10**12`, `_feedScale = 10**(18-feedDecimals)`
- Concern: rounding errors in price conversion causing accounting drift
- Concern: stale price feed causing incorrect totalAssets() valuation

### 6. Keeper Economics (KeeperRegistry.sol)
- Permissionless registration with ETH stake
- Per-block cooldown prevents same-block double execution
- Concern: griefing via minimal stake, keeper front-running, stake/slash edge cases

### 7. ERC-4626 Compliance (RAYPVault.sol)
- High-water mark performance fees
- TWAP-based share price oracle for lending protocol integrations
- Concern: fee calculation affecting share price, deposit/withdraw rounding direction

## Invariants the Audit Should Verify

The following invariants are enforced by design and should be tested by wardens via targeted PoCs:

| ID | Invariant | Contract |
|----|-----------|----------|
| INV-1 | `totalAssets()` never returns zero while assets are deployed in the underlying protocol | All strategies |
| INV-2 | `withdraw()` delivers the exact requested amount in the same transaction | RAYPVault |
| INV-3 | `withdrawAll()` always leaves `totalAssets() == 0` after completion | All strategies |
| INV-4 | In EMERGENCY_EXIT state, `deposit()` reverts and `withdrawAll()` succeeds | BaseStrategy |
| INV-5 | `harvestAndReport()` never reverts under any condition (uses try/catch internally) | BaseStrategy |

## Known Design Decisions

These are intentional and should not be reported as findings:

1. **All strategies use Aave v3** — architectural consistency, not a limitation
2. **RegimeDampener requires 3 confirmations** — intentional latency to prevent whipsaw
3. **Vol floor bypass skips dampener** — emergency CRISIS detection by design
4. **Push pattern for strategy deposits** — vault sends assets before calling deposit(), not pull
5. **Chainlink staleness reverts** — BearStrategy and BullStrategy revert on stale feeds (not return 0), caught by vault's try/catch in healthCheck()
6. **Single active strategy** — vault routes all capital to one strategy at a time, not split across multiple

## Build & Test

```bash
forge build
forge test          # 214 pass, 0 fail
forge test -vvv     # with traces
```

## Protocol Flow Diagram

```
Chainlink + Pyth Oracles
    → OracleAggregator.snapshot()     [4-layer validation]
    → RegimeDampener.tick()           [3-epoch confirmation]
    → RAYPVault.onRegimeConfirmed()   [regime change callback]
    → KeeperRegistry.executeRebalance()
    → Vault: strategy[old].withdrawAll() → strategy[new].deposit()
```

## Contact

- **Protocol team**: warriorai@proton.me
- **GitHub**: https://github.com/rome-guerrero9/rayp
