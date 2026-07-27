import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { captureP32PerformanceProof } from "./capture-p32-performance-proof.mjs";
import {
  MATCHED_PERFORMANCE_SOURCE_FILES,
  compareMatchedPerformance,
  matchedPerformanceSourceDigest,
} from "./lib/matched-performance.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  P32_REPORT_FILES,
  NATIVE_PERFORMANCE_SOURCE_FILES,
  nativePerformanceSourceDigest,
  validateP32Proof,
  validateP32RawReports,
} from "./lib/p32-performance-proof.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { materializeP32PerformanceSession } from "./materialize-p32-performance-session.mjs";
import { validateProductRequirement } from "./product-validators/P-32.mjs";
import { runP32InstalledPerformanceWorkflow } from "./run-p32-installed-performance-workflow.mjs";

const WORKTREE = process.cwd();
const BASE = path.join(WORKTREE, ".tmp/p32-proof-tests");
const BUDGET = JSON.parse(
  fs.readFileSync(
    path.join(WORKTREE, "budgets/linux-desktop.perf.json"),
    "utf8",
  ),
);
const HEAD = "3".repeat(40);
const RUN_ID = "323232";
const DIGEST = `sha256:${"4".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";

function write(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  fs.chmodSync(file, mode);
  return file;
}
function json(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function rehashProvenance(document) {
  const payload = structuredClone(document);
  delete payload.provenance;
  document.provenance.payloadSha256 = hash(
    Buffer.from(JSON.stringify(payload)),
  );
}
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return {
    path: path.relative(root, file).split(path.sep).join("/"),
    sha256: hash(bytes),
  };
}
function report(platform) {
  const profile = BUDGET.matched.profiles.nightly;
  const value = {
    schemaVersion: 1,
    protocolVersion: BUDGET.matched.protocolVersion,
    generatedAt: "2026-07-20T11:49:59.000Z",
    host: {
      platform,
      architecture: platform === "macos" ? "arm64" : "aarch64",
    },
    configuration: structuredClone(profile),
    workloads: BUDGET.matched.expectedWorkloads.map((id, index) => ({
      id,
      unit: "milliseconds",
      sampleCount: profile.samples,
      checksum: 1000 + index,
      percentiles: {
        minimum: 1 + index,
        p50: 2 + index,
        p95: 3 + index,
        p99: 4 + index,
        maximum: 5 + index,
      },
    })),
    soak: {
      requestedSeconds: profile.soakSeconds,
      elapsedSeconds: profile.soakSeconds + 0.5,
      iterations: 100,
      samples: [{ rss: 10 }, { rss: 11 }],
      rssStartBytes: 10_000_000,
      rssEndBytes: 11_000_000,
      rssMaximumBytes: 12_000_000,
      rssGrowthBytes: 1_000_000,
      cpuUtilizationPercent: 50,
    },
    pass: true,
  };
  value.provenance = {
    schemaVersion: 1,
    producer: "openburnbar-matched-performance-v2",
    platform,
    profile: "nightly",
    gitCommit: HEAD,
    packageVersion: VERSION,
    sourceDigest: matchedPerformanceSourceDigest(WORKTREE),
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    startedAt: "2026-07-20T11:20:00.000Z",
    endedAt: "2026-07-20T11:50:01.000Z",
    payloadSha256: "",
  };
  const payload = structuredClone(value);
  delete payload.provenance;
  value.provenance.payloadSha256 = hash(Buffer.from(JSON.stringify(payload)));
  return value;
}
function attestation(root, raw) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  const privatePem = privateKey.export({ type: "pkcs8", format: "pem" });
  const publicPem = publicKey.export({ type: "spki", format: "pem" });
  write(
    path.join(root, "packaging/linux/openburnbar-linux-ed25519.pub.pem"),
    publicPem,
  );
  const item = (installedPath, bytes, mode) => ({
    path: installedPath,
    type: "file",
    sha256: hash(bytes),
    size: bytes.length,
    mode,
    uid: 0,
    gid: 0,
  });
  const manifest = canonicalJsonBytes(
    createInstalledManifest({
      files: [
        item("/usr/bin/openburnbar-daemon", Buffer.from("daemon"), "0755"),
        item(
          "/usr/bin/openburnbar-linux-desktop",
          Buffer.from("desktop"),
          "0755",
        ),
        item(
          "/usr/share/openburnbar/attestation/release-ed25519.pub.pem",
          publicPem,
          "0644",
        ),
      ],
      packageVersion: VERSION,
      gitCommit: HEAD,
      packageArchitecture: "aarch64",
      packageFormat: "deb",
      firebaseAppId: "1:2:web:3",
    }),
  );
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return {
    manifestPath: write(path.join(raw, "installed-manifest.json"), manifest),
    signaturePath: write(
      path.join(raw, "installed-manifest.json.sig"),
      signature,
    ),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function generateReports(directory) {
  const macos = report("macos");
  const linux = report("linux");
  json(path.join(directory, "matched-performance-macos.json"), macos);
  json(path.join(directory, "matched-performance-linux.json"), linux);
  const comparison = compareMatchedPerformance({
    macos,
    linux,
    budget: BUDGET,
    profile: "nightly",
  });
  comparison.runner = "openburnbar-matched-performance-v2";
  comparison.host = { platform: "linux", architecture: "aarch64" };
  comparison.inputs = {
    macos: "matched-performance-macos.json",
    linux: "matched-performance-linux.json",
    budget: "budgets/linux-desktop.perf.json",
  };
  json(path.join(directory, "matched-performance-comparison.json"), comparison);
  const desktop = {
    generatedAt: "2026-07-20T11:59:00.000Z",
    package: { version: VERSION },
    performance: {
      appStartSamples: Array.from({ length: 10 }, (_, index) => 300 + index),
      ipcHealthRoundTripSamples: Array.from(
        { length: 10 },
        (_, index) => 100 + index,
      ),
      trayClickOpenSamples: Array.from(
        { length: 10 },
        (_, index) => 50 + index,
      ),
    },
  };
  desktop.provenance = {
    schemaVersion: 1,
    producer: "openburnbar-linux-desktop-performance-v1",
    gitCommit: HEAD,
    packageVersion: VERSION,
    sourceDigest: nativePerformanceSourceDigest(WORKTREE),
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    startedAt: "2026-07-20T11:55:00.000Z",
    endedAt: desktop.generatedAt,
    payloadSha256: "",
  };
  const desktopPayload = structuredClone(desktop);
  delete desktopPayload.provenance;
  desktop.provenance.payloadSha256 = hash(
    Buffer.from(JSON.stringify(desktopPayload)),
  );
  json(path.join(directory, "linux-desktop-session-report.json"), desktop);
  const routes = Array.from({ length: 19 }, (_, index) =>
    JSON.stringify({
      name: "route.navigation",
      ms: 20 + index,
      source: `packaged-ui-route-after-paint:route-${index}`,
    }),
  );
  write(
    path.join(directory, "runtime-perf-samples.jsonl"),
    `${routes.join("\n")}\n`,
  );
  json(path.join(directory, "packaged-route-session-transcript.json"), {
    routeCount: 19,
  });
  const result = spawnSync(
    process.execPath,
    [path.join(WORKTREE, "scripts/linux-port/run-perf-budget.mjs")],
    {
      cwd: WORKTREE,
      encoding: "utf8",
      env: { ...process.env, OB_EVIDENCE_OUT: directory },
    },
  );
  assert.equal(result.status, 0, result.stderr);
  for (const name of P32_REPORT_FILES)
    fs.chmodSync(path.join(directory, name), 0o600);
}
function binding(value) {
  return {
    repoRoot: value.root,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    manifestSha256: value.identity.manifestSha256,
    manifestSignatureSha256: value.identity.manifestSignatureSha256,
  };
}
function fixture() {
  fs.mkdirSync(BASE, { recursive: true });
  const root = fs.mkdtempSync(path.join(BASE, "fixture-"));
  const input = path.join(root, "source");
  const raw = path.join(root, "collected");
  const installed = path.join(root, "installed");
  const evidence = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-32",
    ENVIRONMENT,
  );
  for (const directory of [input, raw, installed, evidence])
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.chmodSync(input, 0o700);
  fs.chmodSync(raw, 0o700);
  fs.chmodSync(installed, 0o700);
  fs.chmodSync(evidence, 0o700);
  generateReports(input);
  for (const relative of new Set([
    ...MATCHED_PERFORMANCE_SOURCE_FILES,
    ...NATIVE_PERFORMANCE_SOURCE_FILES,
  ])) {
    write(
      path.join(root, relative),
      fs.readFileSync(path.join(WORKTREE, relative)),
    );
  }
  const identity = attestation(root, installed);
  return { root, input, raw, evidence, identity };
}
function build(value) {
  const bound = binding(value);
  const t0 = Date.parse("2026-07-20T12:00:00.000Z");
  runP32InstalledPerformanceWorkflow(
    { ...bound, inputDir: value.input, outputDir: value.raw },
    {
      installedVerifier: () => ({
        contract: { architecture: "aarch64", format: "deb" },
      }),
      resolveHead: () => HEAD,
      now: () => new Date(t0),
      budget: BUDGET,
    },
  );
  const materialized = materializeP32PerformanceSession(
    { ...bound, outputRoot: value.evidence, rawEvidenceDir: value.raw },
    {
      installedVerifier: () => ({}),
      manifestPath: value.identity.manifestPath,
      signaturePath: value.identity.signaturePath,
      now: () => new Date(t0 + 1000),
      budget: BUDGET,
    },
  );
  const captured = captureP32PerformanceProof(
    { ...bound, inputRoot: value.evidence, sessionReport: materialized.output },
    {
      resolveHead: () => HEAD,
      now: () => new Date(t0 + 2000),
      budget: BUDGET,
    },
  );
  return { bound, materialized, captured };
}
function requirementContext(value, result) {
  const aggregateFile = json(
    path.join(value.evidence, "release-subjects/aggregate.json"),
    { passed: true },
  );
  const runtimeFile = json(
    path.join(value.evidence, "release-subjects/runtime.json"),
    { shellVersion: VERSION, daemonVersion: VERSION },
  );
  const environmentFile = json(
    path.join(value.evidence, "release-subjects/environment.json"),
    {
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      architecture: "aarch64",
      passed: true,
    },
  );
  const manifestFile = path.join(value.evidence, "raw/installed-manifest.json");
  const signatureFile = path.join(
    value.evidence,
    "raw/installed-manifest.json.sig",
  );
  const aggregate = record(value.root, aggregateFile);
  const runtime = record(value.root, runtimeFile);
  const environment = record(value.root, environmentFile);
  const manifest = record(value.root, manifestFile);
  const signature = record(value.root, signatureFile);
  const proof = record(value.root, result.captured.output);
  const closure = {
    schemaVersion: 3,
    targetHead: HEAD,
    sourceCommit: HEAD,
    status: "passed",
    requirementId: "P-32",
    environmentId: ENVIRONMENT,
    version: VERSION,
    blockers: [],
    architectures: [...RELEASE_ARCHITECTURES],
    supportEnvironments: [...SUPPORT_ENVIRONMENTS],
    selectedPackage: { architecture: "aarch64", format: "deb" },
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    packageManifestSignature: signature,
    proofs: [
      { role: "aggregate-product-proof-closure", ...aggregate },
      { role: "feature.performance-installed", ...proof },
    ],
  };
  return {
    schemaVersion: 1,
    repoRoot: value.root,
    requirementId: "P-32",
    checkId: "p-32.performance",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: { document: closure },
    subjects: {
      release: aggregate,
      packageManifest: manifest,
      packages: [manifest],
      runtimes: [runtime],
      installation: [],
      environment,
    },
  };
}

test("P-32 validates and builds exact installed nightly performance proof", () => {
  const value = fixture();
  try {
    const result = build(value);
    assert.equal(result.captured.document.passed, true);
    assert.equal(result.captured.document.soakSeconds, 1800);
    assert.equal(result.captured.document.nativeMetricCount, 4);
    assert.equal(result.captured.document.matchedWorkloadCount, 4);
    validateP32Proof({
      ...result.bound,
      budget: BUDGET,
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, result.captured.output),
        "P-32 proof",
      ),
    });
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-32 product validator accepts the realistic release-closure context", async () => {
  const value = fixture();
  try {
    const result = build(value);
    const verdict = await validateProductRequirement(
      requirementContext(value, result),
    );
    assert.equal(verdict.status, "passed");
    assert.ok(
      verdict.artifacts.some((artifact) =>
        artifact.path.endsWith("p32-installed-performance-proof.json"),
      ),
    );
    assert.ok(
      verdict.artifacts.some((artifact) =>
        artifact.path.endsWith("runtime-perf-samples.jsonl"),
      ),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-32 native packaged-session producer emits candidate provenance before collection", () => {
  const source = fs.readFileSync(
    path.join(WORKTREE, "scripts/linux-port/linux-desktop-session.sh"),
    "utf8",
  );
  for (const marker of [
    "OB_PERFORMANCE_TARGET_HEAD",
    "OB_PERFORMANCE_SOURCE_DIGEST",
    "OB_PERFORMANCE_CAPTURE_STARTED_AT",
    "OB_CANDIDATE_RUN_ID",
    "OB_CANDIDATE_ARTIFACT_DIGEST",
    "nativePerformanceSourceDigest",
    "openburnbar-linux-desktop-performance-v1",
    "payloadSha256",
  ]) {
    assert.match(source, new RegExp(marker), marker);
  }
  assert.ok(
    source.indexOf("report.generatedAt = new Date().toISOString()") <
      source.indexOf("openburnbar-linux-desktop-performance-v1"),
  );
});

test("P-32 reconnect samples resolve live tray actions and require exact healthy receipts", () => {
  const source = fs.readFileSync(
    path.join(WORKTREE, "scripts/linux-port/linux-desktop-session.sh"),
    "utf8",
  );
  assert.match(
    source,
    /resolve_menu_action "Reconnect daemon" "\$out_dir\/tray-reconnect-menu-layout-\$\{sample_index\}\.txt"/u,
  );
  assert.match(
    source,
    /event=rpc_request_received method=daemon\.health /u,
  );
  assert.match(source, /printf '%s\\n' "\$\{count:-0\}"/u);
  assert.match(
    source,
    /\[\[ "\$after_reconnect_revision" -gt "\$before_reconnect_revision" \]\]/u,
  );
  assert.match(source, /\[\[ "\$daemon_connected" == 1 \]\]/u);
  assert.match(source, /tray-reconnect-receipts\.jsonl/u);
  assert.doesNotMatch(source, /before_reconnect_lines/u);
  assert.doesNotMatch(
    source,
    /wc -l <"\$daemon_log"/u,
    "unrelated daemon log traffic must not satisfy the reconnect proof",
  );
});

test("P-32 raw validation rejects shortened soak, architecture, checksum, source, and sample mutations", () => {
  const mutations = [
    [
      "matched-performance-macos.json",
      (row) => {
        row.soak.requestedSeconds = 60;
      },
    ],
    [
      "matched-performance-linux.json",
      (row) => {
        row.host.architecture = "x86_64";
      },
    ],
    [
      "matched-performance-linux.json",
      (row) => {
        row.workloads[0].checksum += 1;
      },
    ],
    ["runtime-perf-samples.jsonl", null],
    [
      "linux-desktop-session-report.json",
      (row) => {
        row.performance.appStartSamples[0] = 5000;
      },
    ],
  ];
  for (const [name, mutate] of mutations) {
    const value = fixture();
    try {
      const file = path.join(value.input, name);
      if (name.endsWith(".jsonl"))
        write(
          file,
          fs
            .readFileSync(file, "utf8")
            .replace("packaged-ui-route-after-paint", "route-render"),
        );
      else {
        const row = JSON.parse(fs.readFileSync(file));
        mutate(row);
        json(file, row);
      }
      const reports = Object.fromEntries(
        P32_REPORT_FILES.map((entry) => [
          entry,
          fs.readFileSync(path.join(value.input, entry)),
        ]),
      );
      assert.throws(() =>
        validateP32RawReports(reports, BUDGET, binding(value)),
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-32 rejects relabeled matched and native candidate provenance", () => {
  const mutations = [
    [
      "matched-performance-macos.json",
      (row) => {
        row.provenance.gitCommit = "9".repeat(40);
      },
    ],
    [
      "matched-performance-linux.json",
      (row) => {
        row.provenance.packageVersion = "9.9.9";
      },
    ],
    [
      "matched-performance-macos.json",
      (row) => {
        row.provenance.candidate.runId = "99";
      },
    ],
    [
      "matched-performance-linux.json",
      (row) => {
        row.provenance.sourceDigest = "8".repeat(64);
      },
    ],
    [
      "matched-performance-macos.json",
      (row) => {
        row.provenance.endedAt = row.provenance.startedAt;
      },
    ],
    [
      "linux-desktop-session-report.json",
      (row) => {
        row.provenance.gitCommit = "7".repeat(40);
      },
    ],
    [
      "linux-desktop-session-report.json",
      (row) => {
        row.provenance.packageVersion = "8.8.8";
      },
    ],
    [
      "linux-desktop-session-report.json",
      (row) => {
        row.provenance.candidate.artifactDigest = `sha256:${"6".repeat(64)}`;
      },
    ],
    [
      "linux-desktop-session-report.json",
      (row) => {
        row.provenance.sourceDigest = "5".repeat(64);
      },
    ],
  ];
  for (const [name, mutate] of mutations) {
    const value = fixture();
    try {
      const file = path.join(value.input, name);
      const document = JSON.parse(fs.readFileSync(file, "utf8"));
      mutate(document);
      rehashProvenance(document);
      json(file, document);
      const reports = Object.fromEntries(
        P32_REPORT_FILES.map((entry) => [
          entry,
          fs.readFileSync(path.join(value.input, entry)),
        ]),
      );
      assert.throws(
        () => validateP32RawReports(reports, BUDGET, binding(value)),
        /provenance|nightly soak/u,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-32 runner rejects old candidate reports before relabeling them", () => {
  const value = fixture();
  try {
    assert.throws(
      () =>
        runP32InstalledPerformanceWorkflow(
          {
            ...binding(value),
            inputDir: value.input,
            outputDir: value.raw,
          },
          {
            installedVerifier: () => ({
              contract: { architecture: "aarch64", format: "deb" },
            }),
            resolveHead: () => HEAD,
            now: () => new Date("2026-07-20T15:00:00.000Z"),
            budget: BUDGET,
          },
        ),
      /stale|bounded/u,
    );
    assert.deepEqual(fs.readdirSync(value.raw), []);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-32 receipt and proof hashes fail closed after mutation", () => {
  const value = fixture();
  try {
    const result = build(value);
    const copied = path.join(value.evidence, "raw/runtime-perf-samples.jsonl");
    fs.appendFileSync(copied, "{}\n");
    assert.throws(
      () =>
        validateP32Proof({
          ...result.bound,
          budget: BUDGET,
          snapshot: readRegularSnapshot(
            value.root,
            path.relative(value.root, result.captured.output),
            "P-32 proof",
          ),
        }),
      /changed|match/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-32 runner and materializer reject reused, symlinked, and escaped paths", () => {
  const value = fixture();
  const outside = fs.mkdtempSync(path.join(BASE, "outside-"));
  fs.chmodSync(outside, 0o700);
  try {
    const bound = binding(value);
    write(path.join(value.raw, "occupied"), "x");
    assert.throws(
      () =>
        runP32InstalledPerformanceWorkflow(
          { ...bound, inputDir: value.input, outputDir: value.raw },
          {
            installedVerifier: () => ({
              contract: { architecture: "aarch64", format: "deb" },
            }),
            resolveHead: () => HEAD,
            budget: BUDGET,
          },
        ),
      /empty/u,
    );
    fs.rmSync(path.join(value.raw, "occupied"));
    const linked = path.join(value.root, "linked-input");
    fs.symlinkSync(value.input, linked);
    assert.throws(
      () =>
        runP32InstalledPerformanceWorkflow(
          { ...bound, inputDir: linked, outputDir: value.raw },
          { installedVerifier: () => ({}), resolveHead: () => HEAD },
        ),
      /canonical/u,
    );
    assert.throws(
      () =>
        materializeP32PerformanceSession(
          { ...bound, outputRoot: outside, rawEvidenceDir: value.raw },
          {
            installedVerifier: () => ({}),
            manifestPath: value.identity.manifestPath,
            signaturePath: value.identity.signaturePath,
            budget: BUDGET,
          },
        ),
      /confined/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
  }
});
