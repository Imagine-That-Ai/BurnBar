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
 * Decide whether a P0 ops failure should page out-of-band (Slack).
 *
 * Dedupe is the persistent `paged:ops` label on the issue — NOT a one-shot
 * "isCreate" flag. This means:
 *   - A first P0 open (create or standing red) that lacks `paged:ops` → page.
 *   - After a successful page + `paged:ops` label, repeats and close→reopen
 *     flaps must NOT page again (the label survives on the issue; a new issue
 *     after close does not have it, so the next genuinely-new P0 open pages).
 *   - A failed or missing webhook must NOT add `paged:ops`, so a later run
 *     can retry paging.
 * Close mode never pages. Non-P0 lanes never page. A named blocker
 * suppresses paging because a known-red is not an actionable new alert.
 *
 * @param {object} params
 * @param {string} params.mode       - "open" | "close"
 * @param {Array}   params.labels    - labels on the issue (strings or {name})
 * @returns {{ shouldPage: boolean, reason: string }}
 */
function shouldPageP0({ mode, labels }) {
  if (mode !== "open") return { shouldPage: false, reason: "not-open-mode" };
  const labelNames = new Set(
    (labels || [])
      .map((label) => (typeof label === "string" ? label : label?.name))
      .filter(Boolean)
  );
  if (!labelNames.has(P0_LABEL)) return { shouldPage: false, reason: "not-p0" };
  if (labelNames.has(BLOCKER_LABEL)) return { shouldPage: false, reason: "named-blocker" };
  if (labelNames.has(PAGED_LABEL)) return { shouldPage: false, reason: "already-paged" };
  return { shouldPage: true, reason: "p0-unpaged" };
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
