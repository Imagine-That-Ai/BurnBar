import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P13_REQUIREMENT_ID = "P-13";
export const P13_PROOF_ROLE = "feature.onboarding-installed";
export const P13_PROOF_FILENAME = "p13-installed-onboarding-proof.json";
export const P13_SESSION_FILENAME = "p13-installed-onboarding-session.json";

const MARKER = /^p13-[a-f0-9]{16}$/u;
const STEPS = Object.freeze([
  ["daemon", "required"],
  ["secret_store", "required"],
  ["provider_paths", "required"],
  ["cloud_identity", "optional"],
  ["portal_input", "optional"],
  ["tray", "optional"],
  ["updates", "optional"],
  ["privacy", "required"],
]);
const PHASES = Object.freeze([
  "reset",
  "completion-gate-rejected",
  "daemon-verified",
  "secret-store-verified",
  "provider-paths-verified",
  "catalog-read",
  "credential-created",
  "credential-readback",
  "credential-removed",
  "cloud-unavailable",
  "cloud-skipped",
  "portal-unavailable",
  "portal-skipped",
  "tray-skipped",
  "updates-unavailable",
  "updates-skipped",
  "privacy-saved",
  "restart-snapshot",
  "privacy-config-readback",
]);
const METHODS = Object.freeze([
  "daemon.onboarding.reset",
  "daemon.onboarding.action",
  "daemon.onboarding.action",
  "daemon.onboarding.action",
  "daemon.onboarding.action",
  "daemon.catalog",
  "daemon.provider.credential_slot.upsert",
  "daemon.config.get",
  "daemon.provider.credential_slot.remove",
  "daemon.onboarding.action",
  "daemon.onboarding.snapshot",
  "daemon.onboarding.snapshot",
  "daemon.onboarding.snapshot",
  "daemon.onboarding.action",
  "daemon.onboarding.action",
  "daemon.onboarding.action",
  "daemon.onboarding.action",
  "daemon.onboarding.snapshot",
  "daemon.config.get",
]);
const UI_PHASES = Object.freeze([
  "provider-setup",
  "cloud-blocked",
  "portal-blocked",
  "privacy",
  "completed",
]);
const UI_ACTIONS = Object.freeze([
  ["cloud-retry", "Retry check"],
  ["cloud-skip", "Skip for now"],
  ["portal-retry", "Check integration"],
  ["portal-skip", "Skip for now"],
]);
const SCREENSHOTS = Object.freeze([
  "providerScreenshot",
  "cloudScreenshot",
  "privacyScreenshot",
  "completedScreenshot",
]);

function fail(message) {
  throw new Error(message);
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P13_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function time(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function successful(event, label) {
  if (
    event?.ok !== true ||
    event.error !== null ||
    !event.result ||
    typeof event.result !== "object"
  )
    fail(`${label} is not a successful installed daemon call`);
  return event.result;
}
function snapshotOf(result) {
  return result?.snapshot ?? result;
}
function step(snapshot, id) {
  return snapshot?.steps?.find((row) => row.id === id);
}
function validateSnapshot(snapshot, label) {
  if (
    snapshot?.schemaVersion !== 1 ||
    !Number.isSafeInteger(snapshot.revision) ||
    snapshot.revision < 0 ||
    !STEPS.some(([id]) => id === snapshot.currentStepID) ||
    !Array.isArray(snapshot.steps) ||
    snapshot.steps.length !== STEPS.length ||
    typeof snapshot.completed !== "boolean"
  )
    fail(`${label} onboarding snapshot is malformed`);
  for (const [index, [id, requirement]] of STEPS.entries()) {
    const row = snapshot.steps[index];
    if (
      row?.id !== id ||
      row.requirement !== requirement ||
      !["pending", "blocked", "verified", "acknowledged", "skipped"].includes(
        row.state,
      ) ||
      !Number.isSafeInteger(row.attemptCount)
    )
      fail(`${label} onboarding step ${index} is malformed`);
  }
  return snapshot;
}
function validateMarker(marker) {
  exactKeys(
    marker,
    ["credentialLabel", "marker", "providerID", "safety", "slotID"],
    "P-13 marker",
  );
  exactKeys(
    marker.safety,
    [
      "credentialMaterialRecordedInEvidence",
      "credentialRemoved",
      "productionOAuthClaimed",
    ],
    "P-13 marker safety",
  );
  if (
    !MARKER.test(marker.marker ?? "") ||
    marker.credentialLabel !== `P13 ${marker.marker}` ||
    marker.slotID !== `p13-${marker.marker.slice(-12)}` ||
    !String(marker.providerID ?? "").length ||
    marker.safety.credentialRemoved !== true ||
    marker.safety.productionOAuthClaimed !== false ||
    marker.safety.credentialMaterialRecordedInEvidence !== false
  )
    fail("P-13 marker or restoration contract is invalid");
}

function validateDaemon(snapshot, marker, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, "P-13 daemon transcript");
  exactKeys(
    value,
    ["events", "producer", "transport"],
    "P-13 daemon transcript",
  );
  if (
    value.producer !== "openburnbar-p13-installed-onboarding-daemon-probe-v1" ||
    value.transport !== "installed daemon AF_UNIX RPC" ||
    !Array.isArray(value.events) ||
    value.events.length !== PHASES.length
  )
    fail("P-13 daemon transcript is incomplete");
  let prior = -Infinity;
  const events = new Map();
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["at", "error", "method", "ok", "phase", "request", "result"],
      `P-13 daemon event ${index}`,
    );
    const at = time(event.at, `P-13 ${event.phase}`);
    if (
      event.phase !== PHASES[index] ||
      event.method !== METHODS[index] ||
      at <= prior ||
      at < startedAt ||
      at > endedAt
    )
      fail(`P-13 daemon event ${index} is out of order or unbound`);
    if (event.phase === "completion-gate-rejected") {
      if (
        event.ok !== false ||
        event.result !== null ||
        !String(event.error ?? "").match(/out.of.order|cannot run|active/iu)
      )
        fail("P-13 premature completion gate did not fail closed");
    } else successful(event, `P-13 ${event.phase}`);
    prior = at;
    events.set(event.phase, event);
  }
  const result = (phase) => events.get(phase).result;
  const reset = validateSnapshot(result("reset"), "P-13 reset");
  const daemon = validateSnapshot(result("daemon-verified"), "P-13 daemon");
  const secret = validateSnapshot(
    result("secret-store-verified"),
    "P-13 secret store",
  );
  const paths = validateSnapshot(
    result("provider-paths-verified"),
    "P-13 provider paths",
  );
  const cloudBlocked = validateSnapshot(
    result("cloud-unavailable"),
    "P-13 cloud unavailable",
  );
  const cloudSkipped = validateSnapshot(
    result("cloud-skipped"),
    "P-13 cloud skipped",
  );
  const portalBlocked = validateSnapshot(
    result("portal-unavailable"),
    "P-13 portal unavailable",
  );
  const portalSkipped = validateSnapshot(
    result("portal-skipped"),
    "P-13 portal skipped",
  );
  const complete = validateSnapshot(result("privacy-saved"), "P-13 complete");
  const restart = validateSnapshot(result("restart-snapshot"), "P-13 restart");
  if (
    reset.completed !== false ||
    reset.currentStepID !== "daemon" ||
    step(daemon, "daemon")?.state !== "verified" ||
    daemon.currentStepID !== "secret_store" ||
    step(secret, "secret_store")?.state !== "verified" ||
    secret.currentStepID !== "provider_paths" ||
    step(paths, "provider_paths")?.state !== "verified" ||
    paths.currentStepID !== "cloud_identity" ||
    step(cloudBlocked, "cloud_identity")?.state !== "blocked" ||
    step(cloudBlocked, "cloud_identity")?.repairAction !== "sign_in" ||
    step(cloudSkipped, "cloud_identity")?.state !== "skipped" ||
    cloudSkipped.currentStepID !== "portal_input" ||
    step(portalBlocked, "portal_input")?.state !== "blocked" ||
    step(portalBlocked, "portal_input")?.repairAction !== "grant_portal" ||
    step(portalSkipped, "portal_input")?.state !== "skipped" ||
    step(
      validateSnapshot(
        result("updates-unavailable"),
        "P-13 updates unavailable",
      ),
      "updates",
    )?.state !== "blocked" ||
    complete.completed !== true ||
    complete.currentStepID !== "privacy" ||
    step(complete, "privacy")?.state !== "verified" ||
    complete.privacyChoices?.telemetryEnabled !== false ||
    complete.privacyChoices?.cloudSyncEnabled !== false ||
    JSON.stringify(restart) !== JSON.stringify(complete)
  )
    fail(
      "P-13 daemon state does not prove required gates, recovery, completion, and restart persistence",
    );
  for (const id of ["tray", "updates"])
    if (step(complete, id)?.state !== "skipped")
      fail(`P-13 ${id} was not explicitly deferred`);
  const catalog = result("catalog-read").catalog ?? result("catalog-read");
  if (
    !Array.isArray(catalog.providers) ||
    !catalog.providers.some(
      (row) => String(row.id ?? row.providerID) === marker.providerID,
    )
  )
    fail("P-13 provider is not bound to the installed daemon catalog");
  const created = result("credential-created");
  const credentialRequest = events.get("credential-created").request;
  const readback = snapshotOf(result("credential-readback"));
  const removed = snapshotOf(result("credential-removed"));
  const findSlot = (config) =>
    config?.providers
      ?.find((row) => row.providerID === marker.providerID)
      ?.credentialSlots?.find((row) => row.slotID === marker.slotID);
  if (
    credentialRequest?.providerID !== marker.providerID ||
    credentialRequest?.slotID !== marker.slotID ||
    credentialRequest?.label !== marker.credentialLabel ||
    credentialRequest?.apiKey !== "[REDACTED]" ||
    created.slot?.slotID !== marker.slotID ||
    created.slot?.label !== marker.credentialLabel ||
    !findSlot(readback) ||
    findSlot(removed) ||
    JSON.stringify(
      snapshotOf(result("privacy-config-readback"))?.telemetryEnabled,
    ) !== "false" ||
    JSON.stringify(
      snapshotOf(result("privacy-config-readback"))?.cloudSyncEnabled,
    ) !== "false"
  )
    fail(
      "P-13 credential or privacy daemon readback/restoration is incomplete",
    );
  return { daemonEvents: value.events.length, revision: complete.revision };
}

function validateUI(snapshot, marker, manifestSha256, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, "P-13 UI transcript");
  exactKeys(
    value,
    ["actions", "events", "producer", "productionAuth"],
    "P-13 UI transcript",
  );
  exactKeys(
    value.productionAuth,
    ["cancelOutcome", "configured", "productionSuccessClaimed", "retryOutcome"],
    "P-13 production auth",
  );
  if (
    value.producer !== "openburnbar-p13-installed-onboarding-ui-probe-v1" ||
    value.productionAuth.productionSuccessClaimed !== false ||
    value.productionAuth.configured !== false ||
    value.productionAuth.cancelOutcome !== "not-started-unavailable" ||
    value.productionAuth.retryOutcome !== "remained-unavailable" ||
    !Array.isArray(value.events) ||
    value.events.length !== UI_PHASES.length ||
    !Array.isArray(value.actions) ||
    value.actions.length !== UI_ACTIONS.length
  )
    fail("P-13 UI transcript overclaims unavailable production authentication");
  let prior = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["appPid", "at", "manifestSha256", "marker", "observed", "phase"],
      `P-13 UI event ${index}`,
    );
    const at = time(event.at, `P-13 UI ${event.phase}`);
    if (
      event.phase !== UI_PHASES[index] ||
      at <= prior ||
      at < startedAt ||
      at > endedAt ||
      !Number.isSafeInteger(event.appPid) ||
      event.appPid <= 1 ||
      event.marker !== marker.marker ||
      event.manifestSha256 !== manifestSha256
    )
      fail(`P-13 UI event ${index} is out of order or unbound`);
    prior = at;
  }
  const [provider, cloud, portal, privacy, complete] = value.events.map(
    (event) => event.observed,
  );
  if (
    provider?.catalogVisible !== true ||
    provider?.credentialFieldVisible !== true ||
    provider?.secureStorageCopyVisible !== true ||
    cloud?.blockedVisible !== true ||
    cloud?.retryVisible !== true ||
    cloud?.skipVisible !== true ||
    portal?.blockedVisible !== true ||
    portal?.retryVisible !== true ||
    portal?.skipVisible !== true ||
    privacy?.choicesVisible !== true ||
    privacy?.saveVisible !== true ||
    complete?.completedVisible !== true ||
    complete?.resetVisible !== true
  )
    fail("P-13 installed UI omits an onboarding gate or recovery control");
  prior = -Infinity;
  for (const [index, action] of value.actions.entries()) {
    exactKeys(action, ["at", "phase", "result"], `P-13 UI action ${index}`);
    exactKeys(
      action.result,
      ["activation", "producer"],
      `P-13 UI action result ${index}`,
    );
    exactKeys(
      action.result.activation,
      ["action", "name", "role"],
      `P-13 UI activation ${index}`,
    );
    const [phase, name] = UI_ACTIONS[index];
    const at = time(action.at, `P-13 UI action ${phase}`);
    if (
      action.phase !== phase ||
      at <= prior ||
      at < startedAt ||
      at > endedAt ||
      action.result.producer !== "openburnbar-p13-atspi-control-v1" ||
      action.result.activation.name !== name ||
      !String(action.result.activation.role).length ||
      !String(action.result.activation.action).length
    )
      fail(`P-13 UI action ${index} is invalid or replayed`);
    prior = at;
  }
  const uiTimes = new Map(
    value.events.map((event) => [event.phase, time(event.at, event.phase)]),
  );
  const actionTimes = new Map(
    value.actions.map((action) => [
      action.phase,
      time(action.at, action.phase),
    ]),
  );
  if (!(
    uiTimes.get("provider-setup") < uiTimes.get("cloud-blocked") &&
    uiTimes.get("cloud-blocked") < actionTimes.get("cloud-retry") &&
    actionTimes.get("cloud-retry") < actionTimes.get("cloud-skip") &&
    actionTimes.get("cloud-skip") < actionTimes.get("portal-retry") &&
    actionTimes.get("portal-retry") < uiTimes.get("portal-blocked") &&
    uiTimes.get("portal-blocked") < actionTimes.get("portal-skip") &&
    actionTimes.get("portal-skip") < uiTimes.get("privacy") &&
    uiTimes.get("privacy") < uiTimes.get("completed")
  ))
    fail("P-13 UI recovery actions are not causally ordered");
  return value.events.length;
}

export function validateP13InstalledSession(
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
    "P-13 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p13-installed-onboarding-session-v1"
  )
    fail("P-13 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P13_REQUIREMENT_ID,
    "P-13 installed session",
  );
  validateMarker(document.marker);
  exactKeys(
    document.evidence,
    [
      "cloudScreenshot",
      "completedScreenshot",
      "daemonTranscript",
      "privacyScreenshot",
      "providerScreenshot",
      "uiTranscript",
    ],
    "P-13 evidence",
  );
  const daemon = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.daemonTranscript,
    "P-13 daemon transcript",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const summary = validateDaemon(
    daemon,
    document.marker,
    envelope.startedAt,
    envelope.endedAt,
  );
  const ui = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.uiTranscript,
    "P-13 UI transcript",
    { mediaType: "json", minimumBytes: 500 },
  );
  const uiStates = validateUI(
    ui,
    document.marker,
    binding.manifestSha256,
    envelope.startedAt,
    envelope.endedAt,
  );
  const hashes = new Set();
  for (const field of SCREENSHOTS) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-13 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-13 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-13 ${field} is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (hashes.size !== SCREENSHOTS.length)
    fail("P-13 screenshots replay a prior UI state");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-13 reuses an evidence artifact");
  return {
    document,
    evidence,
    endedAt: envelope.endedAt,
    uiStates,
    ...summary,
  };
}

export function buildP13Proof({
  session,
  source,
  collectedAt,
  daemonEvents,
  revision,
  uiStates,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p13-onboarding-proof-v1",
    requirementId: P13_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-onboarding-session", ...source },
    claim: {
      passed: true,
      daemonEvents,
      finalRevision: revision,
      uiStates,
      daemonAuthority: true,
      completionGate: true,
      credentialRoundTrip: true,
      privacyReadback: true,
      durableRestart: true,
      recoveryControls: true,
      accessibleUI: true,
      productionOAuthSuccess: false,
    },
  };
}

export function validateP13Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-13 proof");
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
    "P-13 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p13-onboarding-proof-v1" ||
    proof.requirementId !== P13_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-13 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-13 proof source",
  );
  if (proof.source.method !== "live-installed-onboarding-session")
    fail("P-13 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-13 source session",
    { mediaType: "json", minimumBytes: 500 },
  );
  const validated = validateP13InstalledSession(
    parseJson(source.bytes, "P-13 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(
    proof.claim,
    [
      "accessibleUI",
      "completionGate",
      "credentialRoundTrip",
      "daemonAuthority",
      "daemonEvents",
      "durableRestart",
      "finalRevision",
      "passed",
      "privacyReadback",
      "productionOAuthSuccess",
      "recoveryControls",
      "uiStates",
    ],
    "P-13 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.daemonEvents !== validated.daemonEvents ||
    proof.claim.finalRevision !== validated.revision ||
    proof.claim.uiStates !== validated.uiStates ||
    proof.claim.productionOAuthSuccess !== false ||
    [
      "accessibleUI",
      "completionGate",
      "credentialRoundTrip",
      "daemonAuthority",
      "durableRestart",
      "privacyReadback",
      "recoveryControls",
    ].some((field) => proof.claim[field] !== true)
  )
    fail("P-13 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
