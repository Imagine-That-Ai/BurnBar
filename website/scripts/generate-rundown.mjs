#!/usr/bin/env node
/**
 * @fileoverview CLI: build daily router-rundown JSON files for the website.
 *
 * Reads:
 *   scripts/rundown-seed/models.json
 *   scripts/rundown-seed/snapshots-YYYY-MM-DD.json    (one per day)
 *
 * Writes (idempotent):
 *   src/data/router-rundown-history/YYYY-MM-DD.json   (per-day rundown)
 *   src/data/router-rundown-history/latest.json       (mirrors newest day)
 *   src/data/router-rundown-history/index.json        (ordered list of dates)
 *
 * Production flow: this same library (rundown-generator.mjs) consumes
 * Firestore `model_benchmark_snapshots` + `model_benchmark_source_status`
 * docs written by the daily Cloud Function. No secrets, cookies, or auth
 * material ever land in the rundown — see redactExplanation().
 *
 * Usage:
 *   node scripts/generate-rundown.mjs
 *
 * Exit code 0 on success; 1 on any error.
 */

import { readFile, writeFile, readdir, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { buildRundown } from "./lib/rundown-generator.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const SEED_DIR = path.join(ROOT, "scripts", "rundown-seed");
const OUT_DIR = path.join(ROOT, "src", "data", "router-rundown-history");

async function loadJSON(filePath) {
  const text = await readFile(filePath, "utf8");
  return JSON.parse(text);
}

async function main() {
  const models = await loadJSON(path.join(SEED_DIR, "models.json"));

  const files = await readdir(SEED_DIR);
  const dailyFiles = files
    .filter((name) => /^snapshots-\d{4}-\d{2}-\d{2}\.json$/.test(name))
    .sort();

  if (dailyFiles.length === 0) {
    console.error("[rundown] no daily seed files found in", SEED_DIR);
    process.exit(1);
  }

  await mkdir(OUT_DIR, { recursive: true });

  const dates = [];
  let previousRundown = null;
  for (const fileName of dailyFiles) {
    const dateMatch = fileName.match(/^snapshots-(\d{4}-\d{2}-\d{2})\.json$/);
    if (!dateMatch) continue;
    const date = dateMatch[1];
    const day = await loadJSON(path.join(SEED_DIR, fileName));

    const rundown = buildRundown({
      date,
      generatedAt: day.generatedAt ?? `${date}T12:00:00.000Z`,
      models,
      snapshots: day.snapshots ?? [],
      statuses: day.statuses ?? [],
      runtime: day.runtime ?? {},
      notes: day.notes ?? [],
      previousRundown,
    });

    const outFile = path.join(OUT_DIR, `${date}.json`);
    await writeFile(outFile, `${JSON.stringify(rundown, null, 2)}\n`, "utf8");
    dates.push({ date, generatedAt: rundown.generatedAt });
    previousRundown = rundown;
    console.log("[rundown] wrote", path.relative(ROOT, outFile));
  }

  // Newest first.
  dates.sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));

  const latestDate = dates[0]?.date;
  if (latestDate) {
    const latestSrc = path.join(OUT_DIR, `${latestDate}.json`);
    const latestDst = path.join(OUT_DIR, "latest.json");
    const latestBuf = await readFile(latestSrc, "utf8");
    await writeFile(latestDst, latestBuf, "utf8");
    console.log("[rundown] wrote", path.relative(ROOT, latestDst), `(→ ${latestDate})`);
  }

  const indexFile = path.join(OUT_DIR, "index.json");
  await writeFile(indexFile, `${JSON.stringify({ dates }, null, 2)}\n`, "utf8");
  console.log("[rundown] wrote", path.relative(ROOT, indexFile));
}

main().catch((err) => {
  console.error("[rundown] generation failed:", err);
  process.exit(1);
});
