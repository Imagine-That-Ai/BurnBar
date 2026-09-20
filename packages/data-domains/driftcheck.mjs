#!/usr/bin/env node
/**
 * Firestore-rules ⇄ registry drift check.
 *
 * Asserts every per-user subcollection declared in firestore.rules — either as
 * a literal `match /users/{userId}/<collection>/...` path or in a consolidated
 * `collectionId in [...]` gate — is accounted for in the data-domain registry.
 * Each collection must be covered by a domain's firestorePaths or explicitly
 * listed in `excludedCollections`. This makes it impossible to add a new
 * user-data collection without consciously deciding whether it belongs in the
 * Data & Privacy Control Center: no silent gaps.
 *
 * Exit 0 = no drift. Exit 1 = uncovered collection(s). Pure Node.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadRegistry } from "./codegen.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const RULES_PATH = join(HERE, "..", "..", "firestore.rules");

/** First path segment of a registry firestorePath, e.g. "session_logs/{x}/bodies" -> "session_logs". */
function topCollection(path) {
  return String(path).split("/")[0].trim();
}

/** Extract the set of per-user subcollection names declared in firestore.rules text. */
export function userCollectionsInRules(rulesText) {
  const found = new Set();
  // Matches: match /users/{userId}/<collection>/...  (also tolerates {uid})
  const re = /match\s+\/users\/\{[A-Za-z0-9_]+\}\/([A-Za-z0-9_]+)\b/g;
  let m;
  while ((m = re.exec(rulesText)) !== null) {
    found.add(m[1]);
  }

  // Consolidated direct-child gates use a wildcard collection segment and
  // explicit operation-level allowlists. Treat every quoted identifier inside
  // `collectionId in [...]` as a declared user collection too. Limiting the
  // capture to the membership expression avoids pulling unrelated rule strings
  // (field names, enum values, or nested paths) into the registry contract.
  const consolidated = /collectionId\s+in\s+\[([\s\S]*?)\]/g;
  while ((m = consolidated.exec(rulesText)) !== null) {
    const identifiers = m[1].matchAll(/"([A-Za-z0-9_]+)"/g);
    for (const identifier of identifiers) found.add(identifier[1]);
  }
  return found;
}

/** Returns { uncovered: string[], covered: string[] } comparing rules against the registry. */
export function findDrift(rulesText, registry) {
  const declared = userCollectionsInRules(rulesText);
  const covered = new Set();
  for (const d of registry.domains) {
    for (const p of d.firestorePaths) covered.add(topCollection(p));
  }
  for (const k of Object.keys(registry.excludedCollections ?? {})) covered.add(k);
  // `ops` is a server-only doc namespace (users/{uid}/ops/...), never user-facing.
  covered.add("ops");

  const uncovered = [...declared].filter((c) => !covered.has(c)).sort();
  return { uncovered, covered: [...declared].filter((c) => covered.has(c)).sort(), declared: [...declared].sort() };
}

function main() {
  const registry = loadRegistry();
  const rulesText = readFileSync(RULES_PATH, "utf8");
  const { uncovered, declared } = findDrift(rulesText, registry);
  if (uncovered.length) {
    console.error(
      `[data-domains] DRIFT: ${uncovered.length} user-data collection(s) in firestore.rules are not in the registry ` +
        "(add to a domain's firestorePaths or to excludedCollections):\n  - " +
        uncovered.join("\n  - "),
    );
    process.exit(1);
  }
  console.log(`[data-domains] no drift — all ${declared.length} user subcollections in firestore.rules are accounted for.`);
}

// See the note in codegen.mjs: a repo path with a space makes the raw
// `file://${process.argv[1]}` comparison fail and this check silently pass.
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) main();
