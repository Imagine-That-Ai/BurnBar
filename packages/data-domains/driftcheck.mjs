#!/usr/bin/env node
/**
 * Firestore-rules ⇄ registry drift check.
 *
 * Asserts every per-user subcollection declared in firestore.rules
 * (`match /users/{userId}/<collection>/...`) is accounted for in the data-domain
 * registry — either covered by some domain's firestorePaths or explicitly listed
 * in `excludedCollections`. This makes it impossible to add a new user-data
 * collection without consciously deciding whether it belongs in the Data &
 * Privacy Control Center: no silent gaps.
 *
 * Exit 0 = no drift. Exit 1 = uncovered collection(s). Pure Node.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
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

if (import.meta.url === `file://${process.argv[1]}`) main();
