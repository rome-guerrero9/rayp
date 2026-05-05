# RAYP — Project Status

**Canonical state of record.** Read this at the start of every session, edit at the end of every milestone. Anything not in this file (or another committed doc it links to) does not exist as far as this project is concerned.

Last updated: 2026-05-05 — initial consolidation; addresses pending recovery.

---

## At a glance

| Area | Status |
|---|---|
| Smart contracts | Implemented; tests passing on local fork |
| Local test suite | Green (per commit `4bdf0fe`) |
| Arbitrum Sepolia deployment | **Unverified — see `SEPOLIA_DEPLOYMENT.md`** |
| Arbitrum One mainnet deployment | Not deployed |
| Multisig (Arbitrum One) | **Candidate address recorded — see `MULTISIG.md` (unverified)** |
| Audit | **Submission claimed off-record; not confirmed in repo** |
| LTIPP / DAO grant | Drafts referenced but not consolidated |
| Mirror post | URL pending — see `MIRROR_POST.md` |
| Regime signal bot | Implemented in `bot/`, daily GH Actions cron in `.github/workflows/regime-bot.yml` |

---

## Repository layout

```
src/                     — RAYPVault, OracleAggregator, RegimeDampener,
                           KeeperRegistry, NeutralStrategy, BullStrategy,
                           BearStrategy, CrisisStrategy
test/                    — Foundry test suite
script/DeployRAYPSepolia.s.sol  — Sepolia deploy script (12 contracts)
bot/                     — Regime signal bot (TypeScript)
.github/workflows/       — Daily cron for the bot
docs/                    — This file and related artifacts
```

---

## Known unknowns (verify before publishing anything)

The items below were referenced in off-record sessions but are **not currently verifiable from this repo or from this sandbox** (Arbiscan and public RPCs are not reachable here). Treat them as candidates only until you confirm them locally.

1. **Sepolia deployer EOA**: candidate `0x9F4BE17689018e8e56c225d4E5D775E917C7f815` — confirm by running `cast wallet address $DEPLOYER_PRIVATE_KEY` against the key you used to deploy.
2. **Eight Sepolia contract addresses** for RAYPVault, OracleAggregator, RegimeDampener, KeeperRegistry, NeutralStrategy, BullStrategy, BearStrategy, CrisisStrategy — recovery procedure in `SEPOLIA_DEPLOYMENT.md`.
3. **Arbitrum One Safe**: candidate `0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d`, 2-of-3 — confirm at https://app.safe.global before treating as canonical.
4. **Audit submission**: claimed sent 2026-04-20 to Code4rena and/or Sherlock — confirm by retrieving the submission email or thread URL.
5. **Mirror post**: URL not recorded.
6. **LTIPP forum post**: draft mentioned but not committed.

If you can't confirm an item, mark it `TODO — recreate` rather than carrying a phantom value forward.

---

## Open work items

These are the live tasks. Mirror them as GitHub Issues so they survive across devices.

1. **Verify Arbitrum Sepolia deployment.** Recover the 8 production addresses (procedure in `SEPOLIA_DEPLOYMENT.md`); for each contract verify source on Arbiscan.
2. **Confirm and document the multisig.** See `MULTISIG.md`. Verify the Safe address and signer set, then post the address in the README footer.
3. **Audit follow-up.** Either retrieve confirmation of the 2026-04-20 submission, or re-submit. Document the contact + response window in `docs/AUDIT_SCOPE.md`.
4. **LTIPP forum post.** Finalize draft (`docs/ARBITRUM_FORUM_POST.md`), publish, record the URL here.
5. **Seed TVL plan.** Out of scope for this consolidation pass.
6. **Mainnet deployment.** Blocked on (1)–(3).

---

## Session ritual

See `SESSION_PLAYBOOK.md`.
