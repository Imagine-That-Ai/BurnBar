#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  BUNDLE_SCHEMA,
  RECEIPT_SCHEMA,
  validateReceipt,
  validateReleaseCertificationBundle,
  writeSha256Sums,
} from "./validate-release-certification-evidence.mjs";

const COMMIT = "0123456789abcdef0123456789abcdef01234567";

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function receipt(gate, status = "PASS") {
  const root = mkdtempSync(join(tmpdir(), "obb-cert-evidence-"));
  const evidencePath = join(root, "observation.log");
  writeFileSync(evidencePath, `${gate} ${status}\n`);
  return {
    schema: RECEIPT_SCHEMA,
    status,
    gate,
    target: `${gate}.target`,
    source: { commitSha: COMMIT, dirtyTree: false },
    artifact: {
      name: "source-checkout",
      architecture: "macOS-arm64-authoring-host",
      availability: "not-applicable",
      sha256: null,
      workflowRunId: "not-applicable-local",
      workflowRunUrl: "not-applicable",
      signature: { result: "not-applicable", identity: "not-applicable" },
    },
    device: {
      kind: "macos-authoring-host",
      manufacturer: "Apple",
      model: "authoring-host",
      architecture: "arm64",
      osBuild: "Darwin",
      tpm: "not-applicable",
    },
    protocol: { commands: [`local test for ${gate}`], manualSteps: [] },
    time: {
      startedAtUtc: "2026-07-11T00:00:00Z",
      endedAtUtc: "2026-07-11T00:00:01Z",
      durationSeconds: 1,
    },
    expected: "The scoped local check exits successfully.",
    observed: "The scoped local check exited successfully.",
    exitCode: 0,
    evidence: { files: [{ path: "observation.log", sha256: null }] },
    blocker: null,
    root,
  };
}

{
  const sample = receipt("local-automated-checks");
  const result = validateReceipt(sample, { bundleDir: sample.root });
  assert.equal(result.ok, false, "a receipt with an unfilled evidence hash must fail");
  assert.match(result.errors.join("\n"), /sha256 must be a lowercase SHA-256/);
}

{
  const bundleDir = mkdtempSync(join(tmpdir(), "obb-cert-bundle-"));
  mkdirSync(join(bundleDir, "receipts"));
  const evidencePath = join(bundleDir, "receipts/observation.log");
  writeFileSync(evidencePath, "local check passed\n");
  const evidenceHash = createHash("sha256").update(readFileSync(evidencePath)).digest("hex");
  const value = receipt("local-automated-checks");
  delete value.root;
  value.evidence.files = [{ path: "receipts/observation.log", sha256: evidenceHash }];
  const receiptPath = join(bundleDir, "receipts/local-automated-checks.json");
  writeJson(receiptPath, value);
  const receiptHash = createHash("sha256").update(readFileSync(receiptPath)).digest("hex");
  const manifest = {
    schema: BUNDLE_SCHEMA,
    generatedAtUtc: "2026-07-11T00:00:01Z",
    source: { commitSha: COMMIT, dirtyTree: false },
    overallVerdict: "NO-GO",
    receipts: [{ path: "receipts/local-automated-checks.json", sha256: receiptHash }],
    gates: [{ id: "local-automated-checks", status: "PASS", receipts: ["receipts/local-automated-checks.json"] }],
  };
  writeJson(join(bundleDir, "certification-manifest.json"), manifest);
  writeSha256Sums(bundleDir);
  const result = validateReleaseCertificationBundle(bundleDir, { expectedCommit: COMMIT, requireAllGates: false });
  assert.equal(result.ok, true, result.errors.join("\n"));

  const brokenReceipt = JSON.parse(readFileSync(receiptPath, "utf8"));
  brokenReceipt.status = "BLOCKED";
  brokenReceipt.blocker = null;
  writeJson(receiptPath, brokenReceipt);
  writeSha256Sums(bundleDir);
  const blockedResult = validateReleaseCertificationBundle(bundleDir);
  assert.equal(blockedResult.ok, false);
  assert.match(blockedResult.errors.join("\n"), /requires a named blocker/);
}

{
  const value = receipt("physical-performance-x64");
  value.device.kind = "windows-vm";
  value.artifact.availability = "not-applicable";
  value.artifact.signature.result = "not-applicable";
  value.evidence.files[0].sha256 = createHash("sha256").update(readFileSync(join(value.root, "observation.log"))).digest("hex");
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /physical gate cannot PASS/);
  assert.match(result.errors.join("\n"), /physical PASS requires a recorded artifact/);
}

{
  const value = receipt("staging-cloud", "BLOCKED");
  value.blocker = {
    id: "EXT-STAGING-ACCOUNT",
    owner: "Alberto",
    missing: "Named staging OAuth client and App Check-enabled Firebase project access",
    recovery: "Provide the configured secret names and interactive staging login; do not paste secret values.",
  };
  value.device.kind = "not-run";
  value.device.manufacturer = "not-available";
  value.device.model = "not-available";
  value.device.architecture = "not-available";
  value.device.osBuild = "not-available";
  value.device.tpm = "not-available";
  value.evidence.files[0].sha256 = createHash("sha256").update(readFileSync(join(value.root, "observation.log"))).digest("hex");
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, true, result.errors.join("\n"));
}

console.log("PASS: release certification evidence validator tests");
