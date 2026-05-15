import "dotenv/config";
import { AtpAgent, RichText } from "@atproto/api";

import {
  makeClient,
  readSnapshot,
  readConfirmedRegime,
  readActiveRegime,
  readLastRebalanceAt,
  readVaultRebalanceCount,
  regimeLabel,
} from "./contracts.js";
import { formatPost, POST_MAX } from "./format.js";
import { readState, writeState } from "./state.js";

const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has("--dry-run");
const READ_ONLY = args.has("--read-only");

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

async function getBlueskyAgent(): Promise<AtpAgent> {
  const identifier = requireEnv("BLUESKY_IDENTIFIER");
  const password = requireEnv("BLUESKY_APP_PASSWORD");
  const agent = new AtpAgent({ service: "https://bsky.social" });
  await agent.login({ identifier, password });
  return agent;
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

  const postText = formatPost({
    snapshot,
    currentRegime: confirmedRegime,
    previousRegime: state.lastRegime,
    isTransition,
  });

  console.log(`── Composed post (${postText.length}/${POST_MAX} chars) ──`);
  console.log(postText);
  console.log("─".repeat(40));

  if (DRY_RUN) {
    console.log("[dry-run] Skipping Bluesky post and state write.");
    return;
  }

  // ── Post to Bluesky ───────────────────────────────────────────────────────
  // RichText.detectFacets auto-links URLs in the body (e.g. the Arbiscan line)
  // so they render as clickable in Bluesky clients.
  const agent = await getBlueskyAgent();
  const rt = new RichText({ text: postText });
  await rt.detectFacets(agent);
  const result = await agent.post({
    text: rt.text,
    facets: rt.facets,
    createdAt: new Date().toISOString(),
  });
  console.log(`Posted to Bluesky: ${result.uri}`);

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
