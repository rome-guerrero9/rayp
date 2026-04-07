# RAYP — Regime-Adaptive Yield Protocol

> **The first DeFi vault that automatically rotates capital between yield strategies based on on-chain market regime detection.**

> **UNAUDITED — Do not deposit real funds. This protocol has not been audited. Use at your own risk. An audit via Code4rena is planned before mainnet deployment.**

## What is RAYP?

RAYP is an on-chain fund manager for Arbitrum. Depositors put ETH in and get shares. Every hour, the market gets read by two independent oracles, cross-checked, then passed to a classifier that waits for three identical readings before declaring a market regime. When a regime change is confirmed, an authorized keeper triggers the vault to move all assets from the old strategy to the new one.

Four regimes, four strategies:

| Regime | Strategy | Protocol | Purpose |
|--------|----------|----------|---------|
| NEUTRAL (0) | Aave WETH supply | Aave v3 | Moderate lending yield (~2% APY) |
| BULL (1) | Leveraged WETH loop | Aave v3 + Uniswap V3 | 2x leveraged long ETH via flash loans |
| BEAR (2) | Stablecoin supply | Aave v3 + Uniswap V3 | Swap to USDC, preserve capital |
| CRISIS (3) | Safe harbor | Aave v3 | Park everything safe until the storm passes |

## Backtest Results (2020–2024)

Backtested against 43,849 hours of ETH data. Full methodology and raw data: [rayp-backtest](https://github.com/rome-guerrero9/rayp-backtest)

| Metric | Buy & Hold ETH | RAYP |
|--------|---------------|------|
| Total Return | +2,507% | +7,219% |
| Max Drawdown | 81.4% | 56.1% |
| Sharpe Ratio | 1.06 | 1.83 |
| Calmar Ratio | 1.13 | 2.42 |

**Crisis detection: 4 for 4**
- COVID March 2020: detected 15 hours before trough
- China mining ban May 2021: detected 825 hours before trough
- Luna/UST May 2022: detected 797 hours before trough
- FTX November 2022: detected 298 hours before trough

## Architecture

```
OracleAggregator (Chainlink + Pyth)
    → RegimeDampener (3-epoch confirmation, vol-floor CRISIS bypass)
    → RAYPVault (ERC-4626, HWM fees, TWAP oracle, circuit breakers)
    → KeeperRegistry (permissionless, staked keepers)
    → IStrategy / BaseStrategy / {Neutral, Bull, Bear, Crisis}
```

All strategies implement five functions: `_deploy`, `_liquidate`, `_liquidateAll`, `_harvestRewards`, `_checkProtocolHealth`. The vault never knows how a strategy earns yield — only how to move assets in and out.

## Build & Test

```bash
forge build
forge test          # 214 pass, 0 fail
```

## Deploy (Arbitrum Sepolia)

```bash
cp .env.example .env
# Edit .env with your deployer key and RPC URL
forge script script/DeployRAYPSepolia.s.sol --rpc-url arbitrum_sepolia --broadcast -vvvv
```

## Contracts

| Contract | Description |
|----------|-------------|
| `RAYPVault.sol` | ERC-4626 vault with regime-based strategy routing |
| `OracleAggregator.sol` | 4-layer validated oracle (Chainlink + Pyth consensus) |
| `RegimeDampener.sol` | Epoch-based regime classifier with dampening |
| `KeeperRegistry.sol` | Permissionless keeper authorization with staking |
| `AaveMoneyMarketStrategy.sol` | Shared base for Neutral + Crisis strategies |
| `BullStrategy.sol` | Flash-loan leveraged WETH on Aave v3 |
| `BearStrategy.sol` | WETH→USDC capital preservation on Aave v3 |

## Security

This codebase is **unaudited**. Known considerations:
- Flash loan callback access control (`msg.sender == aavePool`, `initiator == address(this)`)
- Stale Chainlink feeds revert (not return 0) to prevent vault mispricing
- Health check auto-triggers EMERGENCY_EXIT after 2 consecutive failures
- Circuit breaker pauses vault if share price drops >5% during rebalance

## License

MIT
