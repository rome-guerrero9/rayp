import { ADDRESSES, regimeLabel, type OracleSnapshot } from "./contracts.js";

export const TWEET_MAX = 280;

const EMOJI: Record<string, string> = {
  NEUTRAL: "🟢",
  BULL: "🚀",
  BEAR: "🐻",
  CRISIS: "🚨",
  UNKNOWN: "❓",
};

/** Scale a 1e18 fixed-point bigint to a JS number. Safe for display-range values. */
function from1e18(x: bigint): number {
  // Preserve 6 decimals of precision via integer math, then divide.
  const scaled = x / 10n ** 12n; // x / 1e12 gives us 1e6 precision
  return Number(scaled) / 1e6;
}

/** Format a USD price with thousands separators and 2 decimals. */
export function formatPrice(price1e18: bigint): string {
  const usd = from1e18(price1e18);
  return usd.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

/** Format a 1e18-scaled ratio as a percentage with 1 decimal, e.g. 0.42e18 → "42.0%". */
export function formatPct(ratio1e18: bigint): string {
  const pct = from1e18(ratio1e18) * 100;
  return `${pct.toFixed(1)}%`;
}

/** Format a signed 1e18-scaled ratio as a percentage with sign, e.g. -0.01e18 → "-1.0%". */
export function formatSignedPct(ratio1e18: bigint): string {
  const neg = ratio1e18 < 0n;
  const abs = neg ? -ratio1e18 : ratio1e18;
  const pct = from1e18(abs) * 100;
  return `${neg ? "-" : ""}${pct.toFixed(1)}%`;
}

export function utcDate(now: Date = new Date()): string {
  return now.toISOString().slice(0, 10); // YYYY-MM-DD
}

export interface FormatInput {
  snapshot: OracleSnapshot | null;
  currentRegime: number;
  previousRegime: number | null;
  isTransition: boolean;
  now?: Date;
}

/**
 * Pure function: builds a tweet ≤ 280 chars describing the current regime and
 * oracle snapshot. If the full message overflows, the Arbiscan line is dropped
 * first (per spec). Further overflow is guarded by a final hard trim.
 *
 * When `snapshot` is null (aggregator reverted off-chain), the metrics line is
 * replaced with an "oracle unavailable" notice and the regime is still posted.
 */
export function formatTweet(input: FormatInput): string {
  const { snapshot, currentRegime, previousRegime, isTransition, now } = input;

  const label = regimeLabel(currentRegime);
  const emoji = EMOJI[label] ?? EMOJI.UNKNOWN;
  const date = utcDate(now);

  const header = `📊 RAYP Regime Signal — ${date}`;
  const regimeLine = `Regime: ${label} ${emoji}`;
  const metricsLine = snapshot
    ? `ETH: $${formatPrice(snapshot.price)} | Vol: ${formatPct(snapshot.smoothedVol)} | Funding: ${formatSignedPct(snapshot.fundingRate)}`
    : `⚠️ Oracle snapshot unavailable`;

  let transitionBlock = "";
  if (isTransition && previousRegime !== null) {
    const oldLabel = regimeLabel(previousRegime);
    transitionBlock = `\n\n⚡ Regime change: ${oldLabel} → ${label}`;
  }

  const link = `Sepolia: arbiscan.io/address/${ADDRESSES.raypVault}`;

  const full =
    `${header}\n\n` +
    `${regimeLine}\n` +
    `${metricsLine}` +
    `${transitionBlock}\n\n` +
    `${link}`;

  if (full.length <= TWEET_MAX) return full;

  // Overflow: drop the Arbiscan line first.
  const withoutLink =
    `${header}\n\n` +
    `${regimeLine}\n` +
    `${metricsLine}` +
    `${transitionBlock}`;

  if (withoutLink.length <= TWEET_MAX) return withoutLink;

  // Extreme overflow safety net: hard trim.
  return withoutLink.slice(0, TWEET_MAX);
}
