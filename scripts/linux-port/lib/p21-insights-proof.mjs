import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P21_REQUIREMENT_ID = "P-21";
export const P21_PROOF_ROLE = "feature.insights-installed";
export const P21_PROOF_FILENAME = "p21-installed-insights-proof.json";
export const P21_SESSION_FILENAME = "p21-installed-insights-session.json";

const MARKER = /^p21-[a-f0-9]{16}$/u;
const DAEMON_PHASES = Object.freeze([
  "record-codex",
  "record-claude",
  "record-gemini",
  "insights-initial",
  "insights-refresh",
  "insights-restart",
]);
const DAEMON_METHODS = Object.freeze([
  "daemon.usage.record",
  "daemon.usage.record",
  "daemon.usage.record",
  "daemon.usage.insights",
  "daemon.usage.insights",
  "daemon.usage.insights",
]);
const UI_PHASES = Object.freeze([
  "initial",
  "configured",
  "chat-handoff",
  "restart",
  "source-loss",
]);
const ISO_UTC_MILLISECONDS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u;

function fail(message) {
  throw new Error(message);
}

function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P21_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}

function timestamp(value, label) {
  if (typeof value !== "string" || !ISO_UTC_MILLISECONDS.test(value)) {
    fail(`${label} timestamp is invalid`);
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toISOString() !== value) {
    fail(`${label} timestamp is invalid`);
  }
  return date.getTime();
}

function validateMarker(marker) {
  exactKeys(marker, ["events", "marker", "prompt"], "P-21 marker");
  if (
    !MARKER.test(marker.marker ?? "") ||
    typeof marker.prompt !== "string" ||
    !marker.prompt.includes(marker.marker)
  )
    fail("P-21 marker identity is invalid");
  if (!Array.isArray(marker.events) || marker.events.length !== 3)
    fail("P-21 marker must describe three usage events");
  const providers = new Set();
  const models = new Set();
  for (const [index, row] of marker.events.entries()) {
    exactKeys(row, ["event", "idempotencyKey"], `P-21 marker event ${index}`);
    if (
      row.idempotencyKey !== `${marker.marker}-${index}` ||
      row.event?.projectName !== `P21 installed insights ${marker.marker}` ||
      typeof row.event?.providerID !== "string" ||
      typeof row.event?.modelID !== "string" ||
      typeof row.event?.sessionID !== "string" ||
      !row.event.sessionID.includes(marker.marker) ||
      !Number.isInteger(row.event.inputTokens) ||
      row.event.inputTokens <= 0 ||
      !Number.isInteger(row.event.outputTokens) ||
      row.event.outputTokens <= 0
    )
      fail(`P-21 marker event ${index} is invalid`);
    providers.add(row.event.providerID);
    models.add(row.event.modelID);
  }
  if (providers.size !== 3 || models.size !== 3)
    fail("P-21 marker does not contain three distinct comparison scopes");
}

function successful(event, label) {
  if (
    event.ok !== true ||
    event.error !== null ||
    !event.result ||
    typeof event.result !== "object"
  )
    fail(`${label} is not a successful installed daemon call`);
  return event.result;
}

function validateAnalysis(result, marker, eventAt, previousGeneratedAt) {
  if (
    result.sourceID !== "daemon.usage.ledger" ||
    typeof result.sourceLabel !== "string" ||
    !result.sourceLabel.includes("Linux daemon usage ledger") ||
    !Array.isArray(result.usage) ||
    result.usage.length < marker.events.length
  )
    fail("P-21 Insights response lacks authoritative populated usage");
  for (const expected of marker.events) {
    if (
      !result.usage.some(
        (row) =>
          row.providerID === expected.event.providerID &&
          row.modelID === expected.event.modelID &&
          row.sessionID === expected.event.sessionID &&
          row.projectName === expected.event.projectName,
      )
    )
      fail("P-21 Insights response omitted a seeded daemon usage row");
  }
  const analysis = result.analysis;
  if (
    typeof analysis?.requestID !== "string" ||
    analysis.requestID.length === 0 ||
    typeof analysis.executiveSummary !== "string" ||
    analysis.executiveSummary.length === 0 ||
    !Array.isArray(analysis.findings) ||
    analysis.findings.length === 0 ||
    !Array.isArray(analysis.citations) ||
    analysis.citations.length === 0
  )
    fail("P-21 qualitative response is incomplete");
  const generatedAt = timestamp(
    analysis.generatedAt,
    "P-21 qualitative generatedAt",
  );
  if (generatedAt > eventAt + 5_000)
    fail("P-21 qualitative timestamp is in the future");
  if (previousGeneratedAt !== null && generatedAt < previousGeneratedAt)
    fail("P-21 qualitative response freshness moved backwards");
  const citationIDs = new Set(
    analysis.citations.map((citation) => citation?.id).filter(Boolean),
  );
  if (
    citationIDs.size === 0 ||
    !analysis.findings.some(
      (finding) =>
        typeof finding?.title === "string" &&
        typeof finding?.whyItMatters === "string" &&
        typeof finding?.recommendedAction === "string" &&
        Array.isArray(finding?.evidence) &&
        finding.evidence.some((citation) => citationIDs.has(citation?.id)),
    )
  )
    fail("P-21 findings are not linked to daemon citations");
  return {
    generatedAt,
    requestID: analysis.requestID,
    citations: citationIDs.size,
  };
}

function validateDaemon(snapshot, marker, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, "P-21 daemon transcript");
  exactKeys(
    value,
    ["events", "producer", "transport"],
    "P-21 daemon transcript",
  );
  if (
    value.producer !== "openburnbar-p21-installed-insights-daemon-probe-v1" ||
    value.transport !== "installed daemon AF_UNIX RPC" ||
    !Array.isArray(value.events) ||
    value.events.length !== DAEMON_PHASES.length
  )
    fail("P-21 daemon transcript is incomplete");
  let previousAt = -Infinity;
  let previousGeneratedAt = null;
  const requestIDs = new Set();
  let citationCount = 0;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["at", "error", "method", "ok", "phase", "request", "result"],
      `P-21 daemon event ${index}`,
    );
    const at = timestamp(event.at, `P-21 ${event.phase}`);
    if (
      event.phase !== DAEMON_PHASES[index] ||
      event.method !== DAEMON_METHODS[index] ||
      at <= previousAt ||
      at < captureStart ||
      at > captureEnd
    )
      fail(`P-21 daemon event ${index} is out of order or unbound`);
    previousAt = at;
    const result = successful(event, `P-21 ${event.phase}`);
    if (index < 3) {
      const expected = marker.events[index];
      if (
        event.request?.idempotencyKey !== expected.idempotencyKey ||
        event.request?.event?.sessionID !== expected.event.sessionID ||
        result.idempotencyKey !== expected.idempotencyKey ||
        result.inserted !== true ||
        result.event?.sessionID !== expected.event.sessionID
      )
        fail(`P-21 usage record ${index} is not daemon-confirmed`);
    } else {
      if (
        event.request?.prompt !== marker.prompt ||
        event.request?.limit !== 200 ||
        event.request?.windowSeconds !== 604800
      )
        fail(`P-21 ${event.phase} request is not canonical`);
      const summary = validateAnalysis(result, marker, at, previousGeneratedAt);
      previousGeneratedAt = summary.generatedAt;
      requestIDs.add(summary.requestID);
      citationCount = Math.max(citationCount, summary.citations);
    }
  }
  if (requestIDs.size !== 3)
    fail(
      "P-21 refresh/restart responses did not carry distinct request identities",
    );
  return { daemonEvents: value.events.length, citationCount };
}

function validateUI(
  snapshot,
  marker,
  manifestSha256,
  captureStart,
  captureEnd,
) {
  const value = parseJson(snapshot.bytes, "P-21 UI transcript");
  exactKeys(value, ["events", "producer"], "P-21 UI transcript");
  if (
    value.producer !== "openburnbar-p21-installed-insights-ui-probe-v1" ||
    !Array.isArray(value.events) ||
    value.events.length !== UI_PHASES.length
  )
    fail("P-21 UI transcript is incomplete");
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["appPid", "at", "manifestSha256", "marker", "observed", "phase"],
      `P-21 UI event ${index}`,
    );
    const at = timestamp(event.at, `P-21 UI ${event.phase}`);
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
      fail(`P-21 UI event ${index} is out of order or unbound`);
    previous = at;
  }
  const [initial, configured, chat, restart, sourceLoss] = value.events.map(
    (event) => event.observed,
  );
  if (
    initial?.workspace !== true ||
    initial?.provenance !== true ||
    initial?.qualitative !== true ||
    initial?.fresh !== true ||
    initial?.citation !== true ||
    initial?.inspector !== true ||
    configured?.compact !== true ||
    configured?.selectedWidget !== "Model mix" ||
    configured?.compareCount !== 3 ||
    configured?.comparison !== true ||
    configured?.provenanceColumns !== 3 ||
    configured?.audit !== true ||
    chat?.chat !== true ||
    chat?.followUp !== true ||
    restart?.compact !== true ||
    restart?.selectedWidget !== "Model mix" ||
    sourceLoss?.snapshotPreserved !== true ||
    sourceLoss?.degradedBanner !== true
  )
    fail("P-21 installed Insights UI does not prove the required states");
  return { compareScopes: configured.compareCount };
}

export function validateP21InstalledSession(
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
    "P-21 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p21-installed-insights-session-v1"
  )
    fail("P-21 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P21_REQUIREMENT_ID,
    "P-21 installed session",
  );
  validateMarker(document.marker);
  exactKeys(
    document.evidence,
    [
      "compareScreenshot",
      "daemonTranscript",
      "initialScreenshot",
      "restartScreenshot",
      "sourceLossScreenshot",
      "uiTranscript",
    ],
    "P-21 evidence",
  );
  const daemon = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.daemonTranscript,
    "P-21 daemon transcript",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const daemonSummary = validateDaemon(
    daemon,
    document.marker,
    envelope.startedAt,
    envelope.endedAt,
  );
  const ui = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.uiTranscript,
    "P-21 UI transcript",
    { mediaType: "json", minimumBytes: 500 },
  );
  const uiSummary = validateUI(
    ui,
    document.marker,
    binding.manifestSha256,
    envelope.startedAt,
    envelope.endedAt,
  );
  const screenshotHashes = new Set();
  for (const field of [
    "initialScreenshot",
    "compareScreenshot",
    "restartScreenshot",
    "sourceLossScreenshot",
  ]) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-21 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-21 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-21 ${field} is blank`);
    screenshotHashes.add(
      crypto.createHash("sha256").update(png.pixels).digest("hex"),
    );
  }
  if (screenshotHashes.size !== 4)
    fail("P-21 screenshots replay the same UI state");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-21 reuses an evidence artifact");
  return {
    document,
    evidence,
    endedAt: envelope.endedAt,
    ...daemonSummary,
    ...uiSummary,
  };
}

export function buildP21Proof({
  session,
  source,
  collectedAt,
  daemonEvents,
  citationCount,
  compareScopes,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p21-insights-proof-v1",
    requirementId: P21_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-insights-session", ...source },
    claim: {
      passed: true,
      daemonEvents,
      citationCount,
      compareScopes,
      populatedQualitativeInsights: true,
      provenanceAndCitations: true,
      selectableWorkspace: true,
      refreshAndOrdering: true,
      followUpHandoff: true,
      persistedWorkspaceRestart: true,
      freshnessFailClosed: true,
      sourceLossPreservation: true,
      accessibleUI: true,
    },
  };
}

export function validateP21Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-21 proof");
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
    "P-21 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p21-insights-proof-v1" ||
    proof.requirementId !== P21_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate?.runId !== String(binding.candidateRunId) ||
    proof.candidate?.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-21 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-21 proof source",
  );
  if (proof.source.method !== "live-installed-insights-session")
    fail("P-21 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-21 source session",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const validated = validateP21InstalledSession(
    parseJson(source.bytes, "P-21 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(
    proof.claim,
    [
      "accessibleUI",
      "citationCount",
      "compareScopes",
      "daemonEvents",
      "followUpHandoff",
      "freshnessFailClosed",
      "passed",
      "persistedWorkspaceRestart",
      "populatedQualitativeInsights",
      "provenanceAndCitations",
      "refreshAndOrdering",
      "selectableWorkspace",
      "sourceLossPreservation",
    ],
    "P-21 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.daemonEvents !== validated.daemonEvents ||
    proof.claim.citationCount !== validated.citationCount ||
    proof.claim.compareScopes !== validated.compareScopes ||
    proof.claim.compareScopes !== 3 ||
    proof.claim.citationCount < 1 ||
    [
      "accessibleUI",
      "followUpHandoff",
      "freshnessFailClosed",
      "persistedWorkspaceRestart",
      "populatedQualitativeInsights",
      "provenanceAndCitations",
      "refreshAndOrdering",
      "selectableWorkspace",
      "sourceLossPreservation",
    ].some((field) => proof.claim[field] !== true)
  )
    fail("P-21 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
