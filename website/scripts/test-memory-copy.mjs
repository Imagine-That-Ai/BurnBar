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
 *   8. Set equality between EVERY tool `server.py` registers with
 *      `@mcp.tool()` — `burnbar_*` and `ministry_*` / `castle_*` / `bench_*`
 *      alike — and the entries in `TOOL_ATLAS`. Both directions, by name, so
 *      adding one tool while deleting another cannot pass, and so a tool
 *      that isn't `burnbar_*` cannot quietly sit outside the claim.
 *   9. Every atlas entry belongs to a declared group, carries a real
 *      description, and actually reaches the rendered page.
 *  10. Each entry's published capability gates equal the capabilities named
 *      at that tool's `_capability_denial(...)` — or daemon
 *      `_local_memory_write_authority(...)` — sites in `server.py`.
 *  11. Each entry's "memory toolset" mark equals its membership of
 *      `MEMORY_TOOLSET`. Castle/Ministry/Bench tools are never members, so
 *      this also proves the atlas never mismarks one of them as memory-scoped.
 *  12. `BURNBAR_TOOL_COUNT` (the `burnbar_*` product tools) and
 *      `ORCHESTRATION_TOOL_COUNT` (`ministry_*` / `castle_*` / `bench_*`)
 *      each match what `server.py` registers, and the atlas heading prints
 *      their real sum — "all" means all 89, not the 63 alone.
 *  13. The capability table's environment variables match
 *      `LOCAL_MCP_CAPABILITY_ENV`, and every capability a published tool
 *      depends on is explained somewhere on the page.
 *  14. The platform statement names Windows and Linux, and the page never
 *      claims to run on them.
 *
 * And, since the review round, the three places a number could still be
 * asserted vacuously or published as something it is not:
 *
 *  15. Each measurement's figure is asserted inside its own bench card, not
 *      anywhere in the page's text. "1.0", "1", "0" and "25" match somewhere
 *      on any page this long, so invariant 4 was true only for the four
 *      figures that happen to be distinctive.
 *  16. The gate-coverage numbers — the credential-shape total and the count
 *      of caller-controlled placements — are read out of `eval_memory.py`
 *      and `tests/test_gate_adversarial.py` rather than typed on the page.
 *  17. A capability whose denial site sits behind a guard is published WITH
 *      the condition that reaches it. `burnbar_recall` denies `sensitive_read`
 *      only under `include_secrets`; publishing that as a flat requirement
 *      tells a reader the flagship read path is behind an off-by-default
 *      capability, which is both wrong and worse than the truth. Checked in
 *      both directions: a guarded site must carry a note, and a note must
 *      correspond to a guarded site.
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

// One pass over the string. A chain of replaces decodes twice: `&amp;lt;` is
// literal "&lt;" in the page, but replacing `&amp;` first turns it into an
// entity the next replace then decodes to "<" (CodeQL: double unescaping).
const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'", "#8203": "" };
const decodeEntities = (s) =>
  s.replace(/&(amp|lt|gt|quot|#39|#8203);/g, (_, name) => ENTITIES[name]);
const text = decodeEntities(html.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ");

/* `text` strips tags, so attribute content — the meta description, the OG
 * description, an aria-label — never reaches it. Those carry claims too. */
const metaDescription = decodeEntities(
  html.match(/<meta\s+name="description"\s+content="([^"]*)"/i)?.[1] ?? ""
);

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
  check(
    onPage !== undefined,
    `kind "${kind}" is in constants.py but missing from src/data/memory.ts`
  );
  check(
    onPage === undefined || onPage === weight,
    `kind "${kind}" is weighted ${weight} in constants.py but ${onPage} on the page`
  );
  check(text.includes(kind), `kind "${kind}" never reaches the rendered page`);
}

/* ── 3 · retrieval constants ────────────────────────────────────────────── */

const pyNumber = (name) =>
  Number(constantsSrc.match(new RegExp(`^${name}\\s*=\\s*([0-9.]+)`, "m"))?.[1]);
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

/* The salience boost cap is the one FUSION value that lives in the engine
 * rather than in constants.py. It sat in a gate-checked-looking block without
 * a gate; this reads it where it is. */
const engineSrc = readFileSync(join(MCP, "memory_engine", "engine.py"), "utf8");
const realBoostCap = Number(engineSrc.match(/boost\s*=\s*min\(\s*([0-9.]+)\s*,/)?.[1]);
assert.ok(
  Number.isFinite(realBoostCap),
  "could not read the salience access-boost cap from memory_engine/engine.py"
);
const pageBoostCap = tsNumber("accessBoostCap");
check(
  realBoostCap === pageBoostCap,
  `accessBoostCap is ${pageBoostCap} on the page but engine.py caps the boost at ${realBoostCap}`
);
check(
  text.includes(`capped at ${realBoostCap}×`),
  `the page should say the reinforcement boost is "capped at ${realBoostCap}×"`
);

/* ── 4 & 5 · every measurement renders, and unpinned ones say so ────────── */

const measurements = [
  ...dataSrc.matchAll(
    /id:\s*"([a-z-]+)",\s*\n\s*figure:\s*"([^"]+)"[\s\S]*?label:\s*"((?:[^"\\]|\\.)*)"[\s\S]*?pin:\s*(null|")/g
  )
].map((m) => ({ id: m[1], figure: m[2], label: m[3], pinned: m[4] !== "null" }));

check(measurements.length >= 6, `parsed only ${measurements.length} measurements from memory.ts`);

/* Scoped to the card, not to the page. Four of the eight figures are "1.0",
 * "1", "0" and "25", and every one of those matches somewhere in a page with
 * a salience table and a coverage count in it, so a page-wide `includes`
 * check passes even after the card is deleted. Each card carries
 * id="bench-<id>"; this slices the HTML from that id to the next one and
 * looks for the figure only in there. */
const benchSlice = (id) => {
  const marker = `id="bench-${id}"`;
  const start = html.indexOf(marker);
  if (start < 0) return null;
  const next = html.indexOf('id="bench-', start + marker.length);
  return html.slice(start, next < 0 ? html.length : next);
};
for (const m of measurements) {
  const card = benchSlice(m.id);
  check(
    card !== null,
    `measurement "${m.id}" has no bench card on /memory — expected id="bench-${m.id}"`
  );
  if (card === null) continue;
  const cardText = decodeEntities(card.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ");
  check(
    cardText.includes(m.figure),
    `measurement "${m.id}" renders a card but its figure (${m.figure}) is not in it`
  );
  check(cardText.includes(m.label), `measurement "${m.id}" renders a card but not its label`);
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
 * The page's headline claim is coverage: "all 89 tools" — not "all 63
 * burnbar_* tools", all of them, ministry_* / castle_* / bench_* included. A
 * marketing page that lists 89 of 89 tools today lists 89 of 97 the moment
 * someone adds a tool to server.py, and nobody notices, because nothing on
 * the website fails when the server grows. This closes that, over every
 * `@mcp.tool()` definition regardless of prefix.
 *
 * Set equality, not a count. A count comparison passes if you add one tool
 * and delete another; a set comparison names both.
 */

const registeredAll = [
  ...serverSrc.matchAll(/@mcp\.tool\(\)\s*(?:async\s+)?def\s+([a-z][a-z0-9_]*)/g)
].map((m) => m[1]);
assert.ok(
  registeredAll.length > 60,
  `parsed only ${registeredAll.length} @mcp.tool() definitions — the parser is wrong, not the page`
);
const registeredSet = new Set(registeredAll);
check(
  registeredSet.size === registeredAll.length,
  `server.py registers a duplicate tool name (${registeredAll.length} definitions, ${registeredSet.size} unique)`
);
const registeredBurnbar = registeredAll.filter((n) => n.startsWith("burnbar_"));
const registeredOrchestration = registeredAll.filter((n) => !n.startsWith("burnbar_"));
assert.ok(
  registeredBurnbar.length > 40,
  `parsed only ${registeredBurnbar.length} @mcp.tool() burnbar_* definitions — the parser is wrong, not the page`
);

/* The atlas block only — so a `name:` in an unrelated exported array cannot
 * be mistaken for a tool entry.
 *
 * Parsed STRUCTURALLY, by matching the array's brackets and evaluating the
 * literal, rather than with one regex per entry across a fixed line shape. A
 * single-line regex reads the file's FORMATTING, not its data: `prettier`
 * reflowing one `desc` onto single quotes (because that description itself
 * contains a double quote) silently dropped `burnbar_recall` from the parse and
 * the gate then reported it as missing from a page that lists it. The bracket
 * scan skips strings and comments so a `[`, `]` or `//` inside a description
 * cannot end the block early. */
function sliceBalanced(src, from) {
  /* After the `=`, so the `[]` of the `AtlasTool[]` type annotation is not
   * mistaken for the array itself. */
  const assign = src.indexOf("=", from);
  assert.ok(assign > -1, "TOOL_ATLAS has no initialiser");
  const open = src.indexOf("[", assign);
  assert.ok(open > -1, "TOOL_ATLAS is not an array literal");
  let depth = 0;
  let quote = null;
  let comment = null; // "line" | "block"
  for (let i = open; i < src.length; i += 1) {
    const ch = src[i];
    const next = src[i + 1];
    if (comment === "line") {
      if (ch === "\n") comment = null;
      continue;
    }
    if (comment === "block") {
      if (ch === "*" && next === "/") {
        comment = null;
        i += 1;
      }
      continue;
    }
    if (quote) {
      if (ch === "\\") i += 1;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "/" && next === "/") {
      comment = "line";
      i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      comment = "block";
      i += 1;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      quote = ch;
      continue;
    }
    if (ch === "[" || ch === "{") depth += 1;
    else if (ch === "]" || ch === "}") {
      depth -= 1;
      if (depth === 0) return src.slice(open, i + 1);
    }
  }
  assert.fail("TOOL_ATLAS array literal is unterminated");
}

const atlasStart = dataSrc.indexOf("export const TOOL_ATLAS");
assert.ok(atlasStart > -1, "could not find TOOL_ATLAS in src/data/memory.ts");
const atlasSrc = dataSrc.slice(atlasStart);
const atlasLiteral = sliceBalanced(dataSrc, atlasStart);

let atlasRaw;
try {
  // The literal is plain data — strings, arrays, booleans and one nested
  // object — so evaluating it is reading it. A TypeScript annotation or any
  // other non-data syntax inside an entry throws here, loudly, instead of
  // being skipped the way an unmatched regex was.
  atlasRaw = new Function(`"use strict"; return ${atlasLiteral};`)();
} catch (err) {
  assert.fail(`TOOL_ATLAS is not a plain data literal the gate can read: ${err.message}`);
}
assert.ok(
  Array.isArray(atlasRaw) && atlasRaw.length > 60,
  "TOOL_ATLAS did not parse as an array of entries"
);

const atlasEntries = atlasRaw.map((entry, index) => {
  assert.ok(
    entry && typeof entry.name === "string" && typeof entry.group === "string",
    `TOOL_ATLAS entry ${index} has no name/group — the atlas shape changed`
  );
  assert.ok(
    typeof entry.desc === "string" &&
      Array.isArray(entry.caps) &&
      typeof entry.memory === "boolean",
    `${entry.name} is missing desc / caps / memory — the atlas shape changed`
  );
  return {
    name: entry.name,
    group: entry.group,
    desc: entry.desc,
    caps: [...entry.caps].sort(),
    capsWhen: new Map(Object.entries(entry.capsWhen ?? {})),
    memory: entry.memory
  };
});
const atlasNames = atlasEntries.map((e) => e.name);
const atlasSet = new Set(atlasNames);
check(
  atlasSet.size === atlasNames.length,
  `TOOL_ATLAS lists a tool twice (${atlasNames.length} entries, ${atlasSet.size} unique)`
);
/* The parse still has to reach every entry the file writes. `name:` is always
 * a bare identifier-shaped string, so prettier keeps it on its own line and
 * cannot reflow this count out from under the check. */
const writtenEntryCount = (atlasSrc.match(/^ {4}name: "/gm) ?? []).length;
check(
  atlasEntries.length === writtenEntryCount,
  `the atlas parser matched ${atlasEntries.length} entries but the file has ` +
    `${writtenEntryCount} — an entry's shape changed, so this gate is no longer reading all of them`
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

/* A denial site is GUARDED when it is only reachable under a condition, and
 * that changes what the atlas is allowed to say about it. Two shapes carry a
 * guard in server.py, and both are decidable from the statement itself:
 *
 *   inline    `if include_secrets and (denied := _capability_denial(…)):`
 *   enclosed  the whole statement is indented past the function body, i.e. it
 *             sits inside an `if prove_headless:` / `if requested_extractor …:`
 *             block rather than at the top of the tool.
 *
 * Anything at body indentation with nothing in front of the call is a flat
 * requirement. The test is deliberately syntactic: a guard style this has not
 * seen leaves an entry unannotated and fails invariant 17 loudly, rather than
 * being quietly guessed at. */
const BODY_INDENT = 4;
const guardedCaps = new Map([...registeredSet].map((n) => [n, new Set()]));
for (const m of serverSrc.matchAll(
  /_capability_denial\(\s*"([a-z][a-z0-9_]*)"\s*,\s*"([a-z_]+)"/g
)) {
  const tool = m[1];
  const capability = m[2];
  realCaps.get(tool)?.add(capability);

  const lineStart = serverSrc.lastIndexOf("\n", m.index) + 1;
  const lineEnd = serverSrc.indexOf("\n", m.index);
  const line = serverSrc.slice(lineStart, lineEnd < 0 ? serverSrc.length : lineEnd);
  const indent = line.length - line.trimStart().length;
  const before = line.slice(0, line.indexOf("_capability_denial")).trim();
  // `if <condition> and (denied := ` — a condition stands between the branch
  // and the call. `if denied := ` and `denied = ` do not.
  const inlineGuard = /^if\s.+\sand\s\(denied\s*:=\s*$/.test(before);
  if (indent > BODY_INDENT || inlineGuard) guardedCaps.get(tool)?.add(capability);
}
// The three daemon-scoped code writers take their local_write denial through
// a helper rather than inline, so the helper's call sites count too.
for (const m of serverSrc.matchAll(/_local_memory_write_authority\(\s*"([a-z][a-z0-9_]*)"/g)) {
  realCaps.get(m[1])?.add("local_write");
}
const gatedCount = [...realCaps.values()].filter((s) => s.size > 0).length;
assert.ok(
  gatedCount > 15,
  `parsed capability gates for only ${gatedCount} tools — the denial-site parser is wrong`
);
const guardedTotal = [...guardedCaps.values()].reduce((total, set) => total + set.size, 0);
assert.ok(
  guardedTotal >= 5,
  `parsed only ${guardedTotal} guarded denial sites — the guard parser is wrong, not the page`
);

for (const entry of atlasEntries) {
  const real = [...(realCaps.get(entry.name) ?? [])].sort();
  check(
    entry.caps.join(",") === real.join(","),
    `${entry.name} is published as needing [${entry.caps.join(", ") || "no capability"}] but ` +
      `server.py gates it on [${real.join(", ") || "nothing"}]`
  );

  /* ── 17 · a conditional gate is published as conditional ─────────────── */
  const guarded = [...(guardedCaps.get(entry.name) ?? [])].sort();
  const noted = [...entry.capsWhen.keys()].sort();
  check(
    guarded.join(",") === noted.join(","),
    `${entry.name}: server.py reaches [${guarded.join(", ") || "nothing"}] only behind a guard, ` +
      `but the atlas annotates [${noted.join(", ") || "nothing"}]. Every guarded capability needs a ` +
      `capsWhen note naming the condition that reaches it, and every capsWhen note needs a guarded ` +
      `denial site — otherwise the atlas publishes a conditional gate as a flat requirement`
  );
  for (const [capability, note] of entry.capsWhen) {
    check(
      entry.caps.includes(capability),
      `${entry.name} annotates "${capability}" with a condition but does not list it in caps`
    );
    check(
      note.trim().length > 3,
      `${entry.name}'s condition for "${capability}" is not a real note`
    );
    check(
      text.includes(note),
      `${entry.name}'s condition for "${capability}" ("${note}") never reaches the rendered page`
    );
  }
}

/* ── 11 · the memory-toolset marks match MEMORY_TOOLSET ──────────────── */

const toolsetSet = new Set(
  [...toolsetBlock[1].matchAll(/"(burnbar_[a-z0-9_]+)"/g)].map((m) => m[1])
);
for (const entry of atlasEntries) {
  check(
    entry.memory === toolsetSet.has(entry.name),
    entry.memory
      ? `${entry.name} is marked as part of the memory toolset but is not in MEMORY_TOOLSET`
      : `${entry.name} is in MEMORY_TOOLSET but the atlas does not mark it as part of the memory toolset`
  );
}

/* ── 12 · the counts the page prints — and "all" means all ───────────── */

const declaredBurnbar = Number(dataSrc.match(/BURNBAR_TOOL_COUNT\s*=\s*(\d+)/)?.[1] ?? NaN);
check(
  declaredBurnbar === registeredBurnbar.length,
  `BURNBAR_TOOL_COUNT is ${declaredBurnbar} but server.py registers ${registeredBurnbar.length} burnbar_* tools`
);

const declaredOrchestration = Number(
  dataSrc.match(/ORCHESTRATION_TOOL_COUNT\s*=\s*(\d+)/)?.[1] ?? NaN
);
check(
  declaredOrchestration === registeredOrchestration.length,
  `ORCHESTRATION_TOOL_COUNT is ${declaredOrchestration} but server.py registers ` +
    `${registeredOrchestration.length} ministry_*/castle_*/bench_* tools`
);

// The atlas heading's claim is the total, not the burnbar_* subset alone —
// "all N tools" has to name every tool the server registers, full stop.
check(
  text.includes(`All ${registeredAll.length} tools`),
  `the atlas heading should read "All ${registeredAll.length} tools" ` +
    `(${registeredBurnbar.length} burnbar_* + ${registeredOrchestration.length} orchestration)`
);
check(
  declaredBurnbar + declaredOrchestration === registeredAll.length,
  `BURNBAR_TOOL_COUNT (${declaredBurnbar}) + ORCHESTRATION_TOOL_COUNT (${declaredOrchestration}) ` +
    `is ${declaredBurnbar + declaredOrchestration} but server.py registers ${registeredAll.length} tools total`
);

/* The hero's own sentence. The atlas heading was fixed in the coverage round
 * and the first paragraph was not, so the page opened on "63 tools in total"
 * and refuted itself ten sections later. Both halves are asserted: the total
 * must be printed as the total, and the burnbar_* subset must never be. */
check(
  text.includes(`${registeredAll.length} tools in total`),
  `the hero should say "${registeredAll.length} tools in total" — every tool server.py registers`
);
check(
  !new RegExp(`\\b${registeredBurnbar.length} tools in total\\b`).test(text),
  `/memory prints "${registeredBurnbar.length} tools in total", which is the burnbar_* subset — ` +
    `the server registers ${registeredAll.length}`
);

/* The tool count also appears in the meta description, which `text` cannot
 * see because attributes do not survive tag-stripping. */
check(
  metaDescription.includes(`${realToolCount} MCP tools`),
  `the /memory meta description should open on "${realToolCount} MCP tools"; it reads ` +
    `"${metaDescription.slice(0, 60)}…"`
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

/* ── 16 · the gate's own coverage numbers ────────────────────────────
 *
 * "25 of 25 credential shapes, planted in 8 caller-controlled places" was the
 * only pair of product numbers on this page with no mechanical link back to
 * Python — on a page whose gate exists to close exactly that door. Add a 26th
 * shape to eval_memory.py and the page kept saying 25 with a green build.
 */

const evalSrc = readFileSync(join(MCP, "eval_memory.py"), "utf8");
const shapesFn = evalSrc.match(/def _secret_shapes\(\)[\s\S]*?\n    return \{([\s\S]*?)\n    \}/);
assert.ok(shapesFn, "could not find _secret_shapes() in tools/openburnbar-mcp/eval_memory.py");
// Keys only: values contain colons of their own ("Authorization: Bearer …"),
// so this anchors on the dict's own indentation rather than on ": ".
const realShapes = [...shapesFn[1].matchAll(/^\s{8}"([a-z0-9_]+)":/gm)].map((m) => m[1]);
assert.ok(
  realShapes.length > 15 && new Set(realShapes).size === realShapes.length,
  `parsed ${realShapes.length} secret shapes from eval_memory.py — the parser is wrong, not the page`
);
const declaredShapes = Number(
  dataSrc.match(/GATE_SHAPES\s*=\s*\{\s*\n\s*total:\s*(\d+)/)?.[1] ?? NaN
);
check(
  declaredShapes === realShapes.length,
  `GATE_SHAPES.total is ${declaredShapes} but eval_memory.py's SECRET_SHAPES holds ` +
    `${realShapes.length} shapes`
);
// The coverage stat itself, not "25" somewhere in a page this long: both
// halves of the N/N have to be inside the rendered figure.
// Tags first: the build stamps a scoped `data-astro-cid-<hash>` on every
// element, and those hashes contain digits of their own.
const coverageFig = html.match(/<p class="coverage__fig[^"]*"[^>]*>([\s\S]*?)<\/p>/)?.[1] ?? "";
const coverageDigits = (coverageFig.replace(/<[^>]+>/g, " ").match(/\d+/g) ?? []).map(Number);
check(
  coverageDigits.length === 2 && coverageDigits.every((d) => d === realShapes.length),
  `the /memory coverage stat should read ${realShapes.length}/${realShapes.length}; it renders ` +
    `[${coverageDigits.join(", ") || "nothing"}]`
);

const adversarialSrc = readFileSync(join(MCP, "tests", "test_gate_adversarial.py"), "utf8");
const contextCount = ["BODY_CONTEXTS", "AUX_CONTEXTS"].reduce((total, name) => {
  const tuple = adversarialSrc.match(new RegExp(`^${name}\\s*=\\s*\\(([^)]*)\\)`, "m"));
  assert.ok(tuple, `could not find ${name} in tests/test_gate_adversarial.py`);
  return total + [...tuple[1].matchAll(/"[a-z_]+"/g)].length;
}, 0);
assert.ok(contextCount >= 4, `parsed only ${contextCount} adversarial contexts`);
const declaredPlacements = (
  dataSrc.match(/GATE_PLACEMENTS\s*=\s*\[([\s\S]*?)\n\];/)?.[1] ?? ""
).match(/"[^"]+"/g)?.length;
check(
  declaredPlacements === contextCount,
  `GATE_PLACEMENTS lists ${declaredPlacements} places but test_gate_adversarial.py plants each ` +
    `shape in ${contextCount} (BODY_CONTEXTS + AUX_CONTEXTS)`
);
check(
  text.includes(`${contextCount} caller-controlled places`),
  `the page should say the gate suite plants every shape in "${contextCount} caller-controlled places"`
);

// And the assertion that now pins the count, quoted where the page cites it.
check(
  /len\(matrix\)\s*==\s*(\d+)/.test(evalTest) &&
    Number(evalTest.match(/len\(matrix\)\s*==\s*(\d+)/)[1]) === realShapes.length,
  `tests/test_eval_extraction.py must pin the shape count at ${realShapes.length} ` +
    `(assert len(matrix) == ${realShapes.length}) for the page to badge it Pinned`
);

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
  `✓ memory copy: ${realToolCount} memory-toolset tools, ${realWeights.size} kinds and 8 retrieval ` +
    `constants match tools/openburnbar-mcp/; ${measurements.length} measurements render in their own ` +
    `bench cards (${unpinned.length} honestly labelled unpinned); extraction floor ${floor} matches ` +
    `the committed assertion; ${realShapes.length} credential shapes across ${contextCount} ` +
    `placements match the gate suite; device sync is published as not shipped.\n` +
    `✓ memory atlas: all ${registeredAll.length} tools listed and printed as the total, none invented ` +
    `(${registeredBurnbar.length} burnbar_* + ${registeredOrchestration.length} ` +
    `ministry_*/castle_*/bench_*); ${atlasEntries.filter((e) => e.memory).length} marked ` +
    `memory-toolset; ${gatedCount} capability-gated tools match their denial sites, ` +
    `${guardedTotal} of those guarded and annotated with the condition that reaches them; ` +
    `${pageCapEnv.size} capability env vars match server.py; platform claim is honest.`
);
