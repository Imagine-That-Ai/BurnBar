#!/usr/bin/env node
// Self-test for the Firestore rules size tripwire. Runs the real gate against
// the live repo files (must pass today) and unit-checks the threshold logic so
// the ceiling/margin constants cannot silently drift.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");

// 1) The gate passes against the committed rules (regression tripwire: if
//    firestore.rules ever grows past the safety threshold, this fails in CI
//    before the deploy does.)
const output = execFileSync(
  "node",
  [resolve(here, "check-firestore-rules-size.mjs")],
  { cwd: repoRoot, encoding: "utf8" },
);
assert.match(
  output,
  /rules size within safe bounds/,
  "size gate must pass against the current committed rules",
);

// 2) The constants track both Firebase ceilings and keep the source ratchet near
//    the last production-proven ruleset rather than the misleading source max.
const source = readFileSync(resolve(here, "check-firestore-rules-size.mjs"), "utf8");
const hardLimit = Number(/HARD_LIMIT_BYTES = (\d+) \* 1024/.exec(source)?.[1]);
const compiledHardLimit = Number(
  /COMPILED_HARD_LIMIT_BYTES = (\d+) \* 1024/.exec(source)?.[1],
);
const failAt = Number(/FAIL_THRESHOLD_BYTES = (\d+) \* 1024/.exec(source)?.[1]);
const warnAt = Number(/WARN_THRESHOLD_BYTES = (\d+) \* 1024/.exec(source)?.[1]);
assert.equal(hardLimit, 256, "hard limit must track Firebase's 256 KiB ceiling");
assert.equal(
  compiledHardLimit,
  250,
  "compiled hard limit must track Firebase's 250 KiB ceiling",
);
assert.equal(failAt, 160, "source ratchet must fail at 160 KiB");
assert.ok(failAt < compiledHardLimit, "fail threshold must sit below both ceilings");
assert.ok(warnAt < failAt, "warn threshold must sit below the fail threshold");
assert.ok(
  compiledHardLimit - failAt >= 80,
  "keep >=80 KiB between the source ratchet and compiled ceiling",
);

// 3) Dead allow clauses still consume source/compiler budget but grant nothing.
//    Default deny has identical behavior and must remain the canonical form.
const firestoreRules = readFileSync(resolve(repoRoot, "firestore.rules"), "utf8");
assert.doesNotMatch(
  firestoreRules,
  /^\s*allow\s+[^:]+:\s*if\s+false\b/m,
  "dead allow-if-false clauses must use Firestore's default deny",
);
assert.match(
  firestoreRules,
  /match \/users\/\{userId\}\/\{collectionId\}\/\{documentId\}/,
  "direct owner gates must stay consolidated to limit compiler expansion",
);

console.log("PASS: firestore rules size gate self-test");
