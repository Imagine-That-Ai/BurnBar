/**
 * Deterministic synthetic usage data for the dashboard.
 *
 * "Deterministic" is load-bearing: the console is a static export, so the
 * dashboard page is prerendered at build time and hydrated on the client. Any
 * use of Date.now()/Math.random() here would make build-time HTML differ from
 * client render and trip a hydration mismatch. Everything below is seeded from
 * a constant, so the same window is produced everywhere. It is clearly labeled
 * "demo data" in the UI until a live feed is wired behind the seam.
 */

import type {
  DashboardRange,
  DashboardWindow,
  ProviderRow,
} from "./types";

/** mulberry32 — tiny deterministic PRNG. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Provider ids deliberately match /brand/logos/<id> and the backdrop swarm so
// the Provider list + Formation cards line up with the brand marks.
const PROVIDER_SEED: { id: string; label: string; weight: number }[] = [
  { id: "claude-code", label: "Claude Code", weight: 0.3 },
  { id: "openai", label: "OpenAI", weight: 0.18 },
  { id: "codex", label: "Codex", weight: 0.14 },
  { id: "gemini-cli", label: "Gemini CLI", weight: 0.1 },
  { id: "cursor", label: "Cursor", weight: 0.09 },
  { id: "copilot", label: "Copilot", weight: 0.07 },
  { id: "deepseek", label: "DeepSeek", weight: 0.05 },
  { id: "kimi", label: "Kimi", weight: 0.04 },
  { id: "qwen", label: "Qwen", weight: 0.03 },
];

const RANGE_META: Record<
  DashboardRange,
  { label: string; seed: number; scale: number; samples: number }
> = {
  today: { label: "Today", seed: 0x7b1d, scale: 1, samples: 24 },
  "7d": { label: "Last 7 days", seed: 0x5e7d, scale: 6.4, samples: 28 },
  "30d": { label: "Last 30 days", seed: 0x30d0, scale: 26, samples: 30 },
};

function round(value: number, dp = 2): number {
  const f = 10 ** dp;
  return Math.round(value * f) / f;
}

export function buildMockWindow(range: DashboardRange): DashboardWindow {
  const meta = RANGE_META[range];
  const rand = mulberry32(meta.seed);

  // Total spend for the window, then split across providers by weight (jittered).
  const totalCostUsd = round(3.2 * meta.scale + rand() * 1.6 * meta.scale);

  const rawProviders = PROVIDER_SEED.map((p) => {
    const jitter = 0.75 + rand() * 0.5;
    const share = p.weight * jitter;
    return { ...p, share };
  });
  const shareSum = rawProviders.reduce((s, p) => s + p.share, 0) || 1;

  const providers: ProviderRow[] = rawProviders
    .map((p) => {
      const costUsd = round((p.share / shareSum) * totalCostUsd);
      const tokens = Math.round(costUsd * (180_000 + rand() * 90_000));
      const sessions = Math.max(1, Math.round(costUsd * (1.4 + rand() * 1.2)));
      const cacheHitRate = round(0.32 + rand() * 0.46, 3);
      return { id: p.id, label: p.label, costUsd, tokens, sessions, cacheHitRate };
    })
    .sort((a, b) => b.costUsd - a.costUsd);

  const totalTokens = providers.reduce((s, p) => s + p.tokens, 0);
  const sessionCount = providers.reduce((s, p) => s + p.sessions, 0);

  // Aggregate cache-hit rate weighted by tokens.
  const cacheHitRate =
    totalTokens > 0
      ? round(
          providers.reduce((s, p) => s + p.cacheHitRate * p.tokens, 0) / totalTokens,
          3,
        )
      : 0;

  // Cumulative cost curve — monotonic, gently accelerating, ending at total.
  const increments: number[] = [];
  let acc = 0;
  for (let i = 0; i < meta.samples; i++) {
    const step = 0.4 + rand();
    acc += step;
    increments.push(acc);
  }
  const peak = increments[increments.length - 1] || 1;
  const costCurve = increments.map((v, i) => ({
    t: meta.samples > 1 ? i / (meta.samples - 1) : 0,
    cumulativeUsd: round((v / peak) * totalCostUsd),
  }));

  // Tokens/sec: a plausible most-recent reading. Real aggregate TPS does not
  // exist server-side yet (it's per-message, mobile-only) — see useDashboardUsage.
  const tokensPerSecond = Math.round(48 + rand() * 92);

  // Fusion ("The Wand"): a slice of runs routed through fusion, saving spend.
  const fusionRuns = Math.max(1, Math.round(sessionCount * (0.18 + rand() * 0.12)));
  const fusionCostUsd = round(totalCostUsd * (0.1 + rand() * 0.08));
  const baselineCostUsd = round(fusionCostUsd * (1.7 + rand() * 0.8));
  const savedUsd = round(Math.max(0, baselineCostUsd - fusionCostUsd));

  return {
    range,
    rangeLabel: meta.label,
    totalCostUsd,
    totalTokens,
    sessionCount,
    cacheHitRate,
    tokensPerSecond,
    costCurve,
    providers,
    fusion: { fusionRuns, fusionCostUsd, baselineCostUsd, savedUsd },
  };
}
