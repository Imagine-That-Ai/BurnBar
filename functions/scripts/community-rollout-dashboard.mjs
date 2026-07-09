#!/usr/bin/env node
import { pathToFileURL } from "node:url";

import { parseArgs as parseCanaryArgs, runLiveCanary } from "./community-leaderboard-canary.mjs";
import { parseArgs as parsePostmergeArgs, runLiveReport } from "./community-postmerge-check.mjs";

function usage() {
  console.log(`Usage: node scripts/community-rollout-dashboard.mjs [options]

Runs the Community launch-readiness dashboard: authenticated public leaderboard canary plus read-only aggregate posture report.

Options:
  --project <id>             Firebase project id. Defaults to FIREBASE_PROJECT, OPENBURNBAR_FIREBASE_PROJECT, or GCLOUD_PROJECT.
  --api-key <key>            Firebase Web API key. Defaults to FIREBASE_WEB_API_KEY.
  --uid <uid>                Synthetic canary auth uid. Default community-canary.
  --threshold-doc <id>       Expected below-threshold leaderboard doc id.
  --live-doc <id>            Expected live leaderboard doc id.
  --revoked-anon-id <id>     Optional anonId that must not appear in the live doc.
  --database <id>            Firestore database id. Default (default).
  --stale-hours <n>          Staleness threshold for public boards. Default 48.
  --strict                   Require revoked anonId evidence in the canary.
  --skip-canary              Skip authenticated REST canary only for environments with no seeded docs/API key.
  --json                     Emit JSON only.
  --help                     Show this help.
`);
}

function requireValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

export function parseDashboardArgs(argv = process.argv, env = process.env) {
  const options = {
    project: env.FIREBASE_PROJECT || env.OPENBURNBAR_FIREBASE_PROJECT || env.GCLOUD_PROJECT || "",
    apiKey: env.FIREBASE_WEB_API_KEY || "",
    uid: env.COMMUNITY_CANARY_UID || "community-canary",
    thresholdDoc: env.COMMUNITY_CANARY_THRESHOLD_DOC || "",
    liveDoc: env.COMMUNITY_CANARY_LIVE_DOC || "",
    revokedAnonId: env.COMMUNITY_CANARY_REVOKED_ANON_ID || "",
    database: env.FIRESTORE_DATABASE || "(default)",
    staleHours: Number.parseFloat(env.COMMUNITY_POSTMERGE_STALE_HOURS || "48"),
    strict: false,
    skipCanary: false,
    json: false,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--strict") {
      options.strict = true;
      continue;
    }
    if (arg === "--skip-canary") {
      options.skipCanary = true;
      continue;
    }
    if (arg === "--json") {
      options.json = true;
      continue;
    }
    if (arg === "--project") {
      options.project = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--api-key") {
      options.apiKey = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--uid") {
      options.uid = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--threshold-doc") {
      options.thresholdDoc = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--live-doc") {
      options.liveDoc = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--revoked-anon-id") {
      options.revokedAnonId = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--database") {
      options.database = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--stale-hours") {
      options.staleHours = Number.parseFloat(requireValue(argv, ++index, arg));
      if (!Number.isFinite(options.staleHours) || options.staleHours < 0) {
        throw new Error("--stale-hours must be a non-negative number");
      }
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  return options;
}

function toCanaryArgv(options) {
  const argv = ["node", "community-leaderboard-canary.mjs"];
  argv.push("--project", options.project);
  argv.push("--api-key", options.apiKey);
  argv.push("--uid", options.uid);
  argv.push("--threshold-doc", options.thresholdDoc);
  argv.push("--live-doc", options.liveDoc);
  argv.push("--database", options.database);
  if (options.revokedAnonId) argv.push("--revoked-anon-id", options.revokedAnonId);
  if (options.strict) argv.push("--strict");
  return argv;
}

function toPostmergeArgv(options) {
  return [
    "node",
    "community-postmerge-check.mjs",
    "--project",
    options.project,
    "--database",
    options.database,
    "--stale-hours",
    String(options.staleHours),
  ];
}

function canRunCanary(options) {
  return Boolean(options.project && options.apiKey && options.thresholdDoc && options.liveDoc);
}

export async function runDashboard(options) {
  if (!options.project) throw new Error("--project or FIREBASE_PROJECT is required");

  let canary = null;
  let canarySkipped = false;

  if (options.skipCanary) {
    canarySkipped = true;
  } else if (!canRunCanary(options)) {
    throw new Error("canary inputs are incomplete; set FIREBASE_WEB_API_KEY, COMMUNITY_CANARY_THRESHOLD_DOC, and COMMUNITY_CANARY_LIVE_DOC or pass --skip-canary for an unseeded environment");
  }

  const postmerge = await runLiveReport(parsePostmergeArgs(toPostmergeArgv(options)));
  if (!canarySkipped) {
    canary = await runLiveCanary(parseCanaryArgs(toCanaryArgv(options)));
  }

  return {
    generatedAt: new Date().toISOString(),
    ok: (canary?.ok ?? true) && postmerge.stalePublicLeaderboards.eligible === 0,
    canarySkipped,
    canary,
    postmerge,
  };
}

function printSection(title) {
  console.log(`\n== ${title} ==`);
}

function printDashboard(summary) {
  console.log(`Community rollout dashboard: ${summary.ok ? "PASS" : "FAIL"}`);
  printSection("Authenticated public read canary");
  if (summary.canarySkipped) {
    console.log("SKIP: canary explicitly skipped for an unseeded environment");
  } else if (summary.canary) {
    for (const section of [summary.canary.threshold, summary.canary.live]) {
      console.log(`${section.docId || "(missing doc)"}: ${section.ok ? "ok" : "FAIL"}`);
      for (const check of section.checks) {
        const marker = check.skipped ? "SKIP" : check.ok ? "ok" : "FAIL";
        console.log(`  ${marker}: ${check.label}${check.detail ? ` — ${check.detail}` : ""}`);
      }
    }
  }

  printSection("Aggregate posture");
  const post = summary.postmerge;
  console.log(`Active participants: ${post.activeCommunityParticipants}`);
  console.log(`Share snapshots: ${post.shareSnapshots} (${post.revokedShareSnapshots} revoked tombstones)`);
  console.log(`Public leaderboards: ${post.publicLeaderboards}`);
  console.log(`Stale public boards: ${post.stalePublicLeaderboards.eligible}`);
  const below = Object.entries(post.belowThresholdByTierWindow).sort();
  console.log("Below-threshold boards:");
  if (below.length === 0) console.log("  none");
  for (const [key, count] of below) console.log(`  ${key}: ${count}`);
}

export async function main(argv = process.argv) {
  const options = parseDashboardArgs(argv);
  const summary = await runDashboard(options);
  if (options.json) console.log(JSON.stringify(summary, null, 2));
  else printDashboard(summary);
  if (!summary.ok) process.exitCode = 1;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch(() => {
    // Errors from Firebase REST clients may include request URLs containing the API key.
    console.error("Community rollout dashboard failed; inspect the preceding operation logs.");
    process.exit(1);
  });
}
