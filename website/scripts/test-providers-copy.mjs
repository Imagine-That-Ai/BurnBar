#!/usr/bin/env node
/**
 * test-providers-copy.mjs — /providers says only what the repository can prove.
 *
 * The provider matrix is the page a reader uses to decide whether BurnBar can
 * see their spend at all, and the routing preamble is a capability promise
 * about what the gateway does when an account runs dry. Both rot the same way:
 * the code changes and the page keeps its old sentence. This gate reads BOTH
 * sides — the built page, the data module, and the Swift that implements the
 * routing claims — and refuses to let them disagree.
 *
 * Nine invariants:
 *
 *   1. The headline count is bound to `PROVIDERS_PRIMARY.length` in source AND
 *      the built page prints that same number.
 *   2. The primary "live data" table is bound to `PROVIDERS_PRIMARY` and the
 *      detection-only table to `PROVIDERS_DETECTED` — asserted on the parsed
 *      `<ProviderTable rows={…} />` invocation inside each section, so
 *      swapping the two collections fails here rather than shipping a page
 *      whose live-data table lists vendors that expose nothing.
 *   3. The built primary table renders exactly the `PROVIDERS_PRIMARY` names,
 *      set-equal in both directions — the same proof from the rendered side.
 *   4. Set equality on the confidence vocabulary: the complete `Confidence`
 *      union in providers.ts, the `confidenceKeys` the page iterates, the keys
 *      of `CONFIDENCE_LABEL` and `CONFIDENCE_BLURB`, and the legend cards the
 *      built page actually renders are all the same set. A fourth enum member
 *      without a legend entry fails; a legend entry without an enum member
 *      fails too.
 *   5. Every required provider id is defined inside `PROVIDERS_PRIMARY` — not
 *      merely somewhere in the file, which a detection-only row would satisfy.
 *   6. The routing claims are grounded in the gateway implementation: the
 *      status code the page calls "structured 503" is read out of the three
 *      exact-model rejection responses in
 *      `OpenBurnBarHTTPGatewayServer+RoutePipeline.swift`, and they must all
 *      agree and all be JSON bodies. Change the daemon to 502 and the page's
 *      sentence fails.
 *   7. The exact-model proof gate the page promises exists in code: the route
 *      pipeline filters ranked routes on `canonicalModelID ==
 *      requiredCanonicalModelID`, and `ProviderAccountTypes.swift` skips any
 *      candidate that fails the same comparison. Delete either and the page's
 *      "only picks accounts that carry your exact model" fails.
 *   8. The account-routing and detection-only section headings still stand.
 *   9. Every factual caveat in the `provnotes` section is still rendered on the
 *      built page — admin-key requirements, the unofficial Cursor and Factory
 *      endpoints, the undocumented Z.ai endpoint, Warp's spoofed user agent,
 *      Gemini's absent quota API, and the self-hosting restriction. Deleting
 *      the section fails.
 */

import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const REPO = join(ROOT, "..");
const PAGE = join(ROOT, "dist", "providers", "index.html");

assert.ok(existsSync(PAGE), `expected a built /providers page at ${PAGE} — run astro build first`);

const providersPage = readFileSync(join(ROOT, "src", "pages", "providers.astro"), "utf8");
const providersData = readFileSync(join(ROOT, "src", "data", "providers.ts"), "utf8");
const html = readFileSync(PAGE, "utf8");

const routePipeline = readFileSync(
  join(
    REPO,
    "OpenBurnBarDaemon",
    "Sources",
    "OpenBurnBarDaemon",
    "OpenBurnBarHTTPGatewayServer+RoutePipeline.swift"
  ),
  "utf8"
);
const providerAccountTypes = readFileSync(
  join(
    REPO,
    "OpenBurnBarCore",
    "Sources",
    "OpenBurnBarKernel",
    "SharedModels",
    "ProviderAccountTypes.swift"
  ),
  "utf8"
);

/* One pass, chained so `&amp;lt;` never double-decodes (CodeQL). */
const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'", "#8203": "" };
const decodeEntities = (s) =>
  s.replace(/&(amp|lt|gt|quot|#39|#8203);/g, (_, name) => ENTITIES[name]);
const textOf = (fragment) =>
  decodeEntities(fragment.replace(/<[^>]+>/g, " "))
    .replace(/\s+/g, " ")
    .trim();
const text = textOf(html);

/* Swift and Astro both wrap freely; compare on collapsed whitespace. */
const collapse = (s) => s.replace(/\s+/g, " ");
const routePipelineFlat = collapse(routePipeline);
const providerAccountTypesFlat = collapse(providerAccountTypes);

const failures = [];
const check = (ok, message) => {
  if (!ok) failures.push(message);
};
const sameSet = (a, b) => a.size === b.size && [...a].every((v) => b.has(v));
const show = (set) => [...set].sort().join(", ") || "(empty)";

/* ── parsers ────────────────────────────────────────────────────────────── */

/** Slice one exported `ProviderRow[]` literal out of the data module. */
function providerBlock(name) {
  const opener = `export const ${name}: ProviderRow[] = [`;
  const start = providersData.indexOf(opener);
  assert.notEqual(start, -1, `could not find ${name} in src/data/providers.ts`);
  const end = providersData.indexOf("\n];", start);
  assert.notEqual(end, -1, `could not find the end of ${name} in src/data/providers.ts`);
  return providersData.slice(start + opener.length, end);
}

const primaryBlock = providerBlock("PROVIDERS_PRIMARY");
const detectedBlock = providerBlock("PROVIDERS_DETECTED");

const fieldValues = (block, field) =>
  [...block.matchAll(new RegExp(`^\\s{4}${field}: "([^"]+)"`, "gm"))].map((m) => m[1]);

const primaryIDs = fieldValues(primaryBlock, "id");
const primaryNames = fieldValues(primaryBlock, "name");
const detectedIDs = fieldValues(detectedBlock, "id");

assert.ok(
  primaryIDs.length > 10,
  `PROVIDERS_PRIMARY parsed as ${primaryIDs.length} rows — parser is wrong`
);
assert.equal(
  primaryIDs.length,
  primaryNames.length,
  "every PROVIDERS_PRIMARY row must carry both an id and a name"
);
assert.ok(
  detectedIDs.length > 3,
  `PROVIDERS_DETECTED parsed as ${detectedIDs.length} rows — parser is wrong`
);

/** Split the page into its top-level `<section …>` blocks. */
function sectionContaining(needle) {
  const at = providersPage.indexOf(needle);
  assert.notEqual(at, -1, `providers.astro no longer contains ${JSON.stringify(needle)}`);
  const start = providersPage.lastIndexOf("<section", at);
  assert.notEqual(start, -1, `no enclosing <section> for ${JSON.stringify(needle)}`);
  const end = providersPage.indexOf("</section>", at);
  assert.notEqual(end, -1, `unterminated <section> for ${JSON.stringify(needle)}`);
  return providersPage.slice(start, end);
}

/** The collection bound to the single `<ProviderTable rows={…}>` in a section. */
function tableBinding(section, label) {
  const matches = [...section.matchAll(/<ProviderTable\b[^>]*?\brows=\{([A-Za-z0-9_]+)\}/g)];
  assert.equal(
    matches.length,
    1,
    `expected exactly one <ProviderTable rows={…}> in the ${label} section, found ${matches.length}`
  );
  return matches[0][1];
}

/* ── 1 · headline count, bound and rendered ─────────────────────────────── */

check(
  /const primaryCount = PROVIDERS_PRIMARY\.length;/.test(providersPage),
  "providers.astro must derive primaryCount from PROVIDERS_PRIMARY.length"
);
check(
  /\{primaryCount\}\s+providers ship with live data\./.test(providersPage),
  "the headline must interpolate {primaryCount}, not a written-out number"
);
check(
  text.includes(`${primaryIDs.length} providers ship with live data.`),
  `the built page should say "${primaryIDs.length} providers ship with live data." — PROVIDERS_PRIMARY holds ${primaryIDs.length} rows`
);

/* ── 2 · each table is bound to the collection its section promises ─────── */

const liveDataSection = sectionContaining("providers ship with live data.");
const detectedSection = sectionContaining("Vendors that don't expose data.");

check(
  tableBinding(liveDataSection, "live-data") === "PROVIDERS_PRIMARY",
  `the live-data table must render PROVIDERS_PRIMARY, not ${tableBinding(liveDataSection, "live-data")}`
);
check(
  tableBinding(detectedSection, "detection-only") === "PROVIDERS_DETECTED",
  `the detection-only table must render PROVIDERS_DETECTED, not ${tableBinding(detectedSection, "detection-only")}`
);

/* ── 3 · the rendered primary table carries exactly those providers ─────── */

const FULL_TABLE = 'class="provider-table "';
const COMPACT_TABLE = 'class="provider-table provider-table--compact"';
const fullAt = html.indexOf(FULL_TABLE);
const compactAt = html.indexOf(COMPACT_TABLE);
assert.notEqual(fullAt, -1, "no full-variant provider table in the built /providers page");
assert.notEqual(compactAt, -1, "no compact-variant provider table in the built /providers page");
assert.ok(fullAt < compactAt, "the live-data table must come before the detection-only table");

const renderedPrimaryNames = new Set(
  [...html.slice(fullAt, compactAt).matchAll(/<strong[^>]*>([^<]*)<\/strong>/g)].map((m) =>
    decodeEntities(m[1]).trim()
  )
);
const declaredPrimaryNames = new Set(primaryNames);
check(
  sameSet(renderedPrimaryNames, declaredPrimaryNames),
  `the built live-data table renders {${show(renderedPrimaryNames)}} but PROVIDERS_PRIMARY declares {${show(declaredPrimaryNames)}}`
);

/* ── 4 · confidence vocabulary, set-equal on every surface ──────────────── */

const unionMatch = providersData.match(/export type Confidence =([^;]+);/);
assert.ok(unionMatch, "could not find the Confidence union in src/data/providers.ts");
const unionKeys = new Set([...unionMatch[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]));
assert.ok(unionKeys.size >= 2, `Confidence parsed as ${unionKeys.size} members — parser is wrong`);

const keysMatch = providersPage.match(/const confidenceKeys: Confidence\[\] = \[([^\]]*)\]/);
assert.ok(keysMatch, "could not find confidenceKeys in src/pages/providers.astro");
const pageKeys = new Set([...keysMatch[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]));

function recordKeys(constant) {
  const opener = `export const ${constant}: Record<Confidence, string> = {`;
  const start = providersData.indexOf(opener);
  assert.notEqual(start, -1, `could not find ${constant} in src/data/providers.ts`);
  const end = providersData.indexOf("\n};", start);
  assert.notEqual(end, -1, `could not find the end of ${constant}`);
  const body = providersData.slice(start + opener.length, end);
  return new Set([...body.matchAll(/^\s{2}([A-Za-z0-9_]+):/gm)].map((m) => m[1]));
}

const labelKeys = recordKeys("CONFIDENCE_LABEL");
const blurbKeys = recordKeys("CONFIDENCE_BLURB");

const renderedLegendKeys = new Set(
  [...html.matchAll(/legend__card legend__card--([a-z0-9-]+)/g)].map((m) => m[1])
);

check(
  sameSet(pageKeys, unionKeys),
  `confidenceKeys is {${show(pageKeys)}} but the Confidence union is {${show(unionKeys)}} — every confidence state needs a legend entry, and the legend may not invent one`
);
check(
  sameSet(labelKeys, unionKeys),
  `CONFIDENCE_LABEL covers {${show(labelKeys)}} but the Confidence union is {${show(unionKeys)}}`
);
check(
  sameSet(blurbKeys, unionKeys),
  `CONFIDENCE_BLURB covers {${show(blurbKeys)}} but the Confidence union is {${show(unionKeys)}}`
);
check(
  sameSet(renderedLegendKeys, unionKeys),
  `the built legend renders {${show(renderedLegendKeys)}} but the Confidence union is {${show(unionKeys)}}`
);

/* ── 5 · required primary providers, inside PROVIDERS_PRIMARY ───────────── */

const requiredProviders = [
  "claude-code",
  "codex",
  "openai",
  "copilot",
  "cursor",
  "cursor-agent",
  "factory",
  "minimax",
  "warp"
];

const primaryIDSet = new Set(primaryIDs);
for (const pid of requiredProviders) {
  check(primaryIDSet.has(pid), `PROVIDERS_PRIMARY must define provider "${pid}"`);
}

/* ── 6 · "structured 503" is the status the gateway actually returns ────── */

/** Read `jsonResponse(status: N, …)` out of one Swift response builder. */
function rejectionStatus(functionName) {
  const at = routePipelineFlat.indexOf(`func ${functionName}(`);
  assert.notEqual(
    at,
    -1,
    `${functionName} is gone from OpenBurnBarHTTPGatewayServer+RoutePipeline.swift — the /providers routing claim has no implementation to point at`
  );
  const body = routePipelineFlat.slice(at, at + 600);
  const shape = body.match(/jsonResponse\( status: (\d{3}), body: errorBody\(/);
  assert.ok(
    shape,
    `${functionName} no longer returns a JSON errorBody response — /providers calls this a "structured" failure`
  );
  return Number(shape[1]);
}

const rejectionStatuses = [
  "noEligibleRouteResponse",
  "exactModelIdentityUnavailableResponse",
  "exactModelFailClosedResponse"
].map((name) => [name, rejectionStatus(name)]);

const distinctStatuses = new Set(rejectionStatuses.map(([, status]) => status));
check(
  distinctStatuses.size === 1,
  `the gateway's exact-model rejections disagree on their status code: ${rejectionStatuses
    .map(([name, status]) => `${name}=${status}`)
    .join(", ")}`
);

const gatewayStatus = rejectionStatuses[0][1];
check(
  new RegExp(`structured ${gatewayStatus}\\b`).test(providersPage),
  `providers.astro says "structured ${
    providersPage.match(/structured (\d{3})/)?.[1] ?? "???"
  }" but the gateway returns ${gatewayStatus} when no row proves the model id`
);
check(
  text.includes(`structured ${gatewayStatus}`),
  `the built /providers page must carry the "structured ${gatewayStatus}" claim`
);

/* ── 7 · the exact-model proof gate exists in the implementation ────────── */

check(
  routePipelineFlat.includes(
    "let routes = rankedRoutes.filter { $0.canonicalModelID == requiredCanonicalModelID }"
  ),
  "the route pipeline no longer filters ranked routes on the required canonical model ID — /providers promises failover only picks accounts that carry the exact model"
);
check(
  /guard let requiredCanonicalModelID = ranking\.requiredCanonicalModelID else \{/.test(
    routePipelineFlat
  ) && routePipelineFlat.includes("return .buffered(exactModelIdentityUnavailableResponse("),
  "the route pipeline must still fail closed when no canonical model identity is available, instead of routing anyway"
);
check(
  providerAccountTypesFlat.includes("public var usesExactSameModelInvariant: Bool"),
  "ProviderAccountTypes.swift no longer declares the exact-same-model router invariant"
);
check(
  /guard candidate\.canonicalModelID == requiredCanonicalModelID else \{ .*?skip\( candidate, \.modelIncompatible/.test(
    providerAccountTypesFlat
  ),
  "ProviderAccountTypes.swift no longer skips candidates whose canonical model differs from the requested one"
);

check(
  /Routing is per-account, not per-provider\./.test(providersPage),
  "providers.astro must state that routing is per-account, not per-provider"
);
check(
  /Failover only picks accounts that carry your exact model\./.test(providersPage),
  "providers.astro must assert model identity preservation during failover"
);
check(
  /Accounts have their own clocks and quotas\./.test(providersPage),
  "providers.astro must document independent account clocks and quotas"
);

/* ── 8 · the detection-only promise ─────────────────────────────────────── */

check(
  text.includes("Vendors that don't expose data."),
  "the built /providers page must document detection-only vendors"
);

/* ── 9 · the caveats that carry the factual limitations ─────────────────── */

const CAVEATS = [
  ["admin keys", "org admin", "OpenAI/Anthropic need org admin keys, not regular API keys"],
  ["admin key shape", "sk-ant-admin-", "the admin key prefix the reader has to go find"],
  ["Cursor & Factory", "unofficial endpoints", "Cursor and Factory ride unofficial endpoints"],
  [
    "Cursor local state",
    "editor's local state DB",
    "Cursor's data comes from the editor's local state DB"
  ],
  ["Factory session", "WorkOS browser session", "Factory needs a WorkOS browser session"],
  ["Z.ai", "undocumented", "the BigModel quota endpoint is undocumented"],
  ["Warp", "spoofed User-Agent", "Warp needs a spoofed user agent or its edge limiter returns 429"],
  ["Gemini", "no programmatic quota API", "Google AI Studio exposes no quota API"],
  [
    "Gemini billing",
    "Vertex BigQuery exports",
    "aggregate Gemini billing needs exports we don't implement"
  ],
  [
    "self-hosting",
    "third-party hosting of Claude.ai credentials",
    "Claude Code and Codex stay self-hosted because Anthropic's policy disallows third-party credential hosting"
  ]
];

check(
  providersPage.includes('<section class="provnotes">'),
  "providers.astro must keep the provnotes section — it carries every factual provider limitation"
);
check(
  text.includes("Where it gets messy."),
  "the built /providers page must render the caveats section heading"
);

for (const [label, needle, why] of CAVEATS) {
  check(
    text.includes(needle),
    `the ${label} caveat is gone from the built /providers page (looking for ${JSON.stringify(needle)}): ${why}`
  );
}

/* ── report ─────────────────────────────────────────────────────────────── */

if (failures.length > 0) {
  console.error(`providers-copy: ${failures.length} claim(s) no longer match the repository:\n`);
  for (const failure of failures) console.error(`  ✗ ${failure}`);
  console.error("");
  process.exit(1);
}

console.log(
  `providers-copy: ${primaryIDs.length} primary providers, ${unionKeys.size}-state confidence vocabulary, routing claims grounded in the gateway (${gatewayStatus}), and ${CAVEATS.length} caveats verified`
);
