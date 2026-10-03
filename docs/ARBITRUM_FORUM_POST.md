# [LTIPP Application] RAYP — Regime-Adaptive Yield Protocol

**Applicant**: Warrior AI Automations
**Contact**: warriorai@proton.me
**Category**: DeFi Protocol / Yield Infrastructure
**Grant request**: 200,000 ARB
**Grant recipient (Safe multisig)**: `0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d` (Arbitrum One, 2-of-3)
**GitHub**: https://github.com/rome-guerrero9/rayp
**Backtest**: https://github.com/rome-guerrero9/rayp-backtest

---

## TL;DR

RAYP is an ERC-4626 vault on Arbitrum that **automatically rotates capital between four yield strategies based on on-chain market regime detection**. The protocol reads Chainlink and Pyth oracles, classifies the market regime (Neutral, Bull, Bear, Crisis), and rebalances capital via a permissionless keeper network — no governance votes, no manual rebalancing, no multisig delay.

**The protocol is built, tested, and open-source.** 214 passing Foundry tests, 0 failures. Backtested against 43,849 hours of ETH data (2020-2024):

| Metric | Buy & Hold ETH | RAYP |
|--------|---------------|------|
| Total Return | +2,507% | **+7,219%** |
| Max Drawdown | 81.4% | **56.1%** |
| Sharpe Ratio | 1.06 | **1.83** |
| Calmar Ratio | 1.13 | **2.42** |

**Crisis detection: 4/4** on COVID, China mining ban, Luna/UST, and FTX — lead times from 15 hours to 825 hours before trough.

We are requesting **200,000 ARB** under LTIPP to fund a Code4rena audit, bootstrap the keeper network, provide early-depositor LP incentives, and complete mainnet deployment.

---

## 1. Problem Statement

### Static vaults fail in dynamic markets

Every major yield aggregator deployed today — Yearn, Beefy, Convex, Pendle — selects a strategy at deployment time and holds it regardless of macro conditions. During bull markets this works. During the 2022 bear and 2023 liquidity crises, these protocols systematically underperformed because they were structurally incapable of rotating to defensive positions.

### Governance is too slow for tactical rotation

Protocols that do support multi-strategy vaults rely on governance votes to rotate capital. DAO governance operates on weekly or monthly cycles. Markets move in hours. By the time a proposal to exit a failing strategy reaches quorum, the damage to LP capital is done.

### No on-chain macro intelligence primitive exists

There is no primitive in the Arbitrum DeFi stack today that provides reliable on-chain market regime classification. Protocols and DAO treasuries are forced to rely on off-chain signals, centralised oracles, or human discretion — all points of failure.

---

## 2. The RAYP Solution

RAYP replaces governance-gated rotation with a deterministic, auditable, on-chain classifier.

| Regime | Strategy | Protocol | Purpose |
|--------|----------|----------|---------|
| **NEUTRAL (0)** | Aave WETH supply | Aave v3 | Moderate lending yield (~2% APY) |
| **BULL (1)** | Leveraged WETH loop | Aave v3 + Uniswap V3 | 2x leveraged long ETH via flash loans |
| **BEAR (2)** | Stablecoin supply | Aave v3 + Uniswap V3 | Swap to USDC, preserve capital |
| **CRISIS (3)** | Safe harbor | Aave v3 | Park everything safe until the storm passes |

The vault spends 85.3% of time in NEUTRAL, only rotating when confirmed regime shifts occur. Over the backtest period, 348 confirmed transitions averaged one regime change every 5.3 days.

### Architecture

```
OracleAggregator (Chainlink + Pyth)
    → RegimeDampener (3-epoch confirmation, vol-floor CRISIS bypass)
    → RAYPVault (ERC-4626, HWM fees, TWAP oracle, circuit breakers)
    → KeeperRegistry (permissionless, staked keepers)
    → Strategy (Neutral / Bull / Bear / Crisis)
```

**Oracle pipeline**: Chainlink and Pyth are read in parallel, validated for staleness and confidence independently, then cross-validated for 2% consensus agreement. Volatility inputs are TWAP-smoothed over a 1-hour ring buffer.

**Dampener**: Requires three consecutive regime confirmations before any rebalance fires. One exception — if 7-day realised volatility hits 250% annualised, the dampener is bypassed and the vault transitions to CRISIS immediately.

**Keepers**: Permissionless network with ETH staking, per-block cooldowns, and anti-sandwich guards.

---

## 3. Arbitrum Ecosystem Fit

### 3.1 Arbitrum-native by design

RAYP's entire strategy library targets Aave v3 and Uniswap V3 — both live and battle-tested on Arbitrum. Every strategy interaction (supply, withdraw, borrow, repay, flash loan, swap) uses Arbitrum-native contract deployments. This is not a multi-chain protocol with Arbitrum as an afterthought — it is Arbitrum-first by design.

### 3.2 Arbitrum-specific oracle advantages

Chainlink Data Streams on Arbitrum offer sub-second price feeds not available on other chains. Combined with Pyth's pull oracle, RAYP's regime classifier gets materially better input data quality on Arbitrum than it could achieve elsewhere.

### 3.3 Keeper economics

Arbitrum's low gas costs make keeper economics viable at scale — rebalance transactions that would cost $50-100 on L1 cost pennies on Arbitrum. This is what makes a permissionless keeper network feasible in the first place.

### 3.4 DAO treasury opportunity

Arbitrum's own DAO treasury holds idle assets earning nothing. RAYP is a natural fit for protocol-owned treasury diversification — depositing DAO-held ETH into a regime-adaptive vault that automatically protects capital during downturns. We would welcome the opportunity to present RAYP to the Arbitrum treasury working group as a pilot use case, with the DAO itself as an early depositor during the capped TVL phase.

---

## 4. What Is Already Built

This is not vapourware. Everything below is complete, tested, and open-source:

### Smart contracts (Solidity ^0.8.24, Foundry)

| Contract | nSLOC | Description |
|----------|-------|-------------|
| `RAYPVault.sol` | 456 | ERC-4626 vault with HWM fees, TWAP oracle, circuit breakers |
| `OracleAggregator.sol` | 356 | 4-layer Chainlink + Pyth consensus pipeline |
| `BullStrategy.sol` | 265 | Flash-loan leveraged WETH loop on Aave v3 |
| `KeeperRegistry.sol` | 235 | Permissionless keeper auth with staking + slashing |
| `BaseStrategy.sol` | 191 | Abstract base with state machine + health checks |
| `BearStrategy.sol` | 187 | WETH→USDC capital preservation |
| `RegimeDampener.sol` | 146 | 3-epoch confirmation with vol-floor bypass |
| `AaveMoneyMarketStrategy.sol` | 109 | Shared base for Neutral + Crisis |
| `NeutralStrategy.sol` | 16 | Thin wrapper, regime 0 |
| `CrisisStrategy.sol` | 16 | Thin wrapper, regime 3 |

**Total: ~3,020 nSLOC. 214 tests passing, 0 failures.**

### Backtest pipeline

Full Python backtest published at [github.com/rome-guerrero9/rayp-backtest](https://github.com/rome-guerrero9/rayp-backtest):
- Feature engineering (realised vol, momentum, stablecoin dominance, funding rates)
- Regime classifier matching on-chain thresholds exactly
- Dampener simulator replicating `RegimeDampener.sol` tick-for-tick
- Crisis detection with early-warning measurement
- Institutional metrics: Sharpe, Calmar, regime time distribution, monthly returns

---

## 5. Milestones & Deliverables

| Week | Milestone | Verification |
|------|-----------|--------------|
| 1-2 | Sepolia operational demo (deploy already complete, April 2026) | Addresses published in this thread + recorded classifier walk-through |
| 3-4 | Code4rena audit submission | Public contest page live |
| 4-6 | Audit remediation (all C/H findings fixed) | Git commits + updated test suite |
| 6-7 | Mainnet deployment | Verified on Arbiscan |
| 7-8 | Keeper bootstrap (5+ independent keepers) | On-chain KeeperRegistry count |
| 8-10 | Seed TVL phase ($5M cap, whitelisted) | On-chain vault balance |
| 10-12 | Public launch + regime signal API live | TVL cap raised, API endpoint live |

---

## 6. Budget Breakdown (200,000 ARB)

| Category | ARB Allocation | Purpose |
|----------|---------------|---------|
| **Code4rena audit** | 60,000 ARB | Competitive audit contest (~$15-25K equivalent) |
| **Keeper incentives** | 50,000 ARB | Bootstrap keeper network for first 90 days |
| **LP incentives** | 50,000 ARB | Early depositor rewards during TVL cap phase |
| **Infrastructure** | 20,000 ARB | RPC nodes, oracle infrastructure, monitoring |
| **Integration tooling and public goods** | 20,000 ARB | Open-source SDK, regime signal API infrastructure, public dashboard |

**All ARB distributed to keepers and LPs is tracked on-chain and reported monthly. Zero ARB allocated to team equity, buybacks, or compensation.**

---

## 7. Success Metrics

### Protocol health
- TVL: $5M at launch cap → $25M by month 6
- Keeper network: 5+ independent keepers within 30 days of mainnet
- Classifier uptime: 99.5%+ epoch completion
- Rebalance slippage: average ≤ 30bps

### Ecosystem impact
- Oracle integration: Chainlink + Pyth consensus layer operational on Arbitrum
- Open-source adoption: regime classifier forked by 3+ protocols within 6 months
- Regime signal API: 50+ unique addresses consuming public feed within 90 days

### Grant-specific KPIs
- 100% of keeper incentive ARB distributed by week 12
- Zero VC equity sold during grant period
- 80%+ of launch TVL from Arbitrum-native depositors

---

## 8. Risk Disclosure

| Risk | Mitigation |
|------|------------|
| Classifier accuracy in novel regimes | 3x confirmation dampener, 250% vol floor auto-CRISIS bypass, validated against 4 major crashes |
| Smart contract exploit | Code4rena audit before mainnet, Immunefi bug bounty from day one, $5M TVL cap for first 90 days |
| Oracle manipulation | Dual-source consensus (Chainlink + Pyth within 2%), staleness checks, TWAP smoothing |
| Flash loan attack on BullStrategy | `msg.sender == aavePool` + `initiator == address(this)` guards, health factor > 1.3 enforced |
| Keeper centralisation | Permissionless registration with ETH stake, per-block cooldown, competitive fee schedule |
| USDC depeg in BearStrategy | Health check monitors aUSDC vs totalDeposited, >10% drop triggers emergency exit |

---

## 9. Team

**Warrior AI Automations** — an AI consulting and automation agency with production experience building adaptive trading systems, multi-agent infrastructure, and on-chain automation tooling.

**Prior work relevant to RAYP:**
- Production crypto trading bot with adaptive regime detection (bull/bear/crisis classification), stablecoin arbitrage modules, circuit breakers — the direct predecessor to RAYP's on-chain classifier
- Multi-agent AI systems and MCP server integrations deployed for enterprise clients
- RAG systems, n8n automation workflows, and SaaS MVPs for AI-native businesses

**Core build team:**
- Protocol founder — AI/automation architecture, regime classifier design, oracle integration, strategy implementation
- Solidity engineering — vault, keeper registry, strategy contracts, full test suite (complete)
- Quant advisory — regime parameter backtesting, slippage modelling

Security review and audit oversight will be conducted through Code4rena. The founding team operates lean, consistent with the protocol's anti-payroll design philosophy.

---

## 10. Open Questions for the Committee

1. Does the committee prefer a single 200K ARB allocation or a phased release tied to milestone completion? We are open to milestone-gated tranches.
2. Is there an existing Arbitrum DAO treasury working group that RAYP should brief on the regime-adaptive treasury management use case?
3. Would the committee recommend a co-application with an existing Arbitrum-native protocol (Aave, Uniswap) to strengthen the integration milestones?

---

## 11. Links

- **Protocol repo**: https://github.com/rome-guerrero9/rayp
- **Backtest repo**: https://github.com/rome-guerrero9/rayp-backtest
- **Research post** (methodology + results): https://paragraph.com/@0x05fd5259cdd72d3f946e1d82a36ab4ea1a0c14f1-caf4/we-back-tested-a-regime-adaptive-vault-against-43849-hours-of-eth-data-it-detected-every-major-crash
- **Contact**: warriorai@proton.me

Happy to answer any questions, jump on a call, or provide additional materials. Thanks for considering RAYP.

— Rome Guerrero, Warrior AI Automations
