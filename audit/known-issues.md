# RAYP — Known Issues & Static-Analysis Triage

Triage of a `slither` run (162 raw findings) against the contracts in
[`scope.md`](scope.md). Every High/Medium finding was checked against the actual
code. Findings are bucketed below so auditors can skip the noise.

Tooling: `slither` 0.x, `--filter-paths "lib/|test/|script/"`. Raw output:
`slither-report.md` at the repo root.

---

## 1. Resolved in this branch

Both issues found by the triage have been fixed; all 226 tests pass afterward.

### R-1 — Locked ETH in `RAYPVault` — FIXED
`receive() external payable {}` was removed from `RAYPVault`. The vault's asset is
WETH (ERC-20) and the contract has no ETH-spending path, so it now rejects raw ETH
transfers outright — no ETH can become stuck.

### R-2 — Unprotected swap slippage (`amountOutMinimum: 0`) — FIXED
All seven `exactInputSingle` calls that passed `amountOutMinimum: 0` now enforce a
minimum:

- **WETH↔USDC swaps** (`BearStrategy._deploy/_liquidate/_liquidateAll`,
  `BullStrategy._flashDeploy`) — `amountOutMinimum` is derived from the strategy's
  Chainlink price helper (`_wethToUsdc`/`_usdcToWeth`) with a documented 1%
  tolerance (`ORACLE_SWAP_SLIPPAGE_BPS`), sized to absorb Chainlink/Uniswap spot
  drift without reverting a rebalance.
- **Reward-token swaps** (`_harvestRewards` in all three strategies) — the reward
  token has no on-chain price feed, so a keeper-supplied `minRewardOut` is threaded
  through `harvestAndReport`. Sentinel: `minRewardOut == 0` claims rewards but
  skips the swap, so the rebalance-path harvest never performs an unprotected
  swap. Harvest is `onlyVault` and the keeper-facing `harvestStrategy` is
  `KEEPER_ROLE`-gated, so the caller-supplied minimum is trustworthy.

(`BullStrategy._flashLiquidate`/`_flashLiquidateAll` already gated their swaps on
`amountOutMinimum: totalOwed` and were never affected.)

---

## 2. Accepted / by-design — not bugs

These slither findings were reviewed and are intentional. Auditors should not
report them.

| Finding | Verdict |
|---------|---------|
| `arbitrary-send-eth` — `OracleAggregator.updatePythFeeds` | By design. `onlyRole(UPDATER_ROLE)`; fee comes from `pyth.getUpdateFee`, paid to the immutable `pyth` contract; excess refunded to `msg.sender`. |
| `arbitrary-send-eth` — `KeeperRegistry.sweepSlashedFunds` | Accepted. `onlyRole(GUARDIAN_ROLE)` + `to != address(0)`; destination is guardian-chosen by design. |
| `incorrect-equality` (23) | False positives. All are `balanceOf == 0` / `totalSupply == 0` / `shares == 0` integer short-circuit guards, plus the deliberate `block.number == lastRebalanceBlock` same-block anti-sandwich guard. Exact equality is correct. |
| `divide-before-multiply` (2) — `_readPyth`, `harvestFees` | By design. Operands are 1e18-scaled; precision loss is sub-wei / immaterial on already-clamped values. |
| `reentrancy-no-eth` / `reentrancy-benign` / `reentrancy-events` (30) | False positives. Flagged functions carry OpenZeppelin `nonReentrant`; external calls are WETH transfers (cannot reenter) and follow CEI. |
| `uninitialized-local` (4) | False positives. Solidity zero-initializes locals; flagged vars are accumulators (`sum`/`count`) or assigned before use. |
| `unused-return` — Aave reads, Chainlink `latestRoundData` | False positives. Selective tuple destructuring; the fields that matter (staleness, balances) are captured and checked. |
| `pyth-unchecked-confidence` — price feed | False positive. `_readPyth` computes `confBps` and reverts if `> MAX_PYTH_CONF_BPS`; slither's heuristic misses the manual check. |
| `timestamp` (15) | Accepted. `block.timestamp` drives cooldowns / harvest intervals / unbonding; tolerances are minutes-to-days, miner drift immaterial. |
| `assembly` (1) | Accepted. `KeeperRegistry` uses inline assembly only to bubble up an original revert reason. |
| `low-level-calls` (4) | Accepted. `.call` for ETH transfer, `staticcall` for `totalSupply()` — appropriate. |

## 3. Best-practice recommendations (non-blocking)

- **SafeERC20.** The vault and strategies call `transfer`/`transferFrom`/`approve`
  on WETH/USDC and ignore return values. WETH/USDC revert on failure so this is
  safe *today*, but adopting OpenZeppelin `SafeERC20` (`safeTransfer`,
  `forceApprove`) is the standard an auditor will expect and future-proofs
  against non-standard tokens. ~20 call sites.
- **`pyth-unchecked-confidence` — vol feed.** The Pyth *vol* feed's `conf` is not
  explicitly bounded (the *price* feed's is). Mitigated by `_checkVolConsensus`
  cross-checking against Chainlink + FLOOR/CEILING clamps, but an explicit
  conf check would be cleaner.
- **`missing-zero-check` (1)** — add a zero-address guard to the flagged setter.
- **`missing-inheritance` (2)** — declare explicit `is IInterface` inheritance.
- **`cyclomatic-complexity`** — `RAYPVault.executeRebalance` (complexity 13);
  consider extracting rebalance phases for auditor readability.
- **`immutable-states` (6)** / **`naming-convention` (14)** — gas + style only.
