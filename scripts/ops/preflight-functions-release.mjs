#!/usr/bin/env node

// Local GO / NO-GO check before pushing a production Cloud Functions release
// tag. Run it instead of cutting another tag to see whether the last one
// failed.
//
//   node scripts/ops/preflight-functions-release.mjs [--profile public-production]
//                                                    [--release-commit <sha>]
//
// Between 2026-08-20 and 2026-09-02, 39 consecutive `v1.0.40+repair.N` tags
// were pushed against a `prepare-functions-deploy` job that could never pass,
// because `gh attestation download` 404s for a candidate bundle no
// promotion-proof run ever signed. The tag was never the problem, and cutting
// another one never helped. This tells you that before you burn one.
//
// Read-only: it resolves the activation from the working tree and, when a
// protected proof is required, asks the GitHub attestations API whether one
// exists. It never deploys, tags, or mutates anything.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { resolveActiveDomainCoreActivation } from "../lib/domain-core-activation.mjs";
import { resolveFunctionsPromotionGate } from "../ci/resolve-functions-promotion-gate.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function argument(argv, flag, fallback) {
  const index = argv.indexOf(flag);
  if (index === -1) return fallback;
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function git(...args) {
  return execFileSync("git", ["-C", ROOT, ...args], { encoding: "utf8" }).trim();
}

function gh(...args) {
  return execFileSync("gh", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function line(label, value) {
  process.stdout.write(`${label.padEnd(22)} ${value}\n`);
}

export function run(argv) {
  const profile = argument(argv, "--profile", "public-production");
  const releaseCommit = argument(argv, "--release-commit", git("rev-parse", "HEAD"));
  const activation = resolveActiveDomainCoreActivation({
    repoRoot: ROOT,
    activationCommit: releaseCommit,
    requireClean: !argv.includes("--allow-dirty"),
  });
  const decision = resolveFunctionsPromotionGate({
    active: String(activation.active),
    profile,
  });

  process.stdout.write("Production Cloud Functions release preflight\n\n");
  line("release commit", releaseCommit);
  line("candidate C", activation.candidateCommit);
  line("domain core active", String(activation.active));
  line("profile", profile);
  line("protected proof", decision.proofRequired ? "REQUIRED" : "not required");

  if (!decision.proofRequired) {
    process.stdout.write(
      "\nGO — the domain core is inactive, so this release does not need a\n" +
        "protected promotion proof. `prepare-functions-deploy` takes the inactive\n" +
        "lane and no promotion attestation is consulted.\n",
    );
    return { decision, ready: true };
  }

  let bundleDigest = null;
  let attested = false;
  try {
    const runs = JSON.parse(
      gh(
        "api",
        "--paginate",
        "--slurp",
        `/repos/Imagine-That-Ai/BurnBar/actions/workflows/domain-core.yml/runs?event=push&status=completed&head_sha=${activation.candidateCommit}&per_page=100`,
      ),
    )
      .flatMap((page) => page.workflow_runs ?? [])
      .filter(
        (value) =>
          value.head_branch === "main" && value.conclusion === "success",
      );
    if (runs.length !== 1) {
      throw new Error(
        `expected exactly one successful deterministic main push run for ${activation.candidateCommit}, found ${runs.length}`,
      );
    }
    line("source run", `${runs[0].id} attempt ${runs[0].run_attempt}`);
    const staging = mkdtempSync(join(tmpdir(), "functions-release-preflight-"));
    try {
      gh(
        "run",
        "download",
        String(runs[0].id),
        "--repo",
        "Imagine-That-Ai/BurnBar",
        "--name",
        `domain-core-candidate-bundle-${activation.candidateCommit}-${runs[0].id}-${runs[0].run_attempt}`,
        "--dir",
        staging,
      );
      bundleDigest = createHash("sha256")
        .update(readFileSync(join(staging, "domain-core-candidate-bundle.json")))
        .digest("hex");
    } finally {
      rmSync(staging, { recursive: true, force: true });
    }
  } catch (error) {
    process.stdout.write(
      `\nCould not resolve the candidate bundle locally: ${error.message}\n`,
    );
  }

  if (bundleDigest !== null) {
    line("bundle sha256", bundleDigest);
    try {
      gh(
        "api",
        `/repos/Imagine-That-Ai/BurnBar/attestations/sha256:${bundleDigest}?per_page=1`,
      );
      attested = true;
    } catch {
      attested = false;
    }
    line("promotion proof", attested ? "present" : "MISSING (404)");
  }

  if (attested) {
    process.stdout.write("\nGO — a protected promotion attestation exists for candidate C.\n");
    return { decision, ready: true };
  }

  process.stdout.write(
    `\nNO-GO — no protected promotion attestation exists for candidate\n` +
      `${activation.candidateCommit}. Pushing a release tag will fail\n` +
      `\`prepare-functions-deploy\` at "Verify protected promotion and exact\n` +
      `rollback before build". Do NOT cut another tag; mint the proof first:\n\n` +
      `  gh workflow run domain-core-promotion-proof.yml \\\n` +
      `    --repo Imagine-That-Ai/BurnBar --ref main \\\n` +
      `    --field candidate_commit=${activation.candidateCommit}\n\n` +
      `That run must pass "Verify candidate control plane matches trusted main",\n` +
      `which requires candidate C's control-plane files to be byte-identical to\n` +
      `current main. If they have drifted, land a new activation commit so C\n` +
      `advances, then mint the proof immediately.\n`,
  );
  return { decision, ready: false };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const result = run(process.argv.slice(2));
    process.exitCode = result.ready ? 0 : 1;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
