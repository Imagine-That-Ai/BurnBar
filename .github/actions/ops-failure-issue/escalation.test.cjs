const assert = require("node:assert/strict");
const test = require("node:test");
const {
  BLOCKER_LABEL,
  ESCALATED_LABEL,
  ESCALATION_AFTER_MS,
  P0_LABEL,
  evaluateP0Escalation,
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
