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

export const HARD_LIMIT_BYTES = 256 * 1024; // Published UTF-8 source ceiling.
export const COMPILED_HARD_LIMIT_BYTES = 250 * 1024; // Published activated-rules ceiling.
// On 2026-08-10, staging accepted the existing 155,997-byte generation but
// rejected a valid 161,581-byte candidate during release activation. Keep new
// source below 150 KiB and warn at 146 KiB. This leaves real headroom below the
// last activated source while emulator tests protect behavior. A successful
// trusted staging deployment is still required because source size is only a
// conservative proxy for Google's hidden compiled representation.
export const FAIL_THRESHOLD_BYTES = 150 * 1024;
export const WARN_THRESHOLD_BYTES = 146 * 1024;
// Storage was not involved in the Firestore release-activation incident. Keep
// its existing ratchet independent so future tuning follows Storage evidence.
export const STORAGE_FAIL_THRESHOLD_BYTES = 160 * 1024;
export const STORAGE_WARN_THRESHOLD_BYTES = 156 * 1024;

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const files = [
  {
    name: "firestore.rules",
    compact: true,
    failThreshold: FAIL_THRESHOLD_BYTES,
    warnThreshold: WARN_THRESHOLD_BYTES,
  },
  {
    name: "storage.rules",
    compact: false,
    failThreshold: STORAGE_FAIL_THRESHOLD_BYTES,
    warnThreshold: STORAGE_WARN_THRESHOLD_BYTES,
  },
];

export function classifyRulesSize(
  bytes,
  {
    failThreshold = FAIL_THRESHOLD_BYTES,
    warnThreshold = WARN_THRESHOLD_BYTES,
  } = {},
) {
  if (bytes >= failThreshold) return "fail";
  if (bytes >= warnThreshold) return "warn";
  return "ok";
}

export function evaluateRulesSources(sources, logger = console) {
  let failed = false;
  for (const {
    name,
    raw,
    compact,
    failThreshold = FAIL_THRESHOLD_BYTES,
    warnThreshold = WARN_THRESHOLD_BYTES,
  } of sources) {
    const shipped = compact ? compactFirebaseRulesSource(raw) : raw;
    const bytes = Buffer.byteLength(shipped, "utf8");
    const pct = ((bytes / HARD_LIMIT_BYTES) * 100).toFixed(1);
    const detail = `${name}: shipped=${bytes}B (${pct}% of ${HARD_LIMIT_BYTES}B source limit, compiled limit=${COMPILED_HARD_LIMIT_BYTES}B, raw=${Buffer.byteLength(raw)}B)`;
    const level = classifyRulesSize(bytes, { failThreshold, warnThreshold });
    if (level === "fail") {
      logger.error(
        `::error::${detail} — exceeds the ${failThreshold}B safety threshold. Consolidate repeated match expressions or reduce the ruleset before it breaks production deploys.`,
      );
      failed = true;
    } else if (level === "warn") {
      logger.warn(`::warning::${detail} — approaching the size limit.`);
    } else {
      logger.log(`ok ${detail}`);
    }
  }
  if (failed) return 1;
  logger.log("firestore/storage rules size within safe bounds");
  return 0;
}

export function runRulesSizeCheck(root = repoRoot, logger = console) {
  return evaluateRulesSources(
    files.map((file) => ({
      ...file,
      raw: readFileSync(resolve(root, file.name), "utf8"),
    })),
    logger,
  );
}

const isMain =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) process.exitCode = runRulesSizeCheck();
