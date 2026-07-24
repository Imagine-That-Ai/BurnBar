import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P22_REQUIREMENT_ID = "P-22";
export const P22_PROOF_ROLE = "feature.database-installed";
export const P22_PROOF_FILENAME = "p22-installed-database-proof.json";
export const P22_SESSION_FILENAME = "p22-installed-database-session.json";

const MARKER_PATTERN = /^p22-[a-f0-9]{16}$/u;
const SHA_PATTERN = /^[a-f0-9]{64}$/u;
const DAEMON_PHASES = Object.freeze([
  "index",
  "watch",
  "search",
  "context",
  "explore",
  "index-status",
  "recovery-ready",
  "snapshot",
  "restore",
  "watcher-reopen-search",
  "bundle-export",
  "wrong-passphrase",
  "tampered-bundle",
  "bundle-import",
  "restart-recovery-status",
  "restart-search",
]);
const DAEMON_METHODS = Object.freeze([
  "daemon.code.index_project",
  "daemon.code.watch_project",
  "daemon.code.search",
  "daemon.code.context_pack",
  "daemon.code.explore",
  "daemon.code.index_status",
  "daemon.database.recovery.status",
  "daemon.code.database_snapshot",
  "daemon.code.database_restore",
  "daemon.code.search",
  "daemon.database.recovery_bundle.export",
  "daemon.database.recovery_bundle.import",
  "daemon.database.recovery_bundle.import",
  "daemon.database.recovery_bundle.import",
  "daemon.database.recovery.status",
  "daemon.code.search",
]);
const UI_PHASES = Object.freeze([
  "atlas",
  "inspector",
  "retrieval",
  "system",
  "restart",
]);

function fail(message) {
  throw new Error(message);
}
function timestamp(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P22_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function success(event, label) {
  if (
    event.ok !== true ||
    event.error !== null ||
    !event.result ||
    typeof event.result !== "object"
  )
    fail(`${label} is not a successful installed daemon call`);
  return event.result;
}
function failed(event, label) {
  if (
    event.ok !== false ||
    typeof event.error !== "string" ||
    event.error.length === 0 ||
    event.result !== null
  )
    fail(`${label} did not fail closed`);
}
function exactRequest(event, expected, label) {
  for (const [key, value] of Object.entries(expected))
    if (event.request?.[key] !== value)
      fail(`${label} request is not canonical`);
}
function validateFileMetadata(value, label) {
  exactKeys(value, ["byteCount", "mode", "path", "sha256"], label);
  if (
    !pathLike(value.path) ||
    !Number.isSafeInteger(value.byteCount) ||
    value.byteCount <= 0 ||
    !SHA_PATTERN.test(value.sha256 ?? "") ||
    value.mode !== "0600"
  )
    fail(`${label} is invalid`);
}
function pathLike(value) {
  return (
    typeof value === "string" && value.startsWith("/") && !value.includes("\0")
  );
}
function containsSecretField(value) {
  if (!value || typeof value !== "object") return false;
  if (Array.isArray(value)) return value.some(containsSecretField);
  const secretFields = new Set([
    "databaseKey",
    "database_key",
    "key",
    "passphrase",
    "secret",
  ]);
  return Object.entries(value).some(
    ([key, child]) => secretFields.has(key) || containsSecretField(child),
  );
}

function validateMarker(marker) {
  exactKeys(
    marker,
    [
      "files",
      "marker",
      "projectDir",
      "query",
      "recoveryBundle",
      "recoveryLimits",
      "snapshot",
      "tamperedBundle",
      "watcherQuery",
    ],
    "P-22 marker",
  );
  if (
    !MARKER_PATTERN.test(marker.marker ?? "") ||
    !pathLike(marker.projectDir) ||
    marker.query !== `P22IndexedMarker_${marker.marker.replace(/-/gu, "_")}` ||
    marker.watcherQuery !==
      `P22WatcherMarker_${marker.marker.replace(/-/gu, "_")}`
  )
    fail("P-22 marker identity is invalid");
  if (
    !Array.isArray(marker.files) ||
    marker.files.length !== 14 ||
    new Set(marker.files).size !== 14 ||
    marker.files.some(
      (file) =>
        path.basename(file) !== file || !/^record-\d{2}\.ts$/u.test(file),
    )
  )
    fail("P-22 marker must describe 14 safe populated files");
  validateFileMetadata(marker.snapshot, "P-22 snapshot metadata");
  validateFileMetadata(marker.recoveryBundle, "P-22 recovery bundle metadata");
  validateFileMetadata(marker.tamperedBundle, "P-22 tampered bundle metadata");
  if (
    marker.recoveryBundle.sha256 === marker.tamperedBundle.sha256 ||
    marker.recoveryBundle.byteCount !== marker.tamperedBundle.byteCount
  )
    fail("P-22 tampered bundle is not a distinct same-size mutation");
  exactKeys(
    marker.recoveryLimits,
    ["destructiveKeyLossNotInduced", "deviceTransferNotInduced", "reason"],
    "P-22 recovery limits",
  );
  if (
    marker.recoveryLimits.destructiveKeyLossNotInduced !== true ||
    marker.recoveryLimits.deviceTransferNotInduced !== true ||
    typeof marker.recoveryLimits.reason !== "string" ||
    marker.recoveryLimits.reason.length < 20
  )
    fail("P-22 recovery limits are not explicit");
}

function validateTrust(result, tool, marker, label) {
  if (
    result.trustSignal?.sourceTool !== tool ||
    result.trustSignal?.untrustedContentWrapped !== true
  )
    fail(`${label} omitted the untrusted-source contract`);
  if (
    !Array.isArray(result.hits) ||
    result.hits.length === 0 ||
    result.hits.some(
      (hit) =>
        typeof hit.filePath !== "string" ||
        typeof hit.snippet !== "string" ||
        !hit.snippet.includes(marker.query),
    )
  )
    fail(`${label} did not return marker-bound indexed hits`);
}

function validateDaemon(snapshot, marker, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, "P-22 daemon transcript");
  exactKeys(
    value,
    ["events", "producer", "transport"],
    "P-22 daemon transcript",
  );
  if (
    value.producer !== "openburnbar-p22-installed-database-daemon-probe-v1" ||
    value.transport !== "installed daemon AF_UNIX RPC" ||
    !Array.isArray(value.events) ||
    value.events.length !== DAEMON_PHASES.length
  )
    fail("P-22 daemon transcript is incomplete");
  if (containsSecretField(value))
    fail("P-22 transcript contains recovery secret material");
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["at", "error", "method", "ok", "phase", "request", "result"],
      `P-22 daemon event ${index}`,
    );
    const at = timestamp(event.at, `P-22 ${event.phase}`);
    if (
      event.phase !== DAEMON_PHASES[index] ||
      event.method !== DAEMON_METHODS[index] ||
      at <= previous ||
      at < captureStart ||
      at > captureEnd
    )
      fail(`P-22 daemon event ${index} is out of order or unbound`);
    previous = at;
    if ([11, 12].includes(index)) failed(event, `P-22 ${event.phase}`);
    else success(event, `P-22 ${event.phase}`);
  }
  const e = value.events;
  exactRequest(
    e[0],
    { projectPath: marker.projectDir, maxFiles: 2500, maxFileBytes: 512000 },
    "P-22 index",
  );
  if (
    e[0].result.projectRoot !== marker.projectDir ||
    e[0].result.indexedFiles < 14 ||
    e[0].result.chunkCount < 14
  )
    fail("P-22 populated index result is incomplete");
  exactRequest(
    e[1],
    { projectPath: marker.projectDir, pollIntervalSeconds: 2 },
    "P-22 watch",
  );
  if (
    e[1].result.watching !== true ||
    e[1].result.projectRoot !== marker.projectDir
  )
    fail("P-22 watcher did not start");
  exactRequest(
    e[2],
    { query: marker.query, projectPath: marker.projectDir, limit: 50 },
    "P-22 search",
  );
  validateTrust(e[2].result, "daemon.code.search", marker, "P-22 search");
  if (e[2].result.hits.length < 11)
    fail("P-22 search does not exercise pagination");
  exactRequest(
    e[3],
    {
      query: marker.query,
      projectPath: marker.projectDir,
      limit: 10,
      maxBytes: 24000,
    },
    "P-22 context pack",
  );
  validateTrust(
    e[3].result,
    "daemon.code.context_pack",
    marker,
    "P-22 context pack",
  );
  if (
    typeof e[3].result.context !== "string" ||
    !e[3].result.context.includes(marker.query) ||
    Buffer.byteLength(e[3].result.context) > 24000
  )
    fail("P-22 context pack is unbound or unbounded");
  if (
    !Array.isArray(e[4].result.files) ||
    !e[4].result.files.some((row) => marker.files.includes(row.filePath))
  )
    fail("P-22 explore omitted populated rows");
  if (e[5].result.artifactCount < 14 || e[5].result.databaseEncrypted !== true)
    fail("P-22 index status is not populated and encrypted");
  if (
    e[6].result.phase !== "ready" ||
    e[6].result.canExport !== true ||
    e[6].result.databaseIntegrityVerified !== true
  )
    fail("P-22 recovery status is not real-key ready");
  if (
    e[7].result.databaseEncrypted !== true ||
    e[7].result.integrityCheck !== "ok" ||
    e[7].result.sha256 !== marker.snapshot.sha256 ||
    e[7].result.byteCount !== marker.snapshot.byteCount
  )
    fail("P-22 snapshot is not integrity-bound");
  if (
    e[8].result.databaseEncrypted !== true ||
    e[8].result.integrityCheck !== "ok" ||
    e[8].result.sha256 !== marker.snapshot.sha256
  )
    fail("P-22 restore is not integrity-bound");
  if (
    !Array.isArray(e[9].result.hits) ||
    !e[9].result.hits.some((hit) => hit.snippet?.includes(marker.watcherQuery))
  )
    fail("P-22 watcher did not reopen after restore");
  if (
    e[10].request.passphraseRedacted !== true ||
    "passphrase" in e[10].request ||
    e[10].result.byteCount !== marker.recoveryBundle.byteCount ||
    e[10].result.formatVersion !== 1
  )
    fail("P-22 recovery export is invalid or leaks a secret");
  for (const index of [11, 12, 13])
    if (
      e[index].request.passphraseRedacted !== true ||
      "passphrase" in e[index].request
    )
      fail(`P-22 ${e[index].phase} request leaks a secret`);
  if (
    e[11].request.sourcePath !== marker.recoveryBundle.path ||
    e[12].request.sourcePath !== marker.tamperedBundle.path
  )
    fail("P-22 fail-closed mutations are not artifact-bound");
  if (
    e[13].result.stored !== true ||
    e[13].result.candidateKeyVerified !== true ||
    e[13].result.databaseIntegrityVerified !== true ||
    e[13].result.phase !== "ready"
  )
    fail("P-22 verified recovery import is incomplete");
  if (
    e[14].result.phase !== "ready" ||
    e[14].result.databaseIntegrityVerified !== true
  )
    fail("P-22 daemon restart lost recovery readiness");
  validateTrust(
    e[15].result,
    "daemon.code.search",
    marker,
    "P-22 restart search",
  );
  if (e[15].result.hits.length < 11)
    fail("P-22 daemon restart lost indexed rows");
  return {
    daemonEvents: e.length,
    indexedFiles: e[0].result.indexedFiles,
    failClosedMutations: 2,
  };
}

function validateUI(
  snapshot,
  marker,
  manifestSha256,
  captureStart,
  captureEnd,
) {
  const value = parseJson(snapshot.bytes, "P-22 UI transcript");
  exactKeys(value, ["events", "producer"], "P-22 UI transcript");
  if (
    value.producer !== "openburnbar-p22-installed-database-ui-probe-v1" ||
    !Array.isArray(value.events) ||
    value.events.length !== UI_PHASES.length
  )
    fail("P-22 UI transcript is incomplete");
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["appPid", "at", "manifestSha256", "marker", "observed", "phase"],
      `P-22 UI event ${index}`,
    );
    const at = timestamp(event.at, `P-22 UI ${event.phase}`);
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
      fail(`P-22 UI event ${index} is out of order or unbound`);
    previous = at;
  }
  const [atlas, inspector, retrieval, system, restart] = value.events.map(
    (event) => event.observed,
  );
  if (
    atlas?.populated !== true ||
    atlas?.indexedCorpus !== true ||
    atlas?.inspectAction !== true ||
    inspector?.inspector !== true ||
    inspector?.path !== true ||
    inspector?.metadataOnly !== true ||
    retrieval?.search !== true ||
    retrieval?.pageTwo !== true ||
    retrieval?.contextPack !== true ||
    retrieval?.trustWarning !== true ||
    system?.encrypted !== true ||
    system?.snapshot !== true ||
    system?.recovery !== true ||
    system?.indexControl !== true ||
    restart?.populated !== true ||
    restart?.indexedCorpus !== true
  )
    fail("P-22 installed Database UI does not prove the required states");
}

export function validateP22InstalledSession(
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
    "P-22 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p22-installed-database-session-v1"
  )
    fail("P-22 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P22_REQUIREMENT_ID,
    "P-22 installed session",
  );
  validateMarker(document.marker);
  exactKeys(
    document.evidence,
    [
      "atlasScreenshot",
      "daemonTranscript",
      "inspectorScreenshot",
      "recoveryBundleArtifact",
      "restartScreenshot",
      "retrievalScreenshot",
      "snapshotArtifact",
      "systemScreenshot",
      "tamperedBundleArtifact",
      "uiTranscript",
    ],
    "P-22 evidence",
  );
  const encryptedArtifacts = [
    ["snapshotArtifact", document.marker.snapshot],
    ["recoveryBundleArtifact", document.marker.recoveryBundle],
    ["tamperedBundleArtifact", document.marker.tamperedBundle],
  ];
  for (const [field, metadata] of encryptedArtifacts) {
    const record = document.evidence[field];
    const snapshot = artifact(
      repoRoot,
      document.environmentId,
      record,
      `P-22 ${field}`,
      { minimumBytes: 1 },
    );
    const stat = fs.lstatSync(path.join(repoRoot, record.path));
    if (
      snapshot.bytes.length !== metadata.byteCount ||
      record.sha256 !== metadata.sha256 ||
      (stat.mode & 0o777) !== 0o600 ||
      !stat.isFile() ||
      stat.isSymbolicLink()
    )
      fail(
        `P-22 ${field} bytes or owner-only mode do not match marker metadata`,
      );
  }
  const daemon = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.daemonTranscript,
    "P-22 daemon transcript",
    { mediaType: "json", minimumBytes: 2000 },
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
    "P-22 UI transcript",
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
    "atlasScreenshot",
    "inspectorScreenshot",
    "retrievalScreenshot",
    "systemScreenshot",
    "restartScreenshot",
  ]) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-22 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-22 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-22 ${field} is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (hashes.size !== 5) fail("P-22 screenshots replay the same UI state");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-22 reuses an evidence artifact");
  return { document, evidence, endedAt: envelope.endedAt, ...summary };
}

export function buildP22Proof({
  session,
  source,
  collectedAt,
  daemonEvents,
  indexedFiles,
  failClosedMutations,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p22-database-proof-v1",
    requirementId: P22_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-database-session", ...source },
    claim: {
      passed: true,
      daemonEvents,
      indexedFiles,
      failClosedMutations,
      populatedIndexSearch: true,
      metadataOnlyInspector: true,
      paginationAndContextPack: true,
      daemonRestartPersistence: true,
      watcherReopenAfterRestore: true,
      sqlCipherSnapshotRestore: true,
      nativeKeyRecoveryReady: true,
      recoveryExportImport: true,
      tamperAndWrongPassphraseFailClosed: true,
      destructiveKeyLossNotInduced: true,
      deviceTransferNotInduced: true,
      accessibleUI: true,
    },
  };
}

export function validateP22Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-22 proof");
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
    "P-22 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p22-database-proof-v1" ||
    proof.requirementId !== P22_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate?.runId !== String(binding.candidateRunId) ||
    proof.candidate?.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-22 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-22 proof source",
  );
  if (proof.source.method !== "live-installed-database-session")
    fail("P-22 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-22 source session",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const validated = validateP22InstalledSession(
    parseJson(source.bytes, "P-22 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  const booleans = [
    "accessibleUI",
    "daemonRestartPersistence",
    "destructiveKeyLossNotInduced",
    "deviceTransferNotInduced",
    "metadataOnlyInspector",
    "nativeKeyRecoveryReady",
    "paginationAndContextPack",
    "populatedIndexSearch",
    "recoveryExportImport",
    "sqlCipherSnapshotRestore",
    "tamperAndWrongPassphraseFailClosed",
    "watcherReopenAfterRestore",
  ];
  exactKeys(
    proof.claim,
    [
      "daemonEvents",
      "failClosedMutations",
      "indexedFiles",
      "passed",
      ...booleans,
    ].sort(),
    "P-22 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.daemonEvents !== validated.daemonEvents ||
    proof.claim.indexedFiles !== validated.indexedFiles ||
    proof.claim.indexedFiles < 14 ||
    proof.claim.failClosedMutations !== validated.failClosedMutations ||
    proof.claim.failClosedMutations !== 2 ||
    booleans.some((field) => proof.claim[field] !== true)
  )
    fail("P-22 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
