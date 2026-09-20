#!/usr/bin/env node
// Self-test for the Firestore rules size tripwire. Runs the real gate against
// the live repo files (must pass today) and unit-checks the threshold logic so
// the ceiling/margin constants cannot silently drift.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  COMPILED_HARD_LIMIT_BYTES,
  evaluateRulesSources,
  FAIL_THRESHOLD_BYTES,
  HARD_LIMIT_BYTES,
  runRulesSizeCheck,
  STORAGE_FAIL_THRESHOLD_BYTES,
  STORAGE_WARN_THRESHOLD_BYTES,
  WARN_THRESHOLD_BYTES,
} from "./check-firestore-rules-size.mjs";

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
assert.equal(
  HARD_LIMIT_BYTES,
  256 * 1024,
  "hard limit must track Firebase's 256 KiB ceiling",
);
assert.equal(
  COMPILED_HARD_LIMIT_BYTES,
  250 * 1024,
  "compiled hard limit must track Firebase's 250 KiB ceiling",
);
assert.equal(
  FAIL_THRESHOLD_BYTES,
  150 * 1024,
  "source ratchet must fail at 150 KiB",
);
assert.equal(
  WARN_THRESHOLD_BYTES,
  146 * 1024,
  "source ratchet must warn at 146 KiB",
);
assert.equal(
  STORAGE_FAIL_THRESHOLD_BYTES,
  160 * 1024,
  "Storage must retain its independently proven 160 KiB failure ratchet",
);
assert.equal(
  STORAGE_WARN_THRESHOLD_BYTES,
  156 * 1024,
  "Storage must retain its independently proven 156 KiB warning ratchet",
);
assert.ok(
  FAIL_THRESHOLD_BYTES < COMPILED_HARD_LIMIT_BYTES,
  "fail threshold must sit below both ceilings",
);
assert.ok(
  WARN_THRESHOLD_BYTES < FAIL_THRESHOLD_BYTES,
  "warn threshold must sit below the fail threshold",
);
assert.ok(
  COMPILED_HARD_LIMIT_BYTES - FAIL_THRESHOLD_BYTES >= 100 * 1024,
  "keep >=100 KiB between the source ratchet and compiled ceiling",
);

// 3) Boundary behavior is executable, not inferred from parsed constants. Exact
//    warning/failure bytes must select the right stream and exit status.
function captureEvaluation(repeatCount, value = "x", thresholds = {}) {
  const output = { log: [], warn: [], error: [] };
  const logger = {
    log: (message) => output.log.push(message),
    warn: (message) => output.warn.push(message),
    error: (message) => output.error.push(message),
  };
  const exitCode = evaluateRulesSources(
    [
      {
        name: "fixture.rules",
        raw: value.repeat(repeatCount),
        compact: false,
        ...thresholds,
      },
    ],
    logger,
  );
  return { exitCode, output };
}

let result = captureEvaluation(WARN_THRESHOLD_BYTES - 1);
assert.equal(result.exitCode, 0, "WARN-1 must pass");
assert.equal(result.output.warn.length, 0, "WARN-1 must not warn");
assert.match(result.output.log[0], /^ok fixture\.rules:/, "WARN-1 must log ok");

result = captureEvaluation(WARN_THRESHOLD_BYTES);
assert.equal(result.exitCode, 0, "WARN must remain non-blocking");
assert.equal(result.output.warn.length, 1, "WARN must emit one warning");
assert.match(
  result.output.warn[0],
  /^::warning::fixture\.rules:/,
  "WARN must use warning output",
);

result = captureEvaluation(FAIL_THRESHOLD_BYTES - 1);
assert.equal(result.exitCode, 0, "FAIL-1 must remain non-blocking");
assert.equal(result.output.warn.length, 1, "FAIL-1 must warn");

result = captureEvaluation(FAIL_THRESHOLD_BYTES);
assert.equal(result.exitCode, 1, "FAIL must return a nonzero exit status");
assert.equal(result.output.error.length, 1, "FAIL must emit one error");
assert.match(
  result.output.error[0],
  /^::error::fixture\.rules:/,
  "FAIL must use error output",
);

result = captureEvaluation(WARN_THRESHOLD_BYTES / 2, "é");
assert.equal(
  result.exitCode,
  0,
  "UTF-8 fixture at WARN must remain non-blocking",
);
assert.equal(
  result.output.warn.length,
  1,
  "UTF-8 byte counting must reach the WARN boundary",
);

result = captureEvaluation(155 * 1024);
assert.equal(result.exitCode, 1, "155 KiB must fail the Firestore ratchet");
result = captureEvaluation(155 * 1024, "x", {
  failThreshold: STORAGE_FAIL_THRESHOLD_BYTES,
  warnThreshold: STORAGE_WARN_THRESHOLD_BYTES,
});
assert.equal(
  result.exitCode,
  0,
  "155 KiB must stay below the independent Storage warning",
);
assert.equal(
  result.output.warn.length,
  0,
  "Storage policy must not inherit Firestore warnings",
);

// 4) The production two-file runner must keep the Firestore and Storage
//    thresholds independent while accumulating a failure from either file.
function captureRun(root) {
  const output = { log: [], warn: [], error: [] };
  const logger = {
    log: (message) => output.log.push(message),
    warn: (message) => output.warn.push(message),
    error: (message) => output.error.push(message),
  };
  return { exitCode: runRulesSizeCheck(root, logger), output };
}

const runnerFixtureRoot = mkdtempSync(
  join(tmpdir(), "openburnbar-rules-size-runner-"),
);
try {
  writeFileSync(
    resolve(runnerFixtureRoot, "firestore.rules"),
    "x".repeat(FAIL_THRESHOLD_BYTES),
  );
  writeFileSync(resolve(runnerFixtureRoot, "storage.rules"), "");
  result = captureRun(runnerFixtureRoot);
  assert.equal(result.exitCode, 1, "an oversized Firestore source must fail");
  assert.equal(result.output.error.length, 1);
  assert.match(result.output.error[0], /^::error::firestore\.rules:/);
  assert.match(
    result.output.log.join("\n"),
    /^ok storage\.rules:/m,
    "Storage must still use its independent policy when Firestore fails",
  );

  writeFileSync(resolve(runnerFixtureRoot, "firestore.rules"), "");
  writeFileSync(
    resolve(runnerFixtureRoot, "storage.rules"),
    "x".repeat(STORAGE_FAIL_THRESHOLD_BYTES),
  );
  result = captureRun(runnerFixtureRoot);
  assert.equal(result.exitCode, 1, "an oversized Storage source must fail");
  assert.equal(result.output.error.length, 1);
  assert.match(result.output.error[0], /^::error::storage\.rules:/);
  assert.match(
    result.output.log.join("\n"),
    /^ok firestore\.rules:/m,
    "Firestore must still use its independent policy when Storage fails",
  );
} finally {
  rmSync(runnerFixtureRoot, { recursive: true, force: true });
}

// 5) The executable CLI must propagate a failing rules check to the process
//    status that CI observes, not merely print an error.
// realpath: on macOS tmpdir() returns a /var symlink; Node realpaths
// import.meta.url but not argv, so the CLI's run-as-main guard would silently
// not fire inside the fixture and the spawn would exit 0 with no output.
// Linux CI has no such symlink, so this failure mode is invisible there: the
// lane stays green while the assertion below never actually exercises the CLI,
// and the same self-test fails for anyone running it on a Mac. Removing the
// realpath call re-opens exactly that split, so keep it even though it reads
// like a redundant no-op next to mkdtempSync.
const cliFixtureRoot = realpathSync(
  mkdtempSync(join(tmpdir(), "openburnbar-rules-size-cli-")),
);
try {
  const cliDirectory = resolve(cliFixtureRoot, "scripts/ci");
  mkdirSync(cliDirectory, { recursive: true });
  copyFileSync(
    resolve(here, "check-firestore-rules-size.mjs"),
    resolve(cliDirectory, "check-firestore-rules-size.mjs"),
  );
  copyFileSync(
    resolve(here, "firebase-rules-source.mjs"),
    resolve(cliDirectory, "firebase-rules-source.mjs"),
  );
  writeFileSync(
    resolve(cliFixtureRoot, "firestore.rules"),
    "x".repeat(FAIL_THRESHOLD_BYTES),
  );
  writeFileSync(resolve(cliFixtureRoot, "storage.rules"), "");

  const failure = spawnSync(
    "node",
    [resolve(cliDirectory, "check-firestore-rules-size.mjs")],
    { cwd: cliFixtureRoot, encoding: "utf8" },
  );
  assert.equal(failure.status, 1, "the real CLI must exit 1 on a size failure");
  assert.match(
    failure.stderr,
    /^::error::firestore\.rules:/m,
    "the failing CLI must identify the oversized Firestore source",
  );
} finally {
  rmSync(cliFixtureRoot, { recursive: true, force: true });
}

// 6) Dead allow clauses still consume source/compiler budget but grant nothing.
//    Default deny has identical behavior and must remain the canonical form.
const firestoreRules = readFileSync(
  resolve(repoRoot, "firestore.rules"),
  "utf8",
);
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
