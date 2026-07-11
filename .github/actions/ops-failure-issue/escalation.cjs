const ESCALATION_AFTER_MS = 72 * 60 * 60 * 1000;
const P0_LABEL = "P0 - Critical";
const BLOCKER_LABEL = "known-red-named-blocker";
const ESCALATED_LABEL = "escalated:72h";

function issueLabelNames(issue) {
  if (!issue || !Array.isArray(issue.labels)) {
    throw new TypeError("issue.labels must be an array");
  }
  return new Set(
    issue.labels
      .map((label) => (typeof label === "string" ? label : label?.name))
      .filter(Boolean)
  );
}

function evaluateP0Escalation(issue, nowMs = Date.now()) {
  const labels = issueLabelNames(issue);
  if (!labels.has(P0_LABEL)) return { shouldEscalate: false, reason: "not-p0" };
  if (labels.has(BLOCKER_LABEL)) return { shouldEscalate: false, reason: "named-blocker" };
  if (labels.has(ESCALATED_LABEL)) return { shouldEscalate: false, reason: "already-escalated" };

  const createdAtMs = Date.parse(issue.created_at);
  if (!Number.isFinite(createdAtMs) || !Number.isFinite(nowMs)) {
    throw new TypeError("issue.created_at and nowMs must be valid timestamps");
  }
  const ageMs = Math.max(0, nowMs - createdAtMs);
  return {
    shouldEscalate: ageMs >= ESCALATION_AFTER_MS,
    reason: ageMs >= ESCALATION_AFTER_MS ? "overdue-p0" : "within-slo",
    ageHours: Math.floor(ageMs / (60 * 60 * 1000)),
  };
}

module.exports = {
  BLOCKER_LABEL,
  ESCALATED_LABEL,
  ESCALATION_AFTER_MS,
  P0_LABEL,
  evaluateP0Escalation,
};
