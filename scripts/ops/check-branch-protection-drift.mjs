#!/usr/bin/env node
/**
 * Fail-closed drift check: LIVE GitHub branch protection for `main` vs the
 * committed source of truth governance/branch-protection.main.json.
 *
 * If the JSON and live state disagree, the FILE wins and live is the bug, so any
 * divergence exits non-zero with a readable diff.
 *
 * LIVE surface: read effective rulesets first and classic branch protection
 * additionally. Current BurnBar uses classic protection, but reading the classic
 * endpoint alone would miss ruleset-only bypass drift if a ruleset is added later.
 *
 * Modes:
 *   (default, CI)  Fetch live state with `gh api` and diff. Needs gh auth + repo
 *                  scope; runs in the ops-plane-verify workflow with creds.
 *     env OPENBURNBAR_GOVERNANCE_REPO   owner/repo (default: gh repo view)
 *     env OPENBURNBAR_GOVERNANCE_ORG    org for the org-ruleset lookup (default:
 *                                       the owner of the repo)
 *     env OPENBURNBAR_GOVERNANCE_BRANCH branch (default: main)
 *
 *   --live-classic <file> [--live-ruleset <file>]
 *                  Diff a provided snapshot instead of calling gh. Used by the
 *                  offline self-test and for reproducing a live diff locally.
 *
 *   --self-test    Run the offline positive+negative controls and exit. (Also
 *                  available as the colocated *.test.mjs for `node --test`-style
 *                  runners; this flag exists so CI can gate the script with one
 *                  command and no network.)
 *
 * Exit: 0 = MATCH (or self-test passed); 1 = DRIFT (or self-test failed);
 *       2 = could not read live state / bad usage.
 */
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  canonicalizeDesired,
  canonicalizeLive,
  diffBranchProtection,
  formatDifferences,
  loadDesired,
} from "../lib/branch-protection-drift.mjs";

function parseArgs(argv) {
  const args = { liveClassic: null, liveRuleset: null, selfTest: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--self-test") args.selfTest = true;
    else if (arg === "--live-classic") args.liveClassic = argv[++i];
    else if (arg === "--live-ruleset") args.liveRuleset = argv[++i];
    else {
      console.error(`unknown argument: ${arg}`);
      process.exit(2);
    }
  }
  return args;
}

function gh(pathArg) {
  const result = spawnSync(
    "gh",
    ["api", "-H", "Accept: application/vnd.github+json", pathArg],
    { encoding: "utf8" },
  );
  return {
    ok: result.status === 0,
    stdout: result.stdout || "",
    stderr: result.stderr || result.error?.message || "",
  };
}

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

/** Fetch the live protection surface (ruleset first, classic additionally). */
function fetchLive() {
  let repo = process.env.OPENBURNBAR_GOVERNANCE_REPO || process.env.GITHUB_REPOSITORY || "";
  if (!repo) {
    const view = spawnSync("gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], {
      encoding: "utf8",
    });
    if (view.status !== 0) {
      return { ok: false, error: view.stderr || view.error?.message || "cannot resolve repo" };
    }
    repo = view.stdout.trim();
  }
  const branch = process.env.OPENBURNBAR_GOVERNANCE_BRANCH || "main";
  const org = process.env.OPENBURNBAR_GOVERNANCE_ORG || repo.split("/")[0];

  // Effective repo rules for the branch (ruleset-derived). This is authoritative
  // for what actually enforces `main`.
  const rulesRes = gh(`/repos/${repo}/rules/branches/${branch}`);
  if (!rulesRes.ok) {
    return { ok: false, error: `gh api rules/branches/${branch} failed: ${rulesRes.stderr}` };
  }
  let effectiveRules;
  try {
    effectiveRules = JSON.parse(rulesRes.stdout || "[]");
  } catch (error) {
    return { ok: false, error: `unparseable rules response: ${error.message}` };
  }

  // Resolve the distinct org rulesets referenced by those rules and pull each one
  // for bypass_actors + enforcement (rules/branches omits bypass actors).
  const rulesetIds = [
    ...new Set(
      (Array.isArray(effectiveRules) ? effectiveRules : [])
        .map((r) => r.ruleset_id)
        .filter((id) => id !== undefined && id !== null),
    ),
  ];
  let bypassActors = [];
  let enforcement = "active";
  for (const id of rulesetIds) {
    // Try org ruleset first, then repo ruleset.
    let res = gh(`/orgs/${org}/rulesets/${id}`);
    const orgError = res.stderr;
    if (!res.ok) res = gh(`/repos/${repo}/rulesets/${id}`);
    if (!res.ok) {
      return {
        ok: false,
        error: `could not read ruleset ${id} details from org or repo endpoints; org error: ${orgError}; repo error: ${res.stderr}`,
      };
    }
    try {
      const rs = JSON.parse(res.stdout);
      if (rs.enforcement && rs.enforcement !== "active") enforcement = rs.enforcement;
      if (Array.isArray(rs.bypass_actors)) bypassActors = bypassActors.concat(rs.bypass_actors);
    } catch (error) {
      return {
        ok: false,
        error: `unparseable ruleset ${id} detail response: ${error.message}`,
      };
    }
  }

  // Classic repo-level protection, if any (consulted additionally, not instead).
  const classicRes = gh(`/repos/${repo}/branches/${branch}/protection`);
  let classic = null;
  if (classicRes.ok) {
    try {
      classic = JSON.parse(classicRes.stdout);
    } catch {
      classic = null;
    }
  }
  // 404 (no classic protection) is fine — ruleset is the authoritative surface.

  return {
    ok: true,
    classic,
    ruleset: rulesetIds.length > 0 || bypassActors.length > 0
      ? { rules: effectiveRules, bypass_actors: bypassActors, enforcement }
      : null,
  };
}

function evaluate(liveInputs, desiredJson) {
  const live = canonicalizeLive(liveInputs);
  const desired = canonicalizeDesired(desiredJson);
  const result = diffBranchProtection(live, desired);
  return { live, desired, result };
}

// ── Offline self-test ──────────────────────────────────────────────────────
// Proves the diff logic reports MATCH on a faithful live rendering of the file
// and DRIFT on each dangerous mutation. No network, self-contained.
function selfTest() {
  const desiredJson = loadDesired();
  const failures = [];

  // A live ruleset payload that faithfully mirrors the desired file (zero drift).
  function matchingLive() {
    const contexts = desiredJson.required_status_checks.contexts;
    return {
      classic: null,
      ruleset: {
        enforcement: "active",
        bypass_actors: [],
        rules: [
          {
            type: "required_status_checks",
            ruleset_id: 111,
            parameters: {
              strict_required_status_checks_policy:
                desiredJson.required_status_checks.strict === true,
              required_status_checks: contexts.map((context) => ({ context })),
            },
          },
          {
            type: "pull_request",
            ruleset_id: 111,
            parameters: {
              required_approving_review_count:
                desiredJson.required_pull_request_reviews.required_approving_review_count,
              require_code_owner_review:
                desiredJson.required_pull_request_reviews.require_code_owner_reviews === true,
              dismiss_stale_reviews_on_push:
                desiredJson.required_pull_request_reviews.dismiss_stale_reviews === true,
              require_last_push_approval:
                desiredJson.required_pull_request_reviews.require_last_push_approval === true,
            },
          },
          { type: "required_conversation_resolution", ruleset_id: 111 },
          { type: "non_fast_forward", ruleset_id: 111 },
          { type: "deletion", ruleset_id: 111 },
        ],
      },
    };
  }

  function expect(label, live, wantOk) {
    const { result } = evaluate(live, desiredJson);
    if (result.ok !== wantOk) {
      failures.push(
        `${label}: expected ${wantOk ? "MATCH" : "DRIFT"} but got ${result.ok ? "MATCH" : "DRIFT"}\n${formatDifferences(result)}`,
      );
    }
  }

  // 1. Positive control: faithful mirror MUST report MATCH.
  expect("identical-ruleset", matchingLive(), true);

  // 1b. Classic-protection mirror MUST also report MATCH (defense in depth).
  const contexts = desiredJson.required_status_checks.contexts;
  expect(
    "identical-classic",
    {
      classic: {
        required_status_checks: {
          strict: desiredJson.required_status_checks.strict === true,
          contexts,
        },
        enforce_admins: { enabled: true },
        required_pull_request_reviews: {
          required_approving_review_count:
            desiredJson.required_pull_request_reviews.required_approving_review_count,
          require_code_owner_reviews:
            desiredJson.required_pull_request_reviews.require_code_owner_reviews === true,
          dismiss_stale_reviews:
            desiredJson.required_pull_request_reviews.dismiss_stale_reviews === true,
          require_last_push_approval:
            desiredJson.required_pull_request_reviews.require_last_push_approval === true,
          bypass_pull_request_allowances: { users: [], teams: [], apps: [] },
        },
        required_conversation_resolution: { enabled: true },
        allow_force_pushes: { enabled: false },
        allow_deletions: { enabled: false },
      },
      ruleset: null,
    },
    true,
  );

  // 2. Negative controls: each dangerous mutation MUST report DRIFT.
  const mutations = {
    "reviews-wiped": (live) => {
      live.ruleset.rules = live.ruleset.rules.filter((r) => r.type !== "pull_request");
    },
    "admins-un-enforced (bypass actor added)": (live) => {
      live.ruleset.bypass_actors = [{ actor_id: 5, actor_type: "Integration", bypass_mode: "always" }];
    },
    "review-count-changed": (live) => {
      live.ruleset.rules.find((r) => r.type === "pull_request").parameters.required_approving_review_count =
        desiredJson.required_pull_request_reviews.required_approving_review_count + 1;
    },
    "code-owner-reviews-changed": (live) => {
      live.ruleset.rules.find((r) => r.type === "pull_request").parameters.require_code_owner_review =
        desiredJson.required_pull_request_reviews.require_code_owner_reviews !== true;
    },
    "last-push-approval-changed": (live) => {
      live.ruleset.rules.find((r) => r.type === "pull_request").parameters.require_last_push_approval =
        desiredJson.required_pull_request_reviews.require_last_push_approval !== true;
    },
    "force-push-allowed": (live) => {
      live.ruleset.rules = live.ruleset.rules.filter((r) => r.type !== "non_fast_forward");
    },
    "deletion-allowed": (live) => {
      live.ruleset.rules = live.ruleset.rules.filter((r) => r.type !== "deletion");
    },
    "conversation-resolution-off": (live) => {
      live.ruleset.rules = live.ruleset.rules.filter(
        (r) => r.type !== "required_conversation_resolution",
      );
    },
    "required-check-dropped": (live) => {
      const rule = live.ruleset.rules.find((r) => r.type === "required_status_checks");
      rule.parameters.required_status_checks = rule.parameters.required_status_checks.slice(1);
    },
    "extra-required-check-added": (live) => {
      const rule = live.ruleset.rules.find((r) => r.type === "required_status_checks");
      rule.parameters.required_status_checks.push({ context: "Some Rogue Gate" });
    },
    "protection-empty (no ruleset, no classic)": (live) => {
      live.ruleset = null;
      live.classic = null;
    },
    "strict-status-checks-toggled": (live) => {
      const rule = live.ruleset.rules.find((r) => r.type === "required_status_checks");
      rule.parameters.strict_required_status_checks_policy =
        !desiredJson.required_status_checks.strict === true;
    },
  };
  for (const [label, mutate] of Object.entries(mutations)) {
    const live = matchingLive();
    mutate(live);
    expect(label, live, false);
  }

  if (failures.length > 0) {
    console.error("FAIL: branch-protection drift self-test");
    for (const failure of failures) console.error(`  - ${failure}`);
    return 1;
  }
  console.log(
    `PASS: branch-protection drift self-test (2 positive controls + ${Object.keys(mutations).length} drift controls)`,
  );
  return 0;
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.selfTest) {
    process.exit(selfTest());
  }

  const desiredJson = loadDesired();

  let liveInputs;
  if (args.liveClassic || args.liveRuleset) {
    try {
      liveInputs = {
        classic: args.liveClassic ? readJsonFile(args.liveClassic) : null,
        ruleset: args.liveRuleset ? readJsonFile(args.liveRuleset) : null,
      };
    } catch (error) {
      console.error(`could not read live snapshot: ${error.message}`);
      process.exit(2);
    }
  } else {
    const fetched = fetchLive();
    if (!fetched.ok) {
      console.error(`could not read live branch protection: ${fetched.error}`);
      process.exit(2);
    }
    liveInputs = { classic: fetched.classic, ruleset: fetched.ruleset };
  }

  const { result } = evaluate(liveInputs, desiredJson);
  console.log(formatDifferences(result));
  process.exit(result.ok ? 0 : 1);
}

main();
