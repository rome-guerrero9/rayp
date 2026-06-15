# RAYP — Project Status

**Canonical state of record.** Read this at the start of every session, edit at the end of every milestone. Anything not in this file (or another committed doc it links to) does not exist as far as this project is concerned.

Last updated: 2026-06-15 — Sepolia addresses confirmed and recorded in `SEPOLIA_DEPLOYMENT.md`.

---

## At a glance

| Area | Status |
|---|---|
| Smart contracts | Implemented; tests passing on local fork |
| Local test suite | Green (per commit `4bdf0fe`) |
| Arbitrum Sepolia deployment | Deployed 2026-04-17 — see `SEPOLIA_DEPLOYMENT.md` |
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

Sepolia deploy is now confirmed (see `SEPOLIA_DEPLOYMENT.md`). Remaining off-record items still to confirm:

1. **Arbitrum One Safe**: candidate `0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d`, 2-of-3 — confirm at https://app.safe.global before treating as canonical.
2. **Audit submission**: claimed sent 2026-04-20 to Code4rena and/or Sherlock — confirm by retrieving the submission email or thread URL.
3. **Mirror post**: URL not recorded.
4. **LTIPP forum post**: draft authored off-record (`F:\rayp\docs\ARBITRUM_FORUM_POST.md`) — needs to be committed.
5. **Audit scope / cover email / grant proposal**: drafts authored off-record (`F:\rayp\docs\AUDIT_SCOPE.md`, `AUDIT_COVER_EMAIL.md`, `RAYP_DAO_Grant_Proposal.md`) — need to be committed.

If you can't confirm an item, mark it `TODO — recreate` rather than carrying a phantom value forward.

---

## Open work items

These are the live tasks. Mirror them as GitHub Issues so they survive across devices.

1. **Verify Sepolia contract source on Arbiscan.** Addresses recorded; run `forge verify-contract` for each of the 8 production contracts so the source is browsable on the explorer.
2. **Confirm and document the multisig.** See `MULTISIG.md`. Verify the Safe address and signer set, then post the address in the README footer.
3. **Audit follow-up.** Either retrieve confirmation of the 2026-04-20 submission, or re-submit. Document the contact + response window in `docs/AUDIT_SCOPE.md`.
4. **LTIPP forum post.** Finalize draft (`docs/ARBITRUM_FORUM_POST.md`), publish, record the URL here.
5. **Seed TVL plan.** Out of scope for this consolidation pass.
6. **Mainnet deployment.** Blocked on (1)–(3).

---

## Session ritual

See `SESSION_PLAYBOOK.md`.
