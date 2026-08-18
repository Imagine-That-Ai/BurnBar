// @vitest-environment jsdom
/**
 * Visual preview generator for the profile page — a dev tool, not a CI gate.
 *
 * Skipped unless BURNBAR_PREVIEW=1. Renders the REAL ProfilePage component
 * (only auth + the Firestore hook are stubbed) and writes a standalone HTML
 * file to /tmp/burnbar-profile-preview.html with the obsidian theme tokens and
 * a Tailwind Play CDN config that mirrors tailwind.config.ts 1:1, so the
 * preview is the page's actual markup with the actual utility classes.
 *
 *   BURNBAR_PREVIEW=1 npx vitest run test/profilePreview.test.tsx
 */
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { beforeAll, describe, expect, it, vi } from "vitest";

import type { UsageRollup } from "../lib/usage";

const PREVIEW = process.env.BURNBAR_PREVIEW === "1";
// A fresh 0700 directory per run instead of a fixed /tmp path: a predictable
// name in a world-writable dir can be pre-created or symlinked by another
// user, so the write lands wherever they point it.
const outPath = () => join(mkdtempSync(join(tmpdir(), "burnbar-profile-preview-")), "profile.html");

// --- fixture: a heavy but realistic member ---------------------------------

function fixtureRollup(): UsageRollup {
  // ~10 months of daily activity with weekday/weekend variance, a couple of
  // quiet gaps, and one monster day — deterministic (no Math.random).
  const dailyPoints: { day: string; tokens: number }[] = [];
  const start = Date.UTC(2025, 9, 12); // 2025-10-12
  const end = Date.UTC(2026, 7, 16); // 2026-08-16
  let seed = 42;
  const rand = () => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed / 2147483648;
  };
  for (let t = start; t <= end; t += 86_400_000) {
    const d = new Date(t);
    const dow = d.getUTCDay();
    const r = rand();
    if (r < 0.28) continue; // quiet days
    if (dow === 0 && r < 0.6) continue; // slower Sundays
    let tokens = Math.round(200_000 + rand() * 4_000_000);
    if (t === Date.UTC(2026, 7, 9)) tokens = 41_200_000; // the monster day
    if (t >= Date.UTC(2026, 5, 1)) tokens = Math.round(tokens * 1.8); // summer ramp
    dailyPoints.push({ day: d.toISOString().slice(0, 10), tokens });
  }
  // Current streak: the last 4 days are all active.
  for (const iso of ["2026-08-13", "2026-08-14", "2026-08-15", "2026-08-16"]) {
    if (!dailyPoints.some((p) => p.day === iso))
      dailyPoints.push({ day: iso, tokens: 2_400_000 });
  }
  dailyPoints.sort((a, b) => (a.day < b.day ? -1 : 1));

  const totalTokens = dailyPoints.reduce((n, p) => n + p.tokens, 0);
  // Per-day provider split (counter schema v3 shape) — jittered around the
  // 58/31/11 provider mix so heatmap hover cards have honest variety.
  const dailyProviderTokens: Record<string, Record<string, number>> = {};
  for (const p of dailyPoints) {
    const a = Math.round(p.tokens * (0.5 + rand() * 0.16));
    const o = Math.round(p.tokens * (0.24 + rand() * 0.12));
    const m = Math.max(0, p.tokens - a - o);
    dailyProviderTokens[p.day] = { anthropic: a, openai: o, moonshot: m };
  }
  return {
    window: "all_time",
    totals: { requests: 6_994, tokens: totalTokens, costUsd: 1_284.17 },
    providerSummaries: [
      { provider: "anthropic", totalRequests: 3_812, totalTokens: Math.round(totalTokens * 0.58), totalCost: 812.4 },
      { provider: "openai", totalRequests: 2_201, totalTokens: Math.round(totalTokens * 0.31), totalCost: 358.9 },
      { provider: "moonshot", totalRequests: 981, totalTokens: Math.round(totalTokens * 0.11), totalCost: 112.87 },
    ],
    modelSummaries: [
      { model: "claude-opus-4.6", provider: "anthropic", requests: 2_247, tokens: Math.round(totalTokens * 0.34), cost: 512.2 },
      { model: "gpt-5.3-codex", provider: "openai", requests: 1_874, tokens: Math.round(totalTokens * 0.24), cost: 301.5 },
      { model: "claude-sonnet-4.6", provider: "anthropic", requests: 1_565, tokens: Math.round(totalTokens * 0.24), cost: 300.2 },
      { model: "kimi-k2.5", provider: "moonshot", requests: 981, tokens: Math.round(totalTokens * 0.11), cost: 112.87 },
      { model: "gpt-5.3", provider: "openai", requests: 327, tokens: Math.round(totalTokens * 0.07), cost: 57.4 },
    ],
    deviceSummaries: [
      { deviceId: "studio-macbook", requests: 5_102, tokens: Math.round(totalTokens * 0.81) },
      { deviceId: "home-mini", requests: 1_892, tokens: Math.round(totalTokens * 0.19) },
    ],
    executionSourceSummaries: [
      { sourceId: "claude-code", sourceName: "Claude Code", totalRequests: 3_204, totalTokens: Math.round(totalTokens * 0.52), totalCost: 701.3 },
      { sourceId: "codex", sourceName: "Codex", totalRequests: 2_106, totalTokens: Math.round(totalTokens * 0.27), totalCost: 342.6 },
      { sourceId: "kimi", sourceName: "Kimi Code", totalRequests: 981, totalTokens: Math.round(totalTokens * 0.12), totalCost: 118.4 },
      { sourceId: "cursor", sourceName: "Cursor", totalRequests: 512, totalTokens: Math.round(totalTokens * 0.06), totalCost: 84.2 },
      { sourceId: "factory", sourceName: "Factory Droid", totalRequests: 191, totalTokens: Math.round(totalTokens * 0.03), totalCost: 37.67 },
    ],
    comboSummaries: [
      { sourceId: "claude-code", sourceName: "Claude Code", provider: "anthropic", model: "claude-opus-4.6", requests: 2_110, tokens: Math.round(totalTokens * 0.33), cost: 498.4 },
      { sourceId: "codex", sourceName: "Codex", provider: "openai", model: "gpt-5.3-codex", requests: 1_874, tokens: Math.round(totalTokens * 0.24), cost: 301.5 },
      { sourceId: "claude-code", sourceName: "Claude Code", provider: "anthropic", model: "claude-sonnet-4.6", requests: 1_094, tokens: Math.round(totalTokens * 0.19), cost: 202.9 },
      { sourceId: "kimi", sourceName: "Kimi Code", provider: "moonshot", model: "kimi-k2.5", requests: 981, tokens: Math.round(totalTokens * 0.11), cost: 112.87 },
      { sourceId: "cursor", sourceName: "Cursor", provider: "openai", model: "gpt-5.3", requests: 327, tokens: Math.round(totalTokens * 0.07), cost: 57.4 },
    ],
    dailyPoints,
    dailyProviderTokens,
    computedAt: "2026-08-16T07:00:00.000Z",
  };
}

vi.mock("@/lib/useAuth", () => ({
  useAuth: () => ({
    user: {
      uid: "preview-member",
      displayName: "Alberto Nunez-Garcia",
      email: "alberto@imaginethat.ai",
      photoURL: null,
      metadata: { creationTime: "2026-06-14T18:22:00.000Z" },
    },
    loading: false,
  }),
}));

vi.mock("@/lib/profile/useProfileUsage", () => ({
  useProfileUsage: () => ({
    rollup: fixtureRollup(),
    source: "live" as const,
    loading: false,
    syncing: false,
    error: null,
    reload: () => {},
  }),
}));

// --- HTML shell: obsidian tokens + a Tailwind CDN config mirroring ours ----

const SHELL_HEAD = `<!doctype html>
<html data-theme="obsidian">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>BurnBar Console — Profile preview</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=JetBrains+Mono:wght@400;500&family=Inter:wght@400;500;600&display=swap" />
<script src="https://cdn.tailwindcss.com"></script>
<script>
tailwind.config = {
  theme: {
    extend: {
      colors: {
        ink: { void: "var(--color-ink-void)", base: "var(--color-ink-base)", elevated: "var(--color-ink-elevated)", furnace: "var(--color-ink-furnace)" },
        mercury: { bright: "var(--color-mercury-bright)", core: "var(--color-mercury-core)", deep: "var(--color-mercury-deep)", wash: "var(--color-mercury-wash)" },
        glass: { bg: "var(--color-glass-bg)", "bg-elevated": "var(--color-glass-bg-elevated)", line: "var(--color-glass-line)", "line-bright": "var(--color-glass-line-bright)" },
        content: { bright: "var(--color-text-bright)", base: "var(--color-text-base)", mute: "var(--color-text-mute)", dim: "var(--color-text-dim)" },
      },
      fontFamily: { display: "var(--font-display)", body: "var(--font-body)", mono: "var(--font-mono)", serif: "var(--font-serif)" },
      borderRadius: { sm: "var(--radius-sm)", md: "var(--radius-md)", lg: "var(--radius-lg)", pill: "var(--radius-pill)" },
      spacing: {
        "token-1": "var(--space-1)", "token-2": "var(--space-2)", "token-3": "var(--space-3)",
        "token-4": "var(--space-4)", "token-6": "var(--space-6)", "token-8": "var(--space-8)",
        "token-10": "var(--space-10)", "token-12": "var(--space-12)",
      },
    },
  },
};
</script>
<style>
  :root[data-theme="obsidian"] {
    color-scheme: dark;
    --color-ink-void: #0b0d12; --color-ink-base: #11141b; --color-ink-elevated: #161a22;
    --color-text-bright: #f4f7fc; --color-text-base: #d9e0ec; --color-text-mute: #9aa3b4; --color-text-dim: #6f7a8c;
    --color-glass-line: rgba(255,255,255,0.1); --color-glass-line-bright: rgba(255,255,255,0.18);
    --color-glass-bg: #161a22; --color-glass-bg-elevated: #1b202a;
    --color-mercury-bright: #f4f7fc; --color-mercury-core: #9aa3b4; --color-mercury-deep: #6f7a8c;
    --color-mercury-wash: rgba(255,255,255,0.05);
    --color-seal-crimson: #e5484d;
    --accent: #fb5d6a; --accent-deep: #ff9aa2; --accent-wash: rgba(251,93,106,0.14);
    --font-display: "Space Grotesk", system-ui, sans-serif;
    --font-body: "Inter", system-ui, sans-serif;
    --font-mono: "JetBrains Mono", ui-monospace, Menlo, monospace;
    --font-serif: Georgia, serif;
    --radius-sm: 8px; --radius-md: 14px; --radius-lg: 20px; --radius-pill: 999px;
    --space-1: 4px; --space-2: 8px; --space-3: 12px; --space-4: 16px;
    --space-6: 24px; --space-8: 32px; --space-10: 40px; --space-12: 48px;
  }
  html { background: var(--color-ink-void); }
  body { font-family: var(--font-body); color: var(--color-text-base); margin: 0; padding: var(--space-12) var(--space-6); }
  h1, h2, h3, h4 { font-weight: 600; letter-spacing: -0.035em; line-height: 1.0; margin: 0; }
  .eyebrow { font-family: var(--font-mono); font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.14em; color: var(--color-text-dim); font-weight: 500; display: inline-flex; align-items: center; gap: 0.6rem; }
  .folio { font-family: var(--font-mono); font-size: 0.68rem; letter-spacing: 0.14em; text-transform: uppercase; color: var(--color-text-dim); }
  .nameplate { font-family: var(--font-display); font-weight: 700; letter-spacing: -0.04em; }
</style>
</head>
<body>
`;

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

describe.runIf(PREVIEW)("profile preview generator", () => {
  it("renders ProfilePage to /tmp/burnbar-profile-preview.html", async () => {
    const { default: ProfilePage } = await import("../app/profile/page");
    const container = document.createElement("div");
    document.body.appendChild(container);
    const root = createRoot(container);
    act(() => root.render(<ProfilePage />));
    expect(container.innerHTML).toContain("Token activity");
    const out = outPath();
    writeFileSync(out, SHELL_HEAD + container.innerHTML + "\n</body>\n</html>\n");
    act(() => root.unmount());
    container.remove();
    console.log("preview written to " + out);
  });
});

describe.runIf(!PREVIEW)("profile preview generator", () => {
  it("is a dev tool — set BURNBAR_PREVIEW=1 to regenerate the HTML preview", () => {
    expect(true).toBe(true);
  });
});
