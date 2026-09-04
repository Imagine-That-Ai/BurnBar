#!/usr/bin/env node
/**
 * test-memory-copy.mjs — /memory says only what the repository can prove.
 *
 * The Memory MCP page publishes numbers that come out of Python source and
 * Python tests two directories up. Marketing copy and engineering source drift
 * in one direction: the source changes and the page keeps quoting last
 * quarter's figure. This gate closes that door by reading BOTH sides and
 * refusing to let them disagree.
 *
 * Seven invariants:
 *
 *   1. The tool count on the page equals the number of entries in
 *      `MEMORY_TOOLSET` in tools/openburnbar-mcp/server.py. Add or remove a
 *      memory tool and the website fails until it is re-counted.
 *   2. The twelve memory kinds and their salience weights match
 *      memory_engine/constants.py exactly — every kind, every weight.
 *   3. The fusion constants (RRF k, lexical and semantic weights, the dedup
 *      thresholds, the two half-lives) match the same file.
 *   4. Every measurement declared in src/data/memory.ts is actually rendered
 *      on the built page, so a figure can never be quietly dropped from the
 *      layout while staying in the claims ledger.
 *   5. Every measurement without a committed pin is labelled "Measured, not
 *      pinned" on the page. Unpinned numbers must look unpinned.
 *   6. The extraction floor quoted on the page matches `RECALL_FLOOR` in
 *      tools/openburnbar-mcp/tests/test_eval_extraction.py.
 *   7. Cross-device sync is described as not shipped. The page must carry the
 *      "Not shipped" lane and must never claim sync/replication across devices
 *      is available, because the pull half is still in review.
 *
 * Run via: `node scripts/test-memory-copy.mjs` (after a build).
 */

import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const REPO = join(ROOT, "..");
const MCP = join(REPO, "tools", "openburnbar-mcp");
const PAGE = join(ROOT, "dist", "memory", "index.html");

assert.ok(existsSync(PAGE), `expected a built /memory page at ${PAGE} — run astro build first`);
const html = readFileSync(PAGE, "utf8");

// The data module is the page's single source. Astro resolves TypeScript at
// build time and plain node does not, so this gate reads it as text and pulls
// out exactly the values it needs — no bundler in front of CI.
const dataSrc = readFileSync(join(ROOT, "src", "data", "memory.ts"), "utf8");

const decodeEntities = (s) =>
  s
    .replace(/&#8203;/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
const text = decodeEntities(html.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ");

const failures = [];
const check = (ok, message) => {
  if (!ok) failures.push(message);
};

/* ── 1 · tool count ─────────────────────────────────────────────────────── */

const serverSrc = readFileSync(join(MCP, "server.py"), "utf8");
const toolsetBlock = serverSrc.match(/MEMORY_TOOLSET[^{]*\{([\s\S]*?)\}\s*\)/);
assert.ok(toolsetBlock, "could not find MEMORY_TOOLSET in tools/openburnbar-mcp/server.py");
const realToolCount = [...toolsetBlock[1].matchAll(/"burnbar_[a-z_]+"/g)].length;
assert.ok(realToolCount > 10, `MEMORY_TOOLSET parsed as ${realToolCount} tools — parser is wrong`);

const pageToolCount = Number(dataSrc.match(/MEMORY_TOOL_COUNT\s*=\s*(\d+)/)?.[1] ?? NaN);
check(
  pageToolCount === realToolCount,
  `MEMORY_TOOL_COUNT is ${pageToolCount} but server.py's MEMORY_TOOLSET holds ${realToolCount} tools`
);
check(
  text.includes(`${realToolCount} MCP tools`),
  `the page should say "${realToolCount} MCP tools"`
);

/* ── 2 · kinds and salience weights ─────────────────────────────────────── */

const constantsSrc = readFileSync(join(MCP, "memory_engine", "constants.py"), "utf8");
const weightsBlock = constantsSrc.match(/KIND_WEIGHTS\s*=\s*\{([\s\S]*?)\}/);
assert.ok(weightsBlock, "could not find KIND_WEIGHTS in memory_engine/constants.py");
const realWeights = new Map(
  [...weightsBlock[1].matchAll(/"([a-z]+)"\s*:\s*([0-9.]+)/g)].map((m) => [m[1], Number(m[2])])
);
assert.ok(realWeights.size >= 10, `parsed only ${realWeights.size} kind weights`);

const pageKinds = new Map(
  [...dataSrc.matchAll(/kind:\s*"([a-z]+)",\s*\n\s*weight:\s*([0-9.]+)/g)].map((m) => [
    m[1],
    Number(m[2])
  ])
);
check(
  pageKinds.size === realWeights.size,
  `the page lists ${pageKinds.size} kinds; constants.py defines ${realWeights.size}`
);
for (const [kind, weight] of realWeights) {
  const onPage = pageKinds.get(kind);
  check(onPage !== undefined, `kind "${kind}" is in constants.py but missing from src/data/memory.ts`);
  check(
    onPage === undefined || onPage === weight,
    `kind "${kind}" is weighted ${weight} in constants.py but ${onPage} on the page`
  );
  check(
    text.includes(kind),
    `kind "${kind}" never reaches the rendered page`
  );
}

/* ── 3 · retrieval constants ────────────────────────────────────────────── */

const pyNumber = (name) => Number(constantsSrc.match(new RegExp(`^${name}\\s*=\\s*([0-9.]+)`, "m"))?.[1]);
const tsNumber = (name) => Number(dataSrc.match(new RegExp(`${name}:\\s*([0-9.]+)`))?.[1]);

for (const [tsKey, pyKey] of [
  ["rrfK", "RRF_K"],
  ["lexicalWeight", "RRF_LEXICAL_WEIGHT"],
  ["semanticWeight", "RRF_SEMANTIC_WEIGHT"],
  ["dedupCosine", "DEDUP_COSINE"],
  ["dedupJaccard", "DEDUP_JACCARD"],
  ["halfLifeShortDays", "HALF_LIFE_DAYS_SHORT"],
  ["halfLifeLongDays", "HALF_LIFE_DAYS_LONG"]
]) {
  const py = pyNumber(pyKey);
  const ts = tsNumber(tsKey);
  check(Number.isFinite(py), `could not read ${pyKey} from constants.py`);
  check(py === ts, `${tsKey} is ${ts} on the page but ${pyKey} is ${py} in constants.py`);
}

/* ── 4 & 5 · every measurement renders, and unpinned ones say so ────────── */

const measurements = [
  ...dataSrc.matchAll(/id:\s*"([a-z-]+)",\s*\n\s*figure:\s*"([^"]+)"[\s\S]*?pin:\s*(null|")/g)
].map((m) => ({ id: m[1], figure: m[2], pinned: m[3] !== "null" }));

check(measurements.length >= 6, `parsed only ${measurements.length} measurements from memory.ts`);
for (const m of measurements) {
  check(text.includes(m.figure), `measurement "${m.id}" (${m.figure}) is not rendered on /memory`);
}
const unpinned = measurements.filter((m) => !m.pinned);
check(unpinned.length > 0, "expected at least one honestly-unpinned measurement");
const unpinnedLabels = (text.match(/Measured, not pinned/g) ?? []).length;
check(
  unpinnedLabels === unpinned.length,
  `${unpinned.length} measurement(s) have no pin but the page shows ${unpinnedLabels} "Measured, not pinned" label(s)`
);
check(text.includes("Pinned"), 'the page must label pinned measurements "Pinned"');

/* ── 6 · the extraction floor matches the committed assertion ───────────── */

const evalTest = readFileSync(join(MCP, "tests", "test_eval_extraction.py"), "utf8");
const floor = evalTest.match(/RECALL_FLOOR\s*=\s*([0-9.]+)/)?.[1];
assert.ok(floor, "could not read RECALL_FLOOR from tests/test_eval_extraction.py");
check(
  text.includes(`RECALL_FLOOR = ${floor}`),
  `the page quotes a different extraction floor than the committed RECALL_FLOOR = ${floor}`
);

/* ── 7 · cross-device sync is not advertised as shipped ─────────────────── */

check(text.includes("Not shipped"), '/memory must carry the "Not shipped" lane');
check(
  /pull half is|pull and merge/i.test(text),
  "the not-shipped lane must name the pull-and-merge half specifically"
);
const OVERCLAIMS = [
  /sync(s|ed)? (?:your )?memories across (?:your )?devices/i,
  /memories follow you (?:to|across) (?:your )?(?:other |second )?(?:mac|device)/i,
  /cross-device sync is (?:now )?(?:live|available|here)/i
];
for (const pattern of OVERCLAIMS) {
  check(!pattern.test(text), `/memory appears to advertise unshipped device sync: ${pattern}`);
}

/* ── report ─────────────────────────────────────────────────────────────── */

if (failures.length) {
  console.error(`\nmemory copy: ${failures.length} violation(s)\n`);
  for (const f of failures) console.error("  • " + f);
  console.error(
    "\nThe /memory page reads from website/src/data/memory.ts; that file's values must\n" +
      "match tools/openburnbar-mcp/. See website/CLAIMS.md § Memory MCP.\n"
  );
  process.exit(1);
}

console.log(
  `✓ memory copy: ${realToolCount} tools, ${realWeights.size} kinds and 7 retrieval constants match ` +
    `tools/openburnbar-mcp/; ${measurements.length} measurements render (${unpinned.length} honestly ` +
    `labelled unpinned); extraction floor ${floor} matches the committed assertion; device sync is ` +
    `published as not shipped.`
);
