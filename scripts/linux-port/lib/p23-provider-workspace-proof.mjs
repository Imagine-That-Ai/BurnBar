import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P23_REQUIREMENT_ID = "P-23";
export const P23_PROOF_ROLE = "feature.provider-workspace-installed";
export const P23_PROOF_FILENAME = "p23-installed-provider-workspace-proof.json";
export const P23_SESSION_FILENAME =
  "p23-installed-provider-workspace-session.json";

const MARKER = /^p23-[a-f0-9]{16}$/u;
const ID = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/u;
const PHASES = Object.freeze([
  "config-original",
  "catalog-original",
  "quota-original",
  "route-log-baseline",
  "client-attach",
  "client-claim",
  "manual-a-config",
  "manual-a-run",
  "manual-a-route",
  "manual-b-config",
  "manual-b-run",
  "manual-b-route",
  "custom-upsert",
  "alias-upsert",
  "variant-upsert",
  "automatic-drain-config",
  "automatic-drain-run",
  "automatic-drain-route",
  "restart-config",
  "degraded-config",
  "unavailable-config",
  "restore-config",
  "restore-restart-config",
]);
const METHODS = Object.freeze([
  "daemon.config.get",
  "daemon.catalog",
  "daemon.quota.signals.recent",
  "daemon.proxy.route_log.recent",
  "client.attach",
  "client.claimControl",
  "daemon.config.update",
  "run.create",
  "daemon.proxy.route_log.recent",
  "daemon.config.update",
  "run.create",
  "daemon.proxy.route_log.recent",
  "daemon.provider.custom_model.upsert",
  "daemon.provider.model_alias.upsert",
  "daemon.provider.model_variant.upsert",
  "daemon.config.update",
  "run.create",
  "daemon.proxy.route_log.recent",
  "daemon.config.get",
  "daemon.config.update",
  "daemon.config.update",
  "daemon.config.update",
  "daemon.config.get",
]);
const UI_PHASES = Object.freeze([
  "detail",
  "model-deep-link",
  "deep-link-restoration",
  "degraded",
  "unavailable",
]);
const SUCCESS = new Set(["exact", "same_model_failover"]);
const FOUNDATION_REFERENCE_EPOCH_MS = Date.UTC(2001, 0, 1);

function fail(message) {
  throw new Error(message);
}
function timestamp(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function nativeTimestamp(value, label) {
  const parsed =
    typeof value === "number" && Number.isFinite(value)
      ? FOUNDATION_REFERENCE_EPOCH_MS + value * 1000
      : Number.NaN;
  if (!Number.isFinite(parsed)) fail(`${label} native timestamp is invalid`);
  return parsed;
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P23_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function providerID(value) {
  return String(
    value?.providerID ?? value?.providerId ?? value?.id ?? "",
  ).trim();
}
function snapshotOf(result) {
  return result?.snapshot ?? result;
}
function provider(snapshot, id) {
  return (snapshot?.providers ?? []).find((row) => providerID(row) === id);
}
function routeAccount(entry) {
  return String(entry?.accountID ?? entry?.accountId ?? "").trim();
}
function routeProvider(entry) {
  return String(entry?.providerID ?? entry?.providerId ?? "").trim();
}
function containsSecret(value) {
  if (!value || typeof value !== "object") return false;
  if (Array.isArray(value)) return value.some(containsSecret);
  const keys = new Set([
    "apiKey",
    "api_key",
    "apiKeyRef",
    "api_key_ref",
    "credential",
    "credentialRef",
    "databaseKey",
    "key",
    "passphrase",
    "secret",
    "secretRef",
    "token",
    "tokenRef",
  ]);
  return Object.entries(value).some(
    ([key, child]) => keys.has(key) || containsSecret(child),
  );
}
function successful(event, label) {
  if (
    event.ok !== true ||
    event.error !== null ||
    !event.result ||
    typeof event.result !== "object"
  )
    fail(`${label} is not a successful daemon call`);
  return event.result;
}
function exactConfig(snapshot, marker, stage) {
  const row = provider(snapshot, marker.providerID);
  if (!row) fail(`P-23 ${stage} omitted the selected provider`);
  const a = (row.credentialSlots ?? []).find(
    (slot) => slot.slotID === marker.slotA.slotID,
  );
  const b = (row.credentialSlots ?? []).find(
    (slot) => slot.slotID === marker.slotB.slotID,
  );
  if (!a || !b) fail(`P-23 ${stage} omitted selected credential slots`);
  nativeTimestamp(a.updatedAt, `P-23 ${stage} slot A updatedAt`);
  nativeTimestamp(b.updatedAt, `P-23 ${stage} slot B updatedAt`);
  return { row, a, b };
}
function modelLifecycle(snapshot, marker, label) {
  const { row } = exactConfig(snapshot, marker, label);
  if (
    !row.customModels?.some((item) => item.modelID === marker.customModelID) ||
    !row.modelAliases?.some(
      (item) =>
        item.aliasID === marker.aliasID &&
        item.baseModelID === marker.baseModelID,
    ) ||
    !row.modelVariants?.some(
      (item) =>
        item.variantID === marker.variantID &&
        item.baseModelID === marker.baseModelID,
    )
  )
    fail(`P-23 ${label} omitted provider model lifecycle mutations`);
}
function validateRoute(event, marker, slot, label) {
  const result = successful(event, label);
  if (
    result.id !== marker.liveRouteEvidence[label] ||
    routeProvider(result) !== marker.providerID ||
    routeAccount(result) !== slot ||
    !SUCCESS.has(result.finalStatus) ||
    (result.httpStatus != null && result.httpStatus >= 400) ||
    !Number.isFinite(nativeTimestamp(result.occurredAt, `P-23 ${label}`)) ||
    typeof result.clientModelSlug !== "string" ||
    !result.clientModelSlug.includes(marker.baseModelID)
  )
    fail(`P-23 ${label} is not a native successful credential route`);
}
function validateMarker(value) {
  exactKeys(
    value,
    [
      "aliasID",
      "baseModelID",
      "customModelID",
      "liveRouteEvidence",
      "marker",
      "providerID",
      "providerLabel",
      "safety",
      "slotA",
      "slotB",
      "variantID",
    ],
    "P-23 marker",
  );
  if (
    !MARKER.test(value.marker ?? "") ||
    !ID.test(value.providerID ?? "") ||
    !ID.test(value.baseModelID ?? "") ||
    !ID.test(value.customModelID ?? "") ||
    !ID.test(value.aliasID ?? "") ||
    !ID.test(value.variantID ?? "") ||
    typeof value.providerLabel !== "string" ||
    value.providerLabel.length === 0 ||
    !value.customModelID.includes(value.marker.slice(-8)) ||
    !value.aliasID.includes(value.marker.slice(-8)) ||
    !value.variantID.includes(value.marker.slice(-8))
  )
    fail("P-23 marker identity is invalid");
  for (const [label, slot] of [
    ["slotA", value.slotA],
    ["slotB", value.slotB],
  ]) {
    exactKeys(slot, ["label", "slotID"], `P-23 ${label}`);
    if (
      !ID.test(slot.slotID ?? "") ||
      typeof slot.label !== "string" ||
      !slot.label.trim()
    )
      fail(`P-23 ${label} is invalid`);
  }
  if (value.slotA.slotID === value.slotB.slotID)
    fail("P-23 marker does not identify two credential slots");
  exactKeys(
    value.liveRouteEvidence,
    ["automaticDrain", "manualA", "manualB"],
    "P-23 route evidence",
  );
  if (
    Object.values(value.liveRouteEvidence).some(
      (id) => typeof id !== "string" || !id,
    ) ||
    new Set(Object.values(value.liveRouteEvidence)).size !== 3
  )
    fail("P-23 route evidence identity is invalid");
  exactKeys(
    value.safety,
    [
      "controlledQuotaStateMutation",
      "credentialsRecorded",
      "originalConfigRestored",
      "unsupportedLiveFailoverClaimed",
    ],
    "P-23 safety",
  );
  if (
    value.safety.credentialsRecorded !== false ||
    value.safety.originalConfigRestored !== true ||
    value.safety.controlledQuotaStateMutation !== true ||
    value.safety.unsupportedLiveFailoverClaimed !== false
  )
    fail("P-23 safety boundary is invalid");
}

function validateDaemon(snapshot, marker, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, "P-23 daemon transcript");
  exactKeys(
    value,
    ["events", "producer", "startedAt", "transport"],
    "P-23 daemon transcript",
  );
  if (
    value.producer !== "openburnbar-p23-installed-provider-daemon-probe-v1" ||
    value.transport !== "installed daemon AF_UNIX RPC" ||
    !Array.isArray(value.events) ||
    value.events.length !== PHASES.length ||
    containsSecret(value)
  )
    fail("P-23 daemon transcript is incomplete or contains credentials");
  const startedAt = timestamp(value.startedAt, "P-23 daemon start");
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["at", "error", "method", "ok", "phase", "request", "result"],
      `P-23 daemon event ${index}`,
    );
    const at = timestamp(event.at, `P-23 ${event.phase}`);
    if (
      event.phase !== PHASES[index] ||
      event.method !== METHODS[index] ||
      at <= previous ||
      at < captureStart ||
      at > captureEnd ||
      at < startedAt
    )
      fail(`P-23 daemon event ${index} is out of order or unbound`);
    successful(event, `P-23 ${event.phase}`);
    previous = at;
  }
  const e = value.events;
  const original = snapshotOf(e[0].result);
  const originalProvider = exactConfig(original, marker, "original config").row;
  const catalog = e[1].result.catalog ?? e[1].result;
  const catalogRow = (catalog.providers ?? []).find(
    (row) => providerID(row) === marker.providerID,
  );
  if (
    !catalogRow ||
    !(catalogRow.models ?? []).some(
      (row) => String(row.id ?? row.modelID) === marker.baseModelID,
    )
  )
    fail("P-23 canonical daemon catalog omitted the selected model");
  if (e[2].request.limit !== 200 || e[3].request.limit !== 200)
    fail("P-23 bounded observability requests are invalid");
  const clientID = `p23-proof-${marker.marker}`;
  const sessionID = `p23-session-${marker.marker}`;
  if (
    e[4].request.clientID !== clientID ||
    e[4].request.sessionID !== sessionID ||
    e[5].request.clientID !== clientID
  )
    fail("P-23 client arbitration is not marker-bound");
  const manualA = exactConfig(snapshotOf(e[6].result), marker, "manual A");
  if (
    snapshotOf(e[6].result).routerMode !== "same_model_failover" ||
    manualA.row.preferredCredentialSlotID !== marker.slotA.slotID ||
    manualA.a.status !== "ready" ||
    manualA.b.status !== "ready"
  )
    fail("P-23 manual A policy was not confirmed");
  for (const index of [7, 10, 16]) {
    if (
      e[index].request.clientID !== clientID ||
      e[index].request.sessionID !== sessionID ||
      e[index].request.modelID !== marker.baseModelID ||
      !String(e[index].request.prompt).includes(marker.marker) ||
      !e[index].result.runID
    )
      fail(`P-23 ${e[index].phase} is not a marker-bound live run`);
  }
  validateRoute(e[8], marker, marker.slotA.slotID, "manualA");
  const manualB = exactConfig(snapshotOf(e[9].result), marker, "manual B");
  if (manualB.row.preferredCredentialSlotID !== marker.slotB.slotID)
    fail("P-23 manual B account routing was not confirmed");
  validateRoute(e[11], marker, marker.slotB.slotID, "manualB");
  if (
    e[12].request.providerID !== marker.providerID ||
    e[12].request.customModel?.modelID !== marker.customModelID ||
    e[13].request.alias?.aliasID !== marker.aliasID ||
    e[13].request.alias?.baseModelID !== marker.baseModelID ||
    e[14].request.variant?.variantID !== marker.variantID ||
    e[14].request.variant?.baseModelID !== marker.baseModelID ||
    e[14].request.variant?.thinkingLevel !== "high" ||
    !Number.isFinite(
      nativeTimestamp(
        e[12].request.customModel?.createdAt,
        "P-23 custom model createdAt",
      ),
    ) ||
    !Number.isFinite(
      nativeTimestamp(e[13].request.alias?.createdAt, "P-23 alias createdAt"),
    ) ||
    !Number.isFinite(
      nativeTimestamp(
        e[14].request.variant?.createdAt,
        "P-23 variant createdAt",
      ),
    )
  )
    fail("P-23 typed model lifecycle requests are invalid");
  modelLifecycle(snapshotOf(e[14].result), marker, "model mutation readback");
  const drain = exactConfig(
    snapshotOf(e[15].result),
    marker,
    "automatic drain",
  );
  if (
    snapshotOf(e[15].result).routerMode !== "same_model_failover" ||
    drain.row.preferredCredentialSlotID !== marker.slotA.slotID ||
    drain.a.status !== "exhausted" ||
    drain.a.lastQuotaRemainingPercent !== 0 ||
    drain.b.status !== "ready"
  )
    fail("P-23 deterministic quota drain policy is invalid");
  validateRoute(e[17], marker, marker.slotB.slotID, "automaticDrain");
  modelLifecycle(snapshotOf(e[18].result), marker, "restart readback");
  const restart = exactConfig(
    snapshotOf(e[18].result),
    marker,
    "restart readback",
  );
  if (
    restart.row.preferredCredentialSlotID !== marker.slotA.slotID ||
    snapshotOf(e[18].result).routerMode !== "same_model_failover"
  )
    fail("P-23 restart lost routing policy");
  const degraded = exactConfig(
    snapshotOf(e[19].result),
    marker,
    "degraded readback",
  );
  if (
    degraded.a.status !== "coolingDown" ||
    degraded.b.status !== "coolingDown"
  )
    fail("P-23 degraded state is not daemon-confirmed");
  const unavailable = exactConfig(
    snapshotOf(e[20].result),
    marker,
    "unavailable readback",
  );
  if (
    unavailable.a.status !== "missingSecret" ||
    unavailable.b.status !== "missingSecret"
  )
    fail("P-23 unavailable state is not daemon-confirmed");
  if (
    JSON.stringify(snapshotOf(e[21].result)) !== JSON.stringify(original) ||
    JSON.stringify(snapshotOf(e[22].result)) !== JSON.stringify(original)
  )
    fail("P-23 original daemon config was not restored across restart");
  if (JSON.stringify(originalProvider).includes(marker.marker))
    fail("P-23 original config was already contaminated by this proof marker");
  return {
    daemonEvents: e.length,
    liveCredentialRoutes: 3,
    lifecycleMutations: 3,
  };
}

function validateUI(
  snapshot,
  marker,
  manifestSha256,
  captureStart,
  captureEnd,
) {
  const value = parseJson(snapshot.bytes, "P-23 UI transcript");
  exactKeys(value, ["events", "producer"], "P-23 UI transcript");
  if (
    value.producer !== "openburnbar-p23-installed-provider-ui-probe-v1" ||
    !Array.isArray(value.events) ||
    value.events.length !== UI_PHASES.length
  )
    fail("P-23 UI transcript is incomplete");
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["appPid", "at", "manifestSha256", "marker", "observed", "phase"],
      `P-23 UI event ${index}`,
    );
    const at = timestamp(event.at, `P-23 UI ${event.phase}`);
    if (
      event.phase !== UI_PHASES[index] ||
      at <= previous ||
      at < captureStart ||
      at > captureEnd ||
      !Number.isSafeInteger(event.appPid) ||
      event.appPid <= 1 ||
      event.marker !== marker.marker ||
      event.manifestSha256 !== manifestSha256
    )
      fail(`P-23 UI event ${index} is out of order or unbound`);
    previous = at;
  }
  const [detail, model, deep, degraded, unavailable] = value.events.map(
    (event) => event.observed,
  );
  if (
    detail?.workspace !== true ||
    detail?.provider !== true ||
    detail?.health !== true ||
    detail?.failover !== true ||
    detail?.account !== true ||
    detail?.exhausted !== true ||
    model?.custom !== true ||
    model?.alias !== true ||
    model?.variant !== true ||
    model?.focused !== true ||
    deep?.provider !== true ||
    deep?.alias !== true ||
    deep?.focused !== true ||
    degraded?.degraded !== true ||
    degraded?.unavailableFailover !== true ||
    degraded?.cooling !== true ||
    unavailable?.unavailable !== true ||
    unavailable?.missing !== true ||
    unavailable?.routeUnavailable !== true
  )
    fail("P-23 installed provider workspace UI does not prove required states");
}

export function validateP23InstalledSession(
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
    "P-23 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !==
      "openburnbar-linux-p23-installed-provider-workspace-session-v1"
  )
    fail("P-23 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P23_REQUIREMENT_ID,
    "P-23 installed session",
  );
  validateMarker(document.marker);
  exactKeys(
    document.evidence,
    [
      "daemonTranscript",
      "deepLinkScreenshot",
      "degradedScreenshot",
      "detailScreenshot",
      "modelScreenshot",
      "uiTranscript",
      "unavailableScreenshot",
    ],
    "P-23 evidence",
  );
  const daemon = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.daemonTranscript,
    "P-23 daemon transcript",
    { mediaType: "json", minimumBytes: 4000 },
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
    "P-23 UI transcript",
    { mediaType: "json", minimumBytes: 500 },
  );
  validateUI(
    ui,
    document.marker,
    binding.manifestSha256,
    envelope.startedAt,
    envelope.endedAt,
  );
  const hashes = new Set();
  for (const field of [
    "detailScreenshot",
    "modelScreenshot",
    "deepLinkScreenshot",
    "degradedScreenshot",
    "unavailableScreenshot",
  ]) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-23 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-23 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-23 ${field} is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (hashes.size !== 5) fail("P-23 screenshots replay the same UI state");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-23 reuses an evidence artifact");
  return { document, evidence, endedAt: envelope.endedAt, ...summary };
}

export function buildP23Proof({
  session,
  source,
  collectedAt,
  daemonEvents,
  liveCredentialRoutes,
  lifecycleMutations,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p23-provider-workspace-proof-v1",
    requirementId: P23_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-provider-workspace-session", ...source },
    claim: {
      passed: true,
      daemonEvents,
      liveCredentialRoutes,
      lifecycleMutations,
      canonicalCatalog: true,
      liveCredentialAccounts: true,
      manualAccountRouting: true,
      automaticQuotaDrain: true,
      customAliasVariantLifecycle: true,
      daemonRestartPersistence: true,
      deepLinkRestoration: true,
      keyboardFocus: true,
      degradedAndUnavailableStates: true,
      originalConfigRestored: true,
      credentialsExcluded: true,
      accessibleUI: true,
    },
  };
}

export function validateP23Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-23 proof");
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
    "P-23 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p23-provider-workspace-proof-v1" ||
    proof.requirementId !== P23_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate?.runId !== String(binding.candidateRunId) ||
    proof.candidate?.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-23 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-23 proof source",
  );
  if (proof.source.method !== "live-installed-provider-workspace-session")
    fail("P-23 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-23 source session",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const validated = validateP23InstalledSession(
    parseJson(source.bytes, "P-23 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  const booleans = [
    "accessibleUI",
    "automaticQuotaDrain",
    "canonicalCatalog",
    "credentialsExcluded",
    "customAliasVariantLifecycle",
    "daemonRestartPersistence",
    "deepLinkRestoration",
    "degradedAndUnavailableStates",
    "keyboardFocus",
    "liveCredentialAccounts",
    "manualAccountRouting",
    "originalConfigRestored",
  ];
  exactKeys(
    proof.claim,
    [
      "daemonEvents",
      "lifecycleMutations",
      "liveCredentialRoutes",
      "passed",
      ...booleans,
    ],
    "P-23 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.daemonEvents !== validated.daemonEvents ||
    proof.claim.liveCredentialRoutes !== 3 ||
    proof.claim.liveCredentialRoutes !== validated.liveCredentialRoutes ||
    proof.claim.lifecycleMutations !== 3 ||
    proof.claim.lifecycleMutations !== validated.lifecycleMutations ||
    booleans.some((field) => proof.claim[field] !== true)
  )
    fail("P-23 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
