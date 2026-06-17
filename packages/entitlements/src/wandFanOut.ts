/**
 * The single source of truth for The Wand's per-tier parallel fan-out cap.
 *
 * This constant is imported by every Node consumer (functions, relay) and the
 * generated `generate-wand-fanout.mjs` script emits the Swift, Kotlin,
 * Firestore rules, Python, and TypeScript surface copies from it. The six
 * distributed copies (Core Swift `WandFanOut`, Android `GatedFeature.kt`,
 * `firestore.rules` `wandFanOutCap`, Python `ministry.py`, functions
 * `dataDomainUsage.ts`, and website `site.ts`) all trace back to THIS table.
 *
 * To change a cap: edit this file, run `node scripts/generate-wand-fanout.mjs`,
 * and commit all generated surfaces. The generator fails if a surface has
 * drifted from the source.
 */

export type WandTierCap = {
  readonly tier: "free" | "cloud" | "cloud_pro" | "cloud_ultra";
  readonly maxParallel: number;
};

export const WAND_FAN_OUT_CAPS: readonly WandTierCap[] = [
  { tier: "free", maxParallel: 1 },
  { tier: "cloud", maxParallel: 3 },
  { tier: "cloud_pro", maxParallel: 8 },
  { tier: "cloud_ultra", maxParallel: 16 },
] as const;

export function wandMaxParallelForTier(tier: WandTierCap["tier"]): number {
  const entry = WAND_FAN_OUT_CAPS.find((c) => c.tier === tier);
  return entry?.maxParallel ?? 1;
}
