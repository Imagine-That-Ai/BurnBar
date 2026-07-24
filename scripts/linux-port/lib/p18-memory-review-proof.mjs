import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P18_REQUIREMENT_ID = "P-18";
export const P18_PROOF_ROLE = "feature.memory-review-installed";
export const P18_PROOF_FILENAME = "p18-installed-memory-review-proof.json";
export const P18_SESSION_FILENAME = "p18-installed-memory-review-session.json";

const HASH = /^[a-f0-9]{64}$/u;
const MARKER = /^P18-[a-f0-9]{16}$/u;
const PHASES = Object.freeze([
  "quarantine-created",
  "normal-recall-excludes-quarantine",
  "review-feed-includes-quarantine",
  "approved",
  "normal-recall-includes-approved",
  "rejected-candidate-created",
  "rejected",
  "normal-recall-excludes-rejected",
  "forgotten",
  "forgotten-tombstone",
  "restart-readback",
  "audit-readback",
]);
const METHODS = Object.freeze([
  "daemon.memory.remember",
  "daemon.memory.recall",
  "daemon.memory.recall",
  "daemon.memory.review_status",
  "daemon.memory.recall",
  "daemon.memory.remember",
  "daemon.memory.review_status",
  "daemon.memory.recall",
  "daemon.memory.forget",
  "daemon.memory.recall",
  "daemon.memory.recall",
  "daemon.memory.audit_trail",
]);

function fail(message) {
  throw new Error(message);
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P18_REQUIREMENT_ID,
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
function result(row, label) {
  if (
    row.ok !== true ||
    row.error !== null ||
    row.result === null ||
    typeof row.result !== "object"
  ) {
    fail(`${label} is not a successful installed daemon call`);
  }
  return row.result;
}
function hits(document, label) {
  if (!Array.isArray(document?.hits)) fail(`${label} has no memory hits`);
  return document.hits;
}

function validateTranscript(snapshot, marker, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, "P-18 daemon transcript");
  exactKeys(
    value,
    ["events", "producer", "transport"],
    "P-18 daemon transcript",
  );
  if (
    value.producer !== "openburnbar-p18-installed-daemon-probe-v1" ||
    value.transport !== "installed daemon AF_UNIX RPC" ||
    !Array.isArray(value.events) ||
    value.events.length !== PHASES.length
  ) {
    fail("P-18 daemon transcript is incomplete");
  }
  const events = new Map();
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      ["at", "error", "method", "ok", "phase", "request", "result"],
      `P-18 daemon event ${index}`,
    );
    const at = timestamp(event.at, `P-18 ${event.phase}`);
    if (
      event.phase !== PHASES[index] ||
      event.method !== METHODS[index] ||
      at <= previous ||
      at < captureStart ||
      at > captureEnd ||
      typeof event.method !== "string" ||
      !event.method.startsWith("daemon.memory.")
    ) {
      fail(`P-18 daemon event ${index} is out of order or unbound`);
    }
    previous = at;
    events.set(event.phase, result(event, `P-18 ${event.phase}`));
  }

  const request = (phase) => value.events[PHASES.indexOf(phase)].request;
  const recallIs = (phase, includeQuarantined, includeForgotten) => {
    const row = request(phase);
    return (
      row?.query === marker.marker &&
      row?.includeCrossProject === false &&
      row?.includeQuarantined === includeQuarantined &&
      row?.includeForgotten === includeForgotten
    );
  };
  if (
    request("quarantine-created")?.text !== marker.body ||
    request("quarantine-created")?.reviewStatus !== "quarantined" ||
    !recallIs("normal-recall-excludes-quarantine", false, false) ||
    !recallIs("review-feed-includes-quarantine", true, true) ||
    request("approved")?.memoryID !== marker.memoryID ||
    request("approved")?.status !== "approved" ||
    !recallIs("normal-recall-includes-approved", false, false) ||
    request("rejected-candidate-created")?.text !== marker.rejectedBody ||
    request("rejected-candidate-created")?.reviewStatus !== "quarantined" ||
    request("rejected")?.memoryID !== marker.rejectedMemoryID ||
    request("rejected")?.status !== "rejected" ||
    !recallIs("normal-recall-excludes-rejected", false, false) ||
    request("forgotten")?.memoryID !== marker.memoryID ||
    request("forgotten")?.requireCloudDelete !== false ||
    !recallIs("forgotten-tombstone", true, true) ||
    !recallIs("restart-readback", true, true) ||
    request("audit-readback")?.limit !== 50
  ) {
    fail("P-18 daemon requests do not match the required review lifecycle");
  }

  const created = events.get("quarantine-created");
  if (
    created.memoryID !== marker.memoryID ||
    created.projectID !== marker.projectID ||
    !HASH.test(created.auditHash ?? "")
  ) {
    fail("P-18 quarantined candidate identity is invalid");
  }
  if (
    hits(
      events.get("normal-recall-excludes-quarantine"),
      "P-18 quarantine recall",
    ).some((hit) => hit.memoryID === marker.memoryID)
  )
    fail("P-18 quarantined candidate leaked into normal recall");
  const pending = hits(
    events.get("review-feed-includes-quarantine"),
    "P-18 review feed",
  ).filter((hit) => hit.memoryID === marker.memoryID);
  if (
    pending.length !== 1 ||
    pending[0].reviewStatus !== "quarantined" ||
    pending[0].bodyRedacted !== marker.body ||
    pending[0].snippet !== marker.body
  ) {
    fail("P-18 review feed did not expose the exact quarantined body");
  }
  const approved = events.get("approved");
  if (
    approved.memoryID !== marker.memoryID ||
    approved.status !== "approved" ||
    !HASH.test(approved.auditHash ?? "")
  ) {
    fail("P-18 approve transition is invalid");
  }
  const recalled = hits(
    events.get("normal-recall-includes-approved"),
    "P-18 approved recall",
  ).filter((hit) => hit.memoryID === marker.memoryID);
  if (
    recalled.length !== 1 ||
    recalled[0].reviewStatus !== "approved" ||
    recalled[0].bodyRedacted !== marker.body
  ) {
    fail("P-18 approved memory is absent from normal recall");
  }
  const rejected = events.get("rejected");
  const rejectedCreated = events.get("rejected-candidate-created");
  if (
    rejectedCreated.memoryID !== marker.rejectedMemoryID ||
    rejectedCreated.projectID !== marker.projectID ||
    !HASH.test(rejectedCreated.auditHash ?? "")
  )
    fail("P-18 rejected candidate was not quarantined first");
  if (
    rejected.memoryID !== marker.rejectedMemoryID ||
    rejected.status !== "rejected" ||
    !HASH.test(rejected.auditHash ?? "")
  ) {
    fail("P-18 reject transition is invalid");
  }
  if (
    hits(
      events.get("normal-recall-excludes-rejected"),
      "P-18 rejected recall",
    ).some((hit) => hit.memoryID === marker.rejectedMemoryID)
  )
    fail("P-18 rejected candidate leaked into normal recall");
  const forgotten = events.get("forgotten");
  if (
    forgotten.memoryID !== marker.memoryID ||
    forgotten.localDeleted !== true ||
    forgotten.cloudDeletePending !== false ||
    !HASH.test(forgotten.auditHash ?? "")
  ) {
    fail("P-18 forget transition did not delete the local body");
  }
  const tombstones = hits(
    events.get("forgotten-tombstone"),
    "P-18 forgotten feed",
  ).filter((hit) => hit.memoryID === marker.memoryID);
  if (
    tombstones.length !== 1 ||
    tombstones[0].reviewStatus !== "forgotten" ||
    tombstones[0].bodyRedacted !== "" ||
    tombstones[0].snippet !== ""
  ) {
    fail("P-18 forget did not preserve a body-free metadata tombstone");
  }
  const restart = hits(events.get("restart-readback"), "P-18 restart feed");
  const restartForgotten = restart.filter(
    (hit) => hit.memoryID === marker.memoryID,
  );
  const restartRejected = restart.filter(
    (hit) => hit.memoryID === marker.rejectedMemoryID,
  );
  if (
    restartForgotten.length !== 1 ||
    restartForgotten[0].reviewStatus !== "forgotten" ||
    restartForgotten[0].bodyRedacted !== "" ||
    restartRejected.length !== 1 ||
    restartRejected[0].reviewStatus !== "rejected" ||
    restartRejected[0].bodyRedacted !== marker.rejectedBody
  ) {
    fail("P-18 daemon restart lost durable review decisions");
  }

  const audit = events.get("audit-readback");
  if (!Array.isArray(audit.events) || audit.events.length < 5)
    fail("P-18 audit trail is incomplete");
  const chronological = [...audit.events].sort(
    (left, right) => left.seq - right.seq,
  );
  let previousHash = null;
  let previousSequence = 0;
  for (const event of chronological) {
    if (
      !Number.isSafeInteger(event.seq) ||
      event.seq <= previousSequence ||
      !HASH.test(event.hash ?? "") ||
      (previousHash !== null && event.prevHash !== previousHash)
    )
      fail("P-18 audit chain continuity is invalid");
    previousSequence = event.seq;
    previousHash = event.hash;
  }
  const actions = chronological.filter((event) =>
    [marker.memoryID, marker.rejectedMemoryID].includes(event.subjectID),
  );
  const labels = actions.flatMap((event) => event.labels ?? []);
  if (
    !actions.some(
      (event) =>
        event.action === "memory.remember" &&
        event.subjectID === marker.memoryID,
    ) ||
    !actions.some(
      (event) =>
        event.action === "memory.review_status" &&
        event.subjectID === marker.memoryID,
    ) ||
    !actions.some(
      (event) =>
        event.action === "memory.review_status" &&
        event.subjectID === marker.rejectedMemoryID,
    ) ||
    !actions.some(
      (event) =>
        event.action === "memory.forget" && event.subjectID === marker.memoryID,
    ) ||
    !labels.includes("review_status:quarantined") ||
    !labels.includes("review_status:approved") ||
    !labels.includes("review_status:rejected") ||
    !labels.includes("review_status:forgotten")
  ) {
    fail("P-18 audit trail does not cover the full review lifecycle");
  }
  return { events: value.events.length, auditEvents: audit.events.length };
}

function validateUI(
  snapshot,
  marker,
  manifestSha256,
  captureStart,
  captureEnd,
) {
  const value = parseJson(snapshot.bytes, "P-18 UI transcript");
  exactKeys(value, ["events", "producer"], "P-18 UI transcript");
  const phases = ["pending", "approved", "rejected-forgotten", "restart"];
  if (
    value.producer !== "openburnbar-p18-installed-ui-probe-v1" ||
    !Array.isArray(value.events) ||
    value.events.length !== phases.length
  )
    fail("P-18 UI transcript is incomplete");
  let initialPid = null;
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    exactKeys(
      event,
      [
        "appPid",
        "at",
        "manifestSha256",
        "marker",
        "memoryID",
        "observed",
        "phase",
      ],
      `P-18 UI event ${index}`,
    );
    const at = timestamp(event.at, `P-18 UI ${event.phase}`);
    if (
      event.phase !== phases[index] ||
      event.marker !== marker.marker ||
      event.memoryID !== marker.memoryID ||
      event.manifestSha256 !== manifestSha256 ||
      !Number.isSafeInteger(event.appPid) ||
      event.appPid < 2 ||
      at <= previous ||
      at < captureStart ||
      at > captureEnd
    )
      fail(`P-18 UI event ${index} is not live-session-bound`);
    previous = at;
    if (index === 0) initialPid = event.appPid;
  }
  if (value.events.at(-1).appPid === initialPid)
    fail("P-18 final restart reused the initial desktop process");
  const [pending, approved, terminal, restart] = value.events.map(
    (event) => event.observed,
  );
  for (const [label, observation] of [
    ["pending", pending],
    ["approved", approved],
    ["terminal", terminal],
    ["restart", restart],
  ]) {
    if (observation === null || typeof observation !== "object")
      fail(`P-18 ${label} UI observation is absent`);
  }
  if (
    pending.body !== true ||
    pending.approveAction !== true ||
    pending.rejectAction !== true ||
    pending.auditVisible !== true ||
    approved.status !== "approved" ||
    approved.forgetAction !== true ||
    terminal.rejectedStatus !== true ||
    terminal.forgottenStatus !== true ||
    terminal.forgottenBodyAbsent !== true ||
    restart.rejectedStatus !== true ||
    restart.forgottenStatus !== true ||
    restart.auditVisible !== true
  ) {
    fail("P-18 UI did not expose the complete accessible review lifecycle");
  }
  return value;
}

export function validateP18InstalledSession(
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
    "P-18 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p18-installed-memory-review-session-v1"
  ) {
    fail("P-18 installed session identity is invalid");
  }
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P18_REQUIREMENT_ID,
    "P-18 installed session",
  );
  exactKeys(
    document.marker,
    [
      "body",
      "marker",
      "memoryID",
      "projectID",
      "rejectedBody",
      "rejectedMemoryID",
    ],
    "P-18 marker",
  );
  if (
    !MARKER.test(document.marker.marker ?? "") ||
    !document.marker.body.includes(document.marker.marker) ||
    !document.marker.rejectedBody.includes(document.marker.marker) ||
    !/^mem_[a-f0-9]{32}$/u.test(document.marker.memoryID ?? "") ||
    !/^mem_[a-f0-9]{32}$/u.test(document.marker.rejectedMemoryID ?? "") ||
    document.marker.memoryID === document.marker.rejectedMemoryID ||
    !document.marker.projectID
  )
    fail("P-18 marker identity is invalid");
  exactKeys(
    document.evidence,
    [
      "daemonTranscript",
      "initialScreenshot",
      "restartScreenshot",
      "uiTranscript",
    ],
    "P-18 evidence",
  );
  const daemon = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.daemonTranscript,
    "P-18 daemon transcript",
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
    "P-18 UI transcript",
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
      `P-18 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-18 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-18 ${field} is blank`);
    screenshotHashes.add(
      crypto.createHash("sha256").update(png.pixels).digest("hex"),
    );
  }
  if (screenshotHashes.size !== 2)
    fail("P-18 screenshots replay the same UI state");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-18 reuses an evidence artifact");
  return { document, evidence, endedAt: envelope.endedAt, ...summary };
}

export function buildP18Proof({
  session,
  source,
  collectedAt,
  events,
  auditEvents,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p18-memory-review-proof-v1",
    requirementId: P18_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-memory-review-session", ...source },
    claim: {
      passed: true,
      memoryID: session.marker.memoryID,
      daemonEvents: events,
      auditEvents,
      quarantineIsolation: true,
      approveRejectForget: true,
      durableRestart: true,
      hashChainedAudit: true,
      accessibleUI: true,
    },
  };
}

export function validateP18Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-18 proof");
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
    "P-18 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p18-memory-review-proof-v1" ||
    proof.requirementId !== P18_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-18 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-18 proof source",
  );
  if (proof.source.method !== "live-installed-memory-review-session")
    fail("P-18 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-18 source session",
    { mediaType: "json", minimumBytes: 500 },
  );
  const validated = validateP18InstalledSession(
    parseJson(source.bytes, "P-18 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(
    proof.claim,
    [
      "accessibleUI",
      "approveRejectForget",
      "auditEvents",
      "daemonEvents",
      "durableRestart",
      "hashChainedAudit",
      "memoryID",
      "passed",
      "quarantineIsolation",
    ],
    "P-18 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.memoryID !== validated.document.marker.memoryID ||
    proof.claim.daemonEvents !== validated.events ||
    proof.claim.auditEvents !== validated.auditEvents ||
    [
      "accessibleUI",
      "approveRejectForget",
      "durableRestart",
      "hashChainedAudit",
      "quarantineIsolation",
    ].some((field) => proof.claim[field] !== true)
  )
    fail("P-18 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
