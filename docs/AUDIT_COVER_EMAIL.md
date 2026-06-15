# Audit Cover Email

**To**: sponsors@code4rena.com (and/or Sherlock intake form)
**Subject**: Audit request — RAYP (ERC-4626 regime-adaptive vault, ~3K nSLOC, Arbitrum)
**From**: warriorai@proton.me

---

Hi team,

I'd like to submit RAYP for a competitive audit. Quick summary below, with links to the full codebase and supporting materials.

## Protocol

RAYP (Regime-Adaptive Yield Protocol) is an ERC-4626 vault on Arbitrum that automatically rotates capital between four yield strategies based on on-chain market regime detection. The vault reads from Chainlink and Pyth oracles, classifies the market regime (Neutral, Bull, Bear, Crisis), and rebalances capital via a permissionless keeper network. No governance votes, no multisig delay — deterministic, auditable, fully on-chain.

- **GitHub**: https://github.com/rome-guerrero9/rayp
- **Backtest**: https://github.com/rome-guerrero9/rayp-backtest
- **Research post** (methodology + results): https://paragraph.com/@0x05fd5259cdd72d3f946e1d82a36ab4ea1a0c14f1-caf4/we-back-tested-a-regime-adaptive-vault-against-43849-hours-of-eth-data-it-detected-every-major-crash

## Scope

- **Language**: Solidity ^0.8.24
- **Framework**: Foundry (`via_ir = true`)
- **Chain**: Arbitrum One (L2)
- **nSLOC**: ~3,020 across 11 contracts
- **Test suite**: 214 tests passing, 0 failures

Scope document with per-contract nSLOC, external integrations, and key areas of concern is in the repo at `docs/AUDIT_SCOPE.md`.

## External integrations

- Aave v3 Pool (supply, withdraw, borrow, repay, flashLoanSimple)
- Uniswap V3 SwapRouter (WETH↔USDC)
- Chainlink AggregatorV3 (ETH/USD price, volatility, funding feeds)
- Pyth Network (ETH/USD price + confidence interval)
- OpenZeppelin 5.x (AccessControl, Pausable, ReentrancyGuard, ERC4626)

## Key areas for audit attention

1. **Flash loan callback security** — BullStrategy uses Aave v3 flash loans for leveraged WETH loops. Need careful review of `executeOperation()` callback guards and state consistency.
2. **Oracle manipulation** — Dual-source consensus between Chainlink and Pyth with TWAP smoothing. Can an attacker manipulate regime transitions?
3. **Vault rebalance atomicity** — Single-tx withdrawAll → deposit pattern across strategies. MEV and circuit breaker review.
4. **Strategy state machine** — ACTIVE → WIND_DOWN → EMERGENCY_EXIT transitions with auto-emergency after 2 failed health checks.
5. **Price conversion accuracy** — Bear and Bull strategies convert between WETH and USDC denominations using Chainlink ETH/USD; rounding and staleness handling critical.
6. **ERC-4626 compliance** — HWM performance fees + TWAP share price oracle for lending protocol integrations.

## Validation work already completed

- **214 passing tests** including unit tests, mock-based integration tests, and a fork test against live Arbitrum Aave v3 and Uniswap V3
- **5-year backtest** on 43,849 hours of ETH data — Sharpe 1.83, Calmar 2.42, 4/4 crisis detection on major drawdowns (COVID, China ban, Luna/UST, FTX)
- **Clean compile** with `via_ir = true`, no warnings

## Timeline

I'm looking to start the contest as soon as prep is complete — ideally within 3-4 weeks. Mainnet deployment is gated on audit completion, so post-audit mitigation work will be prioritised.

## Budget

Open to either a standard competitive contest ($30-50K range) or a hybrid model with a lead auditor. I'd be particularly interested in a hybrid approach with a certified lead warden assigned to the flash loan callback security and oracle manipulation surfaces — those benefit from deep, sustained attention rather than purely crowdsourced review. Welcome your recommendation based on scope and complexity.

## Known design decisions (not findings)

These are intentional and documented in `docs/AUDIT_SCOPE.md`:

- All four strategies use Aave v3 (architectural consistency)
- RegimeDampener requires 3 confirmations (intentional latency vs whipsaw)
- Vol floor bypass skips dampener for emergency CRISIS detection
- Push pattern for strategy deposits (vault sends assets before calling deposit)
- Chainlink staleness reverts (caught by vault's try/catch in healthCheck)
- Single active strategy at a time (not split across multiple)

Happy to jump on a call to walk through the architecture and scope in detail. Let me know what materials you need next.

Best,
Rome Guerrero
Warrior AI Automations
warriorai@proton.me
