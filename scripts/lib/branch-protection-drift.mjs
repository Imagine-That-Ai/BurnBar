/**
 * Branch-protection drift primitives: normalize a LIVE GitHub protection surface
 * (classic branch-protection GET response OR org/repo ruleset response) onto the
 * field names used by governance/branch-protection.main.json, then diff the two.
 *
 * The desired state (governance/branch-protection.main.json) is the SINGLE SOURCE
 * OF TRUTH — see governance/README.md. This module exists so a scheduled CI job can
 * fail CLOSED on any divergence between live protection and that file, and so the
 * pure diff logic is unit-testable OFFLINE with fixtures (no gh/network).
 *
 * Why normalize the ruleset shape too: the current repo uses classic branch
 * protection, but GitHub rulesets can also enforce `main`. The classic
 * `GET .../branches/main/protection` endpoint reflects only classic repo-level
 * protection and can be empty/stale while a ruleset actively enforces `main`.
 * Diffing the branch-protection endpoint alone would MISS ruleset-only bypass
 * drift, so this module accepts either shape and maps both onto the same
 * canonical field names before diffing.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const BRANCH_PROTECTION_SOURCE_OF_TRUTH = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "governance",
  "branch-protection.main.json",
);

/**
 * The canonical, comparable subset of fields drift is checked on. Documentation
 * metadata keys (prefixed with "_") and the segregated
 * `_pending_required_status_checks` placeholders are intentionally EXCLUDED.
 * A pending context is not guaranteed to report on every PR: it may be path-scoped
 * or not emitted yet. Requiring it globally would leave some PRs pending forever.
 */
export function canonicalizeDesired(desired) {
  const reviews = desired.required_pull_request_reviews || null;
  const mergeQueue = desired.merge_queue || null;
  return {
    requiredStatusCheckContexts: sortedUnique(
      desired.required_status_checks?.contexts || [],
    ),
    strictRequiredStatusChecks: desired.required_status_checks?.strict === true,
    enforceAdmins: desired.enforce_admins === true,
    reviewsPresent: reviews !== null,
    requiredApprovingReviewCount: reviews?.required_approving_review_count ?? 0,
    requireCodeOwnerReviews: reviews?.require_code_owner_reviews === true,
    dismissStaleReviews: reviews?.dismiss_stale_reviews === true,
    requireLastPushApproval: reviews?.require_last_push_approval === true,
    bypassActors: sortedUnique(canonicalBypassActors(reviews)),
    requireConversationResolution:
      desired.required_conversation_resolution === true,
    allowForcePushes: desired.allow_force_pushes === true,
    allowDeletions: desired.allow_deletions === true,
    mergeQueuePresent: mergeQueue !== null,
    mergeQueueParameters: canonicalMergeQueueParameters(mergeQueue),
  };
}

/**
 * Normalize a LIVE protection payload onto the same shape as canonicalizeDesired.
 * Accepts either the classic branch-protection GET response (fields like
 * `enforce_admins.enabled`) or a ruleset response (an object with a `rules` array,
 * optionally `{ rules, bypass_actors, enforcement }`). When a ruleset is present,
 * ruleset-owned governance fields are verified on that ruleset surface; classic
 * protection is still accepted when no ruleset is present.
 *
 * @param {object} params
 * @param {object|null} params.classic  classic branch-protection GET response
 * @param {object|Array|null} params.ruleset  ruleset response (array of effective
 *   rules from GET /repos/{o}/{r}/rules/branches/main, or an object carrying
 *   `rules` + `bypass_actors` + `enforcement` from the org ruleset)
 */
export function canonicalizeLive({ classic = null, ruleset = null } = {}) {
  const rulesetView = normalizeRuleset(ruleset);
  const classicView = normalizeClassic(classic);

  // Union required contexts from both surfaces (either can carry them).
  const contexts = sortedUnique([
    ...classicView.requiredStatusCheckContexts,
    ...rulesetView.requiredStatusCheckContexts,
  ]);

  // When a ruleset is present, verify the ruleset-owned governance fields on
  // that ruleset surface. Classic protection is still accepted when no ruleset
  // is present, which matches the current solo-maintainer repo configuration.
  const rulesetActive = rulesetView.present && rulesetView.enforcementActive;
  const reviewView = rulesetActive && rulesetView.pullRequestRules.length > 0
    ? rulesetView
    : classicView;
  const statusView = rulesetActive && rulesetView.requiredStatusCheckRules.length > 0
    ? rulesetView
    : classicView;

  return {
    rulesetPresent: rulesetView.present,
    rulesetPullRequestRules: rulesetView.pullRequestRules,
    rulesetRequiredStatusCheckRules: rulesetView.requiredStatusCheckRules,
    rulesetMergeQueueRules: rulesetView.mergeQueueRules,
    requiredStatusCheckContexts: contexts,
    strictRequiredStatusChecks: statusView.strictRequiredStatusChecks,
    // Classic `enforce_admins` maps to zero bypass actors. If a ruleset is present,
    // bypass actors mean admins are not fully enforced on that ruleset surface.
    enforceAdmins: (classicView.present ? classicView.enforceAdmins : rulesetActive)
      && rulesetView.bypassActors.length === 0,
    reviewsPresent: reviewView.reviewsPresent,
    requiredApprovingReviewCount: reviewView.requiredApprovingReviewCount,
    requireCodeOwnerReviews: reviewView.requireCodeOwnerReviews,
    dismissStaleReviews: reviewView.dismissStaleReviews,
    requireLastPushApproval: reviewView.requireLastPushApproval,
    // Bypass drift is a UNION: any bypass actor on EITHER surface is a bypass.
    bypassActors: sortedUnique([
      ...classicView.bypassActors,
      ...rulesetView.bypassActors,
    ]),
    requireConversationResolution:
      classicView.requireConversationResolution
      || (rulesetActive && rulesetView.requireConversationResolution),
    // Force-push / deletion are disallowed by ruleset rules (non_fast_forward /
    // deletion) or by classic branch protection, depending on the active surface.
    allowForcePushes:
      classicView.allowForcePushes
      && !(rulesetActive && rulesetView.forbidsForcePush),
    allowDeletions:
      classicView.allowDeletions
      && !(rulesetActive && rulesetView.forbidsDeletion),
    mergeQueuePresent: rulesetActive && rulesetView.mergeQueueRules.length > 0,
    mergeQueueParameters:
      rulesetActive && rulesetView.mergeQueueRules.length === 1
        ? rulesetView.mergeQueueRules[0]
        : null,
  };
}

function normalizeClassic(classic) {
  if (!classic || typeof classic !== "object") {
    return {
      present: false,
      requiredStatusCheckContexts: [],
      strictRequiredStatusChecks: false,
      enforceAdmins: false,
      reviewsPresent: false,
      requiredApprovingReviewCount: 0,
      requireCodeOwnerReviews: false,
      dismissStaleReviews: false,
      requireLastPushApproval: false,
      bypassActors: [],
      requireConversationResolution: false,
      // Absent classic protection means force-push/deletion are NOT disabled here.
      allowForcePushes: true,
      allowDeletions: true,
    };
  }
  const reviews = classic.required_pull_request_reviews || null;
  const bypass = reviews?.bypass_pull_request_allowances || {};
  return {
    present: true,
    requiredStatusCheckContexts: sortedUnique([
      ...(classic.required_status_checks?.contexts || []),
      ...((classic.required_status_checks?.checks || [])
        .map((check) => check.context)
        .filter(Boolean)),
    ]),
    strictRequiredStatusChecks: classic.required_status_checks?.strict === true,
    enforceAdmins: classic.enforce_admins?.enabled === true,
    reviewsPresent: reviews !== null && reviews !== undefined,
    requiredApprovingReviewCount: reviews?.required_approving_review_count ?? 0,
    requireCodeOwnerReviews: reviews?.require_code_owner_reviews === true,
    dismissStaleReviews: reviews?.dismiss_stale_reviews === true,
    requireLastPushApproval: reviews?.require_last_push_approval === true,
    bypassActors: canonicalBypassActors(reviews),
    requireConversationResolution:
      classic.required_conversation_resolution?.enabled === true,
    allowForcePushes: classic.allow_force_pushes?.enabled === true,
    allowDeletions: classic.allow_deletions?.enabled === true,
  };
}

function normalizeRuleset(ruleset) {
  const empty = {
    present: false,
    enforcementActive: false,
    requiredStatusCheckContexts: [],
    strictRequiredStatusChecks: false,
    reviewsPresent: false,
    requiredApprovingReviewCount: 0,
    requireCodeOwnerReviews: false,
    dismissStaleReviews: false,
    requireLastPushApproval: false,
    bypassActors: [],
    requireConversationResolution: false,
    forbidsForcePush: false,
    forbidsDeletion: false,
    pullRequestRules: [],
    requiredStatusCheckRules: [],
    mergeQueueRules: [],
  };
  if (!ruleset) return empty;

  // Accept either a bare array of effective rules (rules/branches/main) or an
  // object carrying { rules, bypass_actors, enforcement }.
  const rules = Array.isArray(ruleset)
    ? ruleset
    : Array.isArray(ruleset.rules)
      ? ruleset.rules
      : [];
  if (rules.length === 0 && !Array.isArray(ruleset)) {
    // An object with no rules array is not a usable ruleset payload.
    if (!ruleset.bypass_actors && ruleset.enforcement === undefined) return empty;
  }

  const enforcement = Array.isArray(ruleset) ? "active" : ruleset.enforcement;
  const enforcementActive = enforcement === undefined || enforcement === "active";

  const byType = new Map();
  for (const rule of rules) {
    if (!rule || typeof rule.type !== "string") continue;
    const bucket = byType.get(rule.type) || [];
    bucket.push(rule);
    byType.set(rule.type, bucket);
  }

  const pullRequestRules = (byType.get("pull_request") || []).map(
    canonicalRulesetPullRequestRule,
  );
  const requiredStatusCheckRules = (byType.get("required_status_checks") || []).map(
    canonicalRulesetRequiredStatusRule,
  );
  const mergeQueueRules = (byType.get("merge_queue") || []).map(
    (rule) => canonicalMergeQueueParameters(rule?.parameters),
  );
  const checks = requiredStatusCheckRules.flatMap((rule) => rule.contexts);
  const pr = aggregatePullRequestRules(pullRequestRules);
  const checksRule = aggregateStatusRules(requiredStatusCheckRules);

  // Ruleset bypass_actors: the daily-driver account (or any actor) present here
  // is drift. We canonicalize each entry to a stable string id.
  const bypassActors = canonicalRulesetBypassActors(
    Array.isArray(ruleset) ? [] : ruleset.bypass_actors,
  );

  return {
    present: rules.length > 0 || bypassActors.length > 0 || enforcement !== undefined,
    enforcementActive,
    requiredStatusCheckContexts: sortedUnique(checks),
    strictRequiredStatusChecks: checksRule.strictRequiredStatusChecks,
    reviewsPresent: pr !== null,
    requiredApprovingReviewCount: pr?.requiredApprovingReviewCount ?? 0,
    requireCodeOwnerReviews: pr?.requireCodeOwnerReviews === true,
    dismissStaleReviews: pr?.dismissStaleReviews === true,
    requireLastPushApproval: pr?.requireLastPushApproval === true,
    bypassActors,
    requireConversationResolution: byType.has("required_conversation_resolution"),
    forbidsForcePush: byType.has("non_fast_forward"),
    forbidsDeletion: byType.has("deletion"),
    pullRequestRules,
    requiredStatusCheckRules,
    mergeQueueRules,
  };
}

function canonicalRulesetPullRequestRule(rule) {
  const p = rule?.parameters || {};
  return {
    rulesetId: rule?.ruleset_id ?? null,
    requiredApprovingReviewCount: p.required_approving_review_count ?? 0,
    requireCodeOwnerReviews: p.require_code_owner_review === true,
    dismissStaleReviews: p.dismiss_stale_reviews_on_push === true,
    requireLastPushApproval: p.require_last_push_approval === true,
  };
}

function canonicalRulesetRequiredStatusRule(rule) {
  const p = rule?.parameters || {};
  return {
    rulesetId: rule?.ruleset_id ?? null,
    strictRequiredStatusChecks: p.strict_required_status_checks_policy === true,
    contexts: sortedUnique(
      (p.required_status_checks || [])
        .map((check) => check.context)
        .filter(Boolean),
    ),
  };
}

function canonicalMergeQueueParameters(parameters) {
  if (!parameters || typeof parameters !== "object") return null;
  return {
    mergeMethod: parameters.merge_method ?? null,
    groupingStrategy: parameters.grouping_strategy ?? null,
    checkResponseTimeoutMinutes:
      parameters.check_response_timeout_minutes ?? null,
    maxEntriesToBuild: parameters.max_entries_to_build ?? null,
    minEntriesToMerge: parameters.min_entries_to_merge ?? null,
    maxEntriesToMerge: parameters.max_entries_to_merge ?? null,
    minEntriesToMergeWaitMinutes:
      parameters.min_entries_to_merge_wait_minutes ?? null,
  };
}

function aggregatePullRequestRules(rules) {
  if (rules.length === 0) return null;
  return {
    // Count drift is dangerous in both directions for this repo: adding a review
    // requirement deadlocks solo-maintainer automation; dropping one would be a
    // security regression if the source of truth ever requires reviews again.
    requiredApprovingReviewCount: Math.max(
      ...rules.map((rule) => rule.requiredApprovingReviewCount),
    ),
    requireCodeOwnerReviews: rules.some((rule) => rule.requireCodeOwnerReviews),
    dismissStaleReviews: rules.some((rule) => rule.dismissStaleReviews),
    requireLastPushApproval: rules.some((rule) => rule.requireLastPushApproval),
  };
}

function aggregateStatusRules(rules) {
  return {
    strictRequiredStatusChecks: rules.some(
      (rule) => rule.strictRequiredStatusChecks,
    ),
  };
}

/** Classic bypass_pull_request_allowances -> stable, sorted actor id strings. */
function canonicalBypassActors(reviews) {
  const bypass = reviews?.bypass_pull_request_allowances || {};
  return [
    ...(bypass.users || []).map((u) => `user:${u.login || u.slug || u.id || "?"}`),
    ...(bypass.teams || []).map((t) => `team:${t.slug || t.name || t.id || "?"}`),
    ...(bypass.apps || []).map((a) => `app:${a.slug || a.name || a.id || "?"}`),
  ].filter(Boolean);
}

/** Ruleset bypass_actors[] -> stable id strings. */
function canonicalRulesetBypassActors(actors) {
  if (!Array.isArray(actors)) return [];
  return actors
    .map((actor) => {
      const type = actor.actor_type || "Actor";
      const id = actor.actor_id ?? actor.id ?? "?";
      const mode = actor.bypass_mode ? `:${actor.bypass_mode}` : "";
      return `${type}:${id}${mode}`;
    })
    .filter(Boolean);
}

function sortedUnique(values) {
  return [...new Set(values)].sort();
}

/**
 * Diff canonical live vs desired. Returns { ok, differences[] } where each
 * difference is { field, desired, live, severity }. `severity` is "critical" for
 * the highest-danger drifts (reviews wiped, admins un-enforced, any bypass actor)
 * so the caller can surface them first — but ANY difference fails the gate.
 */
export function diffBranchProtection(live, desired) {
  const differences = [];

  const cmpBool = (field, severity = "high") => {
    if (live[field] !== desired[field]) {
      differences.push({ field, desired: desired[field], live: live[field], severity });
    }
  };
  const cmpNum = (field, severity = "high") => {
    if (live[field] !== desired[field]) {
      differences.push({ field, desired: desired[field], live: live[field], severity });
    }
  };

  // The single most dangerous drift: protection wiped so no review is required.
  if (desired.reviewsPresent && !live.reviewsPresent) {
    differences.push({
      field: "reviewsPresent",
      desired: true,
      live: false,
      severity: "critical",
    });
  } else if (live.reviewsPresent !== desired.reviewsPresent) {
    differences.push({
      field: "reviewsPresent",
      desired: desired.reviewsPresent,
      live: live.reviewsPresent,
      severity: "high",
    });
  }

  cmpBool("enforceAdmins", "critical");
  cmpNum("requiredApprovingReviewCount", "critical");
  cmpBool("requireCodeOwnerReviews");
  cmpBool("dismissStaleReviews");
  cmpBool("requireLastPushApproval");
  cmpBool("requireConversationResolution");
  cmpBool("strictRequiredStatusChecks");

  // allow_force_pushes / allow_deletions must both be false. Live=true is drift.
  cmpBool("allowForcePushes", "high");
  cmpBool("allowDeletions", "high");
  cmpBool("mergeQueuePresent", "critical");

  if (
    live.mergeQueuePresent
    && desired.mergeQueuePresent
    && JSON.stringify(live.mergeQueueParameters)
      !== JSON.stringify(desired.mergeQueueParameters)
  ) {
    differences.push({
      field: "mergeQueueParameters",
      desired: desired.mergeQueueParameters,
      live: live.mergeQueueParameters,
      severity: "high",
    });
  }

  if (live.rulesetPresent) {
    const expectedPullRequestRule = {
      requiredApprovingReviewCount: desired.requiredApprovingReviewCount,
      requireCodeOwnerReviews: desired.requireCodeOwnerReviews,
      dismissStaleReviews: desired.dismissStaleReviews,
      requireLastPushApproval: desired.requireLastPushApproval,
    };
    const mismatchedPullRequestRules = (live.rulesetPullRequestRules || []).filter(
      (rule) =>
        rule.requiredApprovingReviewCount !==
          expectedPullRequestRule.requiredApprovingReviewCount ||
        rule.requireCodeOwnerReviews !==
          expectedPullRequestRule.requireCodeOwnerReviews ||
        rule.dismissStaleReviews !==
          expectedPullRequestRule.dismissStaleReviews ||
        rule.requireLastPushApproval !==
          expectedPullRequestRule.requireLastPushApproval,
    );
    if (mismatchedPullRequestRules.length > 0) {
      differences.push({
        field: "rulesetPullRequestRules",
        desired: expectedPullRequestRule,
        live: mismatchedPullRequestRules,
        severity: "critical",
      });
    }

    const desiredChecks = new Set(desired.requiredStatusCheckContexts);
    const mismatchedStatusRules = (live.rulesetRequiredStatusCheckRules || []).filter(
      (rule) => {
        const ruleChecks = new Set(rule.contexts);
        const missing = desired.requiredStatusCheckContexts.filter(
          (context) => !ruleChecks.has(context),
        );
        const extra = rule.contexts.filter((context) => !desiredChecks.has(context));
        return (
          rule.strictRequiredStatusChecks !== desired.strictRequiredStatusChecks ||
          missing.length > 0 ||
          extra.length > 0
        );
      },
    );
    if (mismatchedStatusRules.length > 0) {
      differences.push({
        field: "rulesetRequiredStatusCheckRules",
        desired: {
          strictRequiredStatusChecks: desired.strictRequiredStatusChecks,
          requiredStatusCheckContexts: desired.requiredStatusCheckContexts,
        },
        live: mismatchedStatusRules,
        severity: "high",
      });
    }

    if (
      desired.mergeQueuePresent
      && (live.rulesetMergeQueueRules || []).length !== 1
    ) {
      differences.push({
        field: "rulesetMergeQueueRules",
        desired: [desired.mergeQueueParameters],
        live: live.rulesetMergeQueueRules || [],
        severity: "critical",
      });
    }
  }

  // Bypass actors: desired is empty (zero bypass). ANY live bypass actor is
  // critical drift; a set difference in either direction fails.
  const desiredBypass = new Set(desired.bypassActors);
  const liveBypass = new Set(live.bypassActors);
  const bypassAdded = live.bypassActors.filter((a) => !desiredBypass.has(a));
  const bypassRemoved = desired.bypassActors.filter((a) => !liveBypass.has(a));
  if (bypassAdded.length > 0 || bypassRemoved.length > 0) {
    differences.push({
      field: "bypassActors",
      desired: desired.bypassActors,
      live: live.bypassActors,
      added: bypassAdded,
      removed: bypassRemoved,
      severity: bypassAdded.length > 0 ? "critical" : "high",
    });
  }

  // Required status checks: set difference in either direction (README §Drift).
  const desiredChecks = new Set(desired.requiredStatusCheckContexts);
  const liveChecks = new Set(live.requiredStatusCheckContexts);
  const checksMissingLive = desired.requiredStatusCheckContexts.filter(
    (c) => !liveChecks.has(c),
  );
  const checksExtraLive = live.requiredStatusCheckContexts.filter(
    (c) => !desiredChecks.has(c),
  );
  if (checksMissingLive.length > 0 || checksExtraLive.length > 0) {
    differences.push({
      field: "requiredStatusCheckContexts",
      missingFromLive: checksMissingLive,
      extraInLive: checksExtraLive,
      severity: "high",
    });
  }

  return { ok: differences.length === 0, differences };
}

/** Loads and parses the desired branch-protection source of truth. */
export function loadDesired(sourcePath = BRANCH_PROTECTION_SOURCE_OF_TRUTH) {
  let raw;
  try {
    raw = readFileSync(sourcePath, "utf8");
  } catch (error) {
    throw new Error(
      `cannot read branch-protection source of truth at ${sourcePath}: ${error.message}`,
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`invalid JSON in ${sourcePath}: ${error.message}`);
  }
  const contexts = parsed?.required_status_checks?.contexts;
  if (!Array.isArray(contexts) || contexts.length === 0) {
    throw new Error(
      `${sourcePath} has no required_status_checks.contexts; refusing to run the drift check against an empty required-check set`,
    );
  }
  const mergeQueue = parsed?.merge_queue;
  if (
    !mergeQueue
    || !Number.isInteger(mergeQueue.check_response_timeout_minutes)
    || mergeQueue.check_response_timeout_minutes <= 0
  ) {
    throw new Error(
      `${sourcePath} has no positive merge_queue.check_response_timeout_minutes; refusing to leave merge-queue completion ungoverned`,
    );
  }
  return parsed;
}

/** Human-readable rendering of a diff result for CI logs. */
export function formatDifferences(result) {
  if (result.ok) return "MATCH: live branch protection equals governance/branch-protection.main.json";
  const lines = ["DRIFT: live branch protection diverges from governance/branch-protection.main.json"];
  const order = { critical: 0, high: 1 };
  const sorted = [...result.differences].sort(
    (a, b) => (order[a.severity] ?? 9) - (order[b.severity] ?? 9),
  );
  for (const diff of sorted) {
    const tag = diff.severity === "critical" ? "[CRITICAL]" : "[drift]";
    if (diff.field === "requiredStatusCheckContexts") {
      if (diff.missingFromLive.length > 0) {
        lines.push(`  ${tag} required checks MISSING from live: ${JSON.stringify(diff.missingFromLive)}`);
      }
      if (diff.extraInLive.length > 0) {
        lines.push(`  ${tag} required checks PRESENT live but not in file: ${JSON.stringify(diff.extraInLive)}`);
      }
    } else if (diff.field === "bypassActors") {
      if (diff.added.length > 0) {
        lines.push(`  ${tag} bypass actors ADDED live (must be zero): ${JSON.stringify(diff.added)}`);
      }
      if (diff.removed.length > 0) {
        lines.push(`  ${tag} bypass actors in file but missing live: ${JSON.stringify(diff.removed)}`);
      }
    } else if (diff.field === "rulesetPullRequestRules") {
      lines.push(
        `  ${tag} ruleset pull_request rule drift: desired=${JSON.stringify(diff.desired)} live=${JSON.stringify(diff.live)}`,
      );
    } else if (diff.field === "rulesetRequiredStatusCheckRules") {
      lines.push(
        `  ${tag} ruleset required_status_checks rule drift: desired=${JSON.stringify(diff.desired)} live=${JSON.stringify(diff.live)}`,
      );
    } else if (diff.field === "rulesetMergeQueueRules") {
      lines.push(
        `  ${tag} ruleset merge_queue rule drift: desired=${JSON.stringify(diff.desired)} live=${JSON.stringify(diff.live)}`,
      );
    } else {
      lines.push(`  ${tag} ${diff.field}: desired=${JSON.stringify(diff.desired)} live=${JSON.stringify(diff.live)}`);
    }
  }
  return lines.join("\n");
}
