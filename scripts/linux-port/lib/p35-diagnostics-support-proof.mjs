import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P35_REQUIREMENT_ID = "P-35";
export const P35_PROOF_ROLE = "feature.diagnostics-support-installed";
export const P35_PROOF_FILENAME = "p35-installed-diagnostics-support-proof.json";
export const P35_SESSION_FILENAME = "p35-installed-diagnostics-support-session.json";
export const P35_RAW_FILES = Object.freeze([
  "diagnostics-marker.json",
  "diagnostics-native-transcript.json",
  "diagnostics-export.json",
  "diagnostics-preview.png",
  "diagnostics-exported.png",
  "diagnostics-degraded.png",
  "diagnostics-recovered.png",
  "diagnostics-preview-atspi.json",
  "diagnostics-exported-atspi.json",
  "diagnostics-degraded-atspi.json",
  "diagnostics-recovered-atspi.json",
]);

const MARKER = /^p35-[a-f0-9]{16}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const NONCE = /^[a-f0-9]{32}$/u;
const VERSION = /^v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u;
const SCREENSHOTS = ["previewScreenshot", "exportedScreenshot", "degradedScreenshot", "recoveredScreenshot"];
const ACCESSIBILITY = ["previewAccessibility", "exportedAccessibility", "degradedAccessibility", "recoveredAccessibility"];
const INCLUDED = ["shell version", "daemon health (ok, version, protocol)", "package channel and runtime facts", "renderer and capability facts", "export schema and file permissions"];
const EXCLUDED = ["provider API keys and credentials", "socket auth tokens", "provider response payloads", "user session content"];

function fail(message) { throw new Error(message); }
function instant(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(root, record, P35_REQUIREMENT_ID, environmentId, label, options);
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
function assertMetadataOnly(value) {
  const scrubbed = { ...value, included: [], excluded: [] };
  const encoded = JSON.stringify(scrubbed);
  const strings = [];
  const visit = (item) => {
    if (typeof item === "string") strings.push(item);
    else if (Array.isArray(item)) item.forEach(visit);
    else if (item && typeof item === "object") Object.values(item).forEach(visit);
  };
  visit(scrubbed);
  if (/(?:sk-[A-Za-z0-9]|api[_-]?key|auth[_-]?token|refresh[_-]?token|bearer\s|workspace|prompt|messageBody|providerPayload)/iu.test(encoded) || strings.some((item) => item.startsWith("/")))
    fail("P-35 diagnostics export contains a secret, payload, or local path");
}

function validateMarker(value, expected, binding) {
  exactKeys(value, ["challenge", "installed", "marker", "nonce", "package", "producer"], "P-35 marker");
  if (!MARKER.test(value.marker ?? "") || !NONCE.test(value.nonce ?? "") || value.producer !== "openburnbar-p35-installed-diagnostics-probe-v1")
    fail("P-35 marker identity is invalid");
  exactKeys(value.installed, ["daemon", "desktop", "packageOwned"], "P-35 installed identity");
  if (value.installed.desktop !== "/usr/bin/openburnbar-linux-desktop" || value.installed.daemon !== "/usr/bin/openburnbar-daemon" || value.installed.packageOwned !== true)
    fail("P-35 did not use package-owned installed executables");
  exactKeys(value.package, ["architecture", "format", "manifestSha256", "version"], "P-35 package identity");
  if (value.package.architecture !== expected.architecture || value.package.format !== expected.format || value.package.version !== binding.packageVersion || value.package.manifestSha256 !== binding.manifestSha256)
    fail("P-35 package identity is forged");
  if (value.challenge !== expectedChallenge(value, binding)) fail("P-35 marker challenge is stale or replayed");
}

function validateA11y(snapshot, label, startedAt, endedAt, expectedName) {
  const value = parseJson(snapshot.bytes, label);
  if (value.application !== "OpenBurnBar" || value.route !== "support" || value.pass !== true || value.expectedNamePresent !== true || value.expectedName !== expectedName || value.nodeCount < 12 || value.namedNodeCount < 6 || value.actionableNodeCount < 1)
    fail(`${label} is not live Support-route AT-SPI evidence`);
  const capturedAt = instant(value.capturedAt, `${label} capture`);
  if (capturedAt < startedAt || capturedAt > endedAt) fail(`${label} is outside the live session`);
}

function validateNative(value, marker, expected, envelope, binding, exportSnapshot) {
  exactKeys(value, ["challenge", "degradation", "endedAt", "export", "marker", "packageFacts", "producer", "restoration", "startedAt"], "P-35 native transcript");
  const startedAt = instant(value.startedAt, "P-35 native start");
  const endedAt = instant(value.endedAt, "P-35 native end");
  if (value.producer !== marker.producer || value.marker !== marker.marker || value.challenge !== marker.challenge || startedAt < envelope.startedAt || endedAt > envelope.endedAt || endedAt <= startedAt || endedAt - startedAt > 300_000)
    fail("P-35 native transcript is stale or replayed");
  exactKeys(value.packageFacts, ["architecture", "channel", "daemonVersion", "desktop", "displayServer", "manager", "os", "packageVersion", "sessionType", "shellVersion"], "P-35 package/runtime facts");
  if (value.packageFacts.architecture !== expected.architecture || value.packageFacts.channel !== expected.format || value.packageFacts.manager !== { deb: "dpkg", rpm: "rpm", arch: "pacman" }[expected.format] || value.packageFacts.packageVersion !== binding.packageVersion || value.packageFacts.shellVersion !== binding.packageVersion || !VERSION.test(value.packageFacts.daemonVersion ?? "") || value.packageFacts.os !== "linux" || value.packageFacts.sessionType !== expected.session.toLowerCase() || value.packageFacts.displayServer !== expected.session || value.packageFacts.desktop !== expected.desktop)
    fail("P-35 package, runtime, or version facts are inaccurate");
  exactKeys(value.export, ["atomic", "byteCount", "excluded", "included", "metadataOnly", "mode", "ownerUid", "partialArtifacts", "path", "sha256"], "P-35 export receipt");
  if (value.export.atomic !== true || value.export.metadataOnly !== true || value.export.mode !== "0600" || value.export.ownerUid !== process.getuid?.() || value.export.partialArtifacts !== 0 || value.export.byteCount !== exportSnapshot.bytes.length || value.export.sha256 !== exportSnapshot.sha256 || !SHA256.test(value.export.sha256 ?? "") || !/\/openburnbar-diagnostics-[0-9]+\.json$/u.test(value.export.path ?? "") || JSON.stringify(value.export.included) !== JSON.stringify(INCLUDED) || JSON.stringify(value.export.excluded) !== JSON.stringify(EXCLUDED))
    fail("P-35 diagnostics destination, preview, or atomic write receipt is unsafe");
  const exported = parseJson(exportSnapshot.bytes, "P-35 exported bundle");
  exactKeys(exported, ["daemonHealth", "excluded", "exportedAt", "included", "package", "renderer", "runtime", "schemaVersion", "shellVersion"], "P-35 exported bundle");
  if (exported.schemaVersion !== 1 || exported.shellVersion !== binding.packageVersion || exported.daemonHealth?.ok !== true || !Number.isSafeInteger(exported.daemonHealth?.protocolVersion) || exported.renderer?.shell !== "tauri" || exported.renderer?.webview !== "webkitgtk" || JSON.stringify(exported.renderer?.capabilities) !== JSON.stringify(["support.diagnostics.export", "support.diagnostics.preview"]) || JSON.stringify(exported.included) !== JSON.stringify(value.export.included) || JSON.stringify(exported.excluded) !== JSON.stringify(value.export.excluded))
    fail("P-35 exported bundle facts do not match the installed shell preview");
  if (exported.package?.channel !== expected.format || exported.package?.manager !== value.packageFacts.manager || exported.runtime?.os !== "linux" || exported.runtime?.architecture !== expected.architecture || exported.runtime?.sessionType?.toLowerCase() !== expected.session.toLowerCase() || exported.runtime?.displayServer?.toLowerCase() !== expected.session.toLowerCase())
    fail("P-35 exported package/runtime metadata is inaccurate");
  assertMetadataOnly(exported);
  exactKeys(value.degradation, ["daemonStopped", "degradedVisible", "optimisticSuccess", "reconnectAttemptCount", "reconnectBoundMillis", "recoveredHealth", "recoveryVisible"], "P-35 degradation receipt");
  if (value.degradation.daemonStopped !== true || value.degradation.degradedVisible !== true || value.degradation.optimisticSuccess !== false || value.degradation.reconnectAttemptCount !== 1 || !Number.isFinite(value.degradation.reconnectBoundMillis) || value.degradation.reconnectBoundMillis < 0 || value.degradation.reconnectBoundMillis > 5_000 || value.degradation.recoveredHealth !== true || value.degradation.recoveryVisible !== true)
    fail("P-35 degraded reconnect or recovery proof is optimistic or unbounded");
  exactKeys(value.restoration, ["daemonActiveAfter", "daemonActiveBefore", "desktopPidsAfter", "desktopPidsBefore", "isolatedStateRestored"], "P-35 restoration");
  if (value.restoration.daemonActiveAfter !== value.restoration.daemonActiveBefore || JSON.stringify(value.restoration.desktopPidsAfter) !== JSON.stringify(value.restoration.desktopPidsBefore) || value.restoration.isolatedStateRestored !== true)
    fail("P-35 service, process, or state restoration is incomplete");
  return { startedAt, endedAt };
}

export function validateP35InstalledSession(document, binding, { repoRoot = binding.repoRoot } = {}) {
  exactKeys(document, ["candidate", "capture", "desktop", "environmentId", "evidence", "id", "marker", "package", "requirementId", "schemaVersion", "targetHead"], "P-35 installed session");
  if (document.schemaVersion !== 1 || document.id !== "openburnbar-linux-p35-installed-diagnostics-support-session-v1") fail("P-35 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P35_REQUIREMENT_ID, "P-35 installed session");
  validateMarker(document.marker, envelope.expected, binding);
  exactKeys(document.evidence, ["nativeTranscript", "exportBundle", ...SCREENSHOTS, ...ACCESSIBILITY], "P-35 evidence");
  const native = artifact(repoRoot, document.environmentId, document.evidence.nativeTranscript, "P-35 native transcript", { mediaType: "json", minimumBytes: 1000 });
  const exported = artifact(repoRoot, document.environmentId, document.evidence.exportBundle, "P-35 diagnostics export", { mediaType: "json", minimumBytes: 300 });
  const timing = validateNative(parseJson(native.bytes, "P-35 native transcript"), document.marker, envelope.expected, envelope, binding, exported);
  const hashes = new Set();
  for (const field of SCREENSHOTS) {
    const row = artifact(repoRoot, document.environmentId, document.evidence[field], `P-35 ${field}`, { mediaType: "png", minimumBytes: 1024 });
    const png = validatePng(row.bytes, `P-35 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-35 ${field} is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (hashes.size !== SCREENSHOTS.length) fail("P-35 screenshots are reused across states");
  const expectedNames = ["Diagnostics export", "Export written", "Daemon unavailable", "Connected"];
  ACCESSIBILITY.forEach((field, index) => {
    const row = artifact(repoRoot, document.environmentId, document.evidence[field], `P-35 ${field}`, { mediaType: "json", minimumBytes: 300 });
    validateA11y(row, `P-35 ${field}`, timing.startedAt, timing.endedAt, expectedNames[index]);
  });
  const evidence = [...envelope.attestation, ...Object.values(document.evidence)];
  if (new Set(evidence.map((entry) => entry.path)).size !== evidence.length) fail("P-35 reuses an evidence artifact");
  return { document, evidence, endedAt: timing.endedAt };
}

export function buildP35Proof({ session, source, collectedAt }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p35-diagnostics-support-proof-v1",
    requirementId: P35_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    package: { version: session.package.version, architecture: session.package.architecture, format: session.package.format },
    collectedAt,
    source: { method: "live-installed-diagnostics-support-session", ...source },
    claim: {
      installedSupportRoute: true,
      metadataOnlyExport: true,
      privateAtomicDestination: true,
      accurateRuntimeFacts: true,
      boundedReconnectRecovery: true,
      exactRestoration: true,
      replayResistant: true,
    },
  };
}

export function validateP35Proof({ snapshot, repoRoot, targetHead, environmentId, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256 }) {
  const value = parseJson(snapshot.bytes, "P-35 proof");
  exactKeys(value, ["candidate", "claim", "collectedAt", "environmentId", "id", "package", "requirementId", "schemaVersion", "source", "targetHead"], "P-35 proof");
  if (value.schemaVersion !== 1 || value.id !== "openburnbar-linux-p35-diagnostics-support-proof-v1" || value.requirementId !== P35_REQUIREMENT_ID || value.targetHead !== targetHead || value.environmentId !== environmentId || String(value.candidate?.runId) !== String(candidateRunId) || value.candidate?.artifactDigest !== candidateArtifactDigest)
    fail("P-35 proof binding is invalid");
  exactKeys(value.package, ["architecture", "format", "version"], "P-35 proof package");
  exactKeys(value.claim, ["accurateRuntimeFacts", "boundedReconnectRecovery", "exactRestoration", "installedSupportRoute", "metadataOnlyExport", "privateAtomicDestination", "replayResistant"], "P-35 claim");
  if (!Object.values(value.claim).every((item) => item === true)) fail("P-35 claim is incomplete");
  exactKeys(value.source, ["method", "path", "sha256", "size"], "P-35 proof source");
  if (value.source.method !== "live-installed-diagnostics-support-session") fail("P-35 proof source is not live");
  const source = artifact(repoRoot, environmentId, { path: value.source.path, sha256: value.source.sha256, size: value.source.size }, "P-35 session source", { mediaType: "json", minimumBytes: 1000 });
  const sourceDocument = parseJson(source.bytes, "P-35 source session");
  const validated = validateP35InstalledSession(sourceDocument, {
    repoRoot,
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest,
    packageVersion,
    manifestSha256,
    manifestSignatureSha256,
  });
  if (value.package.version !== sourceDocument.package.version || value.package.architecture !== sourceDocument.package.architecture || value.package.format !== sourceDocument.package.format) fail("P-35 proof package does not match its signed source session");
  validateCollectedAt(value.collectedAt, validated.endedAt);
  return { ...value, evidence: validated.evidence };
}
