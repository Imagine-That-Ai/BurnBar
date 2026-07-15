import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(HERE, "..", "check-deploy-freshness.mjs");
const FIXTURES = join(HERE, "fixtures", "deploy-freshness");

/**
 * Run the deploy-freshness monitor with the given env overrides.
 * Returns { code, stderr } so callers can assert on both exit code and
 * error-message content. execFileSync throws on non-zero exit, so we
 * capture the status and stderr from the thrown error.
 */
function run(env = {}) {
  const mergedEnv = { ...process.env, ...env };
  try {
    execFileSync("node", [SCRIPT], {
      env: mergedEnv,
      stdio: "pipe",
    });
    return { code: 0, stderr: "" };
  } catch (e) {
    return { code: e.status ?? 1, stderr: String(e.stderr ?? "") };
  }
}

// ---------------------------------------------------------------------------
// Case 1 — Recent fixture passes (exit 0)
// ---------------------------------------------------------------------------
test("recent fixture (2-day-old deploys) passes with default 14-day threshold", () => {
  const { code } = run({ DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "recent.json") });
  assert.equal(code, 0);
});

// ---------------------------------------------------------------------------
// Case 2 — Stale fixture fails (exit 1) — the 6/18 freeze proof
// ---------------------------------------------------------------------------
test("stale fixture (~24-day-old deploys) fails with exit 1 and 6/18 freeze message", () => {
  const { code, stderr } = run({ DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "stale.json") });
  assert.equal(code, 1);
  assert.match(stderr, /FAIL/);
  assert.match(stderr, /6\/18 freeze/);
});

// ---------------------------------------------------------------------------
// Case 3 — Invalid threshold (zero) fails (exit 2)
// ---------------------------------------------------------------------------
test("DEPLOY_FRESHNESS_MAX_AGE_DAYS=0 fails with exit 2 and 'positive integer' message", () => {
  const { code, stderr } = run({
    DEPLOY_FRESHNESS_MAX_AGE_DAYS: "0",
    DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "recent.json"),
  });
  assert.equal(code, 2);
  assert.match(stderr, /positive integer/);
});

// ---------------------------------------------------------------------------
// Case 4 — Invalid threshold (negative) fails (exit 2)
// ---------------------------------------------------------------------------
test("DEPLOY_FRESHNESS_MAX_AGE_DAYS=-5 fails with exit 2", () => {
  const { code, stderr } = run({
    DEPLOY_FRESHNESS_MAX_AGE_DAYS: "-5",
    DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "recent.json"),
  });
  assert.equal(code, 2);
  assert.match(stderr, /positive integer/);
});

// ---------------------------------------------------------------------------
// Case 5 — Invalid threshold (non-integer) fails (exit 2)
// ---------------------------------------------------------------------------
test("DEPLOY_FRESHNESS_MAX_AGE_DAYS=3.5 fails with exit 2", () => {
  const { code, stderr } = run({
    DEPLOY_FRESHNESS_MAX_AGE_DAYS: "3.5",
    DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "recent.json"),
  });
  assert.equal(code, 2);
  assert.match(stderr, /positive integer/);
});

// ---------------------------------------------------------------------------
// Case 6 — Functions-only fixture passes (exit 0)
// ---------------------------------------------------------------------------
test("functions-only fixture (no cloudRun, 2-day-old functions) passes", () => {
  const { code } = run({ DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "functions-only.json") });
  assert.equal(code, 0);
});

// ---------------------------------------------------------------------------
// Case 7 — Custom valid threshold works (exit 0)
// ---------------------------------------------------------------------------
test("DEPLOY_FRESHNESS_MAX_AGE_DAYS=7 passes recent fixture (2 days < 7 days)", () => {
  const { code } = run({
    DEPLOY_FRESHNESS_MAX_AGE_DAYS: "7",
    DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "recent.json"),
  });
  assert.equal(code, 0);
});

// ---------------------------------------------------------------------------
// Case 8 — Custom threshold catches stale (exit 1)
// ---------------------------------------------------------------------------
test("DEPLOY_FRESHNESS_MAX_AGE_DAYS=7 catches stale fixture (24 days > 7 days)", () => {
  const { code, stderr } = run({
    DEPLOY_FRESHNESS_MAX_AGE_DAYS: "7",
    DEPLOY_FRESHNESS_FIXTURE: join(FIXTURES, "stale.json"),
  });
  assert.equal(code, 1);
  assert.match(stderr, /FAIL/);
});