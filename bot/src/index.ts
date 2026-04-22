import "dotenv/config";
import { TwitterApi } from "twitter-api-v2";

import {
  makeClient,
  readSnapshot,
  readConfirmedRegime,
  readActiveRegime,
  readLastRebalanceAt,
  readVaultRebalanceCount,
  regimeLabel,
} from "./contracts.js";
import { formatTweet, TWEET_MAX } from "./format.js";
import { readState, writeState } from "./state.js";

const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has("--dry-run");
const READ_ONLY = args.has("--read-only");

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

function getTwitterClient(): TwitterApi {
  const apiKey = requireEnv("TWITTER_API_KEY");
  const apiSecret = requireEnv("TWITTER_API_SECRET");
  const accessToken = requireEnv("TWITTER_ACCESS_TOKEN");
  const accessSecret = requireEnv("TWITTER_ACCESS_SECRET");
  return new TwitterApi({
    appKey: apiKey,
    appSecret: apiSecret,
    accessToken,
    accessSecret,
  });
}

async function main(): Promise<void> {
  const rpc = requireEnv("ARBITRUM_SEPOLIA_RPC");
  const client = makeClient(rpc);

  // ── Read everything on-chain in parallel ──────────────────────────────────
  const [snapshot, confirmedRegime, activeRegime, lastRebalanceAt, vaultRebalances] =
    await Promise.all([
      readSnapshot(client),
      readConfirmedRegime(client),
      readActiveRegime(client),
      readLastRebalanceAt(client),
      readVaultRebalanceCount(client),
    ]);

  if (READ_ONLY) {
    console.log("── On-chain read-only snapshot ──");
    console.log(
      JSON.stringify(
        {
          confirmedRegime,
          confirmedRegimeLabel: regimeLabel(confirmedRegime),
          activeRegime,
          activeRegimeLabel: regimeLabel(activeRegime),
          lastRebalanceAt,
          vaultRebalanceCount: vaultRebalances.toString(),
          snapshot: snapshot
            ? {
                price: snapshot.price.toString(),
                smoothedVol: snapshot.smoothedVol.toString(),
                fundingRate: snapshot.fundingRate.toString(),
                stableDominance: snapshot.stableDominance.toString(),
                timestamp: snapshot.timestamp,
                volPenaltyFlag: snapshot.volPenaltyFlag,
              }
            : null,
        },
        null,
        2,
      ),
    );
    return;
  }

  // ── Transition detection based on persisted state ─────────────────────────
  const state = await readState();
  const isTransition =
    state.lastRegime !== null && state.lastRegime !== confirmedRegime;

  const tweet = formatTweet({
    snapshot,
    currentRegime: confirmedRegime,
    previousRegime: state.lastRegime,
    isTransition,
  });

  console.log(`── Composed tweet (${tweet.length}/${TWEET_MAX} chars) ──`);
  console.log(tweet);
  console.log("─".repeat(40));

  if (DRY_RUN) {
    console.log("[dry-run] Skipping Twitter post and state write.");
    return;
  }

  // ── Post to Twitter ───────────────────────────────────────────────────────
  const twitter = getTwitterClient();
  const result = await twitter.v2.tweet(tweet);
  const tweetId = result.data?.id ?? "<unknown>";
  console.log(`Posted tweet id=${tweetId}`);

  // ── Persist state ─────────────────────────────────────────────────────────
  await writeState({
    lastRegime: confirmedRegime,
    lastPostedAt: new Date().toISOString(),
  });
  console.log("state.json updated.");
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
