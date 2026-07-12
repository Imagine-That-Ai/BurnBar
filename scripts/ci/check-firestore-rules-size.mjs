#!/usr/bin/env node
// PR-time + pre-deploy tripwire for the Firebase Security Rules size limit.
//
// Why this exists: the Firestore rules deploy silently rotted for ~3 weeks
// (diligence 2026-07-12 LB-2). firestore.rules grew close to the Firebase Rules
// API ceiling; a ruleset that CREATEs can still be rejected at release time, and
// the failure mode is an opaque 400 INVALID_ARGUMENT with no size hint. This
// gate fails loudly, at PR time, with the exact numbers — so rules growth can
// never again break production deploys without a reviewer seeing it first.
//
// Firebase's documented hard limit is 256 KiB of UTF-8 rules source per ruleset.
// We evaluate the COMPACTED form (comments/blank lines stripped) because that is
// what the deploy actually ships, and enforce a safety margin below the ceiling.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { compactFirebaseRulesSource } from "./firebase-rules-source.mjs";

const HARD_LIMIT_BYTES = 256 * 1024; // Firebase Rules API ceiling (262144).
// Fail well before the ceiling: a rejected release is a production incident, and
// the ruleset AST can be rejected below the raw byte ceiling. 230 KiB leaves
// ~26 KiB of headroom while still flagging growth early.
const FAIL_THRESHOLD_BYTES = 230 * 1024;
const WARN_THRESHOLD_BYTES = 200 * 1024;

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const files = [
  { name: "firestore.rules", compact: true },
  { name: "storage.rules", compact: false },
];

let failed = false;
for (const { name, compact } of files) {
  const raw = readFileSync(resolve(repoRoot, name), "utf8");
  const shipped = compact ? compactFirebaseRulesSource(raw) : raw;
  const bytes = Buffer.byteLength(shipped, "utf8");
  const pct = ((bytes / HARD_LIMIT_BYTES) * 100).toFixed(1);
  const detail = `${name}: shipped=${bytes}B (${pct}% of ${HARD_LIMIT_BYTES}B limit, raw=${Buffer.byteLength(raw)}B)`;
  if (bytes >= FAIL_THRESHOLD_BYTES) {
    console.error(
      `::error::${detail} — exceeds the ${FAIL_THRESHOLD_BYTES}B safety threshold. Split the ruleset into composable per-domain files or reduce it before it breaks production deploys.`,
    );
    failed = true;
  } else if (bytes >= WARN_THRESHOLD_BYTES) {
    console.warn(`::warning::${detail} — approaching the size limit.`);
  } else {
    console.log(`ok ${detail}`);
  }
}

if (failed) process.exit(1);
console.log("firestore/storage rules size within safe bounds");
