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
 * And, since the coverage round, the atlas — the page's claim to list every
 * tool the server has, which is exactly the kind of claim that rots quietly:
 *
 *   8. Set equality between the `burnbar_*` tools `server.py` registers with
 *      `@mcp.tool()` and the entries in `TOOL_ATLAS`. Both directions, by
 *      name, so adding one tool while deleting another cannot pass.
 *   9. Every atlas entry belongs to a declared group, carries a real
 *      description, and actually reaches the rendered page.
 *  10. Each entry's published capability gates equal the capabilities named
 *      at that tool's `_capability_denial(...)` — or daemon
 *      `_local_memory_write_authority(...)` — sites in `server.py`.
 *  11. Each entry's "memory toolset" mark equals its membership of
 *      `MEMORY_TOOLSET`.
 *  12. `BURNBAR_TOOL_COUNT` and `ORCHESTRATION_TOOL_COUNT` match what
 *      `server.py` registers, and the atlas heading prints the real number.
 *  13. The capability table's environment variables match
 *      `LOCAL_MCP_CAPABILITY_ENV`, and every capability a published tool
 *      depends on is explained somewhere on the page.
 *  14. The platform statement names Windows and Linux, and the page never
 *      claims to run on them.
 *
 * Each parser asserts its own parse succeeded before comparing, so a change
 * in the shape of `server.py` fails loudly rather than passing vacuously.
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


/* ── 8 · the atlas is complete, in both directions ───────────────────────
 *
 * The page's headline claim is coverage: "all 63 tools". A marketing page
 * that lists 63 of 63 tools today lists 63 of 71 the moment someone adds a
 * tool to server.py, and nobody notices, because nothing on the website
 * fails when the server grows. This closes that.
 *
 * Set equality, not a count. A count comparison passes if you add one tool
 * and delete another; a set comparison names both.
 */

const registered = [
  ...serverSrc.matchAll(/@mcp\.tool\(\)\s*(?:async\s+)?def\s+(burnbar_[a-z0-9_]+)/g)
].map((m) => m[1]);
assert.ok(
  registered.length > 40,
  `parsed only ${registered.length} @mcp.tool() burnbar_* definitions — the parser is wrong, not the page`
);
const registeredSet = new Set(registered);
check(
  registeredSet.size === registered.length,
  `server.py registers a duplicate burnbar_* tool name (${registered.length} definitions, ${registeredSet.size} unique)`
);

/* The atlas block only — so a `name:` in an unrelated exported array cannot
 * be mistaken for a tool entry. */
const atlasStart = dataSrc.indexOf("export const TOOL_ATLAS");
assert.ok(atlasStart > -1, "could not find TOOL_ATLAS in src/data/memory.ts");
const atlasSrc = dataSrc.slice(atlasStart);

const ATLAS_ENTRY =
  /name:\s*"(burnbar_[a-z0-9_]+)",\s*group:\s*"([a-z]+)",\s*desc:\s*"((?:[^"\\]|\\.)*)",\s*caps:\s*\[([^\]]*)\],\s*memory:\s*(true|false)/g;
const atlasEntries = [...atlasSrc.matchAll(ATLAS_ENTRY)].map((m) => ({
  name: m[1],
  group: m[2],
  desc: m[3],
  caps: [...m[4].matchAll(/"([a-z_]+)"/g)].map((c) => c[1]).sort(),
  memory: m[5] === "true"
}));
const atlasNames = atlasEntries.map((e) => e.name);
const atlasSet = new Set(atlasNames);
check(
  atlasSet.size === atlasNames.length,
  `TOOL_ATLAS lists a tool twice (${atlasNames.length} entries, ${atlasSet.size} unique)`
);
check(
  atlasEntries.length === (atlasSrc.match(/\n    name: "burnbar_/g) ?? []).length,
  `the atlas parser matched ${atlasEntries.length} entries but the file has ` +
    `${(atlasSrc.match(/\n    name: "burnbar_/g) ?? []).length} — an entry's shape changed, so this gate is no longer reading all of them`
);

for (const name of registeredSet) {
  check(
    atlasSet.has(name),
    `server.py registers ${name} but the /memory tool atlas does not list it — add it to TOOL_ATLAS in src/data/memory.ts`
  );
}
for (const name of atlasSet) {
  check(
    registeredSet.has(name),
    `the /memory tool atlas lists ${name} but server.py does not register it — remove it from TOOL_ATLAS`
  );
}

/* ── 9 · every atlas group is real, and every tool reaches the page ───── */

const groupIds = new Set(
  [...dataSrc.matchAll(/^\s{4}id:\s*"([a-z]+)",\n\s{4}label:/gm)].map((m) => m[1])
);
for (const entry of atlasEntries) {
  check(
    groupIds.size === 0 || groupIds.has(entry.group),
    `${entry.name} is in atlas group "${entry.group}", which ATLAS_GROUPS does not define`
  );
  check(entry.desc.trim().length > 20, `${entry.name} has no real description in the atlas`);
  check(
    text.includes(entry.name),
    `${entry.name} is in TOOL_ATLAS but never reaches the rendered /memory page`
  );
}

/* ── 10 · declared capability gates match the code that enforces them ─── */

const realCaps = new Map([...registeredSet].map((n) => [n, new Set()]));
for (const m of serverSrc.matchAll(
  /_capability_denial\(\s*"(burnbar_[a-z0-9_]+)"\s*,\s*"([a-z_]+)"/g
)) {
  realCaps.get(m[1])?.add(m[2]);
}
// The three daemon-scoped code writers take their local_write denial through
// a helper rather than inline, so the helper's call sites count too.
for (const m of serverSrc.matchAll(/_local_memory_write_authority\(\s*"(burnbar_[a-z0-9_]+)"/g)) {
  realCaps.get(m[1])?.add("local_write");
}
const gatedCount = [...realCaps.values()].filter((s) => s.size > 0).length;
assert.ok(
  gatedCount > 15,
  `parsed capability gates for only ${gatedCount} tools — the denial-site parser is wrong`
);

for (const entry of atlasEntries) {
  const real = [...(realCaps.get(entry.name) ?? [])].sort();
  check(
    entry.caps.join(",") === real.join(","),
    `${entry.name} is published as needing [${entry.caps.join(", ") || "no capability"}] but ` +
      `server.py gates it on [${real.join(", ") || "nothing"}]`
  );
}

/* ── 11 · the memory-toolset marks match MEMORY_TOOLSET ──────────────── */

const toolsetSet = new Set([...toolsetBlock[1].matchAll(/"(burnbar_[a-z0-9_]+)"/g)].map((m) => m[1]));
for (const entry of atlasEntries) {
  check(
    entry.memory === toolsetSet.has(entry.name),
    entry.memory
      ? `${entry.name} is marked as part of the memory toolset but is not in MEMORY_TOOLSET`
      : `${entry.name} is in MEMORY_TOOLSET but the atlas does not mark it as part of the memory toolset`
  );
}

/* ── 12 · the counts the page prints ────────────────────────────────── */

const declaredBurnbar = Number(dataSrc.match(/BURNBAR_TOOL_COUNT\s*=\s*(\d+)/)?.[1] ?? NaN);
check(
  declaredBurnbar === registered.length,
  `BURNBAR_TOOL_COUNT is ${declaredBurnbar} but server.py registers ${registered.length} burnbar_* tools`
);
check(
  text.includes(`All ${registered.length} tools`),
  `the atlas heading should read "All ${registered.length} tools"`
);

const orchestration = [
  ...serverSrc.matchAll(/@mcp\.tool\(\)\s*(?:async\s+)?def\s+([a-z0-9_]+)/g)
].filter((m) => !m[1].startsWith("burnbar_")).length;
const declaredOrchestration = Number(
  dataSrc.match(/ORCHESTRATION_TOOL_COUNT\s*=\s*(\d+)/)?.[1] ?? NaN
);
check(
  declaredOrchestration === orchestration,
  `ORCHESTRATION_TOOL_COUNT is ${declaredOrchestration} but server.py registers ${orchestration} non-burnbar_* tools`
);

/* ── 13 · the capability table names the real environment variables ──── */

const capEnvBlock = serverSrc.match(/LOCAL_MCP_CAPABILITY_ENV\s*(?::[^=]*)?=\s*\{([\s\S]*?)\n\}/);
assert.ok(capEnvBlock, "could not find LOCAL_MCP_CAPABILITY_ENV in server.py");
const realCapEnv = new Map(
  [...capEnvBlock[1].matchAll(/"([a-z_]+)"\s*:\s*"([A-Z0-9_]+)"/g)].map((m) => [m[1], m[2]])
);
assert.ok(realCapEnv.size >= 6, `parsed only ${realCapEnv.size} capability env vars`);
const pageCapEnv = new Map(
  [...dataSrc.matchAll(/id:\s*"([a-z_]+)",\n\s*env:\s*"([A-Z0-9_]+)"/g)].map((m) => [m[1], m[2]])
);
for (const [capability, env] of pageCapEnv) {
  const real = realCapEnv.get(capability);
  check(
    real !== undefined,
    `the page publishes a capability "${capability}" that server.py does not define`
  );
  check(
    real === undefined || real === env,
    `capability "${capability}" is enabled by ${real} in server.py but the page says ${env}`
  );
}
// Every capability a published tool depends on must be explained in the table.
for (const entry of atlasEntries) {
  for (const capability of entry.caps) {
    check(
      pageCapEnv.has(capability),
      `${entry.name} is gated on "${capability}" but the page's capability table never explains it`
    );
  }
}

/* ── 14 · the platform statement stays honest ───────────────────────── */

check(
  /Windows and Linux/i.test(text),
  "/memory must name Windows and Linux explicitly rather than leaving the platform question open"
);
const PLATFORM_OVERCLAIMS = [
  /(runs|works|available) on (windows|linux)/i,
  /(windows|linux) (is|are) supported/i,
  /cross-platform support/i
];
for (const pattern of PLATFORM_OVERCLAIMS) {
  check(!pattern.test(text), `/memory appears to claim unsupported platform support: ${pattern}`);
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
  `✓ memory copy: ${realToolCount} memory-toolset tools, ${realWeights.size} kinds and 7 retrieval ` +
    `constants match tools/openburnbar-mcp/; ${measurements.length} measurements render ` +
    `(${unpinned.length} honestly labelled unpinned); extraction floor ${floor} matches the committed ` +
    `assertion; device sync is published as not shipped.\n` +
    `✓ memory atlas: all ${registered.length} burnbar_* tools listed, none invented; ` +
    `${atlasEntries.filter((e) => e.memory).length} marked memory-toolset; ` +
    `${gatedCount} capability-gated tools match their denial sites; ` +
    `${orchestration} orchestration tools counted and excluded; ` +
    `${pageCapEnv.size} capability env vars match server.py; platform claim is honest.`
);
