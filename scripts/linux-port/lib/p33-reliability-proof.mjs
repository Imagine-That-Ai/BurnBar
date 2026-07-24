import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P33_REQUIREMENT_ID = "P-33";
export const P33_PROOF_ROLE = "feature.reliability-installed";
export const P33_PROOF_FILENAME = "p33-installed-reliability-proof.json";
export const P33_SESSION_FILENAME = "p33-installed-reliability-session.json";
export const P33_STATES = Object.freeze(["healthy", "degraded", "recovered", "relaunched"]);
export const P33_RAW_FILES = Object.freeze([
  "reliability-marker.json",
  "reliability-native-transcript.json",
  ...P33_STATES.flatMap((state) => [
    `reliability-${state}.png`,
    `reliability-${state}-atspi.json`,
  ]),
]);

const MARKER = /^p33-[a-f0-9]{16}$/u;
const NONCE = /^[a-f0-9]{32}$/u;
const VERSION = /^v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u;
const EXPECTED_NAMES = Object.freeze({
  healthy: "Connected",
  degraded: "Daemon unavailable",
  recovered: "Connected",
  relaunched: "Connected",
});

function fail(message) { throw new Error(message); }
function instant(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(root, record, P33_REQUIREMENT_ID, environmentId, label, options);
}
function expectedChallenge(value, binding) {
  return crypto.createHash("sha256").update([
    binding.targetHead,
    String(binding.candidateRunId),
    binding.candidateArtifactDigest,
    value.marker,
    value.nonce,
  ].join("\n")).digest("hex");
}
function same(left, right) { return JSON.stringify(left) === JSON.stringify(right); }
function bounded(value, minimum, maximum, label) {
  if (!Number.isFinite(value) || value < minimum || value > maximum) fail(`${label} is outside its reliability budget`);
}

function validateMarker(value, expected, binding) {
  exactKeys(value, ["challenge", "installed", "marker", "nonce", "package", "producer"], "P-33 marker");
  if (!MARKER.test(value.marker ?? "") || !NONCE.test(value.nonce ?? "") || value.producer !== "openburnbar-p33-installed-reliability-probe-v1") fail("P-33 marker identity is invalid");
  exactKeys(value.installed, ["cli", "daemon", "desktop", "packageOwned"], "P-33 installed identity");
  if (value.installed.cli !== "/usr/bin/openburnbar-cli" || value.installed.daemon !== "/usr/bin/openburnbar-daemon" || value.installed.desktop !== "/usr/bin/openburnbar-linux-desktop" || value.installed.packageOwned !== true) fail("P-33 did not use package-owned installed executables");
  exactKeys(value.package, ["architecture", "format", "manifestSha256", "version"], "P-33 package identity");
  if (value.package.architecture !== expected.architecture || value.package.format !== expected.format || value.package.manifestSha256 !== binding.manifestSha256 || value.package.version !== binding.packageVersion) fail("P-33 package identity is forged");
  if (value.challenge !== expectedChallenge(value, binding)) fail("P-33 marker challenge is stale or replayed");
}

function validateA11y(snapshot, label, startedAt, endedAt, expectedName) {
  const value = parseJson(snapshot.bytes, label);
  if (value.application !== "OpenBurnBar" || value.route !== "support" || value.pass !== true || value.expectedNamePresent !== true || value.expectedName !== expectedName || value.nodeCount < 12 || value.namedNodeCount < 6 || value.actionableNodeCount < 1) fail(`${label} is not live Support-route AT-SPI evidence`);
  const capturedAt = instant(value.capturedAt, `${label} capture`);
  if (capturedAt < startedAt || capturedAt > endedAt) fail(`${label} is outside the installed reliability session`);
}

function validatePackageFacts(value, expected, binding) {
  exactKeys(value, ["architecture", "cliVersion", "daemonVersion", "desktop", "displayServer", "format", "os", "packageVersion", "sessionType"], "P-33 package/runtime facts");
  if (value.architecture !== expected.architecture || value.format !== expected.format || value.packageVersion !== binding.packageVersion || value.cliVersion !== binding.packageVersion || !VERSION.test(value.daemonVersion ?? "") || value.os !== "linux" || value.sessionType !== expected.session.toLowerCase() || value.displayServer !== expected.session || value.desktop !== expected.desktop) fail("P-33 package or runtime facts are inaccurate");
}

function validateSubscription(value) {
  exactKeys(value, ["backpressure", "cursorMonotonic", "disconnectDetected", "duplicateEvents", "initialId", "initialSeq", "recoveredAfterRestart", "resumedId", "resumedSeq", "singleFlight", "terminalStateDelivered"], "P-33 subscription receipt");
  if (typeof value.initialId !== "string" || value.initialId.length < 8 || value.resumedId !== value.initialId || !Number.isSafeInteger(value.initialSeq) || !Number.isSafeInteger(value.resumedSeq) || value.initialSeq < 1 || value.resumedSeq <= value.initialSeq || value.cursorMonotonic !== true || value.disconnectDetected !== true || value.recoveredAfterRestart !== true || value.backpressure !== "bounded" || value.singleFlight !== true || value.duplicateEvents !== 0 || value.terminalStateDelivered !== false) fail("P-33 subscription restart/cursor/backpressure proof is incomplete");
}

function validateFaultRecovery(value) {
  exactKeys(value, ["backoffMillis", "daemonFailureObserved", "daemonRecoveryMillis", "desktopRelaunchMillis", "portalRestarted", "socketStallMillis", "stallTimedOut"], "P-33 fault recovery");
  if (value.daemonFailureObserved !== true || value.stallTimedOut !== true || value.portalRestarted !== true || !Array.isArray(value.backoffMillis) || value.backoffMillis.length < 3) fail("P-33 did not exercise all process/socket/portal failures");
  bounded(value.daemonRecoveryMillis, 0, 30_000, "P-33 daemon recovery");
  bounded(value.socketStallMillis, 1_000, 10_000, "P-33 socket stall");
  bounded(value.desktopRelaunchMillis, 0, 30_000, "P-33 desktop relaunch");
  for (let index = 0; index < value.backoffMillis.length; index += 1) {
    bounded(value.backoffMillis[index], 1, 30_000, "P-33 retry backoff");
    if (index > 0 && value.backoffMillis[index] < value.backoffMillis[index - 1]) fail("P-33 retry backoff is not monotonic");
  }
}

function validateEnvironmentRecovery(value) {
  exactKeys(value, ["attemptsWhileOffline", "clockChangeMillis", "clockRecoveryMillis", "databaseLockObserved", "databaseRecoveryMillis", "keyringLockedObserved", "keyringRecoveryMillis", "offlineObserved", "onlineRecoveryMillis", "resumeRecoveryMillis", "suspendElapsedMillis"], "P-33 environment recovery");
  if (value.offlineObserved !== true || value.attemptsWhileOffline !== 0 || value.keyringLockedObserved !== true || value.databaseLockObserved !== true || Math.abs(value.clockChangeMillis) < 60_000) fail("P-33 offline, clock, keyring, or database fault was not genuinely observed");
  bounded(value.onlineRecoveryMillis, 0, 30_000, "P-33 online recovery");
  bounded(value.suspendElapsedMillis, 1_000, 900_000, "P-33 suspend interval");
  bounded(value.resumeRecoveryMillis, 0, 60_000, "P-33 resume recovery");
  bounded(value.clockRecoveryMillis, 0, 30_000, "P-33 clock recovery");
  bounded(value.keyringRecoveryMillis, 0, 60_000, "P-33 keyring recovery");
  bounded(value.databaseRecoveryMillis, 0, 30_000, "P-33 database recovery");
}

function validateScale(value) {
  exactKeys(value, ["largeTranscriptBytes", "lowMemoryRecovery", "rows100k", "rows10k", "softwareRenderingRecovery"], "P-33 scale pressure");
  for (const [field, minimum] of [["rows10k", 10_000], ["rows100k", 100_000]]) {
    exactKeys(value[field], ["latencyMillis", "requested", "returned"], `P-33 ${field}`);
    if (value[field].requested !== minimum || value[field].returned < minimum) fail(`P-33 ${field} did not exercise the required data volume`);
    bounded(value[field].latencyMillis, 0, 30_000, `P-33 ${field} latency`);
  }
  if (!Number.isSafeInteger(value.largeTranscriptBytes) || value.largeTranscriptBytes < 1_000_000 || value.lowMemoryRecovery !== true || value.softwareRenderingRecovery !== true) fail("P-33 transcript, memory, or software-rendering pressure is incomplete");
}

function validateSoak(value) {
  exactKeys(value, ["durationMillis", "healthFailures", "idleCycles", "rssGrowthBytes", "useCycles"], "P-33 soak");
  if (value.durationMillis < 1_800_000 || value.idleCycles < 30 || value.useCycles < 30 || value.healthFailures !== 0 || value.rssGrowthBytes < -134_217_728 || value.rssGrowthBytes > 67_108_864) fail("P-33 30-minute idle/use soak or leak budget failed");
}

function validateRestoration(value) {
  exactKeys(value, ["clockRestored", "daemonActiveAfter", "daemonActiveBefore", "desktopPidsAfter", "desktopPidsBefore", "isolatedStateRestored", "keyringRestored", "networkEnabledAfter", "networkEnabledBefore", "portalActiveAfter", "portalActiveBefore"], "P-33 restoration");
  if (value.daemonActiveAfter !== value.daemonActiveBefore || value.networkEnabledAfter !== value.networkEnabledBefore || value.portalActiveAfter !== value.portalActiveBefore || !same(value.desktopPidsAfter, value.desktopPidsBefore) || value.clockRestored !== true || value.keyringRestored !== true || value.isolatedStateRestored !== true) fail("P-33 exact service/process/environment/state restoration is incomplete");
}

function validateNative(value, marker, expected, envelope, binding) {
  exactKeys(value, ["challenge", "endedAt", "environmentRecovery", "faultRecovery", "marker", "packageFacts", "producer", "restoration", "scale", "soak", "startedAt", "subscription"], "P-33 native transcript");
  const startedAt = instant(value.startedAt, "P-33 native start");
  const endedAt = instant(value.endedAt, "P-33 native end");
  if (value.producer !== marker.producer || value.marker !== marker.marker || value.challenge !== marker.challenge || startedAt < envelope.startedAt || endedAt > envelope.endedAt || endedAt <= startedAt || endedAt - startedAt > 7_200_000) fail("P-33 native transcript is stale, replayed, or unbounded");
  validatePackageFacts(value.packageFacts, expected, binding);
  validateSubscription(value.subscription);
  validateFaultRecovery(value.faultRecovery);
  validateEnvironmentRecovery(value.environmentRecovery);
  validateScale(value.scale);
  validateSoak(value.soak);
  validateRestoration(value.restoration);
  return { startedAt, endedAt };
}

export function validateP33InstalledSession(document, binding, { repoRoot = binding.repoRoot } = {}) {
  exactKeys(document, ["candidate", "capture", "desktop", "environmentId", "evidence", "id", "marker", "package", "requirementId", "schemaVersion", "targetHead"], "P-33 installed session");
  if (document.schemaVersion !== 1 || document.id !== "openburnbar-linux-p33-installed-reliability-session-v1") fail("P-33 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P33_REQUIREMENT_ID, "P-33 installed session");
  validateMarker(document.marker, envelope.expected, binding);
  const evidenceKeys = ["marker", "nativeTranscript", ...P33_STATES.flatMap((state) => [`${state}Screenshot`, `${state}Accessibility`])];
  exactKeys(document.evidence, evidenceKeys, "P-33 evidence");
  const markerArtifact = artifact(repoRoot, document.environmentId, document.evidence.marker, "P-33 marker artifact", { mediaType: "json", minimumBytes: 300 });
  if (!same(parseJson(markerArtifact.bytes, "P-33 marker artifact"), document.marker)) fail("P-33 marker artifact does not match the signed session marker");
  const native = artifact(repoRoot, document.environmentId, document.evidence.nativeTranscript, "P-33 native transcript", { mediaType: "json", minimumBytes: 1_500 });
  const timing = validateNative(parseJson(native.bytes, "P-33 native transcript"), document.marker, envelope.expected, envelope, binding);
  const hashes = new Set();
  for (const state of P33_STATES) {
    const screenshot = artifact(repoRoot, document.environmentId, document.evidence[`${state}Screenshot`], `P-33 ${state} screenshot`, { mediaType: "png", minimumBytes: 1_024 });
    const png = validatePng(screenshot.bytes, `P-33 ${state} screenshot`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-33 ${state} screenshot is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
    const accessibility = artifact(repoRoot, document.environmentId, document.evidence[`${state}Accessibility`], `P-33 ${state} accessibility`, { mediaType: "json", minimumBytes: 300 });
    validateA11y(accessibility, `P-33 ${state} accessibility`, timing.startedAt, timing.endedAt, EXPECTED_NAMES[state]);
  }
  if (hashes.size !== P33_STATES.length) fail("P-33 screenshots are reused across reliability states");
  const evidence = [...envelope.attestation, ...Object.values(document.evidence)];
  if (new Set(evidence.map((entry) => entry.path)).size !== evidence.length) fail("P-33 reuses an evidence artifact");
  return { document, evidence, endedAt: timing.endedAt };
}

export function buildP33Proof({ session, source, collectedAt }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p33-reliability-proof-v1",
    requirementId: P33_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    package: { version: session.package.version, architecture: session.package.architecture, format: session.package.format },
    collectedAt,
    source: { method: "live-installed-reliability-session", ...source },
    claim: {
      boundedSupervisorRecovery: true,
      cursorAndBackpressureIntegrity: true,
      environmentLifecycleRecovery: true,
      installedProcessRecovery: true,
      longIdleUseStability: true,
      scaleAndPressureStability: true,
      exactRestoration: true,
      replayResistant: true,
    },
  };
}

export function validateP33Proof({ snapshot, repoRoot, targetHead, environmentId, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256 }) {
  const value = parseJson(snapshot.bytes, "P-33 proof");
  exactKeys(value, ["candidate", "claim", "collectedAt", "environmentId", "id", "package", "requirementId", "schemaVersion", "source", "targetHead"], "P-33 proof");
  if (value.schemaVersion !== 1 || value.id !== "openburnbar-linux-p33-reliability-proof-v1" || value.requirementId !== P33_REQUIREMENT_ID || value.targetHead !== targetHead || value.environmentId !== environmentId || String(value.candidate?.runId) !== String(candidateRunId) || value.candidate?.artifactDigest !== candidateArtifactDigest) fail("P-33 proof binding is invalid");
  exactKeys(value.package, ["architecture", "format", "version"], "P-33 proof package");
  exactKeys(value.claim, ["boundedSupervisorRecovery", "cursorAndBackpressureIntegrity", "environmentLifecycleRecovery", "exactRestoration", "installedProcessRecovery", "longIdleUseStability", "replayResistant", "scaleAndPressureStability"], "P-33 claim");
  if (!Object.values(value.claim).every((item) => item === true)) fail("P-33 claim is incomplete");
  exactKeys(value.source, ["method", "path", "sha256", "size"], "P-33 proof source");
  if (value.source.method !== "live-installed-reliability-session") fail("P-33 proof source is not live");
  const source = artifact(repoRoot, environmentId, { path: value.source.path, sha256: value.source.sha256, size: value.source.size }, "P-33 session source", { mediaType: "json", minimumBytes: 1_500 });
  const sourceDocument = parseJson(source.bytes, "P-33 source session");
  const validated = validateP33InstalledSession(sourceDocument, { repoRoot, targetHead, environmentId, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256 });
  if (value.package.version !== sourceDocument.package.version || value.package.architecture !== sourceDocument.package.architecture || value.package.format !== sourceDocument.package.format) fail("P-33 proof package does not match its signed source session");
  validateCollectedAt(value.collectedAt, validated.endedAt);
  return { ...value, evidence: validated.evidence };
}
