#!/usr/bin/env node
/**
 * @fileoverview Run the REAL model-landscape research pipeline locally
 *               and use its output as the website's build-time rundown.
 *
 * This is the same code path the production daily Cloud Function takes:
 *   1. Call `collectModelLandscapeBenchmarks` from `functions/src/modelLandscape.ts`
 *      (compiled in `functions/lib/`). That hits Artificial Analysis (if key
 *      bound), Terminal-Bench via Hugging Face (public), Design Arena (if
 *      key or fixture configured), and any manual fixtures.
 *   2. Feed the sanitized snapshots + statuses into the website's rundown
 *      generator (`scripts/lib/rundown-generator.mjs`).
 *   3. Write the output to `src/data/router-rundown-history/` so the site
 *      ships with whatever research actually said.
 *
 * Honest about what it doesn't have:
 *   - Without ARTIFICIAL_ANALYSIS_API_KEY, OpenAI / Anthropic / Google
 *     models won't be in the snapshot set — they don't publish to HF.
 *   - Without DESIGN_ARENA_API_KEY (or fixture env), the design-task
 *     rankings will be empty.
 *
 * The script never invents data. If a source is unavailable, the rundown
 * is honest about that ("unavailable"). If no model has any snapshot for
 * a task, that task is suppressed, not guessed at.
 *
 * Usage:
 *   node scripts/run-research.mjs
 *
 *   # with a key:
 *   ARTIFICIAL_ANALYSIS_API_KEY=sk-... node scripts/run-research.mjs
 *
 *   # with a Design Arena fixture file:
 *   DESIGN_ARENA_FIXTURE_JSON="$(cat path/to/design-arena.json)" \
 *     node scripts/run-research.mjs
 *
 * The operator-maintained catalog (model display names, tier, context
 * window, cost signal, runtime metadata) lives in
 * `scripts/rundown-seed/models.json` and `scripts/rundown-seed/runtime.json`.
 * Both are MERGED with the research output, never override it.
 */

import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { buildRundown } from "./lib/rundown-generator.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const SEED_DIR = path.join(ROOT, "scripts", "rundown-seed");
const OUT_DIR = path.join(ROOT, "src", "data", "router-rundown-history");
const FUNCTIONS_LIB = path.resolve(ROOT, "..", "functions", "lib", "modelLandscape.js");

async function loadCatalog() {
  // Operator-maintained metadata: keyed by modelID, attaches display name,
  // tier, providerLogo, contextWindowTokens, costSignal, runtime info.
  try {
    const text = await readFile(path.join(SEED_DIR, "models.json"), "utf8");
    return JSON.parse(text);
  } catch {
    return [];
  }
}

async function loadRuntime() {
  try {
    const text = await readFile(path.join(SEED_DIR, "runtime.json"), "utf8");
    return JSON.parse(text);
  } catch {
    return {};
  }
}

/**
 * Build a {snapshotID → canonicalID} map driven by the operator catalog.
 * A snapshot is canonical if its modelID matches a catalog row's modelID or
 * any of its aliases (case-insensitive, after stripping any leading
 * `org/` namespace).
 */
function buildAliasIndex(catalog) {
  const idx = new Map();
  for (const m of catalog) {
    const canonical = m.modelID;
    idx.set(canonical.toLowerCase(), canonical);
    for (const alias of (m.aliases ?? [])) {
      idx.set(alias.toLowerCase(), canonical);
    }
  }
  return idx;
}

function canonicalizeID(modelID, aliasIndex) {
  const lower = modelID.toLowerCase();
  if (aliasIndex.has(lower)) return aliasIndex.get(lower);
  const tail = lower.split("/").pop();
  if (tail && aliasIndex.has(tail)) return aliasIndex.get(tail);
  return null;
}

function rewriteSnapshotModelIDs(snapshots, catalog) {
  // Map any AA slug / HF org-name onto the catalog's canonical modelID so
  // the rundown's joins work on a single shared key. Snapshots that have
  // no catalog entry are dropped — we don't render unknowns to the UI.
  const idx = buildAliasIndex(catalog);
  const rewritten = [];
  for (const snap of snapshots) {
    const canonical = canonicalizeID(snap.modelID, idx);
    if (!canonical) continue;
    rewritten.push({ ...snap, modelID: canonical });
  }
  return rewritten;
}

function mergeCatalog(rewrittenSnapshots, catalog) {
  const seen = new Set(rewrittenSnapshots.map((s) => s.modelID));
  return catalog.filter((m) => seen.has(m.modelID));
}

async function loadSeedSnapshotsForDate(dateISO) {
  // When live sources are unreachable or rate-limited, fall back to the
  // operator-curated snapshot fixture in seed/. The Manual OpenBurnBar
  // fixture source surfaces this as `manual` freshness so the page never
  // claims "fresh" for cached data.
  const candidates = [
    path.join(SEED_DIR, `snapshots-${dateISO}.json`),
    path.join(SEED_DIR, "snapshots-latest.json"),
  ];
  for (const file of candidates) {
    try {
      const text = await readFile(file, "utf8");
      const parsed = JSON.parse(text);
      const rows = Array.isArray(parsed) ? parsed : (parsed?.snapshots ?? null);
      if (Array.isArray(rows) && rows.length > 0) {
        return { file: path.relative(ROOT, file), rows };
      }
    } catch {
      // try next candidate
    }
  }
  return null;
}

async function main() {
  console.log("[research] loading compiled landscape adapters from", path.relative(ROOT, FUNCTIONS_LIB));
  const modelLandscape = await import(FUNCTIONS_LIB);

  console.log("[research] running live research against public endpoints…");
  const now = new Date();

  // If the operator hasn't bound a manual fixture explicitly, fall back to the
  // committed seed snapshot for today (or a date-less `snapshots-latest.json`
  // if present). This means a build with no API keys still produces a richer
  // rundown than just Terminal-Bench alone — the Manual fixture is the floor.
  if (!process.env.MODEL_LANDSCAPE_MANUAL_FIXTURES_JSON?.trim()) {
    const seed = await loadSeedSnapshotsForDate(now.toISOString().slice(0, 10));
    if (seed) {
      process.env.MODEL_LANDSCAPE_MANUAL_FIXTURES_JSON = JSON.stringify(seed.rows);
      console.log(`[research] seed fixture loaded · ${seed.file} (${seed.rows.length} rows) · used as manual fallback`);
    }
  }

  const result = await modelLandscape.collectModelLandscapeBenchmarks(process.env, now);

  console.log("[research] source statuses:");
  for (const s of result.statuses) {
    console.log("  -", s.source, "→", s.status, s.message ? "· " + s.message : "");
  }
  console.log("[research] snapshots returned:", result.snapshots.length);

  const catalog = await loadCatalog();
  const runtime = await loadRuntime();
  console.log("[research] operator catalog entries:", catalog.length);

  const rewrittenSnapshots = rewriteSnapshotModelIDs(result.snapshots, catalog);
  const models = mergeCatalog(rewrittenSnapshots, catalog);
  console.log("[research] catalog entries matched to research output:", models.length);

  if (models.length === 0) {
    console.warn("[research] no catalog entries matched the research output.");
    console.warn("[research] either:");
    console.warn("[research]   - bind ARTIFICIAL_ANALYSIS_API_KEY for OpenAI/Anthropic/Google data, or");
    console.warn("[research]   - update scripts/rundown-seed/models.json with the IDs the adapters returned");
  }

  const date = now.toISOString().slice(0, 10);
  const rundown = buildRundown({
    date,
    generatedAt: now.toISOString(),
    models,
    snapshots: rewrittenSnapshots,
    statuses: result.statuses,
    runtime,
    notes: [
      "Generated by `node website/scripts/run-research.mjs` against live public benchmark adapters.",
      `Snapshots from research: ${result.snapshots.length}. Catalog matches: ${models.length}.`,
      "Sources without an API key configured render as 'unavailable' — never guessed at.",
    ],
  });

  await mkdir(OUT_DIR, { recursive: true });
  const outFile = path.join(OUT_DIR, `${date}.json`);
  await writeFile(outFile, JSON.stringify(rundown, null, 2) + "\n", "utf8");
  await writeFile(path.join(OUT_DIR, "latest.json"), JSON.stringify(rundown, null, 2) + "\n", "utf8");
  console.log("[research] wrote", path.relative(ROOT, outFile), "(", rundown.taskRankings.length, "task rankings)");

  // Index of all dated rundowns.
  const { readdir } = await import("node:fs/promises");
  const files = await readdir(OUT_DIR);
  const dates = files
    .filter((f) => /^\d{4}-\d{2}-\d{2}\.json$/.test(f))
    .map((f) => f.replace(/\.json$/, ""))
    .sort()
    .reverse()
    .map((d) => ({ date: d, generatedAt: `${d}T12:00:00.000Z` }));
  await writeFile(path.join(OUT_DIR, "index.json"), JSON.stringify({ dates }, null, 2) + "\n", "utf8");
  console.log("[research] index updated · dates:", dates.map((d) => d.date).join(", "));
}

main().catch((err) => {
  console.error("[research] failed:", err);
  process.exit(1);
});
