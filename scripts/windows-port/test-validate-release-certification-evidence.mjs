#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  BUNDLE_SCHEMA,
  RECEIPT_SCHEMA,
  REQUIRED_GATE_IDS,
  validateReceipt,
  validateReleaseCertificationBundle,
  writeSha256Sums,
} from "./validate-release-certification-evidence.mjs";
import { sanitizeCertificationLog } from "./certification-log-sanitizer.mjs";

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

function physicalPassReceipt(gate = "physical-performance-x64") {
  const value = receipt(gate);
  value.device = {
    kind: "physical-windows",
    manufacturer: "HP",
    model: "ENVY x360 15-ew0xxx",
    assetTag: "5CD1234567",
    assetTagSource: "Win32_ComputerSystemProduct.IdentifyingNumber",
    architecture: "x64",
    osBuild: "Windows 11 10.0.26100",
    tpm: "present-ready-enabled-activated-owned",
  };
  value.artifact = {
    name: "OpenBurnBar-1.0.30-x64.msix",
    architecture: "x64",
    availability: "recorded",
    sha256: "a".repeat(64),
    workflowRunId: "123",
    workflowRunUrl: "https://example.invalid/runs/123",
    signature: { result: "verified", identity: "Imagine That AI LLC" },
  };
  value.evidence.files[0].sha256 = createHash("sha256")
    .update(readFileSync(join(value.root, "observation.log")))
    .digest("hex");
  return value;
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

  const missingReceiptHashManifest = structuredClone(manifest);
  delete missingReceiptHashManifest.receipts[0].sha256;
  writeJson(join(bundleDir, "certification-manifest.json"), missingReceiptHashManifest);
  writeSha256Sums(bundleDir);
  const missingReceiptHashResult = validateReleaseCertificationBundle(
    bundleDir,
    { expectedCommit: COMMIT, requireAllGates: false },
  );
  assert.equal(missingReceiptHashResult.ok, false);
  assert.match(
    missingReceiptHashResult.errors.join("\n"),
    /receipt sha256 is required/,
  );

  function validateState(
    receiptValue,
    manifestValue,
    options = { requireAllGates: false },
  ) {
    writeJson(receiptPath, receiptValue);
    manifestValue.receipts[0].sha256 = createHash("sha256")
      .update(readFileSync(receiptPath))
      .digest("hex");
    writeJson(join(bundleDir, "certification-manifest.json"), manifestValue);
    writeSha256Sums(bundleDir);
    return validateReleaseCertificationBundle(bundleDir, options);
  }

  const brokenReceipt = structuredClone(value);
  brokenReceipt.status = "BLOCKED";
  brokenReceipt.blocker = null;
  const brokenManifest = structuredClone(manifest);
  brokenManifest.gates[0].status = "BLOCKED";
  const blockedResult = validateState(brokenReceipt, brokenManifest);
  assert.equal(blockedResult.ok, false);
  assert.match(blockedResult.errors.join("\n"), /requires a named blocker/);

  const wrongGateManifest = structuredClone(manifest);
  wrongGateManifest.gates[0].id = "physical-performance-x64";
  const wrongGateResult = validateState(value, wrongGateManifest);
  assert.equal(wrongGateResult.ok, false);
  assert.match(
    wrongGateResult.errors.join("\n"),
    /does not match receipt gate/,
  );

  const staleReceipt = structuredClone(value);
  staleReceipt.source.commitSha = "abcdef0123456789abcdef0123456789abcdef01";
  const staleResult = validateState(staleReceipt, structuredClone(manifest));
  assert.equal(staleResult.ok, false);
  assert.match(
    staleResult.errors.join("\n"),
    /receipt commit does not match bundle source commit/,
  );

  const falseGoManifest = structuredClone(manifest);
  falseGoManifest.overallVerdict = "GO";
  const falseGoResult = validateState(value, falseGoManifest);
  assert.equal(falseGoResult.ok, false);
  assert.match(
    falseGoResult.errors.join("\n"),
    /GO requires every required gate to be present and PASS/,
  );

  const dirtyGoManifest = structuredClone(falseGoManifest);
  dirtyGoManifest.source.dirtyTree = true;
  const dirtyGoResult = validateState(value, dirtyGoManifest);
  assert.equal(dirtyGoResult.ok, false);
  assert.match(
    dirtyGoResult.errors.join("\n"),
    /GO requires a clean source tree/,
  );

  const dirtyGoReceipt = structuredClone(value);
  dirtyGoReceipt.source.dirtyTree = true;
  const dirtyReceiptGoResult = validateState(
    dirtyGoReceipt,
    structuredClone(falseGoManifest),
  );
  assert.equal(dirtyReceiptGoResult.ok, false);
  assert.match(
    dirtyReceiptGoResult.errors.join("\n"),
    /GO cannot rely on a dirty PASS receipt/,
  );

  const blockedGoReceipt = structuredClone(value);
  blockedGoReceipt.status = "BLOCKED";
  blockedGoReceipt.blocker = {
    id: "TEST-BLOCKER",
    owner: "test",
    missing: "required live evidence",
    recovery: "run the required protocol",
  };
  const blockedGoManifest = structuredClone(manifest);
  blockedGoManifest.overallVerdict = "GO";
  blockedGoManifest.gates = REQUIRED_GATE_IDS.map((id) => ({
    id,
    status: id === "local-automated-checks" ? "BLOCKED" : "PASS",
    receipts: ["receipts/local-automated-checks.json"],
  }));
  const blockedGoResult = validateState(blockedGoReceipt, blockedGoManifest);
  assert.equal(blockedGoResult.ok, false);
  assert.match(
    blockedGoResult.errors.join("\n"),
    /GO requires every required gate to be present and PASS/,
  );
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
  const value = physicalPassReceipt();
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, true, result.errors.join("\n"));
}

{
  const value = physicalPassReceipt();
  delete value.device.assetTagSource;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /physical PASS requires device\.assetTagSource/);
}

{
  const value = physicalPassReceipt();
  value.device.manufacturer = "Amazon EC2";
  value.device.model = "HVM domU";
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /physical PASS device identity looks virtualized/);
}

{
  const value = receipt("physical-performance-x64");
  value.device.kind = "physical-windows";
  value.device.architecture = "ARM64";
  value.artifact.architecture = "ARM64";
  value.artifact.availability = "recorded";
  value.artifact.sha256 = "a".repeat(64);
  value.artifact.workflowRunId = "123";
  value.artifact.workflowRunUrl = "https://example.invalid/runs/123";
  value.artifact.signature = {
    result: "verified",
    identity: "test-signing-identity",
  };
  value.evidence.files[0].sha256 = createHash("sha256")
    .update(readFileSync(join(value.root, "observation.log")))
    .digest("hex");
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /requires x64 device architecture/);
  assert.match(result.errors.join("\n"), /requires x64 artifact architecture/);
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

{
  const secret = "certification-secret-canary";
  const sanitized = sanitizeCertificationLog(
    [
      `"access_token": "${secret}"`,
      `'client_secret'='${secret}'`,
      `api_key=${secret}`,
      `Authorization: Bearer ${secret}`,
    ].join("\n"),
  );
  assert.doesNotMatch(sanitized, new RegExp(secret, "g"));
  assert.equal((sanitized.match(/\[REDACTED\]/g) ?? []).length, 4);
  assert.match(sanitized, /"access_token": \[REDACTED\]/);
  assert.match(sanitized, /'client_secret'=\[REDACTED\]/);
}

console.log("PASS: release certification evidence validator tests");
