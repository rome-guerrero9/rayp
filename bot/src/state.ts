import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

export interface BotState {
  lastRegime: number | null;
  lastPostedAt: string | null;
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const STATE_PATH = resolve(__dirname, "../state.json");

export function statePath(): string {
  return STATE_PATH;
}

function isValidState(v: unknown): v is BotState {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  const regimeOk =
    o.lastRegime === null ||
    (typeof o.lastRegime === "number" && Number.isInteger(o.lastRegime));
  const postedOk = o.lastPostedAt === null || typeof o.lastPostedAt === "string";
  return regimeOk && postedOk;
}

export async function readState(): Promise<BotState> {
  const raw = await readFile(STATE_PATH, "utf8");
  const parsed: unknown = JSON.parse(raw);
  if (!isValidState(parsed)) {
    throw new Error(`Invalid state.json shape at ${STATE_PATH}`);
  }
  return parsed;
}

export async function writeState(state: BotState): Promise<void> {
  const serialized = JSON.stringify(state, null, 2) + "\n";
  await writeFile(STATE_PATH, serialized, "utf8");
}
