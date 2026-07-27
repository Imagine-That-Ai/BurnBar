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
  const handlerAcks = [];
  const daemonHealthLog = [];
  const receipts = desktop.performance.ipcHealthRoundTripSamples.map(
    (elapsedMs, index) => {
      const clickEpochMs =
        Date.parse("2026-07-20T11:55:10.000Z") + index * 20_000;
      const handlerStartedEpochMs = clickEpochMs + 1;
      const handlerCompletedEpochMs = clickEpochMs + 50;
      const handlerEventId = `tray-health-${(index + 1)
        .toString(16)
        .padStart(32, "0")}`;
      const daemonHealthRequestId = `health-${
        BigInt(handlerStartedEpochMs) * 1_000_000n + 1n
      }`;
      handlerAcks.push(
        JSON.stringify({
          schemaVersion: 1,
          action: "reconnect-daemon",
          handlerEventId,
          daemonHealthRequestId,
          statusItemLogicalId: "status",
          handlerStartedEpochMs,
          handlerCompletedEpochMs,
          daemonConnected: true,
          statusUpdateSucceeded: true,
          statusLabel: "Daemon: connected - 1.2.3",
        }),
      );
      daemonHealthLog.push(
        `event=rpc_request_received method=daemon.health request_id=${daemonHealthRequestId} protocol_version=1`,
      );
      return JSON.stringify({
        sample: index + 1,
        menuId: 3,
        menuRevisionBefore: 12 + index * 2,
        menuRevisionAfter: 13 + index * 2,
        daemonConnected: true,
        clickEpochMs,
        handlerEventId,
        handlerStartedEpochMs,
        handlerCompletedEpochMs,
        daemonHealthRequestId,
        statusItemLogicalId: "status",
        statusMenuId: 7,
        observedStatusLabel: "Daemon: connected - 1.2.3",
        observedEpochMs: clickEpochMs + elapsedMs,
        elapsedMs,
      });
    },
  );
  write(
    path.join(directory, "tray-reconnect-handler-acks.jsonl"),
    `${handlerAcks.join("\n")}\n`,
  );
  write(
    path.join(directory, "tray-reconnect-daemon-health.log"),
    `${daemonHealthLog.join("\n")}\n`,
  );
  write(
    path.join(directory, "tray-reconnect-receipts.jsonl"),
    `${receipts.join("\n")}\n`,
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
  const trayRuntime = fs.readFileSync(
    path.join(
      WORKTREE,
      "apps/linux-desktop/src-tauri/src/desktop/tray_runtime.rs",
    ),
    "utf8",
  );
  const gateway = fs.readFileSync(
    path.join(WORKTREE, "apps/linux-desktop/src-tauri/src/desktop/gateway.rs"),
    "utf8",
  );
  assert.match(
    source,
    /resolve_menu_action "Reconnect daemon" "\$out_dir\/tray-reconnect-menu-layout-\$\{sample_index\}\.txt"/u,
  );
  assert.match(source, /daemon_health_request_occurrences/u);
  assert.match(
    source,
    /\[\[ "\$after_reconnect_revision" -gt "\$before_reconnect_revision" \]\]/u,
  );
  assert.match(source, /\[\[ "\$status_update_succeeded" == 1 \]\]/u);
  assert.match(source, /\[\[ "\$request_log_occurrences" == 1 \]\]/u);
  assert.match(
    source,
    /\[\[ "\$observed_status_label" == "\$ack_status_label" \]\]/u,
  );
  assert.match(source, /tray-reconnect-handler-acks\.jsonl/u);
  assert.match(source, /read_tray_reconnect_handler_ack/u);
  assert.match(source, /handler_started_epoch_ms/u);
  assert.match(source, /daemon_health_request_id/u);
  assert.match(
    source,
    /observedEpochMs: Number\(process\.env\.OBSERVED_EPOCH_MS\)/u,
  );
  assert.ok(
    source.indexOf(
      'read_menu_state "$out_dir/tray-reconnect-menu-layout-after-${sample_index}.txt"',
    ) < source.indexOf('candidate_observed_epoch_ms="$(date +%s%3N)"'),
  );
  assert.match(source, /clickEpochMs: Number\(process\.env\.CLICK_EPOCH_MS\)/u);
  assert.match(source, /tray-reconnect-daemon-health\.log/u);
  assert.match(source, /tray-reconnect-receipts\.jsonl/u);
  assert.match(trayRuntime, /TrayReconnectHandlerAck/u);
  assert.match(trayRuntime, /record_tray_reconnect_handler_ack/u);
  assert.match(trayRuntime, /status_update_succeeded/u);
  assert.match(trayRuntime, /Daemon: reconnecting\.\.\./u);
  const healthHandler = trayRuntime.slice(
    trayRuntime.indexOf('"health" => {'),
    trayRuntime.indexOf('"quit" =>'),
  );
  assert.match(healthHandler, /set_text\(status_label\.clone\(\)\)/u);
  assert.doesNotMatch(healthHandler, /refresh_tray_status_items/u);
  assert.match(gateway, /probe_daemon_health_with_receipt/u);
  assert.match(gateway, /validated_daemon_health_result/u);
  assert.match(gateway, /Health response id mismatch/u);
  assert.doesNotMatch(source, /correlated_health_request_ids/u);
  assert.doesNotMatch(source, /wait_for_tray_menu_quiescence/u);
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
    [
      "runtime-perf-samples.jsonl",
      (text) => text.replace("packaged-ui-route-after-paint", "route-render"),
    ],
    [
      "linux-desktop-session-report.json",
      (row) => {
        row.performance.appStartSamples[0] = 5000;
      },
    ],
    [
      "tray-reconnect-receipts.jsonl",
      (text) => `${text.split("\n").filter(Boolean).slice(0, 9).join("\n")}\n`,
    ],
    [
      "tray-reconnect-receipts.jsonl",
      (text) =>
        text.replace('"daemonConnected":true', '"daemonConnected":false'),
    ],
    [
      "tray-reconnect-receipts.jsonl",
      (text) =>
        text.replace('"menuRevisionAfter":13', '"menuRevisionAfter":12'),
    ],
    [
      // Increasing revisions are still invalid when either value is negative.
      "tray-reconnect-receipts.jsonl",
      (text) => {
        const lines = text.split("\n").filter(Boolean);
        const first = JSON.parse(lines[0]);
        first.menuRevisionBefore = -2;
        first.menuRevisionAfter = -1;
        lines[0] = JSON.stringify(first);
        return `${lines.join("\n")}\n`;
      },
    ],
    [
      // DBusMenu action IDs are sent as signed int32 values.
      "tray-reconnect-receipts.jsonl",
      (text) => text.replace('"menuId":3', '"menuId":2147483648'),
    ],
    [
      // DBusMenu item zero is the root node, never the reconnect action.
      "tray-reconnect-receipts.jsonl",
      (text) => text.replace('"menuId":3', '"menuId":0'),
    ],
    [
      // DBusMenu revisions are unsigned 32-bit values.
      "tray-reconnect-receipts.jsonl",
      (text) =>
        text.replace(
          '"menuRevisionAfter":13',
          '"menuRevisionAfter":4294967296',
        ),
    ],
    [
      "tray-reconnect-receipts.jsonl",
      (text) => text.replace('"elapsedMs":100', '"elapsedMs":101'),
    ],
    [
      "tray-reconnect-handler-acks.jsonl",
      (text) => `${text.split("\n").filter(Boolean).slice(0, 9).join("\n")}\n`,
    ],
    [
      "tray-reconnect-handler-acks.jsonl",
      (text) =>
        text.replace('"daemonConnected":true', '"daemonConnected":false'),
    ],
    [
      "tray-reconnect-handler-acks.jsonl",
      (text) =>
        text.replace(
          '"statusUpdateSucceeded":true',
          '"statusUpdateSucceeded":false',
        ),
    ],
    [
      "tray-reconnect-handler-acks.jsonl",
      (text) =>
        text.replace(
          '"action":"reconnect-daemon"',
          '"action":"background-refresh"',
        ),
    ],
    [
      // Every handler-scoped request must occur exactly once in the daemon log.
      "tray-reconnect-daemon-health.log",
      (text) => `${text.split("\n").filter(Boolean).slice(1).join("\n")}\n`,
    ],
    [
      "tray-reconnect-daemon-health.log",
      (text) => {
        const lines = text.split("\n").filter(Boolean);
        return `${lines[0]}\n${lines.join("\n")}\n`;
      },
    ],
    [
      // A click stamped outside the native capture window is not this run's.
      "tray-reconnect-receipts.jsonl",
      (text) => {
        const lines = text.split("\n").filter(Boolean);
        const first = JSON.parse(lines[0]);
        first.clickEpochMs = Date.parse("2026-07-20T11:54:00.000Z");
        lines[0] = JSON.stringify(first);
        return `${lines.join("\n")}\n`;
      },
    ],
    [
      // The live DBusMenu label must be the exact label directly applied by
      // the handler, not a later background refresh.
      "tray-reconnect-receipts.jsonl",
      (text) =>
        text.replace(
          '"observedStatusLabel":"Daemon: connected - 1.2.3"',
          '"observedStatusLabel":"Daemon: connected - background"',
        ),
    ],
    [
      // The click-to-observation sample must end after the live menu and log
      // reads, not at handler completion.
      "tray-reconnect-receipts.jsonl",
      (text) => {
        const lines = text.split("\n").filter(Boolean);
        const first = JSON.parse(lines[0]);
        first.observedEpochMs -= 1;
        lines[0] = JSON.stringify(first);
        return `${lines.join("\n")}\n`;
      },
    ],
    [
      // Every sample must observe the same logical status menu item.
      "tray-reconnect-receipts.jsonl",
      (text) => {
        const lines = text.split("\n").filter(Boolean);
        const second = JSON.parse(lines[1]);
        second.statusMenuId += 1;
        lines[1] = JSON.stringify(second);
        return `${lines.join("\n")}\n`;
      },
    ],
  ];
  for (const [name, mutate] of mutations) {
    const value = fixture();
    try {
      const file = path.join(value.input, name);
      if (name.endsWith(".jsonl") || name.endsWith(".log")) {
        const original = fs.readFileSync(file, "utf8");
        const mutated = mutate(original);
        assert.notEqual(
          mutated,
          original,
          `${name} mutation must change bytes`,
        );
        write(file, mutated);
      } else {
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

test("P-32 reconnect validation rejects forged causal and sequencing evidence", () => {
  const mutations = [
    (rows) => {
      const oldId = rows.receipts[0].daemonHealthRequestId;
      const forgedId = `health-${
        BigInt(rows.receipts[0].handlerStartedEpochMs) * 1_000_000n + 2n
      }`;
      rows.receipts[0].daemonHealthRequestId = forgedId;
      rows.acks[0].daemonHealthRequestId = forgedId;
      assert.ok(rows.logs[0].includes(oldId));
    },
    (rows) => {
      const forgedId = `health-${
        BigInt(rows.receipts[0].handlerStartedEpochMs) * 1_000_000n - 1n
      }`;
      const oldId = rows.receipts[0].daemonHealthRequestId;
      rows.receipts[0].daemonHealthRequestId = forgedId;
      rows.acks[0].daemonHealthRequestId = forgedId;
      rows.logs[0] = rows.logs[0].replace(oldId, forgedId);
    },
    (rows) => {
      rows.receipts[1].handlerEventId = rows.receipts[0].handlerEventId;
      rows.acks[1].handlerEventId = rows.acks[0].handlerEventId;
    },
    (rows) => {
      rows.receipts[1].sample = 3;
    },
    (rows) => {
      rows.receipts[1].menuRevisionBefore =
        rows.receipts[0].menuRevisionAfter - 1;
      rows.receipts[1].menuRevisionAfter =
        rows.receipts[0].menuRevisionAfter + 1;
    },
    (rows) => {
      rows.receipts[0].handlerCompletedEpochMs =
        rows.receipts[0].clickEpochMs + rows.receipts[0].elapsedMs + 1;
      rows.acks[0].handlerCompletedEpochMs =
        rows.receipts[0].handlerCompletedEpochMs;
    },
    (rows) => {
      const previous = rows.receipts[0];
      const receipt = rows.receipts[1];
      const ack = rows.acks[1];
      const oldId = receipt.daemonHealthRequestId;
      receipt.clickEpochMs = previous.clickEpochMs + previous.elapsedMs - 1;
      receipt.handlerStartedEpochMs = receipt.clickEpochMs + 1;
      receipt.handlerCompletedEpochMs = receipt.clickEpochMs + 50;
      ack.handlerStartedEpochMs = receipt.handlerStartedEpochMs;
      ack.handlerCompletedEpochMs = receipt.handlerCompletedEpochMs;
      const requestId = `health-${
        BigInt(receipt.handlerStartedEpochMs) * 1_000_000n + 1n
      }`;
      receipt.daemonHealthRequestId = requestId;
      ack.daemonHealthRequestId = requestId;
      rows.logs[1] = rows.logs[1].replace(oldId, requestId);
    },
    (rows) => {
      const receipt = rows.receipts[0];
      const ack = rows.acks[0];
      const oldId = receipt.daemonHealthRequestId;
      receipt.clickEpochMs = Date.parse("2026-07-20T11:54:59.000Z");
      receipt.handlerStartedEpochMs = receipt.clickEpochMs + 1;
      receipt.handlerCompletedEpochMs = receipt.clickEpochMs + 50;
      ack.handlerStartedEpochMs = receipt.handlerStartedEpochMs;
      ack.handlerCompletedEpochMs = receipt.handlerCompletedEpochMs;
      const requestId = `health-${
        BigInt(receipt.handlerStartedEpochMs) * 1_000_000n + 1n
      }`;
      receipt.daemonHealthRequestId = requestId;
      ack.daemonHealthRequestId = requestId;
      rows.logs[0] = rows.logs[0].replace(oldId, requestId);
    },
    (rows) => {
      rows.acks[0].unexpected = true;
    },
  ];

  for (const mutate of mutations) {
    const value = fixture();
    try {
      const receiptsPath = path.join(
        value.input,
        "tray-reconnect-receipts.jsonl",
      );
      const acksPath = path.join(
        value.input,
        "tray-reconnect-handler-acks.jsonl",
      );
      const logPath = path.join(
        value.input,
        "tray-reconnect-daemon-health.log",
      );
      const rows = {
        receipts: fs
          .readFileSync(receiptsPath, "utf8")
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line)),
        acks: fs
          .readFileSync(acksPath, "utf8")
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line)),
        logs: fs.readFileSync(logPath, "utf8").split("\n").filter(Boolean),
      };
      mutate(rows);
      write(
        receiptsPath,
        `${rows.receipts.map((row) => JSON.stringify(row)).join("\n")}\n`,
      );
      write(
        acksPath,
        `${rows.acks.map((row) => JSON.stringify(row)).join("\n")}\n`,
      );
      write(logPath, `${rows.logs.join("\n")}\n`);
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

test("P-32 reconnect validation accepts the zero DBusMenu revision boundary", () => {
  const value = fixture();
  try {
    const receiptPath = path.join(value.input, "tray-reconnect-receipts.jsonl");
    const receipts = fs
      .readFileSync(receiptPath, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    receipts[0].menuRevisionBefore = 0;
    receipts[0].menuRevisionAfter = 1;
    write(
      receiptPath,
      `${receipts.map((row) => JSON.stringify(row)).join("\n")}\n`,
    );
    const reports = Object.fromEntries(
      P32_REPORT_FILES.map((entry) => [
        entry,
        fs.readFileSync(path.join(value.input, entry)),
      ]),
    );
    assert.doesNotThrow(() =>
      validateP32RawReports(reports, BUDGET, binding(value)),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
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
