# RAYP Regime Signal Bot

Daily Twitter/X bot that reads the live RAYP deployment on **Arbitrum Sepolia**
(chainId `421614`) and posts the current regime + oracle snapshot at 13:00 UTC
via GitHub Actions.

This bot is **Sepolia-only** until the mainnet deploy.

## What it does

On every run it:

1. Reads `RegimeDampener.confirmedRegime()`, `RAYPVault.activeRegime()`, and
   the validated `OracleAggregator.getSnapshot()` via an RPC call.
2. Compares the confirmed regime against the `lastRegime` stored in
   `bot/state.json`. If different, the tweet includes a transition line.
3. Formats a tweet (≤280 chars) and posts it using `twitter-api-v2`.
4. Writes the new regime + timestamp back to `state.json`, which GitHub
   Actions auto-commits to `master`.

## Contracts read (Arbitrum Sepolia)

| Contract          | Address                                                              |
| ----------------- | -------------------------------------------------------------------- |
| RegimeDampener    | `0x596281184591df85cee239c7251c836c3efb620d`                         |
| OracleAggregator  | `0x4dedaeab1063ec4867dcd6902b4e5d7298fb0b9f`                         |
| RAYPVault         | `0x8739d8101e8f9cebe5d62a075b132ebd12a0b4d5`                         |

## Local development

```bash
cd bot
cp .env.example .env
# edit .env and fill in ARBITRUM_SEPOLIA_RPC (Twitter creds optional for dry-run)
npm install
npm run dry-run    # prints formatted tweet, does NOT post, does NOT write state
npm run read       # prints raw on-chain values as JSON and exits
npm start          # reads, posts, and updates state.json
```

### CLI flags

| Flag            | Behaviour                                                          |
| --------------- | ------------------------------------------------------------------ |
| `--dry-run`     | Print the composed tweet, skip posting and state write.            |
| `--read-only`   | Print raw on-chain values as JSON and exit.                        |
| (none)          | Read, post, update `state.json`.                                   |

## Required environment variables

All variables live in `bot/.env` locally and in **GitHub Actions secrets** in
CI. Missing any of these will fail the job (by design — red jobs are visible).

| Env var                    | Required by                   | Notes                                          |
| -------------------------- | ----------------------------- | ---------------------------------------------- |
| `ARBITRUM_SEPOLIA_RPC`     | all modes                     | Any RPC on chainId 421614 (Alchemy, public, …) |
| `TWITTER_API_KEY`          | live post only                | OAuth 1.0a consumer key                        |
| `TWITTER_API_SECRET`       | live post only                | OAuth 1.0a consumer secret                     |
| `TWITTER_ACCESS_TOKEN`     | live post only                | OAuth 1.0a user access token                   |
| `TWITTER_ACCESS_SECRET`    | live post only                | OAuth 1.0a user access secret                  |

Only `ARBITRUM_SEPOLIA_RPC` is required for `npm run dry-run` / `npm run read`.

## Twitter / X setup

1. Go to <https://developer.twitter.com> and create a **Project** + **App**.
2. Under the app's **User authentication settings**, enable OAuth 1.0a with
   **Read and Write** permissions. Set any callback URL (not used for posting,
   but required by the form).
3. From **Keys and Tokens** copy:
   - API Key + API Key Secret → `TWITTER_API_KEY`, `TWITTER_API_SECRET`
   - Access Token + Access Token Secret → `TWITTER_ACCESS_TOKEN`,
     `TWITTER_ACCESS_SECRET`
     (use the tokens for the **same account** you want to post from)
4. Verify locally with `npm start` after filling `.env`.

## GitHub Actions secrets

Add these as **repository secrets** at
`Settings → Secrets and variables → Actions → New repository secret`:

- `ARBITRUM_SEPOLIA_RPC`
- `TWITTER_API_KEY`
- `TWITTER_API_SECRET`
- `TWITTER_ACCESS_TOKEN`
- `TWITTER_ACCESS_SECRET`

The workflow (`.github/workflows/regime-bot.yml`) needs `contents: write`
permission (granted in the workflow file) so it can commit `state.json` back
to `master` via `stefanzweifel/git-auto-commit-action@v5`.

## Manually triggering the workflow

```bash
gh workflow run regime-bot.yml
gh run watch
```

Or: *Actions → regime-bot → Run workflow* in the GitHub UI.

## Tweet format

```
📊 RAYP Regime Signal — 2026-04-18

Regime: BULL 🚀
ETH: $3,421.55 | Vol: 62.4% | Funding: 0.8%

⚡ Regime change: NEUTRAL → BULL     ← only when transition detected

Sepolia: arbiscan.io/address/0x8739...4d5
```

Emojis: NEUTRAL 🟢, BULL 🚀, BEAR 🐻, CRISIS 🚨.

If the full message exceeds 280 characters, the Arbiscan line is dropped
first. See `src/format.ts` for the pure `formatTweet()` function.

## Layout

```
bot/
  package.json
  tsconfig.json
  .env.example
  .gitignore
  state.json
  abi/
    RegimeDampener.json
    OracleAggregator.json
    RAYPVault.json
  src/
    index.ts         entrypoint (argv parsing, orchestration)
    contracts.ts     addresses, viem client, typed reads
    format.ts        pure tweet formatter (unit-testable)
    state.ts         state.json read/write
```

## Notes

- `OracleAggregator.getSnapshot()` is not `view` — it writes the TWAP ring
  buffer — so the bot uses `simulateContract` against the latest block rather
  than `readContract`. No transaction is broadcast.
- The bot has no test suite. `formatTweet` is a pure function and trivial to
  cover if one is added later.
