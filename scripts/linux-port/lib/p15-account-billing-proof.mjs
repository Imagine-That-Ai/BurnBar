import crypto from "node:crypto";
import { exactKeys, parseJson, validateArtifact, validateCollectedAt, validateInstalledSessionEnvelope, validatePng } from "./installed-ui-proof.mjs";

export const P15_REQUIREMENT_ID = "P-15";
export const P15_PROOF_ROLE = "feature.account-billing-installed";
export const P15_PROOF_FILENAME = "p15-installed-account-billing-proof.json";
export const P15_SESSION_FILENAME = "p15-installed-account-billing-session.json";
export const P15_RAW_FILES = Object.freeze([
  "account-marker.json", "account-native-transcript.json",
  "account-initial.png", "account-action.png", "account-degraded.png", "account-recovered.png",
  "account-initial-atspi.json", "account-action-atspi.json", "account-degraded-atspi.json", "account-recovered-atspi.json",
]);

const MARKER = /^p15-[a-f0-9]{16}$/u;
const NONCE = /^[a-f0-9]{32}$/u;
const VERSION = /^v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u;
const SCREENSHOTS = ["initialScreenshot", "actionScreenshot", "degradedScreenshot", "recoveredScreenshot"];
const ACCESSIBILITY = ["initialAccessibility", "actionAccessibility", "degradedAccessibility", "recoveredAccessibility"];
const ACCOUNT_KEYS = ["detail", "deviceApprovalRequired", "identityLabelPresent", "signedIn", "state", "syncState", "trustClass"];
const ENTITLEMENTS = new Set(["burnbar_pro", "hosted_quota_sync", "burnbar_pro_max", "burnbar_ultra"]);

function fail(message) { throw new Error(message); }
function instant(value, label) { const parsed = Date.parse(value); if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`); return parsed; }
function artifact(root, environmentId, record, label, options = {}) { return validateArtifact(root, record, P15_REQUIREMENT_ID, environmentId, label, options); }
function challenge(value, binding) { return crypto.createHash("sha256").update([binding.targetHead, String(binding.candidateRunId), binding.candidateArtifactDigest, value.marker, value.nonce].join("\n")).digest("hex"); }
function noSecrets(value, label) {
  const encoded = JSON.stringify(value);
  if (/(?:authorizationURL|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|paymentMethod|cardNumber|bearer\s|cs_(?:live|test)_)/iu.test(encoded)) fail(`${label} contains credentials, checkout identifiers, or authorization URLs`);
  const strings = [];
  const visit = (item) => { if (typeof item === "string") strings.push(item); else if (Array.isArray(item)) item.forEach(visit); else if (item && typeof item === "object") Object.values(item).forEach(visit); };
  visit(value);
  if (strings.some((item) => item.startsWith("/") || item.includes("@"))) fail(`${label} contains a local path or account identifier`);
}

function validateMarker(value, expected, binding) {
  exactKeys(value, ["challenge", "installed", "marker", "nonce", "package", "producer"], "P-15 marker");
  if (!MARKER.test(value.marker ?? "") || !NONCE.test(value.nonce ?? "") || value.producer !== "openburnbar-p15-installed-account-billing-probe-v1" || value.challenge !== challenge(value, binding)) fail("P-15 marker is forged, stale, or replayed");
  exactKeys(value.installed, ["daemon", "desktop", "packageManager", "packageName", "packageOwned"], "P-15 installed identity");
  const manager = { deb: "dpkg", rpm: "rpm", arch: "pacman" }[expected.format];
  const packageName = expected.format === "arch" ? "openburnbar" : "open-burn-bar";
  if (value.installed.daemon !== "/usr/bin/openburnbar-daemon" || value.installed.desktop !== "/usr/bin/openburnbar-linux-desktop" || value.installed.packageManager !== manager || value.installed.packageName !== packageName || value.installed.packageOwned !== true) fail("P-15 did not use canonical package-owned executables");
  exactKeys(value.package, ["architecture", "format", "manifestSha256", "version"], "P-15 package identity");
  if (value.package.architecture !== expected.architecture || value.package.format !== expected.format || value.package.version !== binding.packageVersion || value.package.manifestSha256 !== binding.manifestSha256) fail("P-15 package identity is not closure-bound");
}

function validateAccount(value, label) {
  exactKeys(value, ACCOUNT_KEYS, label);
  if (!["signed-out", "authorizing", "awaiting-device-approval", "active", "unavailable"].includes(value.state) || typeof value.signedIn !== "boolean" || value.trustClass !== "linux-lower-trust" || !["local-only", "paused", "active"].includes(value.syncState) || typeof value.identityLabelPresent !== "boolean" || typeof value.deviceApprovalRequired !== "boolean") fail(`${label} is not a redacted daemon account status`);
  if (value.identityLabelPresent !== value.signedIn || (!value.signedIn && value.syncState !== "local-only")) fail(`${label} exposes stale identity or sync state`);
  if (value.detail !== null && typeof value.detail !== "string") fail(`${label} detail is invalid`);
  noSecrets(value, label);
}

function validateA11y(snapshot, label, expectedName, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, label);
  const allowedNames = Array.isArray(expectedName) ? expectedName : [expectedName];
  if (value.application !== "OpenBurnBar" || value.route !== "account" || value.pass !== true || value.expectedNamePresent !== true || !allowedNames.includes(value.expectedName) || value.nodeCount < 12 || value.namedNodeCount < 6 || value.actionableNodeCount < 1) fail(`${label} is not live Account-route AT-SPI evidence`);
  const capturedAt = instant(value.capturedAt, `${label} capture`);
  if (capturedAt < startedAt || capturedAt > endedAt) fail(`${label} is outside the live session`);
}

function validateTranscript(value, marker, expected, envelope, binding) {
  exactKeys(value, ["account", "auth", "billing", "challenge", "degradation", "endedAt", "marker", "packageFacts", "producer", "restoration", "startedAt"], "P-15 native transcript");
  const startedAt = instant(value.startedAt, "P-15 native start");
  const endedAt = instant(value.endedAt, "P-15 native end");
  if (value.producer !== marker.producer || value.marker !== marker.marker || value.challenge !== marker.challenge || startedAt < envelope.startedAt || endedAt > envelope.endedAt || endedAt <= startedAt || endedAt - startedAt > 300_000) fail("P-15 native transcript is stale or replayed");
  exactKeys(value.packageFacts, ["architecture", "channel", "desktop", "displayServer", "manager", "os", "packageVersion", "sessionType", "shellVersion"], "P-15 package/runtime facts");
  if (value.packageFacts.architecture !== expected.architecture || value.packageFacts.channel !== expected.format || value.packageFacts.manager !== { deb: "dpkg", rpm: "rpm", arch: "pacman" }[expected.format] || value.packageFacts.packageVersion !== binding.packageVersion || value.packageFacts.shellVersion !== binding.packageVersion || value.packageFacts.os !== "linux" || value.packageFacts.sessionType !== expected.session.toLowerCase() || value.packageFacts.displayServer !== expected.session || value.packageFacts.desktop !== expected.desktop) fail("P-15 package or runtime facts are inaccurate");
  exactKeys(value.account, ["final", "initial", "refreshObserved"], "P-15 account receipt");
  validateAccount(value.account.initial, "P-15 initial account"); validateAccount(value.account.final, "P-15 final account");
  if (value.account.refreshObserved !== true) fail("P-15 did not refresh daemon-owned account state");
  exactKeys(value.auth, ["allowlistedAuthorization", "attempted", "browserCredentialsCollected", "cancelObserved", "cloudDeleteInvalidRejected", "loopbackRedirect", "stateLength"], "P-15 auth receipt");
  if (typeof value.auth.attempted !== "boolean" || value.auth.browserCredentialsCollected !== false || value.auth.cloudDeleteInvalidRejected !== true || (value.auth.attempted && (value.auth.allowlistedAuthorization !== true || value.auth.cancelObserved !== true || value.auth.loopbackRedirect !== true || value.auth.stateLength !== 43)) || (!value.auth.attempted && (value.auth.allowlistedAuthorization !== false || value.auth.cancelObserved !== false || value.auth.loopbackRedirect !== false || value.auth.stateLength !== 0))) fail("P-15 browser auth safety or cancellation is incomplete");
  exactKeys(value.billing, ["checkout", "entitlements", "provenance", "restoreAvailable", "tier"], "P-15 billing receipt");
  if (!["free", "pro"].includes(value.billing.tier) || !Array.isArray(value.billing.entitlements) || value.billing.entitlements.some((item) => !ENTITLEMENTS.has(item)) || value.billing.provenance !== "live-daemon" || typeof value.billing.restoreAvailable !== "boolean") fail("P-15 membership state is not daemon-authoritative");
  exactKeys(value.billing.checkout, ["host", "outcome", "paymentCredentialsCollected"], "P-15 checkout receipt");
  if (!['allowlisted-url', 'fail-closed'].includes(value.billing.checkout.outcome) || value.billing.checkout.paymentCredentialsCollected !== false || (value.billing.checkout.outcome === "allowlisted-url" ? !/^(?:checkout\.stripe\.com|billing\.stripe\.com)$/u.test(value.billing.checkout.host ?? "") : value.billing.checkout.host !== null)) fail("P-15 checkout is embedded, unsafe, or optimistic");
  exactKeys(value.degradation, ["daemonStopped", "degradedVisible", "optimisticSuccess", "reconnectAttemptCount", "reconnectBoundMillis", "recoveredVisible"], "P-15 degradation receipt");
  if (value.degradation.daemonStopped !== true || value.degradation.degradedVisible !== true || value.degradation.optimisticSuccess !== false || value.degradation.reconnectAttemptCount !== 1 || value.degradation.reconnectBoundMillis < 0 || value.degradation.reconnectBoundMillis > 5_000 || value.degradation.recoveredVisible !== true) fail("P-15 degraded recovery is optimistic or unbounded");
  exactKeys(value.restoration, ["daemonActiveAfter", "daemonActiveBefore", "desktopPidsAfter", "desktopPidsBefore", "isolatedStateRestored"], "P-15 restoration");
  if (value.restoration.daemonActiveAfter !== value.restoration.daemonActiveBefore || JSON.stringify(value.restoration.desktopPidsAfter) !== JSON.stringify(value.restoration.desktopPidsBefore) || value.restoration.isolatedStateRestored !== true) fail("P-15 service, process, or state restoration is incomplete");
  noSecrets(value, "P-15 transcript");
  return { startedAt, endedAt, signedInAfter: value.account.final.signedIn };
}

export function validateP15InstalledSession(document, binding, { repoRoot = binding.repoRoot } = {}) {
  exactKeys(document, ["candidate", "capture", "desktop", "environmentId", "evidence", "id", "marker", "package", "requirementId", "schemaVersion", "targetHead"], "P-15 installed session");
  if (document.schemaVersion !== 1 || document.id !== "openburnbar-linux-p15-installed-account-billing-session-v1") fail("P-15 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P15_REQUIREMENT_ID, "P-15 installed session");
  validateMarker(document.marker, envelope.expected, binding);
  exactKeys(document.evidence, ["nativeTranscript", ...SCREENSHOTS, ...ACCESSIBILITY], "P-15 evidence");
  const native = artifact(repoRoot, document.environmentId, document.evidence.nativeTranscript, "P-15 native transcript", { mediaType: "json", minimumBytes: 1000 });
  const timing = validateTranscript(parseJson(native.bytes, "P-15 native transcript"), document.marker, envelope.expected, envelope, binding);
  const hashes = new Set();
  for (const field of SCREENSHOTS) { const row = artifact(repoRoot, document.environmentId, document.evidence[field], `P-15 ${field}`, { mediaType: "png", minimumBytes: 1024 }); const png = validatePng(row.bytes, `P-15 ${field}`); if (png.nonBlankPixelRatio < 0.05) fail(`P-15 ${field} is blank`); hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex")); }
  if (hashes.size !== SCREENSHOTS.length) fail("P-15 screenshots are reused across states");
  ["Identity and sync", "Membership", "Account and sync status need", timing.signedInAfter ? "Signed in as" : "Local-first"].forEach((name, index) => { const field = ACCESSIBILITY[index]; const row = artifact(repoRoot, document.environmentId, document.evidence[field], `P-15 ${field}`, { mediaType: "json", minimumBytes: 300 }); validateA11y(row, `P-15 ${field}`, name, timing.startedAt, timing.endedAt); });
  const evidence = [...envelope.attestation, ...Object.values(document.evidence)];
  if (new Set(evidence.map((entry) => entry.path)).size !== evidence.length) fail("P-15 reuses an evidence artifact");
  return { document, evidence, endedAt: timing.endedAt };
}

export function buildP15Proof({ session, source, collectedAt }) { return { schemaVersion: 1, id: "openburnbar-linux-p15-account-billing-proof-v1", requirementId: P15_REQUIREMENT_ID, environmentId: session.environmentId, targetHead: session.targetHead, candidate: session.candidate, package: { version: session.package.version, architecture: session.package.architecture, format: session.package.format }, collectedAt, source: { method: "live-installed-account-billing-session", ...source }, claim: { installedAccountRoute: true, daemonOwnedIdentity: true, safeExternalBilling: true, authCancellation: true, degradedRecovery: true, exactRestoration: true, replayResistant: true } }; }

export function validateP15Proof({ snapshot, repoRoot, targetHead, environmentId, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256 }) {
  const value = parseJson(snapshot.bytes, "P-15 proof");
  exactKeys(value, ["candidate", "claim", "collectedAt", "environmentId", "id", "package", "requirementId", "schemaVersion", "source", "targetHead"], "P-15 proof");
  if (value.schemaVersion !== 1 || value.id !== "openburnbar-linux-p15-account-billing-proof-v1" || value.requirementId !== P15_REQUIREMENT_ID || value.targetHead !== targetHead || value.environmentId !== environmentId || String(value.candidate?.runId) !== String(candidateRunId) || value.candidate?.artifactDigest !== candidateArtifactDigest) fail("P-15 proof binding is invalid");
  exactKeys(value.package, ["architecture", "format", "version"], "P-15 proof package");
  exactKeys(value.claim, ["authCancellation", "daemonOwnedIdentity", "degradedRecovery", "exactRestoration", "installedAccountRoute", "replayResistant", "safeExternalBilling"], "P-15 claim");
  if (!Object.values(value.claim).every((item) => item === true)) fail("P-15 claim is incomplete");
  exactKeys(value.source, ["method", "path", "sha256", "size"], "P-15 source");
  if (value.source.method !== "live-installed-account-billing-session") fail("P-15 proof source is not live");
  const source = artifact(repoRoot, environmentId, { path: value.source.path, sha256: value.source.sha256, size: value.source.size }, "P-15 session source", { mediaType: "json", minimumBytes: 1000 });
  const validated = validateP15InstalledSession(parseJson(source.bytes, "P-15 source session"), { repoRoot, targetHead, environmentId, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256 });
  if (value.package.version !== packageVersion || value.package.version !== validated.document.package.version || value.package.architecture !== validated.document.package.architecture || value.package.format !== validated.document.package.format) fail("P-15 proof package does not match its closure-bound source");
  validateCollectedAt(value.collectedAt, validated.endedAt);
  return { ...value, evidence: validated.evidence };
}
