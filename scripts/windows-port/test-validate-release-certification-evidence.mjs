#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  BUNDLE_SCHEMA,
  CERTIFICATION_PROTOCOL_CATALOG,
  CERTIFICATION_PROTOCOL_SCHEMA,
  HARDWARE_ATTESTATION_SCHEMA,
  RECEIPT_SCHEMA,
  REQUIRED_GATE_IDS,
  certificationProtocolForGate,
  parseArgs,
  validateCertificationProtocolCatalog,
  validateReceipt,
  validateReleaseCertificationBundle,
  writeSha256Sums,
} from "./validate-release-certification-evidence.mjs";
import { sanitizeCertificationLog } from "./certification-log-sanitizer.mjs";
import {
  PERFORMANCE_BUDGET_CATALOG,
  PERFORMANCE_BUDGET_SCHEMA,
  PERFORMANCE_BUDGET_SHA256,
  PERFORMANCE_BUDGET_STATUS,
  derivePerformanceValue,
  performanceContextTemplate,
  performanceMeasurementTemplate,
  validatePerformanceBudgetCatalog,
} from "./release-performance-budget.mjs";

const COMMIT = "0123456789abcdef0123456789abcdef01234567";
const HARNESS_COMMIT = "89abcdef0123456789abcdef0123456789abcdef";

assert.deepEqual(
  parseArgs([
    "--expected-commit",
    COMMIT.toUpperCase(),
    "--expected-harness-commit",
    HARNESS_COMMIT.toUpperCase(),
    "evidence",
  ]),
  {
    bundleDir: "evidence",
    writeSums: false,
    expectedCommit: COMMIT,
    expectedHarnessCommit: HARNESS_COMMIT,
  },
);
assert.throws(
  () => parseArgs(["--expected-harness-commit", "evidence"]),
  /requires a full 40-character Git SHA/,
);
assert.throws(
  () => parseArgs(["--expected-commit", "--write-sums", "evidence"]),
  /requires a full 40-character Git SHA/,
);
assert.throws(() => parseArgs(["--unknown", "evidence"]), /unknown argument/);

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
    source: {
      commitSha: COMMIT,
      dirtyTree: false,
      harness: { commitSha: HARNESS_COMMIT, dirtyTree: false },
    },
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
  const attestation = {
    schema: HARDWARE_ATTESTATION_SCHEMA,
    operator: "Alberto",
    physicalHardware: true,
    architecture: "x64",
    manufacturer: "HP",
    model: "ENVY x360 15-ew0xxx",
    assetTag: "5CD1234567",
    assetTagSource: "Win32_ComputerSystemProduct.IdentifyingNumber",
    capturedAtUtc: "2026-07-11T00:00:00Z",
  };
  const attestationPath = join(value.root, "hardware-attestation.json");
  writeJson(attestationPath, attestation);
  const attestationHash = createHash("sha256").update(readFileSync(attestationPath)).digest("hex");
  value.device = {
    kind: "physical-windows",
    manufacturer: "HP",
    model: "ENVY x360 15-ew0xxx",
    assetTag: "5CD1234567",
    assetTagSource: "Win32_ComputerSystemProduct.IdentifyingNumber",
    architecture: "x64",
    osBuild: "Windows 11 10.0.26100",
    tpm: "present-ready-enabled-activated-owned",
    hardwareAttestation: {
      schema: HARDWARE_ATTESTATION_SCHEMA,
      operator: "Alberto",
      assetTag: "5CD1234567",
      assetTagSource: "Win32_ComputerSystemProduct.IdentifyingNumber",
      evidencePath: "hardware-attestation.json",
      sha256: attestationHash,
    },
  };
  value.artifact = {
    name: "OpenBurnBar-1.0.30-x64.msix",
    architecture: "x64",
    availability: "recorded",
    sourceCommit: COMMIT,
    sha256: "a".repeat(64),
    workflowRunId: "123",
    workflowRunUrl: "https://example.invalid/runs/123",
    signature: { result: "verified", identity: "Imagine That AI LLC" },
  };
  value.evidence.files[0].sha256 = createHash("sha256")
    .update(readFileSync(join(value.root, "observation.log")))
    .digest("hex");
  value.evidence.files.push({ path: "hardware-attestation.json", sha256: attestationHash });
  const protocol = certificationProtocolForGate(gate);
  assert.ok(protocol, `missing test protocol for ${gate}`);
  value.protocol = {
    commands: [`execute ${gate} protocol`],
    manualSteps: ["Review every assertion against its raw evidence."],
    profileSchema: CERTIFICATION_PROTOCOL_SCHEMA,
    profile: protocol.profileName,
    assertions: protocol.profile.assertions.map((assertion) => ({
      id: assertion.id,
      status: "PASS",
      observed: `${assertion.id} passed on the physical test device.`,
      evidence: ["observation.log"],
    })),
  };
  value.time = {
    startedAtUtc: "2026-07-11T00:00:00Z",
    endedAtUtc: "2026-07-11T01:00:00Z",
    durationSeconds: 3600,
  };
  value.protocol.performanceBudget = {
    schema: PERFORMANCE_BUDGET_SCHEMA,
    status: PERFORMANCE_BUDGET_STATUS,
    revision: PERFORMANCE_BUDGET_CATALOG.revision,
    sha256: PERFORMANCE_BUDGET_SHA256,
  };
  value.protocol.performanceContext = Object.fromEntries(
    Object.keys(performanceContextTemplate()).map((field) => [
      field,
      `${field} recorded for the physical test workload.`,
    ]),
  );
  value.protocol.performanceMeasurements = performanceMeasurementTemplate().map((measurement) => {
    let samples = Array(measurement.minimumSamples).fill(measurement.limit);
    if (measurement.statistic === "rate") {
      samples = Array(measurement.minimumSamples).fill(0);
      for (let index = 0; index < Math.round(measurement.minimumSamples * measurement.limit / 100); index += 1) {
        samples[index] = 1;
      }
    } else if (measurement.statistic === "growth") {
      samples = [100, 100 + measurement.limit];
    } else if (measurement.statistic === "count") {
      samples = Array(measurement.minimumSamples).fill(0);
    }
    return {
      ...measurement,
      value: derivePerformanceValue(samples, measurement.statistic),
      sampleCount: samples.length,
      samples,
      durationSeconds: measurement.minimumDurationSeconds,
      context: "Windows Performance Recorder 11; AC power; balanced mode; declared fixture dataset.",
      evidence: ["observation.log"],
    };
  });
  return value;
}

{
  assert.deepEqual(validatePerformanceBudgetCatalog(), []);
  assert.equal(PERFORMANCE_BUDGET_CATALOG.status, "ACTIVE_RELEASE_GATE");
  assert.ok(PERFORMANCE_BUDGET_CATALOG.measurements.length >= 15);
}

{
  assert.deepEqual(validateCertificationProtocolCatalog(), []);
  for (const gate of REQUIRED_GATE_IDS.slice(1)) {
    const protocol = certificationProtocolForGate(gate);
    assert.ok(protocol, `required gate ${gate} must have a protocol`);
    assert.ok(protocol.profile.assertions.length > 0);
    assert.equal(
      new Set(protocol.profile.assertions.map((assertion) => assertion.id)).size,
      protocol.profile.assertions.length,
      `${gate} assertion ids must be unique`,
    );
  }
}

{
  const catalog = structuredClone(CERTIFICATION_PROTOCOL_CATALOG);
  catalog.profiles["physical-performance"].assertions.push(
    structuredClone(catalog.profiles["physical-performance"].assertions[0]),
  );
  assert.match(
    validateCertificationProtocolCatalog(catalog).join("\n"),
    /duplicate assertion/,
  );
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
    source: structuredClone(value.source),
    artifact: structuredClone(value.artifact),
    overallVerdict: "NO-GO",
    receipts: [{ path: "receipts/local-automated-checks.json", sha256: receiptHash }],
    gates: [{ id: "local-automated-checks", status: "PASS", receipts: ["receipts/local-automated-checks.json"] }],
  };
  writeJson(join(bundleDir, "certification-manifest.json"), manifest);
  writeSha256Sums(bundleDir);
  const result = validateReleaseCertificationBundle(bundleDir, {
    expectedCommit: COMMIT,
    expectedHarnessCommit: HARNESS_COMMIT,
    requireAllGates: false,
  });
  assert.equal(result.ok, true, result.errors.join("\n"));

  const wrongExpectedHarness = validateReleaseCertificationBundle(bundleDir, {
    expectedCommit: COMMIT,
    expectedHarnessCommit: "f".repeat(40),
    requireAllGates: false,
  });
  assert.equal(wrongExpectedHarness.ok, false);
  assert.match(
    wrongExpectedHarness.errors.join("\n"),
    /bundle: harness commit mismatch/,
  );

  const missingSourceManifest = structuredClone(manifest);
  delete missingSourceManifest.source;
  writeJson(join(bundleDir, "certification-manifest.json"), missingSourceManifest);
  writeSha256Sums(bundleDir);
  const missingSourceResult = validateReleaseCertificationBundle(bundleDir, {
    expectedCommit: COMMIT,
    expectedHarnessCommit: HARNESS_COMMIT,
    requireAllGates: false,
  });
  assert.equal(missingSourceResult.ok, false);
  assert.match(missingSourceResult.errors.join("\n"), /bundle: source is required/);
  assert.match(missingSourceResult.errors.join("\n"), /bundle: commit mismatch/);
  assert.match(missingSourceResult.errors.join("\n"), /bundle: harness commit mismatch/);
  writeJson(join(bundleDir, "certification-manifest.json"), manifest);
  writeSha256Sums(bundleDir);

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

  const wrongHarnessReceipt = structuredClone(value);
  wrongHarnessReceipt.source.harness.commitSha = "a".repeat(40);
  const wrongHarnessResult = validateState(
    wrongHarnessReceipt,
    structuredClone(manifest),
  );
  assert.equal(wrongHarnessResult.ok, false);
  assert.match(
    wrongHarnessResult.errors.join("\n"),
    /receipt harness does not match bundle source harness/,
  );

  const wrongArtifactManifest = structuredClone(manifest);
  wrongArtifactManifest.artifact.sha256 = "f".repeat(64);
  const wrongArtifactResult = validateState(value, wrongArtifactManifest);
  assert.equal(wrongArtifactResult.ok, false);
  assert.match(
    wrongArtifactResult.errors.join("\n"),
    /receipt artifact does not match bundle artifact/,
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

  const dirtyHarnessGoManifest = structuredClone(falseGoManifest);
  dirtyHarnessGoManifest.source.harness.dirtyTree = true;
  const dirtyHarnessGoResult = validateState(value, dirtyHarnessGoManifest);
  assert.equal(dirtyHarnessGoResult.ok, false);
  assert.match(
    dirtyHarnessGoResult.errors.join("\n"),
    /GO requires a clean certification harness/,
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
  delete value.protocol.performanceBudget;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /requires protocol\.performanceBudget/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceBudget.sha256 = "0".repeat(64);
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /performanceBudget\.sha256 does not match/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceContext.sampling = "";
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /performanceContext\.sampling is required/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceMeasurements.shift();
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /cold-start-p95 is missing/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceMeasurements[0].value =
    value.protocol.performanceMeasurements[0].limit + 0.001;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /violates at_most/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceMeasurements[0].sampleCount =
    value.protocol.performanceMeasurements[0].minimumSamples - 1;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /sampleCount must be at least/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceMeasurements[0].samples.fill(0);
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /does not match the independently derived value/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceMeasurements[0].samples[0] = -1;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /samples must be non-negative/);
}

{
  const value = physicalPassReceipt();
  const measurement = value.protocol.performanceMeasurements[0];
  measurement.samples = Array(PERFORMANCE_BUDGET_CATALOG.maximumSamplesPerMeasurement + 1).fill(0);
  measurement.sampleCount = measurement.samples.length;
  measurement.value = 0;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /samples exceeds 100000/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceMeasurements[0].evidence = ["missing-performance.csv"];
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /evidence reference is not present/);
}

{
  const value = physicalPassReceipt();
  value.protocol.performanceMeasurements.find((measurement) => measurement.id === "soak-crashes")
    .durationSeconds = 3602;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /durationSeconds exceeds the receipt interval/);
}

{
  const value = physicalPassReceipt();
  delete value.source.harness;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /source\.harness is required/);
}

{
  const value = physicalPassReceipt();
  value.protocol.assertions = [];
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /required protocol assertion is missing/);
}

{
  const value = physicalPassReceipt();
  value.artifact.sourceCommit = "b".repeat(40);
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /artifact\.sourceCommit does not match/);
}

{
  const value = physicalPassReceipt();
  value.device.assetTag = "Chassis Asset Tag";
  value.device.hardwareAttestation.assetTag = value.device.assetTag;
  const attestationPath = join(value.root, "hardware-attestation.json");
  const attestation = JSON.parse(readFileSync(attestationPath, "utf8"));
  attestation.assetTag = value.device.assetTag;
  writeJson(attestationPath, attestation);
  const attestationHash = createHash("sha256")
    .update(readFileSync(attestationPath))
    .digest("hex");
  value.device.hardwareAttestation.sha256 = attestationHash;
  value.evidence.files.find((file) => file.path === "hardware-attestation.json").sha256 =
    attestationHash;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /requires a usable device\.assetTag/);
}

{
  const value = physicalPassReceipt();
  value.protocol.profileSchema = "openburnbar.windows.release-certification-protocols.invalid";
  value.protocol.profile = "invalid-profile";
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /protocol\.profileSchema/);
  assert.match(result.errors.join("\n"), /protocol\.profile/);
}

{
  const value = physicalPassReceipt();
  value.protocol.assertions[0].status = "FAIL";
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /status must be PASS/);
}

{
  const value = physicalPassReceipt();
  value.protocol.assertions.push({
    id: "not-in-the-canonical-protocol",
    status: "PASS",
    observed: "This assertion must not be accepted.",
    evidence: ["observation.log"],
  });
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /unknown protocol assertion/);
}

{
  const value = physicalPassReceipt();
  value.protocol.assertions[0].evidence = ["missing-evidence.log"];
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /evidence reference is not present/);
}

{
  const value = physicalPassReceipt();
  value.evidence.files.push({ ...value.evidence.files[0] });
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /duplicate evidence path/);
}

{
  const value = physicalPassReceipt();
  delete value.device.hardwareAttestation;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /physical PASS requires device\.hardwareAttestation/);
}

{
  const value = physicalPassReceipt();
  value.evidence.files = value.evidence.files.filter((file) => file.path !== "hardware-attestation.json");
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /must reference exactly one evidence\.files entry/);
}

{
  const value = physicalPassReceipt();
  value.device.hardwareAttestation.sha256 = "b".repeat(64);
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /evidence hash does not match device metadata/);
}

{
  const value = physicalPassReceipt();
  const path = join(value.root, "hardware-attestation.json");
  const attestation = JSON.parse(readFileSync(path, "utf8"));
  attestation.assetTag = "different-device";
  writeJson(path, attestation);
  const hash = createHash("sha256").update(readFileSync(path)).digest("hex");
  value.device.hardwareAttestation.sha256 = hash;
  value.evidence.files.find((file) => file.path === "hardware-attestation.json").sha256 = hash;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /hardware attestation\.assetTag does not match device\.assetTag/);
}

{
  const value = physicalPassReceipt();
  const path = join(value.root, "hardware-attestation.json");
  const attestation = JSON.parse(readFileSync(path, "utf8"));
  attestation.manufacturer = "Amazon EC2";
  attestation.model = "HVM domU";
  writeJson(path, attestation);
  const hash = createHash("sha256").update(readFileSync(path)).digest("hex");
  value.device.hardwareAttestation.sha256 = hash;
  value.evidence.files.find((file) => file.path === "hardware-attestation.json").sha256 = hash;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /hardware attestation identity looks virtualized/);
}

{
  const value = physicalPassReceipt();
  const path = join(value.root, "hardware-attestation.json");
  const attestation = JSON.parse(readFileSync(path, "utf8"));
  attestation.capturedAtUtc = "2026-07-01T00:00:00Z";
  writeJson(path, attestation);
  const hash = createHash("sha256").update(readFileSync(path)).digest("hex");
  value.device.hardwareAttestation.sha256 = hash;
  value.evidence.files.find((file) => file.path === "hardware-attestation.json").sha256 = hash;
  const result = validateReceipt(value, { bundleDir: value.root });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /outside the allowed receipt time window/);
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
