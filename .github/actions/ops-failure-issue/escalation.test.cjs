const assert = require("node:assert/strict");
const test = require("node:test");
const {
  BLOCKER_LABEL,
  ESCALATED_LABEL,
  ESCALATION_AFTER_MS,
  REPAGE_LABEL,
  SEVEN_DAY_REPAGE_AFTER_MS,
  P0_LABEL,
  PAGED_LABEL,
  classifyFailure,
  evaluateP0Escalation,
  evaluateSevenDayRepage,
  shouldRepageP0,
  shouldPageP0,
} = require("./escalation.cjs");

const now = Date.parse("2026-07-10T12:00:00Z");

function issue({ ageMs = ESCALATION_AFTER_MS, labels = [P0_LABEL], createdAt } = {}) {
  return {
    created_at: createdAt ?? new Date(now - ageMs).toISOString(),
    labels,
  };
}

test("escalates a P0 exactly at the 72-hour SLO", () => {
  assert.deepEqual(evaluateP0Escalation(issue(), now), {
    shouldEscalate: true,
    reason: "overdue-p0",
    ageHours: 72,
  });
});

test("does not escalate before 72 hours", () => {
  assert.equal(
    evaluateP0Escalation(issue({ ageMs: ESCALATION_AFTER_MS - 1 }), now).reason,
    "within-slo"
  );
});

test("does not escalate non-P0 issues", () => {
  assert.deepEqual(evaluateP0Escalation(issue({ labels: ["P1 - High"] }), now), {
    shouldEscalate: false,
    reason: "not-p0",
  });
});

test("a named blocker suppresses the age escalation", () => {
  assert.deepEqual(evaluateP0Escalation(issue({ labels: [P0_LABEL, BLOCKER_LABEL] }), now), {
    shouldEscalate: false,
    reason: "named-blocker",
  });
});

test("the escalation label makes notification one-time", () => {
  assert.deepEqual(evaluateP0Escalation(issue({ labels: [P0_LABEL, ESCALATED_LABEL] }), now), {
    shouldEscalate: false,
    reason: "already-escalated",
  });
});

test("accepts GitHub API label objects", () => {
  assert.equal(
    evaluateP0Escalation(issue({ labels: [{ name: P0_LABEL }] }), now).shouldEscalate,
    true
  );
});

test("invalid issue timestamps fail closed", () => {
  assert.throws(
    () => evaluateP0Escalation(issue({ createdAt: "invalid" }), now),
    /valid timestamps/
  );
});

test("re-pages an unblocked P0 at the seven-day tier exactly once", () => {
  const sevenDayIssue = issue({
    ageMs: SEVEN_DAY_REPAGE_AFTER_MS,
    labels: [P0_LABEL, PAGED_LABEL],
  });
  assert.deepEqual(evaluateSevenDayRepage(sevenDayIssue, now), {
    shouldRepage: true,
    reason: "repage-p0",
    ageHours: 168,
  });
  assert.deepEqual(
    evaluateSevenDayRepage(
      { ...sevenDayIssue, labels: [P0_LABEL, PAGED_LABEL, REPAGE_LABEL] },
      now,
    ),
    { shouldRepage: false, reason: "already-repaged" },
  );
});

test("does not re-page before seven days or for a named blocker", () => {
  assert.equal(
    evaluateSevenDayRepage(
      issue({ ageMs: SEVEN_DAY_REPAGE_AFTER_MS - 1, labels: [P0_LABEL, PAGED_LABEL] }),
      now,
    ).reason,
    "within-seven-day-slo",
  );
  assert.deepEqual(
    evaluateSevenDayRepage(
      issue({ ageMs: SEVEN_DAY_REPAGE_AFTER_MS, labels: [P0_LABEL, PAGED_LABEL, BLOCKER_LABEL] }),
      now,
    ),
    { shouldRepage: false, reason: "named-blocker" },
  );
});

test("shouldRepageP0 has explicit mode, timestamp, and label gates", () => {
  const createdAt = new Date(now - SEVEN_DAY_REPAGE_AFTER_MS).toISOString();
  assert.deepEqual(
    shouldRepageP0({ mode: "open", labels: [P0_LABEL, PAGED_LABEL], createdAt, nowMs: now }),
    { shouldRepage: true, reason: "repage-p0", ageHours: 168 },
  );
  assert.deepEqual(
    shouldRepageP0({ mode: "close", labels: [P0_LABEL, PAGED_LABEL], createdAt, nowMs: now }),
    { shouldRepage: false, reason: "not-open-mode" },
  );
  assert.deepEqual(
    shouldRepageP0({ mode: "open", labels: [P0_LABEL], createdAt, nowMs: now }),
    { shouldRepage: false, reason: "not-initially-paged" },
  );
});

test("classifies infra-failed and skipped states separately from budget failures", () => {
  assert.deepEqual(
    classifyFailure({ conclusion: "failure", reasonCode: "helper-timeout" }),
    { classification: "infra", failureClass: "infra", reasonCode: "helper-timeout" },
  );
  assert.deepEqual(
    classifyFailure({ conclusion: "infra-failed" }),
    { classification: "infra", failureClass: "infra", reasonCode: "infra-failed" },
  );
  assert.deepEqual(
    classifyFailure({ conclusion: "skipped" }),
    { classification: "infra", failureClass: "infra", reasonCode: "skipped" },
  );
  assert.deepEqual(
    classifyFailure({ conclusion: "failure" }),
    { classification: "budget", failureClass: "budget", reasonCode: "budget-failed" },
  );
  assert.deepEqual(
    classifyFailure({ conclusion: "success", reasonCode: "linux-performance-budget-failed" }),
    { classification: "budget", failureClass: "budget", reasonCode: "linux-performance-budget-failed" },
  );
  assert.deepEqual(
    classifyFailure({ conclusion: "stale" }),
    { classification: "infra", failureClass: "infra", reasonCode: "unknown-conclusion" },
  );
  assert.deepEqual(
    classifyFailure({ status: "queued", conclusion: "success" }),
    { classification: "infra", failureClass: "infra", reasonCode: "infra-failed" },
  );
  assert.deepEqual(
    classifyFailure({ status: "skipped", conclusion: "success" }),
    { classification: "infra", failureClass: "infra", reasonCode: "infra-failed" },
  );
});

// ---------------------------------------------------------------------------
// P-OPS-4 paging: shouldPageP0
// Dedupe is the persistent paged:ops label on the issue, not a one-shot flag.

test("shouldPageP0 pages a P0 that lacks paged:ops (first open or unpaged standing red)", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-unpaged" }
  );
});

test("shouldPageP0 does not page a P0 that already has paged:ops (dedupe)", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", P0_LABEL, PAGED_LABEL] }),
    { shouldPage: false, reason: "already-paged" }
  );
});

test("shouldPageP0 never pages in close mode", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "close", labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: false, reason: "not-open-mode" }
  );
});

test("shouldPageP0 never pages for a non-P0 lane", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", "P1 - High"] }),
    { shouldPage: false, reason: "not-p0" }
  );
});

test("shouldPageP0 suppresses paging when a named blocker is present", () => {
  assert.deepEqual(
    shouldPageP0({
      mode: "open",
      labels: ["lane:nightly-e2e", P0_LABEL, BLOCKER_LABEL],
    }),
    { shouldPage: false, reason: "named-blocker" }
  );
});

test("shouldPageP0 accepts GitHub API label objects", () => {
  assert.deepEqual(
    shouldPageP0({
      mode: "open",
      labels: [{ name: "lane:nightly-e2e" }, { name: P0_LABEL }],
    }),
    { shouldPage: true, reason: "p0-unpaged" }
  );
});

test("PAGED_LABEL is the expected 'paged:ops' string", () => {
  assert.equal(PAGED_LABEL, "paged:ops");
});

test("dedupe lifecycle: first open pages, repeat suppresses, close→reopen pages again", () => {
  // First genuine open (issue lacks paged:ops) → page.
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-unpaged" }
  );
  // After successful page, the action adds paged:ops; a repeat (standing
  // red with paged:ops) does NOT page.
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", P0_LABEL, PAGED_LABEL] }),
    { shouldPage: false, reason: "already-paged" }
  );
  // Close → never pages.
  assert.deepEqual(
    shouldPageP0({ mode: "close", labels: ["lane:nightly-e2e", P0_LABEL, PAGED_LABEL] }),
    { shouldPage: false, reason: "not-open-mode" }
  );
  // New open after close (new issue, no paged:ops) → page again.
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-unpaged" }
  );
});

test("failed/missing webhook leaves issue unpaged so a later run can retry", () => {
  // First run: P0 lacks paged:ops → eligible to page. If webhook is
  // missing/failed, the action does NOT add paged:ops.
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-unpaged" }
  );
  // Next run: the issue STILL lacks paged:ops → eligible again (retry).
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-unpaged" }
  );
});