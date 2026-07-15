const assert = require("node:assert/strict");
const test = require("node:test");
const {
  BLOCKER_LABEL,
  ESCALATED_LABEL,
  ESCALATION_AFTER_MS,
  P0_LABEL,
  PAGED_LABEL,
  evaluateP0Escalation,
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

// ---------------------------------------------------------------------------
// P-OPS-4 paging: shouldPageP0

test("shouldPageP0 pages once on the first P0 open (isCreate)", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "open", isCreate: true, labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-create" }
  );
});

test("shouldPageP0 does not page on standing red (repeat open, isCreate=false)", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "open", isCreate: false, labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: false, reason: "standing-red-no-page" }
  );
});

test("shouldPageP0 never pages in close mode", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "close", isCreate: true, labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: false, reason: "not-open-mode" }
  );
});

test("shouldPageP0 never pages for a non-P0 lane", () => {
  assert.deepEqual(
    shouldPageP0({ mode: "open", isCreate: true, labels: ["lane:nightly-e2e", "P1 - High"] }),
    { shouldPage: false, reason: "not-p0" }
  );
});

test("shouldPageP0 suppresses paging when a named blocker is present", () => {
  assert.deepEqual(
    shouldPageP0({
      mode: "open",
      isCreate: true,
      labels: ["lane:nightly-e2e", P0_LABEL, BLOCKER_LABEL],
    }),
    { shouldPage: false, reason: "named-blocker" }
  );
});

test("shouldPageP0 accepts GitHub API label objects", () => {
  assert.deepEqual(
    shouldPageP0({
      mode: "open",
      isCreate: true,
      labels: [{ name: "lane:nightly-e2e" }, { name: P0_LABEL }],
    }),
    { shouldPage: true, reason: "p0-create" }
  );
});

test("PAGED_LABEL is the expected 'paged:ops' string", () => {
  assert.equal(PAGED_LABEL, "paged:ops");
});

test("flap lifecycle: close then reopen pages again", () => {
  // First genuine open → page.
  assert.deepEqual(
    shouldPageP0({ mode: "open", isCreate: true, labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-create" }
  );
  // Standing red (comment+bump) → no page.
  assert.deepEqual(
    shouldPageP0({ mode: "open", isCreate: false, labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: false, reason: "standing-red-no-page" }
  );
  // Close → no page.
  assert.deepEqual(
    shouldPageP0({ mode: "close", isCreate: true, labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: false, reason: "not-open-mode" }
  );
  // New open after close → page again (lane is no longer standing red).
  assert.deepEqual(
    shouldPageP0({ mode: "open", isCreate: true, labels: ["lane:nightly-e2e", P0_LABEL] }),
    { shouldPage: true, reason: "p0-create" }
  );
});
