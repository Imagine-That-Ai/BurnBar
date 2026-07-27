import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  DIGEST_PATTERN,
  HEAD_PATTERN,
  RUN_ID_PATTERN,
  SHA256_PATTERN,
  VERSION_PATTERN,
  INSTALLED_UI_ENVIRONMENTS,
  exactKeys,
  parseJson,
  validateArtifact,
} from "./installed-ui-proof.mjs";
import {
  compareMatchedPerformance,
  matchedPerformanceSourceDigest,
} from "./matched-performance.mjs";
import {
  RELEASE_PUBLIC_KEY_PATH,
  assertInstalledManifest,
} from "./linux-installed-manifest.mjs";
import { readRegularSnapshot } from "./product-proof-closure.mjs";

export const P32_REQUIREMENT_ID = "P-32";
export const P32_PROOF_ROLE = "feature.performance-installed";
export const P32_PROOF_FILENAME = "p32-installed-performance-proof.json";
export const P32_SESSION_FILENAME = "p32-installed-performance-session.json";
export const P32_REPORT_FILES = Object.freeze([
  "linux-desktop-session-report.json",
  "runtime-perf-samples.jsonl",
  "tray-reconnect-handler-acks.jsonl",
  "tray-reconnect-daemon-health.log",
  "tray-reconnect-receipts.jsonl",
  "packaged-route-session-transcript.json",
  "matched-performance-macos.json",
  "matched-performance-linux.json",
  "matched-performance-comparison.json",
  "perf-budget.json",
  "perf-threshold-enforcement.json",
  "macos-perf-comparison.json",
]);
export const P32_RAW_FILES = Object.freeze([
  ...P32_REPORT_FILES,
  "p32-native-performance-receipt.json",
]);

const EXPECTED_METRICS = Object.freeze([
  "app.start",
  "route.navigation",
  "ipc.health.roundtrip",
  "tray.click.open",
]);
export const NATIVE_PERFORMANCE_SOURCE_FILES = Object.freeze([
  "apps/linux-desktop/src-tauri/src/desktop/gateway.rs",
  "apps/linux-desktop/src-tauri/src/desktop/tray_runtime.rs",
  "budgets/linux-desktop.perf.json",
  "scripts/linux-port/linux-desktop-session.sh",
  "scripts/linux-port/lib/p32-performance-proof.mjs",
  "scripts/linux-port/run-perf-budget.mjs",
]);
export function nativePerformanceSourceDigest(root) {
  const digest = crypto.createHash("sha256");
  for (const relative of NATIVE_PERFORMANCE_SOURCE_FILES) {
    digest.update(relative);
    digest.update("\0");
    digest.update(fs.readFileSync(path.join(root, relative)));
    digest.update("\0");
  }
  return digest.digest("hex");
}
const METRIC_SOURCES = Object.freeze({
  "app.start": "packaged-tauri-deb-process-launch-to-x11-window-visible",
  "route.navigation":
    "packaged-tauri-command-palette-route-to-two-animation-frames",
  "ipc.health.roundtrip": "packaged-tray-reconnect-to-af-unix-daemon-activity",
  "tray.click.open": "appindicator-dbusmenu-open-to-visible-x11-window",
});

function fail(message) {
  throw new Error(message);
}
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function same(left, right, label) {
  if (JSON.stringify(left) !== JSON.stringify(right))
    fail(`${label} does not match recomputed raw evidence`);
}
function finite(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0)
    fail(`${label} must be finite and non-negative`);
  return value;
}
function percentile(sorted, quantile) {
  const position = quantile * (sorted.length - 1);
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  return lower === upper
    ? sorted[lower]
    : sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}
function summarize(values, label) {
  if (!Array.isArray(values) || values.length === 0)
    fail(`${label} has no raw samples`);
  const sorted = values
    .map((value, index) => finite(value, `${label} sample ${index}`))
    .sort((a, b) => a - b);
  return {
    minimum: sorted[0],
    p50: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    p99: percentile(sorted, 0.99),
    maximum: sorted.at(-1),
  };
}
function normalizedArchitecture(value) {
  if (value === "arm64" || value === "aarch64") return "aarch64";
  if (value === "x64" || value === "amd64" || value === "x86_64")
    return "x86_64";
  return value;
}
function comparableMatched(value) {
  const copy = structuredClone(value);
  delete copy.generatedAt;
  delete copy.runner;
  delete copy.host;
  delete copy.inputs;
  return copy;
}
function parseJsonLines(bytes, label) {
  const lines = Buffer.from(bytes)
    .toString("utf8")
    .split(/\n/u)
    .filter(Boolean);
  if (lines.length === 0) fail(`${label} is empty`);
  return lines.map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      fail(`${label} line ${index + 1} is invalid JSON: ${error.message}`);
    }
  });
}
function basenames(value) {
  return path.posix.basename(String(value ?? ""));
}

export function validateP32RawReports(reports, budget, binding) {
  exactKeys(reports, P32_REPORT_FILES, "P-32 raw reports");
  if (budget?.schemaVersion !== 2)
    fail("P-32 performance budget schema must be 2");
  const nightly = budget?.matched?.profiles?.nightly;
  if (!nightly || nightly.soakSeconds < 1800)
    fail(
      "P-32 requires the full nightly profile with at least 1800 seconds of soak",
    );
  if (
    JSON.stringify(budget.nativeShell?.requiredMetrics) !==
    JSON.stringify(EXPECTED_METRICS)
  ) {
    fail("P-32 native metric set changed");
  }

  const macos = parseJson(
    reports["matched-performance-macos.json"],
    "P-32 macOS matched report",
  );
  const linux = parseJson(
    reports["matched-performance-linux.json"],
    "P-32 Linux matched report",
  );
  const comparison = parseJson(
    reports["matched-performance-comparison.json"],
    "P-32 matched comparison",
  );
  const desktop = parseJson(
    reports["linux-desktop-session-report.json"],
    "P-32 desktop report",
  );
  const routeTranscript = parseJson(
    reports["packaged-route-session-transcript.json"],
    "P-32 route transcript",
  );
  const runtime = parseJsonLines(
    reports["runtime-perf-samples.jsonl"],
    "P-32 runtime samples",
  );
  const reconnectReceipts = parseJsonLines(
    reports["tray-reconnect-receipts.jsonl"],
    "P-32 tray reconnect receipts",
  );
  const reconnectHandlerAcks = parseJsonLines(
    reports["tray-reconnect-handler-acks.jsonl"],
    "P-32 tray reconnect handler acknowledgements",
  );
  const daemonHealthLines = Buffer.from(
    reports["tray-reconnect-daemon-health.log"],
  )
    .toString("utf8")
    .split(/\n/u)
    .filter((line) =>
      line.includes("event=rpc_request_received method=daemon.health "),
    );
  const perf = parseJson(
    reports["perf-budget.json"],
    "P-32 performance report",
  );
  const trend = parseJson(
    reports["perf-threshold-enforcement.json"],
    "P-32 threshold report",
  );
  const macosCrossLink = parseJson(
    reports["macos-perf-comparison.json"],
    "P-32 macOS cross-link",
  );
  if (!binding?.repoRoot)
    fail("P-32 raw validation requires candidate binding");
  const expectedProvenance = {
    gitCommit: binding.targetHead,
    packageVersion: binding.packageVersion,
    sourceDigest:
      binding.matchedSourceDigest ??
      matchedPerformanceSourceDigest(binding.repoRoot),
    candidateRunId: String(binding.candidateRunId),
    candidateArtifactDigest: binding.candidateArtifactDigest,
  };

  for (const [platform, report] of [
    ["macos", macos],
    ["linux", linux],
  ]) {
    if (
      report.host?.platform !== platform ||
      report.configuration?.soakSeconds < 1800 ||
      report.soak?.requestedSeconds < 1800 ||
      report.soak?.elapsedSeconds < report.soak.requestedSeconds * 0.95 ||
      Date.parse(report.provenance?.endedAt) -
        Date.parse(report.provenance?.startedAt) <
        report.soak.requestedSeconds * 0.95 * 1000
    ) {
      fail(`P-32 ${platform} report is not a full nightly soak`);
    }
  }
  const architecture = normalizedArchitecture(macos.host?.architecture);
  if (
    !architecture ||
    architecture !== normalizedArchitecture(linux.host?.architecture)
  ) {
    fail("P-32 matched reports must use the same normalized architecture");
  }
  const recomputed = compareMatchedPerformance({
    macos,
    linux,
    budget,
    profile: "nightly",
    expectedProvenance,
  });
  if (!recomputed.pass)
    fail(
      `P-32 recomputed matched comparison failed: ${recomputed.errors.join("; ")}`,
    );
  same(
    comparableMatched(comparison),
    comparableMatched(recomputed),
    "P-32 matched comparison",
  );
  if (
    comparison.runner !== "openburnbar-matched-performance-v2" ||
    comparison.profile !== "nightly" ||
    comparison.pass !== true ||
    comparison.errors?.length !== 0
  ) {
    fail("P-32 matched comparison is not a clean nightly pass");
  }
  if (
    basenames(comparison.inputs?.macos) !== "matched-performance-macos.json" ||
    basenames(comparison.inputs?.linux) !== "matched-performance-linux.json" ||
    basenames(comparison.inputs?.budget) !== "linux-desktop.perf.json"
  ) {
    fail(
      "P-32 matched comparison does not cross-link the exact raw inputs and budget",
    );
  }

  const routeRows = runtime.filter((row) => row?.name === "route.navigation");
  if (
    routeRows.some(
      (row) =>
        typeof row.source !== "string" ||
        !row.source.startsWith("packaged-ui-route-after-paint:") ||
        /(?:pre-paint|route-render|route-state-loop|placeholder|synthetic|mock)/iu.test(
          row.source,
        ),
    )
  ) {
    fail("P-32 route samples include a pre-paint or non-packaged source");
  }
  const rawMetrics = {
    "app.start": desktop.performance?.appStartSamples,
    "route.navigation": routeRows.map((row) => row.ms),
    "ipc.health.roundtrip": desktop.performance?.ipcHealthRoundTripSamples,
    "tray.click.open": desktop.performance?.trayClickOpenSamples,
  };
  const native = desktop.provenance;
  const nativeStart = Date.parse(native?.startedAt);
  const nativeEnd = Date.parse(native?.endedAt);
  const desktopPayload = structuredClone(desktop);
  delete desktopPayload.provenance;
  if (
    native?.schemaVersion !== 1 ||
    native?.producer !== "openburnbar-linux-desktop-performance-v1" ||
    native?.gitCommit !== binding.targetHead ||
    native?.packageVersion !== binding.packageVersion ||
    desktop.package?.version !== binding.packageVersion ||
    String(native?.candidate?.runId) !== String(binding.candidateRunId) ||
    native?.candidate?.artifactDigest !== binding.candidateArtifactDigest ||
    native?.sourceDigest !==
      (binding.nativeSourceDigest ??
        nativePerformanceSourceDigest(binding.repoRoot)) ||
    !Number.isFinite(nativeStart) ||
    !Number.isFinite(nativeEnd) ||
    nativeEnd < nativeStart ||
    Date.parse(desktop.generatedAt) !== nativeEnd ||
    native?.payloadSha256 !==
      crypto
        .createHash("sha256")
        .update(JSON.stringify(desktopPayload))
        .digest("hex")
  )
    fail("P-32 native desktop report provenance is invalid or relabeled");
  const ipcSamples = rawMetrics["ipc.health.roundtrip"];
  if (
    !Array.isArray(ipcSamples) ||
    reconnectReceipts.length !== ipcSamples.length ||
    reconnectHandlerAcks.length !== ipcSamples.length
  )
    fail(
      "P-32 tray reconnect receipts and handler acknowledgements do not cover every reported round-trip sample",
    );
  const seenHealthRequestIds = new Set();
  const seenHandlerEventIds = new Set();
  reconnectReceipts.forEach((receipt, index) => {
    const label = `P-32 tray reconnect receipt ${index + 1}`;
    const ackLabel = `P-32 tray reconnect handler acknowledgement ${index + 1}`;
    const ack = reconnectHandlerAcks[index];
    exactKeys(
      receipt,
      [
        "sample",
        "menuId",
        "menuRevisionBefore",
        "menuRevisionAfter",
        "daemonConnected",
        "clickEpochMs",
        "handlerEventId",
        "handlerStartedEpochMs",
        "handlerCompletedEpochMs",
        "daemonHealthRequestId",
        "statusItemLogicalId",
        "statusMenuId",
        "observedStatusLabel",
        "observedEpochMs",
        "elapsedMs",
      ],
      label,
    );
    exactKeys(
      ack,
      [
        "schemaVersion",
        "action",
        "handlerEventId",
        "daemonHealthRequestId",
        "statusItemLogicalId",
        "handlerStartedEpochMs",
        "handlerCompletedEpochMs",
        "daemonConnected",
        "statusUpdateSucceeded",
        "statusLabel",
      ],
      ackLabel,
    );
    const previous = reconnectReceipts[index - 1];
    const requestId = receipt.daemonHealthRequestId;
    const handlerEventId = receipt.handlerEventId;
    const clickNs = Number.isSafeInteger(receipt.clickEpochMs)
      ? BigInt(receipt.clickEpochMs) * 1_000_000n
      : null;
    const handlerStartNs = Number.isSafeInteger(receipt.handlerStartedEpochMs)
      ? BigInt(receipt.handlerStartedEpochMs) * 1_000_000n
      : null;
    const handlerEndNs = Number.isSafeInteger(receipt.handlerCompletedEpochMs)
      ? (BigInt(receipt.handlerCompletedEpochMs) + 1n) * 1_000_000n
      : null;
    const requestStampNs =
      typeof requestId === "string" && /^health-[1-9][0-9]*$/u.test(requestId)
        ? BigInt(requestId.slice("health-".length))
        : null;
    const requestLogToken = `request_id=${requestId}`;
    const requestLogOccurrences = daemonHealthLines.filter((line) =>
      line.split(/\s+/u).includes(requestLogToken),
    ).length;
    const observedEpochMs = Number.isSafeInteger(receipt.observedEpochMs)
      ? receipt.observedEpochMs
      : null;
    if (
      receipt.sample !== index + 1 ||
      receipt.daemonConnected !== true ||
      !Number.isSafeInteger(receipt.menuId) ||
      receipt.menuId <= 0 ||
      receipt.menuId > 2_147_483_647 ||
      !Number.isSafeInteger(receipt.menuRevisionBefore) ||
      receipt.menuRevisionBefore < 0 ||
      receipt.menuRevisionBefore > 4_294_967_295 ||
      !Number.isSafeInteger(receipt.menuRevisionAfter) ||
      receipt.menuRevisionAfter < 0 ||
      receipt.menuRevisionAfter > 4_294_967_295 ||
      // Label-only status updates are DBusMenu property updates and do not
      // advance the GetLayout revision, so the revision must only never
      // regress across the click-to-observation window.
      receipt.menuRevisionAfter < receipt.menuRevisionBefore ||
      typeof handlerEventId !== "string" ||
      !/^tray-health-[0-9a-f]{32}$/u.test(handlerEventId) ||
      seenHandlerEventIds.has(handlerEventId) ||
      typeof requestId !== "string" ||
      !/^health-[1-9][0-9]*$/u.test(requestId) ||
      seenHealthRequestIds.has(requestId) ||
      clickNs === null ||
      handlerStartNs === null ||
      handlerEndNs === null ||
      requestStampNs === null ||
      handlerStartNs < clickNs ||
      handlerEndNs < handlerStartNs ||
      requestStampNs < handlerStartNs ||
      requestStampNs >= handlerEndNs ||
      requestLogOccurrences !== 1 ||
      ack.schemaVersion !== 1 ||
      ack.action !== "reconnect-daemon" ||
      ack.handlerEventId !== handlerEventId ||
      ack.daemonHealthRequestId !== requestId ||
      ack.statusItemLogicalId !== "status" ||
      ack.handlerStartedEpochMs !== receipt.handlerStartedEpochMs ||
      ack.handlerCompletedEpochMs !== receipt.handlerCompletedEpochMs ||
      ack.daemonConnected !== true ||
      ack.statusUpdateSucceeded !== true ||
      typeof ack.statusLabel !== "string" ||
      !/^Daemon: connected(?: - .+)?$/u.test(ack.statusLabel) ||
      receipt.statusItemLogicalId !== ack.statusItemLogicalId ||
      !Number.isSafeInteger(receipt.statusMenuId) ||
      receipt.statusMenuId <= 0 ||
      receipt.statusMenuId > 2_147_483_647 ||
      receipt.observedStatusLabel !== ack.statusLabel ||
      observedEpochMs === null ||
      observedEpochMs < receipt.handlerCompletedEpochMs ||
      observedEpochMs !== receipt.clickEpochMs + receipt.elapsedMs ||
      receipt.clickEpochMs < nativeStart ||
      observedEpochMs > nativeEnd ||
      (previous &&
        (receipt.menuRevisionBefore < previous.menuRevisionAfter ||
          receipt.statusMenuId !== previous.statusMenuId ||
          receipt.clickEpochMs < previous.observedEpochMs)) ||
      finite(receipt.elapsedMs, `${label} elapsedMs`) !== ipcSamples[index]
    )
      fail(`${label} does not match the reported reconnect sample`);
    seenHandlerEventIds.add(handlerEventId);
    seenHealthRequestIds.add(requestId);
  });
  const verdicts = EXPECTED_METRICS.map((name) => {
    const samples = rawMetrics[name];
    const minimumSamples = budget.nativeShell.minimumSamples?.[name];
    const limitP95Ms = budget.nativeShell.thresholdsP95Ms?.[name];
    const stats = summarize(samples, `P-32 ${name}`);
    if (
      !Number.isSafeInteger(minimumSamples) ||
      samples.length < minimumSamples
    )
      fail(`P-32 ${name} has insufficient samples`);
    if (!Number.isFinite(limitP95Ms) || stats.p95 > limitP95Ms)
      fail(`P-32 ${name} exceeds its p95 budget`);
    return {
      name,
      unit: "milliseconds",
      source: METRIC_SOURCES[name],
      sampleCount: samples.length,
      minimumSamples,
      limitP95Ms,
      stats,
      measured: true,
      pass: true,
    };
  });
  same(perf.verdicts, verdicts, "P-32 native verdicts");
  if (
    perf.runner !== "linux-desktop-packaged-runtime-perf-v4" ||
    perf.allPass !== true ||
    perf.errors?.length !== 0
  ) {
    fail("P-32 packaged performance report is not a clean pass");
  }
  if (
    basenames(perf.measurements?.desktopSessionReport) !==
      "linux-desktop-session-report.json" ||
    basenames(perf.measurements?.runtimeSamples) !==
      "runtime-perf-samples.jsonl" ||
    basenames(perf.measurements?.packagedRouteTranscript) !==
      "packaged-route-session-transcript.json" ||
    basenames(perf.measurements?.matchedComparison) !==
      "matched-performance-comparison.json" ||
    perf.measurements.runtimeSampleCount !== runtime.length ||
    perf.measurements.packagedRouteCount !== routeTranscript.routeCount ||
    perf.measurements.matchedProfile !== "nightly"
  ) {
    fail("P-32 packaged performance report cross-links are inconsistent");
  }
  same(perf.matchedPerformance, comparison, "P-32 embedded matched comparison");
  same(
    trend.rows,
    verdicts.map((row) => ({
      name: row.name,
      currentP50Ms: row.stats.p50,
      currentP95Ms: row.stats.p95,
      currentP99Ms: row.stats.p99,
      thresholdP95Ms: row.limitP95Ms,
      sampleCount: row.sampleCount,
      source: row.source,
      pass: true,
    })),
    "P-32 threshold rows",
  );
  if (
    trend.matchedProfile !== "nightly" ||
    trend.matchedPass !== true ||
    trend.pass !== true ||
    trend.errors?.length !== 0
  ) {
    fail("P-32 threshold report is not a clean nightly pass");
  }
  same(
    macosCrossLink.workloads,
    comparison.workloads,
    "P-32 macOS workload cross-link",
  );
  same(
    macosCrossLink.resources,
    comparison.resources,
    "P-32 macOS resource cross-link",
  );
  if (
    macosCrossLink.profile !== "nightly" ||
    macosCrossLink.pass !== true ||
    macosCrossLink.status !== "measured-pass" ||
    macosCrossLink.protocolVersion !== comparison.protocolVersion ||
    macosCrossLink.errors?.length !== 0
  ) {
    fail("P-32 macOS comparison cross-link is invalid");
  }
  return {
    architecture,
    comparison,
    verdicts,
    runtimeSampleCount: runtime.length,
    productionWindow: {
      oldest: Math.min(
        Date.parse(macos.provenance.endedAt),
        Date.parse(linux.provenance.endedAt),
        nativeEnd,
      ),
      newest: Math.max(
        Date.parse(macos.provenance.endedAt),
        Date.parse(linux.provenance.endedAt),
        nativeEnd,
      ),
    },
  };
}

function validatePackage(document, binding) {
  exactKeys(
    document.package,
    [
      "architecture",
      "format",
      "installed",
      "manifest",
      "signature",
      "source",
      "version",
    ],
    "P-32 package",
  );
  const expected = INSTALLED_UI_ENVIRONMENTS[binding.environmentId];
  if (
    !expected ||
    document.package.architecture !== expected.architecture ||
    document.package.format !== expected.format ||
    document.package.installed !== true ||
    document.package.source !== "verified-live-installed-candidate" ||
    document.package.version !== binding.packageVersion
  )
    fail("P-32 did not use the selected installed candidate");
  const manifest = validateArtifact(
    binding.repoRoot,
    document.package.manifest,
    P32_REQUIREMENT_ID,
    binding.environmentId,
    "P-32 manifest",
    { mediaType: "json" },
  );
  const signature = validateArtifact(
    binding.repoRoot,
    document.package.signature,
    P32_REQUIREMENT_ID,
    binding.environmentId,
    "P-32 signature",
    { minimumBytes: 64 },
  );
  if (
    manifest.sha256 !== binding.manifestSha256 ||
    signature.sha256 !== binding.manifestSignatureSha256
  )
    fail("P-32 installed attestation digest changed");
  const key = readRegularSnapshot(
    binding.repoRoot,
    "packaging/linux/openburnbar-linux-ed25519.pub.pem",
    "P-32 pinned key",
  );
  let valid = false;
  try {
    const publicKey = crypto.createPublicKey(key.bytes);
    valid =
      publicKey.asymmetricKeyType === "ed25519" &&
      signature.bytes.length === 64 &&
      crypto.verify(null, manifest.bytes, publicKey, signature.bytes);
  } catch {
    valid = false;
  }
  if (!valid) fail("P-32 installed manifest signature is invalid");
  const parsed = assertInstalledManifest(
    parseJson(manifest.bytes, "P-32 manifest"),
  );
  if (
    parsed.gitCommit !== binding.targetHead ||
    parsed.packageVersion !== binding.packageVersion ||
    parsed.packageArchitecture !== document.package.architecture ||
    parsed.packageFormat !== document.package.format
  ) {
    fail(
      "P-32 installed manifest identity does not match the selected candidate",
    );
  }
}

export function validateP32InstalledSession(
  document,
  binding,
  { budget } = {},
) {
  exactKeys(
    document,
    [
      "candidate",
      "capture",
      "environmentId",
      "evidence",
      "id",
      "package",
      "requirementId",
      "schemaVersion",
      "targetHead",
      "verification",
    ],
    "P-32 session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p32-installed-performance-session-v1" ||
    document.requirementId !== P32_REQUIREMENT_ID ||
    document.environmentId !== binding.environmentId ||
    document.targetHead !== binding.targetHead ||
    !HEAD_PATTERN.test(document.targetHead ?? "")
  )
    fail("P-32 session identity is invalid");
  exactKeys(document.candidate, ["artifactDigest", "runId"], "P-32 candidate");
  if (
    !RUN_ID_PATTERN.test(String(document.candidate.runId ?? "")) ||
    String(document.candidate.runId) !== String(binding.candidateRunId) ||
    !DIGEST_PATTERN.test(document.candidate.artifactDigest ?? "") ||
    document.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-32 candidate binding is invalid");
  validatePackage(document, binding);
  exactKeys(
    document.capture,
    ["endedAt", "fixtureMode", "method", "startedAt"],
    "P-32 capture",
  );
  const started = Date.parse(document.capture.startedAt);
  const ended = Date.parse(document.capture.endedAt);
  if (
    !Number.isFinite(started) ||
    !Number.isFinite(ended) ||
    ended <= started ||
    ended - started > 4 * 60 * 60 * 1000 ||
    document.capture.fixtureMode !== false ||
    document.capture.method !== "signed-installed-nightly-performance"
  )
    fail("P-32 capture window is invalid");
  exactKeys(document.evidence, P32_RAW_FILES, "P-32 evidence");
  const snapshots = Object.fromEntries(
    P32_RAW_FILES.map((name) => {
      const snapshot = validateArtifact(
        binding.repoRoot,
        document.evidence[name],
        P32_REQUIREMENT_ID,
        binding.environmentId,
        `P-32 ${name}`,
      );
      return [name, snapshot.bytes];
    }),
  );
  const receipt = parseJson(
    snapshots["p32-native-performance-receipt.json"],
    "P-32 native receipt",
  );
  exactKeys(
    receipt,
    [
      "candidate",
      "collectedAt",
      "environmentId",
      "fixtureMode",
      "package",
      "producer",
      "reports",
      "targetHead",
      "verification",
    ],
    "P-32 native receipt",
  );
  exactKeys(
    receipt.candidate,
    ["artifactDigest", "runId"],
    "P-32 receipt candidate",
  );
  exactKeys(
    receipt.package,
    [
      "architecture",
      "format",
      "manifestSha256",
      "manifestSignatureSha256",
      "version",
    ],
    "P-32 receipt package",
  );
  if (
    receipt.producer !== "openburnbar-p32-installed-performance-workflow-v1" ||
    receipt.fixtureMode !== false ||
    receipt.environmentId !== binding.environmentId ||
    receipt.targetHead !== binding.targetHead ||
    String(receipt.candidate?.runId) !== String(binding.candidateRunId) ||
    receipt.candidate?.artifactDigest !== binding.candidateArtifactDigest ||
    receipt.package?.architecture !== document.package.architecture ||
    receipt.package?.format !== document.package.format ||
    receipt.package?.version !== binding.packageVersion ||
    receipt.package?.manifestSha256 !== binding.manifestSha256 ||
    receipt.package?.manifestSignatureSha256 !== binding.manifestSignatureSha256
  )
    fail("P-32 native receipt is not candidate-bound");
  const collectedAt = Date.parse(receipt.collectedAt);
  const reportEnds = [
    ...["matched-performance-macos.json", "matched-performance-linux.json"].map(
      (name) =>
        Date.parse(
          parseJson(snapshots[name], `P-32 ${name}`).provenance?.endedAt,
        ),
    ),
    Date.parse(
      parseJson(
        snapshots["linux-desktop-session-report.json"],
        "P-32 desktop report",
      ).provenance?.endedAt,
    ),
  ];
  const newestReport = Math.max(...reportEnds);
  const oldestReport = Math.min(...reportEnds);
  if (
    reportEnds.some((value) => !Number.isFinite(value)) ||
    !Number.isFinite(collectedAt) ||
    collectedAt < newestReport ||
    collectedAt - newestReport > 2 * 60 * 60 * 1000 ||
    newestReport - oldestReport > 4 * 60 * 60 * 1000
  )
    fail("P-32 reports are stale or not part of one bounded candidate run");
  exactKeys(receipt.reports, P32_REPORT_FILES, "P-32 receipt report hashes");
  for (const name of P32_REPORT_FILES)
    if (receipt.reports[name] !== hash(snapshots[name]))
      fail(`P-32 receipt hash changed for ${name}`);
  const reportBytes = Object.fromEntries(
    P32_REPORT_FILES.map((name) => [name, snapshots[name]]),
  );
  const verified = validateP32RawReports(reportBytes, budget, binding);
  same(
    receipt.verification,
    {
      architecture: verified.architecture,
      matchedWorkloadCount: verified.comparison.workloads.length,
      nativeMetricCount: verified.verdicts.length,
      profile: "nightly",
      runtimeSampleCount: verified.runtimeSampleCount,
      soakSeconds: budget.matched.profiles.nightly.soakSeconds,
      status: "passed",
    },
    "P-32 receipt verification summary",
  );
  exactKeys(
    document.verification,
    [
      "architecture",
      "matchedWorkloadCount",
      "nativeMetricCount",
      "profile",
      "runtimeSampleCount",
      "soakSeconds",
      "status",
    ],
    "P-32 verification",
  );
  same(
    document.verification,
    {
      architecture: verified.architecture,
      matchedWorkloadCount: verified.comparison.workloads.length,
      nativeMetricCount: verified.verdicts.length,
      profile: "nightly",
      runtimeSampleCount: verified.runtimeSampleCount,
      soakSeconds: budget.matched.profiles.nightly.soakSeconds,
      status: "passed",
    },
    "P-32 verification summary",
  );
  return {
    document,
    evidence: Object.values(document.evidence),
    endedAt: ended,
  };
}

export function buildP32Proof({ session, source, collectedAt }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p32-installed-performance-proof-v1",
    requirementId: P32_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: structuredClone(session.candidate),
    package: {
      architecture: session.package.architecture,
      format: session.package.format,
      version: session.package.version,
      manifestSha256: session.package.manifest.sha256,
      manifestSignatureSha256: session.package.signature.sha256,
    },
    profile: "nightly",
    soakSeconds: session.verification.soakSeconds,
    nativeMetricCount: session.verification.nativeMetricCount,
    matchedWorkloadCount: session.verification.matchedWorkloadCount,
    source,
    evidence: Object.values(session.evidence),
    collectedAt,
    passed: true,
  };
}

export function validateP32Proof(options) {
  const document = parseJson(options.snapshot.bytes, "P-32 proof");
  exactKeys(
    document,
    [
      "candidate",
      "collectedAt",
      "environmentId",
      "evidence",
      "id",
      "matchedWorkloadCount",
      "nativeMetricCount",
      "package",
      "passed",
      "profile",
      "requirementId",
      "schemaVersion",
      "soakSeconds",
      "source",
      "targetHead",
    ],
    "P-32 proof",
  );
  exactKeys(
    document.candidate,
    ["artifactDigest", "runId"],
    "P-32 proof candidate",
  );
  exactKeys(
    document.package,
    [
      "architecture",
      "format",
      "manifestSha256",
      "manifestSignatureSha256",
      "version",
    ],
    "P-32 proof package",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p32-installed-performance-proof-v1" ||
    document.requirementId !== P32_REQUIREMENT_ID ||
    document.environmentId !== options.environmentId ||
    document.targetHead !== options.targetHead ||
    document.passed !== true ||
    document.profile !== "nightly" ||
    document.soakSeconds < 1800 ||
    document.nativeMetricCount !== EXPECTED_METRICS.length ||
    !Number.isSafeInteger(document.matchedWorkloadCount) ||
    document.matchedWorkloadCount < 1
  )
    fail("P-32 proof summary is invalid");
  if (
    String(document.candidate?.runId) !== String(options.candidateRunId) ||
    document.candidate?.artifactDigest !== options.candidateArtifactDigest ||
    document.package?.version !== options.packageVersion ||
    document.package?.manifestSha256 !== options.manifestSha256 ||
    document.package?.manifestSignatureSha256 !==
      options.manifestSignatureSha256
  )
    fail("P-32 proof candidate identity is invalid");
  const source = validateArtifact(
    options.repoRoot,
    document.source,
    P32_REQUIREMENT_ID,
    options.environmentId,
    "P-32 source",
    { mediaType: "json" },
  );
  const session = validateP32InstalledSession(
    parseJson(source.bytes, "P-32 source session"),
    options,
    { budget: options.budget },
  );
  const collectedAt = Date.parse(document.collectedAt);
  if (
    !Number.isFinite(collectedAt) ||
    collectedAt < session.endedAt ||
    collectedAt - session.endedAt > 15 * 60 * 1000
  )
    fail("P-32 proof collection time is invalid");
  same(document.evidence, session.evidence, "P-32 proof evidence cross-link");
  return { document, source: document.source, evidence: document.evidence };
}

export function validateP32Invocation(options) {
  if (
    !HEAD_PATTERN.test(options.targetHead ?? "") ||
    !RUN_ID_PATTERN.test(String(options.candidateRunId ?? "")) ||
    !DIGEST_PATTERN.test(options.candidateArtifactDigest ?? "") ||
    !VERSION_PATTERN.test(options.packageVersion ?? "") ||
    !SHA256_PATTERN.test(options.manifestSha256 ?? "") ||
    !SHA256_PATTERN.test(options.manifestSignatureSha256 ?? "")
  ) {
    fail("P-32 invocation binding is invalid");
  }
}

export function recordBytes(bytes) {
  return { sha256: hash(bytes), size: bytes.length };
}
