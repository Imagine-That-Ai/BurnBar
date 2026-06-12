#!/usr/bin/env node
/**
 * gen-rules-entitlements — renders the firestore.rules entitlement product-ID
 * allowlists from the single catalog in packages/entitlements (tech-debt audit
 * H29 / finding-158: the three rules predicates were hand-maintained copies).
 *
 * The generated regions are delimited by BEGIN/END GENERATED marker comments
 * inside `activePremiumEntitlementData`, `activeMediaEntitlementData`, and
 * `activeComputerUseEntitlementData`. This script is the ONLY writer of those
 * regions; the product IDs live in
 * `packages/entitlements/src/catalog.ts` (FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS).
 *
 * Usage:
 *   node tools/gen-rules-entitlements.mjs            # rewrite firestore.rules in place
 *   node tools/gen-rules-entitlements.mjs --check    # exit 1 if firestore.rules drifts (CI gate)
 *   node tools/gen-rules-entitlements.mjs --print-list <premium|media|computerUse>
 *                                                    # print just the bare allowlist span (no markers)
 *
 * Requires the entitlements package to be built first:
 *   bash scripts/build-entitlements.sh
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const rulesPath = path.join(repoRoot, "firestore.rules");
const catalogJsPath = path.join(repoRoot, "packages/entitlements/lib/catalog.js");

if (!existsSync(catalogJsPath)) {
  console.error(
    `gen-rules-entitlements: ${path.relative(repoRoot, catalogJsPath)} not found.\n` +
      "Build the entitlements package first: bash scripts/build-entitlements.sh",
  );
  process.exit(2);
}

const { FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS } = await import(pathToFileURL(catalogJsPath).href);

/**
 * One region per rules predicate. `linePrefix` preserves the file's historical
 * indentation byte-for-byte (the computer-use predicate has always been
 * tab-prefixed), so adopting the generator produced a comment-only diff.
 */
const REGIONS = [
  { name: "premium", functionName: "activePremiumEntitlementData", linePrefix: "" },
  { name: "media", functionName: "activeMediaEntitlementData", linePrefix: "" },
  { name: "computerUse", functionName: "activeComputerUseEntitlementData", linePrefix: "\t" },
];

function beginMarker(name) {
  return `// BEGIN GENERATED: entitlement-product-ids ${name} — do not hand-edit.`;
}

function endMarker(name) {
  return `// END GENERATED: entitlement-product-ids ${name}`;
}

/** The bare `&& entitlement.productID in [...]` span, byte-identical to the historical hand-written lists. */
function renderListSpan(region) {
  const ids = FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS[region.name];
  if (!Array.isArray(ids) || ids.length === 0) {
    throw new Error(`No allowlist for region "${region.name}" in FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS`);
  }
  const p = region.linePrefix;
  const lines = [`${p}        && entitlement.productID in [`];
  ids.forEach((id, index) => {
    lines.push(`${p}          "${id}"${index === ids.length - 1 ? "" : ","}`);
  });
  lines.push(`${p}        ]`);
  return lines.join("\n");
}

/** The marker-delimited generated block. */
function renderBlock(region) {
  const p = region.linePrefix;
  return [
    `${p}        ${beginMarker(region.name)}`,
    `${p}        // Source: packages/entitlements/src/catalog.ts (FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS.${region.name}).`,
    `${p}        // Regenerate: node tools/gen-rules-entitlements.mjs (CI drift gate: --check).`,
    renderListSpan(region),
    `${p}        ${endMarker(region.name)}`,
  ].join("\n");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Replaces the generated region for `region` in `source` and returns the new
 * source. Prefers the marker pair; falls back to the raw hand-written
 * `&& entitlement.productID in [...]` span inside the named function
 * (bootstrap path). Throws if neither is found — this gate fails closed.
 */
function replaceRegion(source, region) {
  const block = renderBlock(region);

  const markered = new RegExp(
    `^[\\t ]*${escapeRegExp(beginMarker(region.name))}$[\\s\\S]*?^[\\t ]*${escapeRegExp(endMarker(region.name))}$`,
    "m",
  );
  if (markered.test(source)) {
    return source.replace(markered, () => block);
  }

  // Bootstrap: locate the bare list inside the named function.
  const fnStart = source.indexOf(`function ${region.functionName}(`);
  if (fnStart === -1) {
    throw new Error(`firestore.rules: function ${region.functionName} not found`);
  }
  const fnEnd = source.indexOf("\n    }", fnStart);
  const fnBody = source.slice(fnStart, fnEnd === -1 ? undefined : fnEnd);
  const bareSpan = /^[\t ]*&& entitlement\.productID in \[[\s\S]*?^[\t ]*\]/m.exec(fnBody);
  if (!bareSpan) {
    throw new Error(`firestore.rules: product-ID list not found inside ${region.functionName}`);
  }
  const absoluteIndex = fnStart + bareSpan.index;
  return source.slice(0, absoluteIndex) + block + source.slice(absoluteIndex + bareSpan[0].length);
}

function regenerate(source) {
  let next = source;
  for (const region of REGIONS) {
    next = replaceRegion(next, region);
  }
  return next;
}

const args = process.argv.slice(2);
const current = readFileSync(rulesPath, "utf8");

if (args[0] === "--print-list") {
  const region = REGIONS.find((candidate) => candidate.name === args[1]);
  if (!region) {
    console.error(`Unknown region "${args[1]}". Expected one of: ${REGIONS.map((r) => r.name).join(", ")}`);
    process.exit(2);
  }
  process.stdout.write(`${renderListSpan(region)}\n`);
  process.exit(0);
}

const regenerated = regenerate(current);

if (args[0] === "--check") {
  if (regenerated === current) {
    console.log("firestore.rules entitlement allowlists are in sync with packages/entitlements.");
    process.exit(0);
  }
  console.error(
    "firestore.rules entitlement allowlists DRIFTED from packages/entitlements/src/catalog.ts.\n" +
      "Run `node tools/gen-rules-entitlements.mjs` (after scripts/build-entitlements.sh) and commit the result.",
  );
  // Show the first differing line for fast diagnosis.
  const currentLines = current.split("\n");
  const regeneratedLines = regenerated.split("\n");
  const limit = Math.max(currentLines.length, regeneratedLines.length);
  for (let index = 0; index < limit; index += 1) {
    if (currentLines[index] !== regeneratedLines[index]) {
      console.error(`First difference at firestore.rules:${index + 1}`);
      console.error(`  committed:   ${JSON.stringify(currentLines[index] ?? "<missing>")}`);
      console.error(`  regenerated: ${JSON.stringify(regeneratedLines[index] ?? "<missing>")}`);
      break;
    }
  }
  process.exit(1);
}

if (regenerated === current) {
  console.log("firestore.rules already up to date.");
} else {
  writeFileSync(rulesPath, regenerated);
  console.log("firestore.rules entitlement allowlists regenerated.");
}
