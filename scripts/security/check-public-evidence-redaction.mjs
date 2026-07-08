#!/usr/bin/env node
// Guard public launch evidence and operational runbooks against raw operational
// identifiers. Secret scanners catch credentials; this catches the adjacent
// class: device/account/cloud inventory values that are not secrets but still
// should not be published as concrete production evidence.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EVIDENCE_AND_RUNBOOK_PATHS = [
  /^firebase-security-evidence\.json$/,
  /^security\/evidence\/firebase-security-evidence.*\.json$/,
  /^launch-evidence\//,
  /^docs\/runbooks\/computer-use-device-matrix\//,
  /^docs\/runbooks\/computer-use-master-plan-audit\.md$/,
  /^docs\/signalification\/COMPUTER_USE_AGENT_HANDOFF\.md$/,
];

const AGENT_OPERATION_PATHS = [
  /^docs\/signalification\/COMPUTER_USE_AGENT_HANDOFF\.md$/,
  /^docs\/runbooks\/.*\.md$/,
];

const CONCRETE_VALUE_KEYS = [
  "appleDeviceId",
  "appStoreIssuerId",
  "appStoreKeyId",
  "cloudRunUrl",
  "controllerId",
  "debugToken",
  "deviceId",
  "deviceSerial",
  "deviceUdid",
  "firebaseUid",
  "hostedQuotaRunnerUrl",
  "kmsKey",
  "notificationChannelId",
  "openTimestampsVerifierUrl",
  "peerId",
  "project",
  "projectId",
  "projectNumber",
  "purchaseTokenHash",
  "rawUid",
  "relayConnectionId",
  "sentryDsn",
  "serialNumber",
  "serviceAccountEmail",
  "storageBucket",
  "stripePriceId",
  "testerUid",
  "uidHash",
];

const KEYED_CONCRETE_VALUE_RE = new RegExp(
  `(["']?(?:${CONCRETE_VALUE_KEYS.join("|")})["']?\\s*[:=]\\s*["'])(?!<|\\[REDACTED|redacted\\b|unknown\\b|null\\b)([^"',}\\]\\s]{6,})`,
  "i",
);

const EVIDENCE_RULES = [
  {
    id: "concrete-operational-value",
    reason: "raw device/account/cloud inventory value",
    pattern: KEYED_CONCRETE_VALUE_RE,
  },
  {
    id: "apple-device-udid",
    reason: "raw Apple device identifier",
    pattern: /\b[0-9A-F]{8}-[0-9A-F]{16}\b/i,
  },
  {
    id: "sentry-dsn",
    reason: "raw Sentry DSN",
    pattern: /https:\/\/[0-9a-f]{12,}@[a-z0-9.-]*sentry\.io\/\d+/i,
  },
  {
    id: "cloud-run-url",
    reason: "raw Cloud Run service URL",
    pattern: /https:\/\/[a-z0-9][a-z0-9-]*-[a-z0-9-]+\.a\.run\.app\b/i,
  },
  {
    id: "gcp-resource-path",
    reason: "raw Google Cloud resource path",
    pattern: /\bprojects\/(?:\d{6,}|[a-z][a-z0-9-]{2,})\/(?:locations|secrets|services|keys|topics|subscriptions|notificationChannels)\//i,
  },
  {
    id: "service-account-email",
    reason: "raw Google service-account email",
    pattern: /\b[a-z0-9][a-z0-9._-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com\b/i,
  },
  {
    id: "firebase-storage-bucket",
    reason: "raw Firebase Storage bucket",
    pattern: /\b[a-z0-9][a-z0-9.-]+\.firebasestorage\.app\b/i,
  },
  {
    id: "secret-env-name-in-evidence",
    reason: "runtime secret environment variable name in public evidence",
    pattern: /\b[A-Z][A-Z0-9_]*(?:SECRET|TOKEN|PRIVATE|PASSWORD)[A-Z0-9_]*\b/,
  },
];

const AGENT_OPERATION_RULES = [
  {
    id: "direct-main-push",
    reason: "agent-facing direct push to main",
    pattern: /\bgit\s+push\s+origin\s+\S+:main\b/i,
  },
  {
    id: "branch-protection-disable",
    reason: "agent-facing branch-protection bypass command",
    pattern: /\b(?:enforce_admins\s*[:=]\s*false|bypass_pull_request_allowances|required_status_checks\s*[:=]\s*null)\b/i,
  },
];

function pathMatches(path, patterns) {
  return patterns.some((pattern) => pattern.test(path));
}

function trackedFiles(root) {
  // Node's default execFileSync maxBuffer is 1 MiB; the tracked tree's
  // NUL-joined path list outgrew it (spawnSync git ENOBUFS). 64 MiB is orders
  // of magnitude above any plausible repo listing.
  return execFileSync("git", ["ls-files", "-z"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  })
    .split("\0")
    .filter(Boolean);
}

function repoRoot() {
  return execFileSync("git", ["rev-parse", "--show-toplevel"], {
    encoding: "utf8",
  }).trim();
}

function lineLooksRedacted(line) {
  return /<[^>\n]+>|\[REDACTED[^\]\n]*\]|\bredacted\b/i.test(line);
}

export function scanText(path, text) {
  const violations = [];
  const rules = [];
  if (pathMatches(path, EVIDENCE_AND_RUNBOOK_PATHS)) {
    rules.push(...EVIDENCE_RULES);
  }
  if (pathMatches(path, AGENT_OPERATION_PATHS)) {
    rules.push(...AGENT_OPERATION_RULES);
  }
  if (rules.length === 0) return violations;

  const lines = text.split(/\r?\n/u);
  lines.forEach((line, index) => {
    for (const rule of rules) {
      if (!rule.pattern.test(line)) continue;
      if (rule.id !== "direct-main-push" && rule.id !== "branch-protection-disable" && lineLooksRedacted(line)) {
        continue;
      }
      violations.push({
        path,
        line: index + 1,
        ruleId: rule.id,
        reason: rule.reason,
      });
    }
  });
  return violations;
}

export function scanFiles(root, files) {
  const violations = [];
  for (const path of files) {
    if (
      !pathMatches(path, EVIDENCE_AND_RUNBOOK_PATHS) &&
      !pathMatches(path, AGENT_OPERATION_PATHS)
    ) {
      continue;
    }

    let text;
    try {
      text = readFileSync(resolve(root, path), "utf8");
    } catch {
      continue;
    }
    violations.push(...scanText(path, text));
  }
  return violations;
}

function printViolations(violations) {
  if (violations.length === 0) {
    console.log("PASS: public evidence redaction guard found no raw operational evidence.");
    return;
  }

  console.error("FAIL: public evidence/runbook files contain raw operational evidence.");
  console.error("Replace concrete values with placeholders before publishing.\n");
  for (const violation of violations) {
    console.error(
      `${violation.path}:${violation.line}: ${violation.ruleId}: ${violation.reason}`,
    );
  }
}

function main(argv = process.argv.slice(2)) {
  const root = repoRoot();
  const files = argv.length > 0 ? argv : trackedFiles(root);
  const violations = scanFiles(root, files);
  printViolations(violations);
  return violations.length === 0 ? 0 : 1;
}

const isMain =
  process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));

if (isMain) {
  process.exit(main());
}
