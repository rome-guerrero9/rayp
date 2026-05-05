# Audit Scope

**Status:** TODO — recreate. A submission was claimed off-record (2026-04-20, to Code4rena and/or Sherlock) but is not confirmed in this repo. Either retrieve the original scope doc and paste below, or rebuild from scratch before re-submitting.

## In scope

| File | LOC | Notes |
|---|---|---|
| `src/RAYPVault.sol` | TODO | Core vault, share accounting, deposit/withdraw |
| `src/OracleAggregator.sol` | TODO | Chainlink + Pyth aggregation, staleness |
| `src/RegimeDampener.sol` | TODO | Regime-switch logic, hysteresis |
| `src/KeeperRegistry.sol` | TODO | Keeper auth, rate limits |
| `src/NeutralStrategy.sol` | TODO | |
| `src/BullStrategy.sol` | TODO | |
| `src/BearStrategy.sol` | TODO | |
| `src/CrisisStrategy.sol` | TODO | Drawdown halt |

Total in-scope LOC: `TODO`

## Out of scope

- `script/` deploy scripts
- `bot/` regime signal bot (off-chain, no on-chain authority)
- `lib/` external libraries (OpenZeppelin, forge-std)
- Mocks in `script/DeployRAYPSepolia.s.sol`

## Test coverage

- [ ] Branch coverage report attached
- [ ] Fork tests against Arbitrum One (Chainlink + Pyth feeds)
- [ ] Invariant tests for vault accounting

Run locally:

```bash
forge coverage --report lcov
forge test --gas-report
```

## Threat model summary

- Deposit/withdraw share-price manipulation
- Oracle staleness or single-source dependence
- Regime-switch frontrunning
- Keeper griefing
- Strategy migration / upgrade trust assumptions
- Crisis halt unwinding

Expand each into a paragraph before submission.

## Submission record

| Field | Value |
|---|---|
| Submitted to | TODO (Code4rena / Sherlock / other) |
| Submission date | TODO (claimed 2026-04-20) |
| Contact email | TODO |
| Thread / contest URL | TODO |
| Expected response window | TODO |
| Current status | TODO |

If 2026-04-20 submission cannot be confirmed by replying to the original email or finding the contest URL, **assume not submitted** and re-submit fresh. Phantom submissions are worse than no submission.
