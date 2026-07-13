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
// Firebase documents two independent ceilings: 256 KiB of UTF-8 source and
// 250 KiB for the compiled ruleset activated by the backend. The Rules API does
// not expose compiled byte size, so a gate near the 256 KiB source ceiling is a
// false comfort: compiler expansion can reject a much smaller source at release
// time. We evaluate the COMPACTED form that deploy ships and keep it near the
// last production-proven source size while emulator tests protect behavior.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { compactFirebaseRulesSource } from "./firebase-rules-source.mjs";

const HARD_LIMIT_BYTES = 256 * 1024; // Published UTF-8 source ceiling.
const COMPILED_HARD_LIMIT_BYTES = 250 * 1024; // Published activated-rules ceiling.
// The 2026-07-03 production ruleset was 156,570 compacted bytes. Keep new
// source below 160 KiB and warn at 156 KiB; structural compiler expansion still
// requires a real dry-run + deploy proof, but this ratchet catches source growth
// long before another opaque release-time 400.
const FAIL_THRESHOLD_BYTES = 160 * 1024;
const WARN_THRESHOLD_BYTES = 156 * 1024;

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
  const detail = `${name}: shipped=${bytes}B (${pct}% of ${HARD_LIMIT_BYTES}B source limit, compiled limit=${COMPILED_HARD_LIMIT_BYTES}B, raw=${Buffer.byteLength(raw)}B)`;
  if (bytes >= FAIL_THRESHOLD_BYTES) {
    console.error(
      `::error::${detail} — exceeds the ${FAIL_THRESHOLD_BYTES}B safety threshold. Consolidate repeated match expressions or reduce the ruleset before it breaks production deploys.`,
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
