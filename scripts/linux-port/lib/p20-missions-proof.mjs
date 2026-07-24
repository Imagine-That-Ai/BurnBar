import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P20_REQUIREMENT_ID = "P-20";
export const P20_PROOF_ROLE = "feature.missions-installed";
export const P20_PROOF_FILENAME = "p20-installed-missions-proof.json";
export const P20_SESSION_FILENAME = "p20-installed-missions-session.json";

const MARKER = /^p20-[a-f0-9]{16}$/u;
const PHASES = Object.freeze([
  "project-upserted",
  "mission-created",
  "mission-listed",
  "mission-approved-readback",
  "packet-dispatched",
  "result-recorded",
  "mission-health",
  "question-created",
  "question-answered-readback",
  "restart-mission-get",
  "restart-mission-health",
  "mission-cancelled-readback",
]);
const METHODS = Object.freeze([
  "daemon.controller.project.upsert",
  "daemon.mission.create",
  "daemon.mission.list",
  "daemon.mission.get",
  "daemon.mission.packet.dispatch",
  "daemon.mission.result.record",
  "daemon.mission.health",
  "daemon.question.create",
  "daemon.question.list",
  "daemon.mission.get",
  "daemon.mission.health",
  "daemon.mission.get",
]);
const UI_PHASES = Object.freeze([
  "pending-approval",
  "approved",
  "pending-question",
  "restart-detail",
  "mission-detail",
  "cancelled",
]);
const UI_ACTIONS = Object.freeze([
  ["approve", (marker) => `Approve ${marker.missionTitle}`],
  ["question-option", (marker) => marker.optionTitle],
  ["question-submit", () => "Submit answer"],
  ["inspect-logs", () => "Inspect logs"],
  ["cancel-start", () => "Cancel mission"],
  ["cancel-confirm", () => "Confirm cancel"],
]);
const SCREENSHOTS = Object.freeze([
  "pendingScreenshot",
  "approvedScreenshot",
  "questionScreenshot",
  "detailScreenshot",
  "cancelledScreenshot",
]);

function fail(message) {
  throw new Error(message);
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P20_REQUIREMENT_ID,
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
function validateMarker(marker) {
  exactKeys(
    marker,
    [
      "marker",
      "missionID",
      "missionTitle",
      "optionAnswer",
      "optionID",
      "optionTitle",
      "packetID",
      "project",
      "projectSlug",
      "questionID",
      "questionTitle",
      "resultID",
    ],
    "P-20 marker",
  );
  if (
    !MARKER.test(marker.marker ?? "") ||
    marker.projectSlug !== `${marker.marker}-project` ||
    marker.project?.projectSlug !== marker.projectSlug ||
    marker.project?.metadata?.p20_marker !== marker.marker ||
    marker.packetID !== `packet:${marker.marker}` ||
    marker.resultID !== `result:${marker.marker}` ||
    marker.questionID !== `question:${marker.marker}` ||
    marker.optionID !== `option:${marker.marker}` ||
    !String(marker.missionID ?? "").length ||
    !String(marker.missionTitle ?? "").includes(marker.marker) ||
    !String(marker.questionTitle ?? "").includes(marker.marker) ||
    !String(marker.optionTitle ?? "").includes(marker.marker) ||
    !String(marker.optionAnswer ?? "").includes(marker.marker)
  )
    fail("P-20 marker identity is invalid");
}

function validateDaemon(snapshot, marker, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, "P-20 daemon transcript");
  exactKeys(
    value,
    ["events", "producer", "transport"],
    "P-20 daemon transcript",
  );
  if (
    value.producer !== "openburnbar-p20-installed-missions-daemon-probe-v1" ||
    value.transport !== "installed daemon AF_UNIX RPC" ||
    !Array.isArray(value.events) ||
    value.events.length !== PHASES.length
  )
    fail("P-20 daemon transcript is incomplete");
  const events = new Map();
  let prior = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["at", "error", "method", "ok", "phase", "request", "result"],
      `P-20 daemon event ${index}`,
    );
    const at = time(event.at, `P-20 ${event.phase}`);
    if (
      event.phase !== PHASES[index] ||
      event.method !== METHODS[index] ||
      at <= prior ||
      at < startedAt ||
      at > endedAt
    )
      fail(`P-20 daemon event ${index} is out of order or unbound`);
    successful(event, `P-20 ${event.phase}`);
    prior = at;
    events.set(event.phase, event);
  }
  const request = (phase) => events.get(phase).request;
  const result = (phase) => events.get(phase).result;
  const mission = (phase) => result(phase).mission;
  if (
    request("project-upserted")?.project?.projectSlug !== marker.projectSlug ||
    request("mission-created")?.projectSlug !== marker.projectSlug ||
    request("mission-created")?.title !== marker.missionTitle ||
    request("mission-created")?.metadata?.p20_marker !== marker.marker ||
    request("mission-listed")?.projectSlug !== marker.projectSlug ||
    !request("mission-listed")?.statuses?.includes("awaiting_approval") ||
    request("mission-approved-readback")?.missionID !== marker.missionID ||
    request("packet-dispatched")?.missionID !== marker.missionID ||
    request("packet-dispatched")?.packet?.id !== marker.packetID ||
    request("packet-dispatched")?.packet?.missionID !== marker.missionID ||
    request("result-recorded")?.missionID !== marker.missionID ||
    request("result-recorded")?.result?.id !== marker.resultID ||
    request("result-recorded")?.result?.packetID !== marker.packetID ||
    request("result-recorded")?.result?.evidenceRefs?.[0] !==
      `evidence:${marker.marker}` ||
    request("result-recorded")?.result?.burnDelta <= 0 ||
    request("result-recorded")?.result?.prLinkage?.state !== "merged" ||
    request("mission-health")?.missionID !== marker.missionID ||
    request("question-created")?.question?.id !== marker.questionID ||
    request("question-created")?.question?.suggestedOptions?.[0]?.id !==
      marker.optionID ||
    request("question-answered-readback")?.projectSlug !== marker.projectSlug ||
    !request("question-answered-readback")?.statuses?.includes("answered") ||
    request("restart-mission-get")?.missionID !== marker.missionID ||
    request("restart-mission-health")?.missionID !== marker.missionID ||
    request("mission-cancelled-readback")?.missionID !== marker.missionID
  )
    fail("P-20 daemon requests do not match the required mission lifecycle");
  if (
    result("project-upserted").project?.projectSlug !== marker.projectSlug ||
    mission("mission-created")?.id !== marker.missionID ||
    mission("mission-created")?.status !== "awaiting_approval" ||
    !result("mission-listed").missions?.some(
      (row) => row.id === marker.missionID,
    ) ||
    mission("mission-approved-readback")?.status !== "approved" ||
    mission("mission-approved-readback")?.approval?.approved !== true ||
    !mission("packet-dispatched")?.packets?.some(
      (row) => row.id === marker.packetID,
    ) ||
    !mission("result-recorded")?.results?.some(
      (row) => row.id === marker.resultID,
    ) ||
    mission("result-recorded")?.prLinkage?.state !== "merged" ||
    result("mission-health").missionID !== marker.missionID ||
    !Array.isArray(result("mission-health").history) ||
    result("mission-health").history.length < 3 ||
    result("question-created").question?.id !== marker.questionID ||
    !result("question-answered-readback").questions?.some(
      (row) =>
        row.id === marker.questionID &&
        row.latestAnswer?.answer === marker.optionAnswer &&
        row.latestAnswer?.selectedOptionID === marker.optionID,
    ) ||
    !mission("restart-mission-get")?.packets?.some(
      (row) => row.id === marker.packetID,
    ) ||
    !mission("restart-mission-get")?.results?.some(
      (row) => row.id === marker.resultID,
    ) ||
    result("restart-mission-health").history?.length <
      result("mission-health").history.length ||
    mission("mission-cancelled-readback")?.status !== "cancelled"
  )
    fail(
      "P-20 daemon responses do not prove approval, execution, persistence, question, and cancellation parity",
    );
  return {
    daemonEvents: value.events.length,
    historyEntries: result("restart-mission-health").history.length,
  };
}

function validateUI(snapshot, marker, manifestSha256, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, "P-20 UI transcript");
  exactKeys(value, ["actions", "events", "producer"], "P-20 UI transcript");
  if (
    value.producer !== "openburnbar-p20-installed-missions-ui-probe-v1" ||
    !Array.isArray(value.events) ||
    value.events.length !== UI_PHASES.length ||
    !Array.isArray(value.actions) ||
    value.actions.length !== UI_ACTIONS.length
  )
    fail("P-20 UI transcript is incomplete");
  let prior = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      [
        "appPid",
        "at",
        "manifestSha256",
        "marker",
        "missionTitle",
        "observed",
        "phase",
        "projectSlug",
        "questionTitle",
      ],
      `P-20 UI event ${index}`,
    );
    const at = time(event.at, `P-20 UI ${event.phase}`);
    if (
      event.phase !== UI_PHASES[index] ||
      at <= prior ||
      at < startedAt ||
      at > endedAt ||
      !Number.isSafeInteger(event.appPid) ||
      event.appPid <= 1 ||
      event.marker !== marker.marker ||
      event.projectSlug !== marker.projectSlug ||
      event.missionTitle !== marker.missionTitle ||
      event.questionTitle !== marker.questionTitle ||
      event.manifestSha256 !== manifestSha256
    )
      fail(`P-20 UI event ${index} is out of order or unbound`);
    prior = at;
  }
  const [pending, approved, question, restart, detail, cancelled] =
    value.events.map((event) => event.observed);
  if (
    pending?.missionVisible !== true ||
    pending?.pendingVisible !== true ||
    pending?.approveAction !== true ||
    approved?.missionVisible !== true ||
    approved?.approvalSubmitted !== true ||
    approved?.approvedVisible !== true ||
    question?.questionVisible !== true ||
    question?.suggestedAnswerVisible !== true ||
    question?.submitVisible !== true ||
    restart?.missionVisible !== true ||
    restart?.inspectVisible !== true ||
    restart?.cancelVisible !== true ||
    detail?.packetVisible !== true ||
    detail?.resultVisible !== true ||
    detail?.historyVisible !== true ||
    cancelled?.missionVisible !== true ||
    cancelled?.cancelledVisible !== true
  )
    fail("P-20 installed UI does not prove every required mission state");
  prior = -Infinity;
  for (const [index, action] of value.actions.entries()) {
    exactKeys(action, ["at", "phase", "result"], `P-20 UI action ${index}`);
    exactKeys(
      action.result,
      ["activation", "producer"],
      `P-20 UI action result ${index}`,
    );
    exactKeys(
      action.result.activation,
      ["action", "name", "role"],
      `P-20 UI activation ${index}`,
    );
    const [phase, expectedName] = UI_ACTIONS[index];
    const at = time(action.at, `P-20 UI action ${phase}`);
    if (
      action.phase !== phase ||
      at <= prior ||
      at < startedAt ||
      at > endedAt ||
      action.result.producer !== "openburnbar-p20-atspi-control-v1" ||
      action.result.activation.name !== expectedName(marker) ||
      !String(action.result.activation.role ?? "").length ||
      !String(action.result.activation.action ?? "").length
    )
      fail(`P-20 UI action ${index} is invalid or unbound`);
    prior = at;
  }
  return value.events.length;
}

export function validateP20InstalledSession(
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
    "P-20 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p20-installed-missions-session-v1"
  )
    fail("P-20 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P20_REQUIREMENT_ID,
    "P-20 installed session",
  );
  validateMarker(document.marker);
  exactKeys(
    document.evidence,
    [
      "approvedScreenshot",
      "cancelledScreenshot",
      "daemonTranscript",
      "detailScreenshot",
      "pendingScreenshot",
      "questionScreenshot",
      "uiTranscript",
    ],
    "P-20 evidence",
  );
  const daemon = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.daemonTranscript,
    "P-20 daemon transcript",
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
    "P-20 UI transcript",
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
      `P-20 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-20 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-20 ${field} is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (hashes.size !== SCREENSHOTS.length)
    fail("P-20 screenshots replay a prior UI state");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-20 reuses an evidence artifact");
  return {
    document,
    evidence,
    endedAt: envelope.endedAt,
    uiStates,
    ...summary,
  };
}

export function buildP20Proof({
  session,
  source,
  collectedAt,
  daemonEvents,
  historyEntries,
  uiStates,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p20-missions-proof-v1",
    requirementId: P20_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-missions-session", ...source },
    claim: {
      passed: true,
      missionID: session.marker.missionID,
      daemonEvents,
      historyEntries,
      uiStates,
      approvalRoundTrip: true,
      packetResultEvidence: true,
      questionAnswerRoundTrip: true,
      durableRestart: true,
      cancellationRoundTrip: true,
      accessibleUI: true,
    },
  };
}

export function validateP20Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-20 proof");
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
    "P-20 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p20-missions-proof-v1" ||
    proof.requirementId !== P20_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-20 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-20 proof source",
  );
  if (proof.source.method !== "live-installed-missions-session")
    fail("P-20 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-20 source session",
    { mediaType: "json", minimumBytes: 500 },
  );
  const validated = validateP20InstalledSession(
    parseJson(source.bytes, "P-20 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(
    proof.claim,
    [
      "accessibleUI",
      "approvalRoundTrip",
      "cancellationRoundTrip",
      "daemonEvents",
      "durableRestart",
      "historyEntries",
      "missionID",
      "packetResultEvidence",
      "passed",
      "questionAnswerRoundTrip",
      "uiStates",
    ],
    "P-20 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.missionID !== validated.document.marker.missionID ||
    proof.claim.daemonEvents !== validated.daemonEvents ||
    proof.claim.historyEntries !== validated.historyEntries ||
    proof.claim.uiStates !== validated.uiStates ||
    [
      "accessibleUI",
      "approvalRoundTrip",
      "cancellationRoundTrip",
      "durableRestart",
      "packetResultEvidence",
      "questionAnswerRoundTrip",
    ].some((field) => proof.claim[field] !== true)
  )
    fail("P-20 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
