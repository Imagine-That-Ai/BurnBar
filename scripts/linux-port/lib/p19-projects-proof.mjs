import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P19_REQUIREMENT_ID = "P-19";
export const P19_PROOF_ROLE = "feature.projects-installed";
export const P19_PROOF_FILENAME = "p19-installed-projects-proof.json";
export const P19_SESSION_FILENAME = "p19-installed-projects-session.json";

const MARKER = /^p19-[a-f0-9]{16}$/u;
const PHASES = Object.freeze([
  "source-upserted",
  "target-upserted",
  "initial-list",
  "source-get-by-alias",
  "associated-mission-created",
  "source-deleted",
  "deleted-source-reassigned",
  "reassigned-mission-get",
  "post-delete-list",
  "post-delete-get",
  "restart-list",
  "restart-get-deleted",
  "restart-mission-get",
  "restart-upsert-rejected-by-tombstone",
  "restart-reassign-from-tombstone",
]);
const METHODS = Object.freeze([
  "daemon.controller.project.upsert",
  "daemon.controller.project.upsert",
  "daemon.controller.project.list",
  "daemon.controller.project.get",
  "daemon.mission.create",
  "daemon.controller.project.delete",
  "daemon.controller.project.reassign",
  "daemon.mission.get",
  "daemon.controller.project.list",
  "daemon.controller.project.get",
  "daemon.controller.project.list",
  "daemon.controller.project.get",
  "daemon.mission.get",
  "daemon.controller.project.upsert",
  "daemon.controller.project.reassign",
]);

function fail(message) {
  throw new Error(message);
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P19_REQUIREMENT_ID,
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
function successful(event, label) {
  if (
    event.ok !== true ||
    event.error !== null ||
    event.result === null ||
    typeof event.result !== "object"
  )
    fail(`${label} is not a successful installed daemon call`);
  return event.result;
}
function projectSlugs(result, label) {
  if (!Array.isArray(result?.projects)) fail(`${label} has no project list`);
  return result.projects.map((project) => project?.projectSlug);
}

function validateMarker(marker) {
  exactKeys(
    marker,
    [
      "marker",
      "sourceAlias",
      "sourceProject",
      "sourceSlug",
      "targetProject",
      "targetSlug",
    ],
    "P-19 marker",
  );
  if (
    !MARKER.test(marker.marker ?? "") ||
    marker.sourceSlug !== `${marker.marker}-source` ||
    marker.targetSlug !== `${marker.marker}-target` ||
    marker.sourceAlias !== `${marker.marker}:source-alias` ||
    marker.sourceSlug === marker.targetSlug ||
    marker.sourceProject?.projectSlug !== marker.sourceSlug ||
    marker.targetProject?.projectSlug !== marker.targetSlug ||
    marker.sourceProject?.aliases?.[0] !== marker.sourceAlias ||
    marker.sourceProject?.metadata?.p19_marker !== marker.marker ||
    marker.targetProject?.metadata?.p19_marker !== marker.marker
  )
    fail("P-19 marker identity is invalid");
}

function validateTranscript(snapshot, marker, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, "P-19 daemon transcript");
  exactKeys(value, ["events", "producer", "transport"], "P-19 daemon transcript");
  if (
    value.producer !== "openburnbar-p19-installed-projects-daemon-probe-v1" ||
    value.transport !== "installed daemon AF_UNIX RPC" ||
    !Array.isArray(value.events) ||
    value.events.length !== PHASES.length
  )
    fail("P-19 daemon transcript is incomplete");

  const events = new Map();
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["at", "error", "method", "ok", "phase", "request", "result"],
      `P-19 daemon event ${index}`,
    );
    const at = timestamp(event.at, `P-19 ${event.phase}`);
    if (
      event.phase !== PHASES[index] ||
      event.method !== METHODS[index] ||
      at <= previous ||
      at < captureStart ||
      at > captureEnd
    )
      fail(`P-19 daemon event ${index} is out of order or unbound`);
    previous = at;
    events.set(event.phase, event);
  }

  const request = (phase) => events.get(phase)?.request;
  if (
    request("source-upserted")?.project?.projectSlug !== marker.sourceSlug ||
    request("target-upserted")?.project?.projectSlug !== marker.targetSlug ||
    request("initial-list")?.includePaused !== true ||
    request("initial-list")?.limit !== 100 ||
    request("source-get-by-alias")?.projectSlug !== marker.sourceAlias ||
    request("associated-mission-created")?.projectSlug !== marker.sourceSlug ||
    request("associated-mission-created")?.metadata?.p19_marker !== marker.marker ||
    request("source-deleted")?.projectSlug !== marker.sourceSlug ||
    request("deleted-source-reassigned")?.sourceProjectSlug !== marker.sourceAlias ||
    request("deleted-source-reassigned")?.targetProjectSlug !== marker.targetSlug ||
    request("post-delete-get")?.projectSlug !== marker.sourceSlug ||
    request("restart-get-deleted")?.projectSlug !== marker.sourceAlias ||
    request("restart-upsert-rejected-by-tombstone")?.project?.projectSlug !==
      marker.sourceSlug ||
    request("restart-reassign-from-tombstone")?.sourceProjectSlug !==
      marker.sourceAlias ||
    request("restart-reassign-from-tombstone")?.targetProjectSlug !==
      marker.targetSlug
  )
    fail("P-19 daemon requests do not match the required project lifecycle");

  const result = (phase) =>
    successful(events.get(phase), `P-19 ${phase}`);
  if (
    result("source-upserted").project?.projectSlug !== marker.sourceSlug ||
    result("target-upserted").project?.projectSlug !== marker.targetSlug
  )
    fail("P-19 project upsert identity is invalid");
  const initial = projectSlugs(result("initial-list"), "P-19 initial list");
  if (!initial.includes(marker.sourceSlug) || !initial.includes(marker.targetSlug))
    fail("P-19 initial list omitted an upserted project");
  if (result("source-get-by-alias").project?.projectSlug !== marker.sourceSlug)
    fail("P-19 project alias did not resolve to the source project");
  const associatedMission = result("associated-mission-created").mission;
  const missionID = associatedMission?.id;
  if (
    typeof missionID !== "string" ||
    missionID.length === 0 ||
    associatedMission.projectSlug !== marker.sourceSlug ||
    request("reassigned-mission-get")?.missionID !== missionID ||
    request("restart-mission-get")?.missionID !== missionID
  )
    fail("P-19 associated mission identity is invalid");
  const deleted = result("source-deleted");
  if (deleted.deleted !== true || deleted.projectSlug !== marker.sourceSlug)
    fail("P-19 deletion was not confirmed");
  for (const phase of [
    "deleted-source-reassigned",
    "restart-reassign-from-tombstone",
  ]) {
    const reassigned = result(phase);
    const minimumReferences = phase === "deleted-source-reassigned" ? 1 : 0;
    if (
      reassigned.sourceProjectSlug !== marker.sourceSlug ||
      reassigned.targetProjectSlug !== marker.targetSlug ||
      !Number.isInteger(reassigned.updatedReferenceCount) ||
      reassigned.updatedReferenceCount < minimumReferences
    )
      fail(`P-19 ${phase} is invalid`);
  }
  for (const phase of ["reassigned-mission-get", "restart-mission-get"]) {
    const mission = result(phase).mission;
    if (mission?.id !== missionID || mission.projectSlug !== marker.targetSlug)
      fail(`P-19 ${phase} did not preserve the reassigned association`);
  }
  for (const phase of ["post-delete-list", "restart-list"]) {
    const slugs = projectSlugs(result(phase), `P-19 ${phase}`);
    if (slugs.includes(marker.sourceSlug) || !slugs.includes(marker.targetSlug))
      fail(`P-19 ${phase} does not preserve the deletion tombstone`);
  }
  for (const phase of ["post-delete-get", "restart-get-deleted"])
    if (result(phase).project !== null)
      fail(`P-19 ${phase} exposed the deleted project`);

  const rejected = events.get("restart-upsert-rejected-by-tombstone");
  if (
    rejected.ok !== false ||
    typeof rejected.error !== "string" ||
    rejected.error.length === 0 ||
    rejected.result !== null
  )
    fail("P-19 tombstone did not reject project resurrection after restart");

  return {
    associatedReferences: result("deleted-source-reassigned").updatedReferenceCount,
    events: value.events.length,
    tombstoneRejections: 1,
  };
}

function validateUI(snapshot, marker, manifestSha256, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, "P-19 UI transcript");
  exactKeys(value, ["events", "producer"], "P-19 UI transcript");
  if (
    value.producer !== "openburnbar-p19-installed-projects-ui-probe-v1" ||
    !Array.isArray(value.events) ||
    value.events.length !== 3
  )
    fail("P-19 UI transcript is incomplete");
  const phases = ["initial", "restart-list", "restart-detail"];
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      [
        "appPid",
        "at",
        "manifestSha256",
        "marker",
        "observed",
        "phase",
        "sourceSlug",
        "targetSlug",
      ],
      `P-19 UI event ${index}`,
    );
    const at = timestamp(event.at, `P-19 UI ${event.phase}`);
    if (
      event.phase !== phases[index] ||
      at <= previous ||
      at < captureStart ||
      at > captureEnd ||
      !Number.isSafeInteger(event.appPid) ||
      event.appPid <= 1 ||
      event.marker !== marker.marker ||
      event.sourceSlug !== marker.sourceSlug ||
      event.targetSlug !== marker.targetSlug ||
      event.manifestSha256 !== manifestSha256
    )
      fail(`P-19 UI event ${index} is out of order or unbound`);
    previous = at;
  }
  const [initial, restart, detail] = value.events.map((event) => event.observed);
  if (
    initial?.sourceVisible !== true ||
    initial?.targetVisible !== true ||
    initial?.detailsAction !== true ||
    initial?.registerAction !== true ||
    restart?.sourceAbsent !== true ||
    restart?.targetVisible !== true ||
    restart?.detailsAction !== true ||
    detail?.targetVisible !== true ||
    detail?.historyVisible !== true
  )
    fail("P-19 installed Projects UI does not prove the required states");
}

export function validateP19InstalledSession(
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
    "P-19 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p19-installed-projects-session-v1"
  )
    fail("P-19 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P19_REQUIREMENT_ID,
    "P-19 installed session",
  );
  validateMarker(document.marker);
  exactKeys(
    document.evidence,
    ["daemonTranscript", "initialScreenshot", "restartScreenshot", "uiTranscript"],
    "P-19 evidence",
  );
  const daemon = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.daemonTranscript,
    "P-19 daemon transcript",
    { mediaType: "json", minimumBytes: 500 },
  );
  const summary = validateTranscript(
    daemon,
    document.marker,
    envelope.startedAt,
    envelope.endedAt,
  );
  const ui = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.uiTranscript,
    "P-19 UI transcript",
    { mediaType: "json", minimumBytes: 300 },
  );
  validateUI(
    ui,
    document.marker,
    binding.manifestSha256,
    envelope.startedAt,
    envelope.endedAt,
  );
  const screenshotHashes = new Set();
  for (const field of ["initialScreenshot", "restartScreenshot"]) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-19 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-19 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-19 ${field} is blank`);
    screenshotHashes.add(
      crypto.createHash("sha256").update(png.pixels).digest("hex"),
    );
  }
  if (screenshotHashes.size !== 2)
    fail("P-19 screenshots replay the same UI state");
  const evidence = [...envelope.attestation, ...Object.values(document.evidence)];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-19 reuses an evidence artifact");
  return { document, evidence, endedAt: envelope.endedAt, ...summary };
}

export function buildP19Proof({
  session,
  source,
  collectedAt,
  associatedReferences,
  events,
  tombstoneRejections,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p19-projects-proof-v1",
    requirementId: P19_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-projects-session", ...source },
    claim: {
      passed: true,
      sourceSlug: session.marker.sourceSlug,
      targetSlug: session.marker.targetSlug,
      associatedReferences,
      daemonEvents: events,
      tombstoneRejections,
      listGetUpsertDeleteReassign: true,
      durableRestart: true,
      deletionTombstone: true,
      deletedSourceReassignment: true,
      accessibleUI: true,
    },
  };
}

export function validateP19Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-19 proof");
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
    "P-19 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p19-projects-proof-v1" ||
    proof.requirementId !== P19_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-19 proof binding is invalid");
  exactKeys(proof.source, ["method", "path", "sha256", "size"], "P-19 proof source");
  if (proof.source.method !== "live-installed-projects-session")
    fail("P-19 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-19 source session",
    { mediaType: "json", minimumBytes: 500 },
  );
  const validated = validateP19InstalledSession(
    parseJson(source.bytes, "P-19 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(
    proof.claim,
    [
      "accessibleUI",
      "associatedReferences",
      "daemonEvents",
      "deletedSourceReassignment",
      "deletionTombstone",
      "durableRestart",
      "listGetUpsertDeleteReassign",
      "passed",
      "sourceSlug",
      "targetSlug",
      "tombstoneRejections",
    ],
    "P-19 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.sourceSlug !== validated.document.marker.sourceSlug ||
    proof.claim.targetSlug !== validated.document.marker.targetSlug ||
    proof.claim.associatedReferences !== validated.associatedReferences ||
    !Number.isInteger(proof.claim.associatedReferences) ||
    proof.claim.associatedReferences < 1 ||
    proof.claim.daemonEvents !== validated.events ||
    proof.claim.tombstoneRejections !== validated.tombstoneRejections ||
    [
      "accessibleUI",
      "deletedSourceReassignment",
      "deletionTombstone",
      "durableRestart",
      "listGetUpsertDeleteReassign",
    ].some((field) => proof.claim[field] !== true)
  )
    fail("P-19 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
