import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P29_REQUIREMENT_ID = "P-29";
export const P29_PROOF_ROLE = "feature.text-expansion-installed";
export const P29_PROOF_FILENAME = "p29-installed-text-expansion-proof.json";
export const P29_SESSION_FILENAME = "p29-installed-text-expansion-session.json";

const SHA256 = /^[a-f0-9]{64}$/u;
const MARKER = /^p29-[a-f0-9]{16}$/u;
const SCREENSHOTS = Object.freeze([
  "consentScreenshot",
  "createdScreenshot",
  "editedScreenshot",
  "expandedScreenshot",
  "secureDeniedScreenshot",
  "restoredScreenshot",
]);
const ATSPI = Object.freeze([
  "consentAccessibility",
  "createdAccessibility",
  "editedAccessibility",
  "expandedAccessibility",
  "secureDeniedAccessibility",
  "restoredAccessibility",
]);

function fail(message) {
  throw new Error(message);
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P29_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function timestamp(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function truthy(value, fields, label) {
  exactKeys(value, fields, label);
  for (const field of fields)
    if (value[field] !== true) fail(`${label}.${field} must be true`);
}
function validateMarker(value) {
  exactKeys(
    value,
    [
      "installedDaemon",
      "installedDesktop",
      "marker",
      "packageOwned",
      "producer",
    ],
    "P-29 marker",
  );
  if (
    !MARKER.test(value.marker ?? "") ||
    value.installedDaemon !== "/usr/libexec/openburnbar-daemon-launch" ||
    value.installedDesktop !== "/usr/bin/openburnbar-linux-desktop" ||
    value.packageOwned !== true ||
    value.producer !== "openburnbar-p29-installed-probe-v1"
  )
    fail("P-29 installed marker is invalid");
}
function validateNative(value, marker, envelope, binding) {
  exactKeys(
    value,
    [
      "atspiApplication",
      "endedAt",
      "engine",
      "keyring",
      "marker",
      "operations",
      "persistence",
      "producer",
      "restoration",
      "safety",
      "startedAt",
      "store",
    ],
    "P-29 native transcript",
  );
  const startedAt = timestamp(value.startedAt, "P-29 native start");
  const endedAt = timestamp(value.endedAt, "P-29 native end");
  if (
    value.producer !== "openburnbar-p29-installed-probe-v1" ||
    value.marker !== marker.marker ||
    startedAt < envelope.startedAt ||
    endedAt > envelope.endedAt ||
    endedAt <= startedAt ||
    value.atspiApplication !== "OpenBurnBar"
  )
    fail("P-29 native transcript is not bound to the installed session");
  exactKeys(
    value.keyring,
    ["backend", "keyCreated", "keyRemovedForProbe", "keyRestored", "reachable"],
    "P-29 keyring",
  );
  if (
    !["secret-service", "kwallet"].includes(value.keyring.backend) ||
    value.keyring.reachable !== true ||
    value.keyring.keyCreated !== true ||
    value.keyring.keyRemovedForProbe !== true ||
    value.keyring.keyRestored !== true
  )
    fail("P-29 did not prove native keyring custody and restoration");
  exactKeys(
    value.engine,
    [
      "backend",
      "cancellationStopped",
      "engineID",
      "killSwitchStopped",
      "manifestSha256",
      "previousEngine",
      "previousEngineRestored",
      "reachable",
      "registration",
      "selectedEngine",
      "securePolicy",
    ],
    "P-29 engine",
  );
  if (
    value.engine.backend !== "ibus" ||
    value.engine.reachable !== true ||
    value.engine.registration !== "registered" ||
    value.engine.securePolicy !==
      "deny-unless-inspectable-and-explicitly-nonsecure" ||
    value.engine.cancellationStopped !== true ||
    value.engine.killSwitchStopped !== true ||
    value.engine.selectedEngine !== "openburnbar" ||
    typeof value.engine.previousEngine !== "string" ||
    value.engine.previousEngine.length === 0 ||
    value.engine.previousEngineRestored !== true ||
    !SHA256.test(value.engine.manifestSha256 ?? "") ||
    typeof value.engine.engineID !== "string" ||
    !value.engine.engineID
  )
    fail(
      "P-29 did not prove the registered input-method engine safety contract",
    );
  exactKeys(
    value.store,
    [
      "ciphertextSha256",
      "containsPlaintext",
      "mode",
      "ownerUid",
      "path",
      "symlink",
    ],
    "P-29 encrypted store",
  );
  if (
    !SHA256.test(value.store.ciphertextSha256 ?? "") ||
    value.store.containsPlaintext !== false ||
    value.store.mode !== "0600" ||
    value.store.ownerUid !== 0 + (process.getuid?.() ?? value.store.ownerUid) ||
    value.store.symlink !== false ||
    !/text-expansion-v1\.obbsealed$/u.test(value.store.path ?? "")
  )
    fail("P-29 encrypted store receipt is invalid");
  exactKeys(
    value.operations,
    ["consent", "create", "delete", "edit", "expand", "import", "secureField"],
    "P-29 operations",
  );
  truthy(
    value.operations.consent,
    ["declinedGlobalCapture", "inAppOnly", "persisted", "systemIMEEnabled"],
    "P-29 consent",
  );
  for (const name of ["create", "edit", "delete", "import"])
    truthy(
      value.operations[name],
      ["mutated", "readback", "revisionAdvanced"],
      `P-29 ${name}`,
    );
  exactKeys(
    value.operations.expand,
    [
      "expanded",
      "after",
      "before",
      "fieldApplication",
      "fieldRole",
      "inputMethod",
      "probePID",
      "replacementMatched",
      "triggerOnly",
    ],
    "P-29 expansion",
  );
  if (
    value.operations.expand.expanded !== true ||
    value.operations.expand.replacementMatched !== true ||
    value.operations.expand.triggerOnly !== true ||
    value.operations.expand.inputMethod !== "ibus" ||
    value.operations.expand.fieldApplication !== "OpenBurnBar P29 IBus Probe" ||
    value.operations.expand.fieldRole !== "text" ||
    value.operations.expand.before !== "" ||
    value.operations.expand.after !== `expanded-${value.marker}-edited ` ||
    !Number.isSafeInteger(value.operations.expand.probePID) ||
    value.operations.expand.probePID <= 1
  )
    fail("P-29 trigger expansion is invalid");
  exactKeys(
    value.operations.secureField,
    [
      "denied",
      "after",
      "before",
      "fieldApplication",
      "fieldRole",
      "inputMethod",
      "inspectable",
      "isSecureField",
      "probePID",
      "replacementPresent",
    ],
    "P-29 secure-field denial",
  );
  if (
    value.operations.secureField.denied !== true ||
    value.operations.secureField.inspectable !== true ||
    value.operations.secureField.isSecureField !== true ||
    value.operations.secureField.inputMethod !== "ibus" ||
    value.operations.secureField.fieldApplication !== "OpenBurnBar P29 IBus Probe" ||
    value.operations.secureField.fieldRole !== "password text" ||
    value.operations.secureField.before !== "" ||
    value.operations.secureField.after !== `&&${value.marker.slice(4)} ` ||
    value.operations.secureField.replacementPresent !== false ||
    value.operations.secureField.probePID !== value.operations.expand.probePID
  )
    fail("P-29 secure field was not denied before write");
  truthy(
    value.persistence,
    [
      "consentAfterRestart",
      "corruptionFailedClosed",
      "missingKeyFailedClosed",
      "snippetAfterRestart",
    ],
    "P-29 persistence",
  );
  truthy(
    value.safety,
    [
      "fixtureModeFalse",
      "noClipboardPayload",
      "noGlobalCapture",
      "noKeyboardPayload",
      "noSurroundingTextPayload",
    ],
    "P-29 safety",
  );
  truthy(
    value.restoration,
    [
      "daemonService",
      "desktopProcesses",
      "engineStopped",
      "keyring",
      "originalStore",
      "snippets",
    ],
    "P-29 restoration",
  );
  if (value.engine.manifestSha256 === binding.manifestSha256)
    fail("P-29 engine manifest must be distinct from the package manifest");
  return { operationCount: 7 };
}

export function validateP29InstalledSession(
  document,
  binding,
  { repoRoot = binding.repoRoot } = {},
) {
  exactKeys(
    document,
    [
      "candidate",
      "capture",
      "desktop",
      "environmentId",
      "evidence",
      "id",
      "marker",
      "package",
      "requirementId",
      "schemaVersion",
      "targetHead",
    ],
    "P-29 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p29-installed-text-expansion-session-v1"
  )
    fail("P-29 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P29_REQUIREMENT_ID,
    "P-29 installed session",
  );
  validateMarker(document.marker);
  exactKeys(
    document.evidence,
    ["nativeTranscript", ...SCREENSHOTS, ...ATSPI],
    "P-29 evidence",
  );
  const nativeRecord = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.nativeTranscript,
    "P-29 native transcript",
    { mediaType: "json", minimumBytes: 1200 },
  );
  const summary = validateNative(
    parseJson(nativeRecord.bytes, "P-29 native transcript"),
    document.marker,
    envelope,
    binding,
  );
  const screenshotHashes = new Set();
  for (const field of SCREENSHOTS) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-29 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-29 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-29 ${field} is blank`);
    screenshotHashes.add(
      crypto.createHash("sha256").update(png.pixels).digest("hex"),
    );
  }
  if (screenshotHashes.size !== SCREENSHOTS.length)
    fail("P-29 screenshots are reused across distinct states");
  for (const field of ATSPI) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-29 ${field}`,
      { mediaType: "json", minimumBytes: 100 },
    );
    const tree = parseJson(record.bytes, `P-29 ${field}`);
    const inputProbe = field === "expandedAccessibility" || field === "secureDeniedAccessibility";
    if (
      tree.application !== (inputProbe ? "OpenBurnBar P29 IBus Probe" : "OpenBurnBar") ||
      tree.route !== (inputProbe ? "ibus-field-probe" : "text-expansion") ||
      tree.pass !== true ||
      !Array.isArray(tree.nodes) ||
      tree.nodes.length < 8 ||
      JSON.stringify(tree).match(/fixture|synthetic/iu)
    )
      fail(`P-29 ${field} is not live AT-SPI evidence`);
  }
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((entry) => entry.path)).size !== evidence.length)
    fail("P-29 reuses an evidence artifact");
  return { document, evidence, endedAt: envelope.endedAt, ...summary };
}

export function buildP29Proof({
  session,
  source,
  collectedAt,
  operationCount,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p29-text-expansion-proof-v1",
    requirementId: P29_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-text-expansion-session", ...source },
    claim: {
      passed: true,
      operationCount,
      encryptedRestartPersistence: true,
      externalExpansion: true,
      secureFieldFailClosed: true,
      teardownAndRestoration: true,
    },
  };
}

export function validateP29Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-29 proof");
  exactKeys(
    proof,
    [
      "candidate",
      "claim",
      "collectedAt",
      "environmentId",
      "id",
      "requirementId",
      "schemaVersion",
      "source",
      "targetHead",
    ],
    "P-29 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p29-text-expansion-proof-v1" ||
    proof.requirementId !== P29_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-29 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-29 proof source",
  );
  if (proof.source.method !== "live-installed-text-expansion-session")
    fail("P-29 proof source is not live");
  const source = artifact(
    repoRoot,
    binding.environmentId,
    {
      path: proof.source.path,
      sha256: proof.source.sha256,
      size: proof.source.size,
    },
    "P-29 source session",
    { mediaType: "json", minimumBytes: 500 },
  );
  const validated = validateP29InstalledSession(
    parseJson(source.bytes, "P-29 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(
    proof.claim,
    [
      "encryptedRestartPersistence",
      "externalExpansion",
      "operationCount",
      "passed",
      "secureFieldFailClosed",
      "teardownAndRestoration",
    ],
    "P-29 claim",
  );
  if (
    proof.claim.operationCount !== validated.operationCount ||
    Object.entries(proof.claim).some(
      ([key, value]) => key !== "operationCount" && value !== true,
    )
  )
    fail("P-29 proof claim is not derived from its session");
  return {
    proof,
    source: {
      path: proof.source.path,
      sha256: proof.source.sha256,
      size: proof.source.size,
    },
    evidence: validated.evidence,
  };
}
