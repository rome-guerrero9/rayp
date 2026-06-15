# DAO GRANT PROPOSAL

## Regime-Adaptive Yield Protocol

*The first on-chain vault that knows what market it is in.*

---

## 1. Executive Summary

RAYP is a decentralised ERC-4626 vault protocol on Arbitrum that autonomously detects prevailing market regimes -- bull, bear, crisis, or neutral -- and routes LP capital into the optimal yield strategy for each state. No human intervention is required. An on-chain regime classifier reads Chainlink and Pyth oracle feeds, derives a consensus market label each epoch, and triggers vault rebalances via a permissionless keeper network.

**The protocol is built and tested.** The full contract suite -- vault, oracle aggregator, regime dampener, keeper registry, and all four strategy contracts -- compiles and passes 214 unit tests with 0 failures. The backtest covers 43,849 hours of ETH data (2020--2024) and shows:

| Metric | Buy & Hold ETH | RAYP |
|--------|---------------|------|
| Total Return | +2,507% | +7,219% |
| Max Drawdown | 81.4% | 56.1% |
| Sharpe Ratio | 1.06 | 1.83 |
| Calmar Ratio | 1.13 | 2.42 |
| Annualised Return | 91.8% | 135.8% |
| Annualised Volatility | 82.6% | 72.1% |
| Sharpe Ratio | 1.06 | 1.83 |
| Calmar Ratio | 1.13 | 2.42 |

**Crisis detection: 4 for 4** on major ETH drawdowns:
- COVID March 2020: detected 15 hours before trough
- China mining ban May 2021: detected 825 hours before trough
- Luna/UST May 2022: detected 797 hours before trough
- FTX November 2022: detected 298 hours before trough

Unlike static yield aggregators such as Yearn and Beefy, RAYP eliminates macro timing risk for depositors. During the 2022 bear market and subsequent liquidity crises, LPs in bull-optimised vaults suffered compounding losses while protocols continued charging management fees. RAYP's thesis is simple: every yield protocol today assumes the market stays constant. It does not. RAYP is the first protocol where the vault itself adapts -- automatically, transparently, and on-chain.

---

## 2. Problem Statement

### 2.1 Static vaults fail in dynamic markets

Every major yield aggregator deployed today -- Yearn, Beefy, Convex, Pendle -- selects a strategy at deployment time and holds it regardless of macro conditions. During bull markets this works. During the 2022 bear and 2023 liquidity crises, these protocols systematically underperformed because they were structurally incapable of rotating to defensive positions.

### 2.2 Governance is too slow for tactical rotation

Protocols that do support multi-strategy vaults rely on governance votes to rotate capital. DAO governance operates on weekly or monthly cycles. Markets move in hours. By the time a proposal to exit a failing strategy reaches quorum, the damage to LP capital is done. RAYP replaces governance-gated rotation with a deterministic, auditable, on-chain classifier.

### 2.3 No on-chain macro intelligence primitive exists

There is no primitive in the Arbitrum DeFi stack today that provides reliable on-chain market regime classification. Protocols and DAO treasuries are forced to rely on off-chain signals, centralised oracles, or human discretion -- all points of failure. RAYP is the first protocol to bring this capability fully on-chain.

---

## 3. Protocol Solution

### 3.1 The regime classifier

RAYP's core innovation is an on-chain regime classification engine that reads a composite of validated inputs each epoch and outputs a discrete market state label. The classifier is derived from a production trading system and validated against 43,849 hours of historical data.

| Regime | Strategy | Protocol | Purpose |
|--------|----------|----------|---------|
| **NEUTRAL (0)** | Aave WETH supply | Aave v3 | Moderate lending yield (~2% APY) |
| **BULL (1)** | Leveraged WETH loop | Aave v3 + Uniswap V3 | 2x leveraged long ETH via flash loans |
| **BEAR (2)** | Stablecoin supply | Aave v3 + Uniswap V3 | Swap to USDC, preserve capital |
| **CRISIS (3)** | Safe harbor | Aave v3 | Park everything safe until the storm passes |

The vault spends 85.3% of time in NEUTRAL, only rotating when confirmed regime shifts occur. Over the backtest period, 348 confirmed transitions averaged one regime change every 5.3 days -- frequent enough to respond to real shifts, infrequent enough to avoid churning through gas and slippage.

### 3.2 Oracle aggregation pipeline

The classifier reads from a four-layer validated oracle stack:

1. **Raw feeds**: Chainlink ETH/USD price + volatility, Pyth ETH/USD price + confidence interval
2. **Per-source validation**: Staleness checks (7200s threshold), confidence interval bounds, timestamp underflow guards
3. **Cross-source consensus**: Chainlink and Pyth must agree within 2% or the rebalance pauses
4. **TWAP smoothing**: 1-hour ring buffer on volatility inputs prevents single-block manipulation

All oracle logic lives in `OracleAggregator.sol` -- a single contract that outputs a validated `OracleSnapshot` struct each epoch.

### 3.3 Autonomous execution

A permissionless keeper network monitors regime transitions and executes rebalances via the `KeeperRegistry` contract. Keepers post ETH stake to register, earn per-rebalance fees, and are slashed for misbehaviour. An epoch dampening circuit breaker (`RegimeDampener`) requires three consecutive regime confirmations before any rebalance fires -- eliminating false positives from market noise. The one exception: if 7-day realised volatility hits 250% annualised, the dampener is bypassed and the vault transitions to CRISIS immediately.

### 3.4 ERC-4626 composability with lending safety

RAYP vaults implement the ERC-4626 specification with two critical additions:

1. **Rebalance-window locking**: Deposits and withdrawals are locked during rebalance windows, preventing MEV sandwich attacks
2. **TWAP share price oracle**: Exposed for lending protocol integrations (Aave v3, Morpho Blue), preventing transient rebalance dips from triggering unjust liquidations

### 3.5 Strategy architecture

All four strategies inherit from `BaseStrategy`, which handles access control, state machine (ACTIVE / WIND_DOWN / EMERGENCY_EXIT), health check auto-emergency after 2 consecutive failures, and harvest try/catch guarantees. Each strategy implements five functions:

```
_deploy(assets)          -- deploy into yield protocol
_liquidate(assets)       -- partial exit
_liquidateAll()          -- full exit (must leave totalAssets == 0)
_harvestRewards()        -- claim + compound rewards
_checkProtocolHealth()   -- never reverts, returns (bool, string)
```

NEUTRAL and CRISIS share a common base (`AaveMoneyMarketStrategy`) since both supply WETH to Aave v3 -- differing only in regime assignment. BEAR swaps WETH to USDC via Uniswap V3 before supplying. BULL uses Aave v3 flash loans to create a leveraged WETH loop (supply WETH, borrow USDC, swap back, re-supply) at configurable leverage.

---

## 4. Arbitrum Ecosystem Fit

### 4.1 Protocol integrations on Arbitrum

RAYP's entire strategy library targets Aave v3 and Uniswap V3 -- both live and battle-tested on Arbitrum. Every strategy interaction (supply, withdraw, borrow, repay, flash loan, swap) uses Arbitrum-native contract deployments. This is not a multi-chain protocol with Arbitrum as an afterthought -- it is Arbitrum-first by design.

### 4.2 DAO treasury opportunity

Arbitrum's own DAO treasury holds idle assets earning nothing. RAYP is a natural fit for protocol-owned treasury diversification -- depositing DAO-held ETH into a regime-adaptive vault that automatically protects capital during downturns. The grant programme creates a pilot use case with the DAO itself as an early depositor.

### 4.3 Arbitrum-specific oracle advantages

Chainlink Data Streams on Arbitrum offer sub-second price feeds not available on other chains. Combined with Pyth's pull oracle, RAYP's regime classifier gets materially better input data quality on Arbitrum than it could achieve elsewhere.

### 4.4 Keeper network on Arbitrum

RAYP's `KeeperRegistry` is a purpose-built permissionless keeper system with ETH staking, per-block cooldowns, and anti-sandwich guards. Arbitrum's low gas costs make keeper economics viable at scale -- rebalance transactions that would cost $50-100 on L1 cost pennies on Arbitrum.

---

## 5. What Is Already Built

This is not a proposal for vapourware. The following is complete, tested, and open-source:

### 5.1 Smart contracts (Solidity ^0.8.24, Foundry)

| Contract | Status | Description |
|----------|--------|-------------|
| `RAYPVault.sol` | Complete | ERC-4626 vault with HWM fees, TWAP oracle, circuit breakers |
| `OracleAggregator.sol` | Complete | 4-layer Chainlink + Pyth consensus pipeline |
| `RegimeDampener.sol` | Complete | 3-epoch confirmation with vol-floor CRISIS bypass |
| `KeeperRegistry.sol` | Complete | Permissionless keeper auth with staking and slashing |
| `NeutralStrategy.sol` | Complete | Aave v3 WETH supply (regime 0) |
| `BullStrategy.sol` | Complete | Flash-loan leveraged WETH loop (regime 1) |
| `BearStrategy.sol` | Complete | WETH->USDC capital preservation (regime 2) |
| `CrisisStrategy.sol` | Complete | Aave v3 safe harbor (regime 3) |
| `AaveMoneyMarketStrategy.sol` | Complete | Shared base for Neutral + Crisis |
| `BaseStrategy.sol` | Complete | Abstract base with state machine + health checks |

**Test suite: 214 tests passing, 0 failures.** Includes unit tests, mock-based integration tests, and a fork test against live Arbitrum Aave v3 and Uniswap V3 contracts.

### 5.2 Backtest (Python, 43,849 hours)

Full backtest pipeline published at [github.com/rome-guerrero9/rayp-backtest](https://github.com/rome-guerrero9/rayp-backtest):
- Feature engineering: realised vol, momentum, stablecoin dominance, funding rates
- Regime classifier matching on-chain thresholds exactly
- Dampener simulator replicating `RegimeDampener.sol` tick-for-tick
- Crisis detection analysis with early-warning measurement
- Institutional metrics: Sharpe, Calmar, regime time distribution, monthly returns
- Visualisation suite: regime timeline, crisis detection, drawdown comparison, institutional metrics

### 5.3 Deployment scripts

- `DeployStrategies.s.sol` -- mainnet strategy deployment with hardcoded Arbitrum addresses
- `DeployRAYPSepolia.s.sol` -- full protocol stack for Arbitrum Sepolia with mock dependencies

### 5.4 Open source

All code is public:
- **Protocol**: [github.com/rome-guerrero9/rayp](https://github.com/rome-guerrero9/rayp)
- **Backtest**: [github.com/rome-guerrero9/rayp-backtest](https://github.com/rome-guerrero9/rayp-backtest)

---

## 6. Milestones and Deliverables

The following milestones are proposed for the Arbitrum LTIPP 12-week programme. All milestones are verified on-chain or by publicly verifiable deliverables.

| Week | Milestone | Deliverable | Verification |
|------|-----------|-------------|--------------|
| 1-2 | Testnet deployment | Full protocol stack live on Arbitrum Sepolia | Contract addresses published, all functions callable |
| 3-4 | Code4rena audit submission | Audit contest launched | Public Code4rena contest page |
| 4-6 | Audit remediation | All critical/high findings fixed, re-tested | Git commits + updated test suite |
| 6-7 | Mainnet deployment | All contracts deployed to Arbitrum One | Verified on Arbiscan |
| 7-8 | Keeper bootstrap | 5+ independent keepers registered and staked | On-chain keeper count via KeeperRegistry |
| 8-10 | Seed TVL phase | $5M TVL cap, whitelisted early depositors | On-chain vault balance |
| 10-12 | Public launch | TVL cap raised, open deposits, regime signal API live | On-chain + API endpoint |

---

## 7. Success Metrics

### Protocol health

| Metric | Target |
|--------|--------|
| Total Value Locked | $5M at launch cap, $25M by month 6 |
| Keeper network | 5+ independent keepers within 30 days of mainnet |
| Regime classifier uptime | 99.5%+ epoch completion rate |
| Rebalance slippage | Average <= 30bps per rebalance |
| Test coverage | 214+ passing tests maintained through all updates |

### Ecosystem impact

| Metric | Target |
|--------|--------|
| Oracle integration | Chainlink + Pyth consensus layer operational on Arbitrum |
| Lending safety | TWAP oracle adapter pattern published and documented |
| Open-source adoption | Regime classifier forked by 3+ protocols within 6 months |
| Regime signal API | 50+ unique addresses consuming public regime feed within 90 days |

### Grant-specific KPIs (Arbitrum LTIPP)

| Metric | Target |
|--------|--------|
| ARB incentives distributed | 100% of keeper incentive ARB distributed by week 12 |
| Non-dilutive funding | Zero VC equity sold during grant period |
| Arbitrum-native TVL | 80%+ of launch TVL from Arbitrum-native depositors |

---

## 8. Budget and Grant Request

### 8.1 Arbitrum LTIPP -- 200,000 ARB requested

| Category | ARB Allocation | Purpose |
|----------|---------------|---------|
| Code4rena audit | 60,000 ARB | Competitive audit contest (~$15-25K equivalent) |
| Keeper incentives | 50,000 ARB | Bootstrap keeper network for first 90 days |
| LP incentives | 50,000 ARB | Early depositor rewards during TVL cap phase |
| Infrastructure | 20,000 ARB | RPC nodes, oracle infrastructure, monitoring |
| Integration tooling and public goods | 20,000 ARB | Open-source SDK, regime signal API infrastructure, public dashboard |

All ARB distributed to keepers and LPs is tracked on-chain and reported monthly. No ARB allocated to team equity or token buybacks.

### 8.2 Optimism RPGF -- 500,000 OP requested

| Category | OP Allocation | Purpose |
|----------|--------------|---------|
| Open-source contract libraries | 200,000 OP | Regime classifier, oracle aggregator, strategy base |
| Documentation and education | 100,000 OP | Technical docs, integration guides, regime methodology |
| Ecosystem developer grants | 100,000 OP | Sub-grants to builders who fork and extend RAYP's open-source primitives |
| Community tooling | 100,000 OP | Regime signal API, public dashboard, SDK |

OP tokens fund public goods output. No OP allocated to team compensation or equity-equivalent structures.

---

## 9. Team

RAYP is developed by **Warrior AI Automations**, an AI consulting and automation agency with production experience building adaptive trading systems, multi-agent infrastructure, and on-chain automation tooling.

### Relevant prior work

- **Production crypto trading bot** with adaptive regime detection (bull/bear/crisis classification), stablecoin arbitrage modules, and circuit breakers -- the direct predecessor to RAYP's on-chain classifier
- **Multi-agent AI systems** and MCP server integrations deployed for enterprise clients
- **RAG systems**, n8n automation workflows, and SaaS MVPs for AI-native businesses

### Core build team

- **Protocol founder** -- AI/automation architecture, regime classifier design, oracle integration, strategy implementation
- **Solidity engineering** -- vault, keeper registry, strategy contracts, full test suite (complete)
- **Quant advisory** -- regime parameter backtesting, slippage modelling, institutional metrics

Security review and audit oversight will be conducted through Code4rena. The founding team operates the core protocol with AI agents handling routine operations -- a lean team consistent with the protocol's anti-payroll design philosophy.

---

## 10. Risk Disclosure

| Risk | Mitigation |
|------|------------|
| **Classifier accuracy in novel regimes** | 3x confirmation dampener, 250% vol floor auto-CRISIS bypass, validated against 4 major crashes |
| **Smart contract exploit** | Code4rena audit before mainnet, Immunefi bug bounty from day one, $5M TVL cap for first 90 days, immutable vault core |
| **Oracle manipulation** | Dual-source consensus (Chainlink + Pyth within 2%), staleness circuit breakers, TWAP smoothing |
| **Flash loan attack on BullStrategy** | `msg.sender == aavePool` + `initiator == address(this)` guards, health factor > 1.3 enforced |
| **Keeper centralisation** | Permissionless registration with ETH stake, per-block cooldown, competitive fee schedule |
| **USDC depeg in BearStrategy** | Health check monitors aUSDC vs totalDeposited, >10% drop triggers emergency exit |
| **Regulatory classification** | Non-custodial smart contract system, no central operator, no VC pre-sale |

---

## 11. Open Questions for Grant Committee

1. Does the committee prefer a single 200K ARB allocation or a phased release tied to milestone completion? RAYP is open to milestone-gated tranches.
2. Is there an existing Arbitrum DAO treasury working group that RAYP should brief on the regime-adaptive treasury management use case?
3. For Optimism RPGF: does the committee consider production-ready smart contract libraries a qualifying public good, or is community education output weighted more heavily?
4. Would the committee recommend a co-application with an existing Arbitrum-native protocol (e.g. Aave, Uniswap) to de-risk the integration milestones?

---

## 12. Appendices

### A. Deployed contract references

All contracts are available for committee review on GitHub:

- **Protocol repository**: [github.com/rome-guerrero9/rayp](https://github.com/rome-guerrero9/rayp)
- **Backtest repository**: [github.com/rome-guerrero9/rayp-backtest](https://github.com/rome-guerrero9/rayp-backtest)

Key contracts:
- `RAYPVault.sol` -- ERC-4626 vault with regime-based strategy routing
- `OracleAggregator.sol` -- 4-layer Chainlink + Pyth validation pipeline
- `RegimeDampener.sol` -- epoch dampening with 3-confirmation threshold
- `KeeperRegistry.sol` -- permissionless keeper registration with staking
- `BullStrategy.sol` -- flash-loan leveraged WETH loop
- `BearStrategy.sol` -- WETH->USDC capital preservation
- `AaveMoneyMarketStrategy.sol` -- shared Aave v3 supply base (Neutral + Crisis)

### B. Backtest methodology

- **Data**: 43,849 hourly ETH/USD candles (Jan 2020 -- Dec 2024) from CryptoCompare
- **Features**: Realised volatility (168h rolling), 7d/30d momentum, stablecoin dominance (DefiLlama), perpetual funding rates
- **Classifier**: Exact replication of on-chain `OracleAggregator` thresholds
- **Dampener**: Tick-for-tick simulation of `RegimeDampener.sol` with vol-floor bypass
- **Regime distribution**: NEUTRAL 85.3%, BEAR 7.8%, BULL 5.1%, CRISIS 1.8%
- **Transitions**: 348 confirmed over 5 years (~1 every 5.3 days)

### C. Institutional metrics

| Metric | Buy & Hold | RAYP |
|--------|-----------|------|
| Sharpe Ratio | 1.06 | 1.83 |
| Calmar Ratio | 1.13 | 2.42 |
| Annualised Return | 91.8% | 135.8% |
| Annualised Volatility | 82.6% | 72.1% |
| Max Drawdown | 81.4% | 56.1% |

### D. Grant programme alignment

This proposal targets **Arbitrum LTIPP** (Long-Term Incentive Pilot Programme), which funds ecosystem-building work over 12-week periods. It simultaneously targets **Optimism RPGF Round 4** for open-source public goods output. The two grants are complementary, not overlapping: LTIPP funds Arbitrum-specific deployment and incentives; RPGF funds chain-agnostic open-source contributions.

---

*Warrior AI Automations -- warriorai@proton.me -- Submitted for DAO review Q2 2026*
