# RAYP — Project Status

**Canonical state of record.** Read this at the start of every session, edit at the end of every milestone. Anything not in this file (or another committed doc it links to) does not exist as far as this project is concerned.

Last updated: 2026-06-16 — off-record drafts consolidated into `docs/`; cleanup pass on known-unknowns and open work items.

---

## At a glance

| Area | Status |
|---|---|
| Smart contracts | Implemented; 11 contracts, ~3,020 nSLOC in audit scope |
| Local test suite | 214 tests passing, 0 failures (claim per `AUDIT_SCOPE.md` — re-run before sending to a firm) |
| Arbitrum Sepolia deployment | Deployed 2026-04-17 — see `SEPOLIA_DEPLOYMENT.md` |
| Sepolia source verification on Arbiscan | Not done — `forge verify-contract` pending per contract |
| Arbitrum One mainnet deployment | Not deployed |
| Multisig (Arbitrum One Safe) | Candidate address recorded — **on-chain verification pending** (see `MULTISIG.md`) |
| Audit scope document | Committed — `AUDIT_SCOPE.md` |
| Audit cover email | Committed — `AUDIT_COVER_EMAIL.md` |
| Audit submission | **Unconfirmed** — claimed sent 2026-04-20 but no thread URL / firm response in repo |
| LTIPP forum post draft | Committed — `ARBITRUM_FORUM_POST.md` (not yet published) |
| Arbitrum DAO grant proposal | Committed — `RAYP_DAO_Grant_Proposal.md` (not yet submitted) |
| Optimism Retro Funding application | Drafted within `RAYP_DAO_Grant_Proposal.md` §8.2 (not yet submitted) |
| Mirror post | URL not recorded — see `MIRROR_POST.md` |
| Regime signal bot | Implemented in `bot/`, daily GH Actions cron in `.github/workflows/regime-bot.yml` |

---

## Repository layout

```
src/                     — RAYPVault, OracleAggregator, RegimeDampener,
                           KeeperRegistry, NeutralStrategy, BullStrategy,
                           BearStrategy, CrisisStrategy, BaseStrategy,
                           AaveMoneyMarketStrategy
test/                    — Foundry test suite (214 tests)
script/DeployRAYPSepolia.s.sol  — Sepolia deploy (12 contracts incl. mocks)
script/DeployStrategies.s.sol   — Mainnet strategy deploy (hardcoded Arbitrum addrs)
bot/                     — Regime signal bot (TypeScript)
.github/workflows/       — Daily cron for the bot
docs/                    — This file and related artifacts (see below)
```

### `docs/` inventory

| File | Purpose | State |
|---|---|---|
| `PROJECT_STATUS.md` | This file — canonical state | Current |
| `SESSION_PLAYBOOK.md` | Start/end-of-session ritual | Current |
| `SEPOLIA_DEPLOYMENT.md` | Recorded Sepolia addresses + role mapping | Current |
| `MULTISIG.md` | Safe address + verification checklist | **Pending on-chain verification** |
| `AUDIT_SCOPE.md` | Audit scope, threat model, invariants | Current |
| `AUDIT_COVER_EMAIL.md` | Outbound email for audit firm | Current |
| `ARBITRUM_FORUM_POST.md` | LTIPP forum draft | Ready to publish |
| `RAYP_DAO_Grant_Proposal.md` | Full ARB + OP grant proposal | Ready to submit |
| `MIRROR_POST.md` | Mirror post URL slot + body snapshot | Stub — URL not recorded |

---

## Known unknowns

The items below are still off-record and must be confirmed before any public commitment depends on them:

1. **Arbitrum One Safe.** Address `0xa7a8Eb8FF9dD7481b62BC6900F4e331BacBe638d` is referenced in three drafts but not yet confirmed on-chain to be a deployed 2-of-3 Safe with the expected owners. See `MULTISIG.md` for the verification commands. Blocks: grant submission, mainnet deploy.
2. **Audit submission record.** A submission to Code4rena / Sherlock was claimed for 2026-04-20 but no thread URL, contest page, or firm response is in the repo. Treat as **not submitted** until a thread URL is found. The committed `AUDIT_COVER_EMAIL.md` is a *draft* of the outreach, not evidence it was sent.
3. **Mirror post URL.** If a Mirror post about RAYP exists, its URL is unrecorded. If it doesn't exist, delete `docs/MIRROR_POST.md` and note "Mirror: never published" here.
4. **Pre-mainnet admin custody.** `SEPOLIA_DEPLOYMENT.md` records the deployer EOA as admin / guardian / treasury on testnet. This is fine for Sepolia but **must not carry to mainnet** — mainnet roles must be granted to the verified Safe at deploy time, not transferred post-deploy. Track as a hard gate in the mainnet checklist.

---

## Open work items

In rough dependency order. Mirror substantive ones as GitHub Issues so they survive across devices.

### Immediate (this week)

1. **Verify the Safe on-chain.** Run the two `cast call` commands in `MULTISIG.md` against Arbitrum One. If threshold + owners match expectations, flip `MULTISIG.md` to verified and remove caveats here. If they don't match, treat the address as unsafe and re-derive.
2. **Resolve the audit-submission ambiguity.** Search email for any 2026-04-20 outreach to Code4rena / Sherlock. If found, paste the thread URL into `AUDIT_SCOPE.md` §"Submission record". If not found, assume not submitted and send `AUDIT_COVER_EMAIL.md` cleanly.
3. **Run `forge test` on a clean checkout** and confirm the "214 passing, 0 failing" number in `AUDIT_SCOPE.md` and the grant proposal. Update both if the count has drifted.

### Pre-mainnet sequence

4. **Verify all 8 production contracts on Arbiscan Sepolia.** `forge verify-contract` per contract. Required before submitting the audit (auditors expect source-verified targets).
5. **Publish the LTIPP forum post.** `ARBITRUM_FORUM_POST.md` is ready. Once posted, record the forum URL here and in the grant proposal §11.
6. **Submit the Arbitrum DAO grant proposal.** `RAYP_DAO_Grant_Proposal.md` §8.1 (200K ARB). Recipient address is the Safe — gated on item #1 above.
7. **Submit the Optimism Retro Funding application.** Same proposal §8.2 (500K OP). Gated on confirming the current Retro Funding round is open and the eligibility criteria for the proposal language.
8. **Complete the Code4rena audit.** Submission → contest → C/H remediation → re-test. Tracked weeks 3-6 in the grant proposal milestone schedule.
9. **Set up Immunefi bug bounty.** Referenced in the risk disclosure of both forum post and grant proposal. Need a concrete tier (size, scope, payouts) before mainnet.
10. **Mainnet deploy.** Blocked on items #1, #4, #8. Deploy script must grant all admin roles to the verified Safe in the same broadcast — no post-deploy ownership transfer.
11. **Bootstrap the keeper network.** Five-plus independent keepers within 30 days of mainnet (per grant proposal §7). Distribute the 50K ARB keeper-incentive allocation per the budget.
12. **Seed TVL phase.** $5M cap, whitelisted depositors, 90-day duration (per grant proposal §6, weeks 8-10). Not started.
13. **Public launch + regime signal API.** Final milestone in the grant timeline. Includes the public dashboard and SDK referenced in the public-goods allocation.

---

## Recent activity (newest first)

- 2026-06-16 — Off-record drafts consolidated into `docs/` (forum post, audit scope, cover email, grant proposal, Sepolia deployment record). Four pre-submission fixes applied to grant proposal + forum post: deduped table, recast Week 1-2 milestone since Sepolia is already live, dropped contradictory USD audit estimate, renamed "RPGF Round 4" → "Optimism Retro Funding". PR #1 carries all of this.
- 2026-04-17 — Arbitrum Sepolia deploy: 12 contracts (8 production + 4 mocks). Deployer EOA `0x9F4B…f815` holds admin / guardian / treasury roles on testnet.
- 2026-04-22 — Latest commit on master before this consolidation (`37d35ce`): regime signal bot + daily GH Actions cron.

---

## Session ritual

See `SESSION_PLAYBOOK.md`.
