const ESCALATION_AFTER_MS = 72 * 60 * 60 * 1000;
const P0_LABEL = "P0 - Critical";
const BLOCKER_LABEL = "known-red-named-blocker";
const ESCALATED_LABEL = "escalated:72h";
const PAGED_LABEL = "paged:ops";


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

/**
 * Decide whether a P0 ops failure should page out-of-band (Slack/PagerDuty).
 *
 * Paging fires exactly once per genuine P0 open: on issue CREATION when the
 * lane is P0. A standing-red recurrence (issue already open → comment + bump)
 * never pages — the lane label dedupe prevents page-storms. Close mode never
 * pages. Non-P0 lanes never page. A named blocker suppresses paging because a
 * known-red is not an actionable new alert.
 *
 * @param {object} params
 * @param {string} params.mode       - "open" | "close"
 * @param {boolean} params.isCreate  - true when this is a new issue creation (no standing issue), false for a standing-red comment
 * @param {Array} params.labels      - labels applied to the issue (strings or {name})
 * @returns {{ shouldPage: boolean, reason: string }}
 */
function shouldPageP0({ mode, isCreate, labels }) {
  if (mode !== "open") return { shouldPage: false, reason: "not-open-mode" };
  if (!isCreate) return { shouldPage: false, reason: "standing-red-no-page" };
  const labelNames = new Set(
    (labels || [])
      .map((label) => (typeof label === "string" ? label : label?.name))
      .filter(Boolean)
  );
  if (!labelNames.has(P0_LABEL)) return { shouldPage: false, reason: "not-p0" };
  if (labelNames.has(BLOCKER_LABEL)) return { shouldPage: false, reason: "named-blocker" };
  return { shouldPage: true, reason: "p0-create" };
}

module.exports = {
  BLOCKER_LABEL,
  ESCALATED_LABEL,
  ESCALATION_AFTER_MS,
  P0_LABEL,
  PAGED_LABEL,
  evaluateP0Escalation,
  shouldPageP0,
};
