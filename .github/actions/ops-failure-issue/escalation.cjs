const ESCALATION_AFTER_MS = 72 * 60 * 60 * 1000;
const SEVEN_DAY_REPAGE_AFTER_MS = 7 * 24 * 60 * 60 * 1000;
const P0_LABEL = "P0 - Critical";
const BLOCKER_LABEL = "known-red-named-blocker";
const ESCALATED_LABEL = "escalated:72h";
const REPAGE_LABEL = "repage:7d";
const PAGED_LABEL = "paged:ops";
const INFRA_REASON_CODES = new Set([
  "emulator-not-ready",
  "emulator-start-skipped",
  "dast-functions-setup-failed",
  "dast-functions-scan-skipped",
  "dast-website-scan-skipped",
  "docker-unavailable",
  "desktop-session-timeout",
  "desktop-session-failed",
  "evidence-artifacts-missing",
  "npm-unavailable",
  "linux-dependency-install-failed",
  "linux-environment-unavailable",
  "linux-desktop-session-failed",
  "linux-shell-evidence-failed",
  "linux-shell-step-failed",
  "linux-step-timeout",
  "linux-evidence-environment-failed",
  "linux-performance-evidence-unavailable",
  "linux-matched-performance-evidence-unavailable",
  "deploy-health-companion-invalid",
  "github-api-error",
  "job-skipped",
  "job-incomplete",
  "job-cancelled",
  "job-timed-out",
  "job-neutral",
  "job-metadata-missing",
  "job-conclusion-missing",
  "job-unknown-conclusion",
  "unknown-conclusion",
  "run-metadata-missing",
  "no-scheduled-run",
  "scheduled-run-stale",
  "no-production-deploy-run",
  "health-check-failed",
  "health-probe-error",
  "helper-timeout",
  "launch-failed",
  "no-backdrop-ack",
  "privileged-build-failed",
  "privileged-build-path-unavailable",
  "privileged-binaries-missing",
  "privileged-socket-not-ready",
  "privileged-redteam-failed",
  "privileged-redteam-skipped",
  "provenance-unsafe",
  "repair-job-skipped",
]);
const INFRA_CONCLUSIONS = new Set([
  "action_required",
  "cancelled",
  "infra-failed",
  "neutral",
  "skipped",
  "timed_out",
  "unknown",
]);
const INFRA_STATUSES = new Set([
  "action_required",
  "cancelled",
  "in_progress",
  "infra-failed",
  "pending",
  "queued",
  "requested",
  "skipped",
  "timed_out",
  "unknown",
  "waiting",
]);
const BUDGET_REASON_CODES = new Set([
  "budget-failed",
  "dast-functions-scan-failed",
  "dast-website-scan-failed",
  "linux-evidence-contract-failed",
  "linux-matched-performance-failed",
  "linux-performance-budget-failed",
  "linux-shell-build-failed",
  "linux-shell-tests-failed",
  "privileged-peer-auth-accepted",
  "privileged-redteam-test-failed",
  "shell-evidence-tests-failed",
]);


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

function evaluateSevenDayRepage(issue, nowMs = Date.now()) {
  const labels = issueLabelNames(issue);
  if (!labels.has(P0_LABEL)) return { shouldRepage: false, reason: "not-p0" };
  if (labels.has(BLOCKER_LABEL)) return { shouldRepage: false, reason: "named-blocker" };
  if (!labels.has(PAGED_LABEL)) return { shouldRepage: false, reason: "not-initially-paged" };
  if (labels.has(REPAGE_LABEL)) return { shouldRepage: false, reason: "already-repaged" };

  const createdAtMs = Date.parse(issue.created_at);
  if (!Number.isFinite(createdAtMs) || !Number.isFinite(nowMs)) {
    throw new TypeError("issue.created_at and nowMs must be valid timestamps");
  }
  const ageMs = Math.max(0, nowMs - createdAtMs);
  return {
    shouldRepage: ageMs >= SEVEN_DAY_REPAGE_AFTER_MS,
    reason: ageMs >= SEVEN_DAY_REPAGE_AFTER_MS ? "repage-p0" : "within-seven-day-slo",
    ageHours: Math.floor(ageMs / (60 * 60 * 1000)),
  };
}

function shouldRepageP0({ mode, labels, createdAt, nowMs = Date.now() }) {
  if (mode !== "open") return { shouldRepage: false, reason: "not-open-mode" };
  const labelNames = new Set(
    (labels || [])
      .map((label) => (typeof label === "string" ? label : label?.name))
      .filter(Boolean)
  );
  if (!labelNames.has(P0_LABEL)) return { shouldRepage: false, reason: "not-p0" };
  if (labelNames.has(BLOCKER_LABEL)) return { shouldRepage: false, reason: "named-blocker" };
  if (!labelNames.has(PAGED_LABEL)) return { shouldRepage: false, reason: "not-initially-paged" };
  if (labelNames.has(REPAGE_LABEL)) return { shouldRepage: false, reason: "already-repaged" };
  const createdAtMs = Date.parse(createdAt);
  if (!Number.isFinite(createdAtMs) || !Number.isFinite(nowMs)) {
    throw new TypeError("createdAt and nowMs must be valid timestamps");
  }
  const ageMs = Math.max(0, nowMs - createdAtMs);
  return {
    shouldRepage: ageMs >= SEVEN_DAY_REPAGE_AFTER_MS,
    reason: ageMs >= SEVEN_DAY_REPAGE_AFTER_MS ? "repage-p0" : "within-seven-day-slo",
    ageHours: Math.floor(ageMs / (60 * 60 * 1000)),
  };
}

/**
 * Classify a lane result without treating an unexecuted/unknown path as a
 * product or budget failure. A normal `failure` is budget/product red; an
 * infra conclusion, explicit reason code, skipped run, or missing conclusion
 * is infrastructure red.
 */
function classifyFailure({ status, conclusion, reasonCode, skipped = false } = {}) {
  const normalizedStatus = String(status || "").toLowerCase();
  const normalizedConclusion = String(conclusion || "").toLowerCase();
  const normalizedReason = String(reasonCode || "").toLowerCase();
  if (
    INFRA_STATUSES.has(normalizedStatus)
    || INFRA_CONCLUSIONS.has(normalizedConclusion)
    || INFRA_REASON_CODES.has(normalizedReason)
    || skipped
    || !normalizedConclusion
  ) {
    return {
      classification: "infra",
      failureClass: "infra",
      reasonCode: normalizedReason || (
        normalizedConclusion === "skipped" || skipped
          ? "skipped"
          : "infra-failed"
      ),
    };
  }
  if (BUDGET_REASON_CODES.has(normalizedReason)) {
    return {
      classification: "budget",
      failureClass: "budget",
      reasonCode: normalizedReason,
    };
  }
  if (normalizedConclusion === "failure") {
    return {
      classification: "budget",
      failureClass: "budget",
      reasonCode: normalizedReason || "budget-failed",
    };
  }
  if (normalizedConclusion !== "success") {
    return {
      classification: "infra",
      failureClass: "infra",
      reasonCode: normalizedReason || "unknown-conclusion",
    };
  }
  return {
    classification: "healthy",
    failureClass: null,
    reasonCode: null,
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
  BUDGET_REASON_CODES,
  ESCALATED_LABEL,
  ESCALATION_AFTER_MS,
  INFRA_CONCLUSIONS,
  INFRA_REASON_CODES,
  INFRA_STATUSES,
  P0_LABEL,
  PAGED_LABEL,
  REPAGE_LABEL,
  SEVEN_DAY_REPAGE_AFTER_MS,
  classifyFailure,
  evaluateP0Escalation,
  evaluateSevenDayRepage,
  shouldRepageP0,
  shouldPageP0,
};
