import { createPublicClient, http, type Address, type PublicClient } from "viem";
import { arbitrumSepolia } from "viem/chains";

import OracleAggregatorAbi from "../abi/OracleAggregator.json" with { type: "json" };
import RegimeDampenerAbi from "../abi/RegimeDampener.json" with { type: "json" };
import RAYPVaultAbi from "../abi/RAYPVault.json" with { type: "json" };

export const ADDRESSES = {
  regimeDampener: "0x596281184591df85cee239c7251c836c3efb620d" as Address,
  oracleAggregator: "0x4dedaeab1063ec4867dcd6902b4e5d7298fb0b9f" as Address,
  raypVault: "0x8739d8101e8f9cebe5d62a075b132ebd12a0b4d5" as Address,
} as const;

export const ABIS = {
  oracleAggregator: OracleAggregatorAbi,
  regimeDampener: RegimeDampenerAbi,
  raypVault: RAYPVaultAbi,
} as const;

export function makeClient(rpcUrl: string): PublicClient {
  if (!rpcUrl) {
    throw new Error("ARBITRUM_SEPOLIA_RPC is not set");
  }
  return createPublicClient({
    chain: arbitrumSepolia,
    transport: http(rpcUrl, { retryCount: 3, timeout: 15_000 }),
  });
}

/**
 * OracleSnapshot struct returned from OracleAggregator.getSnapshot().
 * All numeric fields are 1e18-scaled except `timestamp` which is a unix second.
 * `fundingRate` can be negative (signed int256 on-chain).
 */
export interface OracleSnapshot {
  price: bigint;
  smoothedVol: bigint;
  fundingRate: bigint;
  stableDominance: bigint;
  timestamp: number;
  volPenaltyFlag: boolean;
}

/**
 * Reads the oracle snapshot. `getSnapshot()` is non-view (it writes the TWAP
 * ring buffer), so from an off-chain reader we must use `simulateContract`
 * rather than `readContract` — this executes the call against the latest
 * state without broadcasting a transaction.
 *
 * Returns `null` if the aggregator reverts (stale feed, vol out of range,
 * cross-source divergence). The bot still posts a regime-only tweet in that
 * case rather than failing the run.
 */
export async function readSnapshot(
  client: PublicClient,
): Promise<OracleSnapshot | null> {
  try {
    const { result } = await client.simulateContract({
      address: ADDRESSES.oracleAggregator,
      abi: ABIS.oracleAggregator,
      functionName: "getSnapshot",
    });

    const snap = result as {
      price: bigint;
      smoothedVol: bigint;
      fundingRate: bigint;
      stableDominance: bigint;
      timestamp: number | bigint;
      volPenaltyFlag: boolean;
    };

    return {
      price: snap.price,
      smoothedVol: snap.smoothedVol,
      fundingRate: snap.fundingRate,
      stableDominance: snap.stableDominance,
      timestamp: Number(snap.timestamp),
      volPenaltyFlag: snap.volPenaltyFlag,
    };
  } catch (err) {
    const shortMsg =
      err instanceof Error ? err.message.split("\n")[0] : String(err);
    console.warn(`[readSnapshot] getSnapshot() reverted: ${shortMsg}`);
    return null;
  }
}

export async function readConfirmedRegime(client: PublicClient): Promise<number> {
  const raw = await client.readContract({
    address: ADDRESSES.regimeDampener,
    abi: ABIS.regimeDampener,
    functionName: "confirmedRegime",
  });
  return Number(raw);
}

export async function readActiveRegime(client: PublicClient): Promise<number> {
  const raw = await client.readContract({
    address: ADDRESSES.raypVault,
    abi: ABIS.raypVault,
    functionName: "activeRegime",
  });
  return Number(raw);
}

export async function readVaultRebalanceCount(client: PublicClient): Promise<bigint> {
  const raw = await client.readContract({
    address: ADDRESSES.raypVault,
    abi: ABIS.raypVault,
    functionName: "rebalanceCount",
  });
  return raw as bigint;
}

export async function readLastRebalanceAt(client: PublicClient): Promise<number> {
  const raw = await client.readContract({
    address: ADDRESSES.raypVault,
    abi: ABIS.raypVault,
    functionName: "lastRebalanceAt",
  });
  return Number(raw);
}

export const REGIME_LABELS = ["NEUTRAL", "BULL", "BEAR", "CRISIS"] as const;
export type RegimeLabel = (typeof REGIME_LABELS)[number];

export function regimeLabel(regime: number): RegimeLabel | "UNKNOWN" {
  return REGIME_LABELS[regime] ?? "UNKNOWN";
}
