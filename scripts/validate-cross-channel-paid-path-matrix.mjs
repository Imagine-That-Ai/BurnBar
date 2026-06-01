#!/usr/bin/env node
/**
 * Convenience validator for the T29 cross-channel paid-path matrix.
 *
 * The final launch bundle validator owns the schema. This wrapper keeps the
 * documented command stable for agents that want to validate only the matrix
 * artifact while still enforcing the same paid-proof-stage requirements.
 */

import { existsSync, readFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import process from "node:process";
import { validateLaunchEvidenceBundle, templateLaunchEvidenceBundle } from "./validate-launch-evidence-bundle.mjs";

function usage() {
  return "Usage: scripts/validate-cross-channel-paid-path-matrix.mjs launch-evidence/cross-channel-paid-path-matrix.json";
}

function copyJSON(source, target) {
  writeFileSync(target, readFileSync(source, "utf8"));
}

function writeJSON(path, value) {
  writeFileSync(path, JSON.stringify(value, null, 2));
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }

  const matrixPath = argv.find((arg) => !arg.startsWith("-"));
  if (!matrixPath) {
    console.error(usage());
    return 2;
  }
  if (!existsSync(matrixPath)) {
    console.error(JSON.stringify({ ok: false, errors: [`${matrixPath}: file does not exist`] }, null, 2));
    return 1;
  }

  const tempDir = mkdtempSync(join(tmpdir(), "openburnbar-cross-channel-matrix-"));
  const manifest = templateLaunchEvidenceBundle();
  manifest.generatedAt = new Date().toISOString();
  manifest.launchGate = { path: "latest-commercial-launch-gate.json" };
  manifest.crossChannelMatrix = { path: "cross-channel-paid-path-matrix.json" };

  writeJSON(join(tempDir, "latest-commercial-launch-gate.json"), {
    verdict: { status: "READY_FOR_CANARY" },
    checks: { repo: { ok: true } },
  });
  copyJSON(matrixPath, join(tempDir, "cross-channel-paid-path-matrix.json"));

  for (const proof of manifest.paidProofs) {
    writeJSON(join(tempDir, proof.path), {
      ok: true,
      channel: proof.channel,
      tier: proof.tier,
    });
  }

  const result = validateLaunchEvidenceBundle(manifest, {
    manifestPath: join(tempDir, "final-launch-evidence.json"),
    stage: "paid-proof",
  });
  if (!result.ok) {
    console.error(JSON.stringify({ ok: false, path: matrixPath, errors: result.errors }, null, 2));
    return 1;
  }
  console.log(JSON.stringify({ ok: true, path: matrixPath }, null, 2));
  return 0;
}

main(process.argv.slice(2)).then((code) => {
  process.exitCode = code;
});
