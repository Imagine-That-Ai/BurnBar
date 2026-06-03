#!/usr/bin/env node
/**
 * CI guard — fail on any new raw region literal under functions/src.
 *
 * The deployment region must flow from a single source of truth
 * (`functions/src/runtimeOptions.ts` → `FUNCTIONS_REGION`), never a hardcoded
 * `"us-central1"` literal. This guard greps every `.ts` file under
 * `functions/src` (except `runtimeOptions.ts`, which owns the literal) for the
 * bare quoted region string and exits non-zero if any are found, so a new raw
 * literal cannot land silently. See docs/ARCHITECTURE/region-strategy.md.
 *
 * Usage: node scripts/ci/check-region-literals.mjs
 * Exit:  0 = clean, 1 = raw literals found.
 */

import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);
const SRC_DIR = path.join(REPO_ROOT, "functions", "src");
// runtimeOptions.ts owns the literal; tests/fixtures carry it as test data and
// are never deployed, so they are out of scope for the guard.
const ALLOWLIST = new Set([path.join(SRC_DIR, "runtimeOptions.ts")]);
const SKIP_DIRS = new Set(["__tests__"]);

// Match the bare quoted region literal in code: "us-central1" or 'us-central1'.
// Intentionally does NOT match documentation/URL forms like
// `us-central1-<project>.cloudfunctions.net` in comments.
const REGION_LITERAL = /["']us-central1["']/;

async function walk(dir) {
  const out = [];
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      out.push(...(await walk(full)));
    } else if (entry.isFile() && full.endsWith(".ts")) out.push(full);
  }
  return out;
}

async function main() {
  const files = (await walk(SRC_DIR)).filter((f) => !ALLOWLIST.has(f));
  const hits = [];
  for (const file of files) {
    const lines = (await fs.readFile(file, "utf8")).split("\n");
    lines.forEach((line, i) => {
      if (REGION_LITERAL.test(line)) {
        hits.push({
          file: path.relative(REPO_ROOT, file),
          line: i + 1,
          text: line.trim(),
        });
      }
    });
  }

  if (hits.length > 0) {
    console.error(
      "✖ Raw region literal(s) found — use FUNCTIONS_REGION from functions/src/runtimeOptions.ts:\n",
    );
    for (const hit of hits) {
      console.error(`  ${hit.file}:${hit.line}  ${hit.text}`);
    }
    console.error(
      `\n${hits.length} raw region literal(s). Import FUNCTIONS_REGION and reference it instead.\n` +
        "See docs/ARCHITECTURE/region-strategy.md.",
    );
    process.exit(1);
  }

  console.log(
    "✓ No raw region literals under functions/src (FUNCTIONS_REGION is the single source of truth).",
  );
}

main().catch((err) => {
  console.error("check-region-literals failed:", err);
  process.exit(2);
});
