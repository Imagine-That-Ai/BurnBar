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

// 2) The constants keep a real margin under Firebase's documented 256 KiB
//    ceiling — the whole point is to fail BEFORE the API does.
const source = readFileSync(resolve(here, "check-firestore-rules-size.mjs"), "utf8");
const hardLimit = Number(/HARD_LIMIT_BYTES = (\d+) \* 1024/.exec(source)?.[1]);
const failAt = Number(/FAIL_THRESHOLD_BYTES = (\d+) \* 1024/.exec(source)?.[1]);
const warnAt = Number(/WARN_THRESHOLD_BYTES = (\d+) \* 1024/.exec(source)?.[1]);
assert.equal(hardLimit, 256, "hard limit must track Firebase's 256 KiB ceiling");
assert.ok(failAt < hardLimit, "fail threshold must sit below the hard ceiling");
assert.ok(warnAt < failAt, "warn threshold must sit below the fail threshold");
assert.ok(hardLimit - failAt >= 16, "keep >=16 KiB of headroom below the ceiling");

console.log("PASS: firestore rules size gate self-test");
