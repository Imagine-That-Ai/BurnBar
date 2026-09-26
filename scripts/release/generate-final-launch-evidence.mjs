#!/usr/bin/env node
/**
 * Generate the launch-evidence manifest skeleton for a release tag.
 *
 * The manifest binds one tag to one SHA plus the evidence checklist the
 * validator enforces. It never fabricates evidence: every section ships
 * empty/absent until the release operator attaches the real artifact, so
 * `validate-launch-evidence-bundle.mjs --require-done-stamp` stays red by
 * design until launch. The output lives under launch-evidence/, which is
 * gitignored by policy (it can hold UIDs, transaction IDs, and live infra
 * evidence) — attach/redact deliberately at launch time, never sooner.
 *
 * Usage:
 *   node scripts/release/generate-final-launch-evidence.mjs --tag <tag> [--out <path>] [--force]
 *   node scripts/release/generate-final-launch-evidence.mjs --self-test
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import process from "node:process";
import { validateLaunchEvidenceBundle } from "../validate-launch-evidence-bundle.mjs";

const DEFAULT_OUT = "launch-evidence/final-launch-evidence.json";

function usage() {
  return `Usage:
  node scripts/release/generate-final-launch-evidence.mjs --tag <tag> [--out <path>] [--force]
  node scripts/release/generate-final-launch-evidence.mjs --self-test`;
}

function resolveTagSha(tag) {
  try {
    return execFileSync("git", ["rev-list", "-1", tag], { encoding: "utf8" }).trim();
  } catch {
    return null;
  }
}

export function buildSkeleton({ tag, sha, generatedAt }) {
  return {
    schemaVersion: 1,
    generatedAt,
    status: "PRE_LAUNCH_SKELETON",
    note: "Not launch evidence: no canary, paid proofs, store submissions, or live rollback drill exist yet, so --require-done-stamp is red by design until launch. Regenerate for the release tag once the deploy lane lands and live evidence exists. Never mark sections ok without their artifacts.",
    tag,
    sha,
    launchGate: {
      path: "latest-commercial-launch-gate.json",
    },
    paidProofs: [],
    crossChannelMatrix: {
      path: "cross-channel-paid-path-matrix.json",
    },
  };
}

function selfTest() {
  const failures = [];
  const check = (name, ok) => {
    console.log(`${ok ? "PASS" : "FAIL"}: self-test ${name}`);
    if (!ok) failures.push(name);
  };

  const skeleton = buildSkeleton({
    tag: "v9.9.99+selftest.1",
    sha: "0".repeat(40),
    generatedAt: "2026-01-02T03:04:05Z",
  });
  check("emits schemaVersion 1", skeleton.schemaVersion === 1);
  check("binds tag and sha", skeleton.tag === "v9.9.99+selftest.1" && skeleton.sha === "0".repeat(40));
  check("round-trips through JSON", JSON.parse(JSON.stringify(skeleton)).sha === "0".repeat(40));

  // The punchline: a fresh skeleton must FAIL validation with the evidence
  // gaps spelled out. A generator that passes pre-launch fabricates proof.
  const result = validateLaunchEvidenceBundle(skeleton, {
    manifestPath: "launch-evidence/self-test-manifest.json",
    stage: "done",
    requireDoneStamp: true,
  });
  check("skeleton fails --require-done-stamp", result.ok === false);
  const joined = result.errors.join("\n");
  check(
    "failure names the missing paid proofs",
    result.errors.filter((error) => error.startsWith("missing paid proof:")).length === 8,
  );
  check("failure names the missing canary", joined.includes("canary must be an object"));
  check("failure names the missing done stamp", joined.includes("LAUNCH_DONE.md is required"));

  if (failures.length > 0) {
    console.error(`self-test failed: ${failures.join(", ")}`);
    return 1;
  }
  console.log("PASS: launch-evidence generator self-test");
  return 0;
}

function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }
  if (argv.includes("--self-test")) return selfTest();

  let tag = null;
  let out = DEFAULT_OUT;
  let force = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--tag") {
      tag = argv[++index] ?? null;
    } else if (argument.startsWith("--tag=")) {
      tag = argument.slice("--tag=".length);
    } else if (argument === "--out") {
      out = argv[++index] ?? out;
    } else if (argument.startsWith("--out=")) {
      out = argument.slice("--out=".length);
    } else if (argument === "--force") {
      force = true;
    } else {
      console.error(`unknown argument: ${argument}\n${usage()}`);
      return 2;
    }
  }
  if (!tag) {
    console.error(`--tag is required\n${usage()}`);
    return 2;
  }
  const sha = resolveTagSha(tag);
  if (!sha) {
    console.error(`tag not found in this checkout: ${tag}`);
    return 1;
  }
  if (existsSync(out) && !force) {
    console.error(`refusing to overwrite ${out} without --force (never clobber collected evidence)`);
    return 1;
  }
  if (existsSync(out)) {
    const current = JSON.parse(readFileSync(out, "utf8"));
    if (current?.status !== "PRE_LAUNCH_SKELETON") {
      console.error(`refusing to overwrite ${out}: status is ${JSON.stringify(current?.status)}, not PRE_LAUNCH_SKELETON`);
      return 1;
    }
  }
  const skeleton = buildSkeleton({ tag, sha, generatedAt: new Date().toISOString() });
  writeFileSync(out, `${JSON.stringify(skeleton, null, 2)}\n`, "utf8");
  console.log(`Wrote skeleton manifest for ${tag} (${sha}) to ${out}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main(process.argv.slice(2));
}
