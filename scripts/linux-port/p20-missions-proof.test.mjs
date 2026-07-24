import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP20MissionsProof } from "./capture-p20-missions-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  P20_PROOF_ROLE,
  validateP20InstalledSession,
  validateP20Proof,
} from "./lib/p20-missions-proof.mjs";
import { materializeP20MissionsSession } from "./materialize-p20-missions-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-20.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "202020";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "p20-fedcba0987654321";
const PROJECT = `${MARKER}-project`;
const MISSION_ID = `mission:${MARKER}`;
const MISSION_TITLE = `P20 Mission ${MARKER}`;
const PACKET_ID = `packet:${MARKER}`;
const RESULT_ID = `result:${MARKER}`;
const QUESTION_ID = `question:${MARKER}`;
const QUESTION_TITLE = `P20 Question ${MARKER}`;
const OPTION_ID = `option:${MARKER}`;
const OPTION_TITLE = `Proceed ${MARKER}`;
const OPTION_ANSWER = `Proceed with ${MARKER}`;

function write(file, bytes, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  if (mode) fs.chmodSync(file, mode);
  return file;
}
function json(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return {
    path: path.relative(root, file).split(path.sep).join("/"),
    sha256: hash(bytes),
    size: bytes.length,
  };
}
function chunk(type, data) {
  const name = Buffer.from(type);
  const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length);
  name.copy(output, 4);
  data.copy(output, 8);
  output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8);
  return output;
}
function png(seed) {
  const width = 320;
  const height = 220;
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1)
    for (let x = 0; x < width; x += 1) {
      const at = y * (width * 3 + 1) + 1 + x * 3;
      raw[at] = (x + seed) % 256;
      raw[at + 1] = (y + seed * 2) % 256;
      raw[at + 2] = (x + y + seed * 3) % 256;
    }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
function attestation(root, raw) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  const privatePem = privateKey.export({ type: "pkcs8", format: "pem" });
  const publicPem = publicKey.export({ type: "spki", format: "pem" });
  write(
    path.join(root, "packaging/linux/openburnbar-linux-ed25519.pub.pem"),
    publicPem,
  );
  const item = (installedPath, bytes, mode) => ({
    path: installedPath,
    type: "file",
    sha256: hash(bytes),
    size: bytes.length,
    mode,
    uid: 0,
    gid: 0,
  });
  const manifest = canonicalJsonBytes(
    createInstalledManifest({
      files: [
        item("/usr/bin/openburnbar-daemon", Buffer.from("daemon"), "0755"),
        item(
          "/usr/bin/openburnbar-linux-desktop",
          Buffer.from("desktop"),
          "0755",
        ),
        item(
          "/usr/share/openburnbar/attestation/release-ed25519.pub.pem",
          publicPem,
          "0644",
        ),
      ],
      packageVersion: VERSION,
      gitCommit: HEAD,
      packageArchitecture: "aarch64",
      packageFormat: "deb",
      firebaseAppId: "1:2:web:3",
    }),
  );
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return {
    manifestPath: write(path.join(raw, "installed-manifest.json"), manifest),
    signaturePath: write(
      path.join(raw, "installed-manifest.json.sig"),
      signature,
    ),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function event(phase, at, method, request, result) {
  return { phase, at, method, request, ok: true, error: null, result };
}
function project() {
  return {
    id: `project:${PROJECT}`,
    projectSlug: PROJECT,
    displayName: `P20 Project ${MARKER}`,
    summary: `Mission lifecycle project ${MARKER}`,
    status: "healthy",
    preferredCadence: "weekly",
    aliases: [`${MARKER}:project-alias`],
    automationMode: "manual",
    reviewModelID: null,
    scheduleHourLocal: 9,
    scheduleWeekdayLocal: 2,
    freshness: "provisional",
    latestDailyReviewAt: null,
    latestWeeklyReviewAt: null,
    nextScheduledReviewAt: null,
    pendingQuestionCount: 0,
    openFollowupCount: 0,
    activeMissionCount: 0,
    activeMissionID: null,
    needsOperatorAttention: false,
    ingestionSource: "manual",
    metadata: { p20_marker: MARKER },
  };
}
function marker(projectValue) {
  return {
    marker: MARKER,
    projectSlug: PROJECT,
    project: projectValue,
    missionID: MISSION_ID,
    missionTitle: MISSION_TITLE,
    packetID: PACKET_ID,
    resultID: RESULT_ID,
    questionID: QUESTION_ID,
    questionTitle: QUESTION_TITLE,
    optionID: OPTION_ID,
    optionTitle: OPTION_TITLE,
    optionAnswer: OPTION_ANSWER,
  };
}
function binding(value) {
  return {
    repoRoot: value.root,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    ...value.identity,
  };
}
function mutateArtifact(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const payload = JSON.parse(fs.readFileSync(file));
  change(payload);
  json(file, payload);
  Object.assign(descriptor, record(value.root, file));
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p20-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-20",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const started = Date.now() - 30_000;
  const at = (offset) => new Date(started + offset).toISOString();
  const projectValue = project();
  const markerValue = marker(projectValue);
  json(path.join(raw, "missions-marker.json"), markerValue);
  const awaiting = {
    id: MISSION_ID,
    projectSlug: PROJECT,
    title: MISSION_TITLE,
    status: "awaiting_approval",
    approval: { approved: false },
    packets: [],
    results: [],
    prLinkage: null,
  };
  const approved = {
    ...awaiting,
    status: "approved",
    approval: { approved: true },
  };
  const packet = {
    id: PACKET_ID,
    missionID: MISSION_ID,
    workerName: "linux-parity-worker",
    objective: `Execute ${MARKER}`,
    status: "dispatched",
    runID: `run:${MARKER}`,
    metadata: { p20_marker: MARKER },
  };
  const resultValue = {
    id: RESULT_ID,
    missionID: MISSION_ID,
    packetID: PACKET_ID,
    runID: `run:${MARKER}`,
    status: "succeeded",
    summary: `Completed ${MARKER}`,
    burnDelta: 12.5,
    evidenceRefs: [`evidence:${MARKER}`],
    prLinkage: {
      schemaVersion: 1,
      repository: "openburnbar/openburnbar",
      prNumberOrID: "20",
      url: "https://github.com/openburnbar/openburnbar/pull/20",
      state: "merged",
      mergeCommitSHA: "2".repeat(40),
    },
  };
  const executed = {
    ...approved,
    status: "in_progress",
    packets: [packet],
    results: [resultValue],
    prLinkage: resultValue.prLinkage,
  };
  const history = [
    { id: "created" },
    { id: "approved" },
    { id: "packet" },
    { id: "result" },
  ];
  const question = {
    id: QUESTION_ID,
    projectSlug: PROJECT,
    title: QUESTION_TITLE,
    status: "pending",
    suggestedOptions: [
      { id: OPTION_ID, title: OPTION_TITLE, answer: OPTION_ANSWER },
    ],
    metadata: { p20_marker: MARKER },
  };
  const answered = {
    ...question,
    status: "answered",
    latestAnswer: { answer: OPTION_ANSWER, selectedOptionID: OPTION_ID },
  };
  const createRequest = {
    projectSlug: PROJECT,
    title: MISSION_TITLE,
    summary: `Verify ${MARKER}`,
    createdBy: "linux-parity-p20",
    recommendation: "review",
    metadata: { p20_marker: MARKER },
  };
  const resultRequest = {
    ...resultValue,
    detail: `Installed Linux evidence ${MARKER}`,
    createdAt: 1,
    metadata: { p20_marker: MARKER },
  };
  const events = [
    event(
      "project-upserted",
      at(1000),
      "daemon.controller.project.upsert",
      { project: projectValue },
      { project: projectValue },
    ),
    event("mission-created", at(2000), "daemon.mission.create", createRequest, {
      mission: awaiting,
    }),
    event(
      "mission-listed",
      at(3000),
      "daemon.mission.list",
      { projectSlug: PROJECT, statuses: ["awaiting_approval"], limit: 100 },
      { missions: [awaiting] },
    ),
    event(
      "mission-approved-readback",
      at(4000),
      "daemon.mission.get",
      { missionID: MISSION_ID },
      { mission: approved },
    ),
    event(
      "packet-dispatched",
      at(5000),
      "daemon.mission.packet.dispatch",
      { missionID: MISSION_ID, actor: "linux-parity-p20", packet },
      { mission: { ...approved, packets: [packet] } },
    ),
    event(
      "result-recorded",
      at(6000),
      "daemon.mission.result.record",
      { missionID: MISSION_ID, result: resultRequest },
      { mission: executed },
    ),
    event(
      "mission-health",
      at(7000),
      "daemon.mission.health",
      { missionID: MISSION_ID },
      {
        missionID: MISSION_ID,
        health: { status: "healthy" },
        history: history.slice(0, 3),
      },
    ),
    event(
      "question-created",
      at(8000),
      "daemon.question.create",
      { question },
      { question },
    ),
    event(
      "question-answered-readback",
      at(9000),
      "daemon.question.list",
      { projectSlug: PROJECT, statuses: ["answered"], limit: 100 },
      { questions: [answered] },
    ),
    event(
      "restart-mission-get",
      at(10_000),
      "daemon.mission.get",
      { missionID: MISSION_ID },
      { mission: executed },
    ),
    event(
      "restart-mission-health",
      at(11_000),
      "daemon.mission.health",
      { missionID: MISSION_ID },
      { missionID: MISSION_ID, health: { status: "healthy" }, history },
    ),
    event(
      "mission-cancelled-readback",
      at(12_000),
      "daemon.mission.get",
      { missionID: MISSION_ID },
      { mission: { ...executed, status: "cancelled" } },
    ),
  ];
  json(path.join(raw, "missions-daemon-transcript.json"), {
    producer: "openburnbar-p20-installed-missions-daemon-probe-v1",
    transport: "installed daemon AF_UNIX RPC",
    events,
  });
  const baseUI = (phase, offset, observed, pid) => ({
    phase,
    at: at(offset),
    appPid: pid,
    marker: MARKER,
    projectSlug: PROJECT,
    missionTitle: MISSION_TITLE,
    questionTitle: QUESTION_TITLE,
    manifestSha256: identity.manifestSha256,
    observed,
  });
  const action = (phase, offset, name) => ({
    phase,
    at: at(offset),
    result: {
      producer: "openburnbar-p20-atspi-control-v1",
      activation: { name, role: "push button", action: "click" },
    },
  });
  json(path.join(raw, "missions-ui-transcript.json"), {
    producer: "openburnbar-p20-installed-missions-ui-probe-v1",
    events: [
      baseUI(
        "pending-approval",
        2500,
        { missionVisible: true, pendingVisible: true, approveAction: true },
        2001,
      ),
      baseUI(
        "approved",
        4500,
        {
          missionVisible: true,
          approvalSubmitted: true,
          approvedVisible: true,
        },
        2001,
      ),
      baseUI(
        "pending-question",
        8500,
        {
          questionVisible: true,
          suggestedAnswerVisible: true,
          submitVisible: true,
        },
        2002,
      ),
      baseUI(
        "restart-detail",
        11_500,
        { missionVisible: true, inspectVisible: true, cancelVisible: true },
        2003,
      ),
      baseUI(
        "mission-detail",
        11_600,
        { packetVisible: true, resultVisible: true, historyVisible: true },
        2003,
      ),
      baseUI(
        "cancelled",
        12_500,
        { missionVisible: true, cancelledVisible: true },
        2003,
      ),
    ],
    actions: [
      action("approve", 3500, `Approve ${MISSION_TITLE}`),
      action("question-option", 8600, OPTION_TITLE),
      action("question-submit", 8700, "Submit answer"),
      action("inspect-logs", 11_550, "Inspect logs"),
      action("cancel-start", 12_000, "Cancel mission"),
      action("cancel-confirm", 12_100, "Confirm cancel"),
    ],
  });
  ["pending", "approved", "question", "detail", "cancelled"].forEach(
    (name, index) =>
      write(path.join(raw, `missions-${name}.png`), png(20 + index)),
  );
  const materialized = materializeP20MissionsSession(
    {
      repoRoot: root,
      outputRoot: input,
      rawEvidenceDir: raw,
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      packageVersion: VERSION,
      ...identity,
      compositor: "Mutter",
    },
    {
      installedVerifier: () => ({}),
      manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath,
    },
  );
  return { root, raw, input, identity, materialized, endedAt: at(12_500) };
}

function context(value, proofFile) {
  const subjects = path.join(value.input, "release-subjects");
  const aggregate = record(
    value.root,
    json(path.join(subjects, "aggregate.json"), { passed: true }),
  );
  const runtime = record(
    value.root,
    json(path.join(subjects, "runtime.json"), {
      daemonVersion: VERSION,
      shellVersion: VERSION,
    }),
  );
  const environment = record(
    value.root,
    json(path.join(subjects, "environment.json"), {
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      architecture: "aarch64",
      passed: true,
    }),
  );
  const pkg = record(
    value.root,
    write(path.join(subjects, "package.deb"), "package\n"),
  );
  const proof = record(value.root, proofFile);
  return {
    schemaVersion: 1,
    repoRoot: value.root,
    requirementId: "P-20",
    checkId: "p-20.missions",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-20",
        environmentId: ENVIRONMENT,
        version: VERSION,
        blockers: [],
        architectures: [...RELEASE_ARCHITECTURES],
        supportEnvironments: [...SUPPORT_ENVIRONMENTS],
        selectedPackage: { architecture: "aarch64", format: "deb" },
        candidate: { runId: RUN_ID, artifactDigest: DIGEST },
        packageManifestSignature: value.materialized.document.package.signature,
        proofs: [
          { role: "aggregate-product-proof-closure", ...aggregate },
          { role: P20_PROOF_ROLE, ...proof },
        ],
      },
    },
    subjects: {
      release: aggregate,
      packageManifest: value.materialized.document.package.manifest,
      packages: [pkg],
      runtimes: [runtime],
      installation: [aggregate],
      environment,
      features: [],
    },
  };
}

test("P-20 materializes, captures, and validates the installed mission lifecycle", async () => {
  const value = fixture();
  try {
    const captured = captureP20MissionsProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.materialized.output,
      },
      {
        resolveHead: () => HEAD,
        now: () => new Date(Date.parse(value.endedAt) + 1),
      },
    );
    const validated = validateP20Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        record(value.root, captured.output).path,
        "P-20 proof",
      ),
    });
    assert.equal(validated.proof.claim.daemonEvents, 12);
    assert.equal(validated.proof.claim.uiStates, 6);
    assert.equal(validated.proof.claim.historyEntries, 4);
    assert.equal(
      (await validateProductRequirement(context(value, captured.output)))
        .status,
      "passed",
    );
    assert.deepEqual(
      JSON.parse(fs.readFileSync(captured.registration)).artifacts,
      [
        {
          role: P20_PROOF_ROLE,
          path: "feature-artifacts/p20-installed-missions-proof.json",
        },
      ],
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-20 rejects substituted mission evidence", () => {
  const value = fixture();
  try {
    const document = structuredClone(value.materialized.document);
    mutateArtifact(value, document.evidence.daemonTranscript, (payload) => {
      payload.events.find(
        (row) => row.phase === "result-recorded",
      ).request.result.evidenceRefs = ["substituted"];
    });
    assert.throws(
      () =>
        validateP20InstalledSession(document, binding(value), {
          repoRoot: value.root,
        }),
      /requests do not match/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-20 rejects replayed UI screenshots", () => {
  const value = fixture();
  try {
    const document = structuredClone(value.materialized.document);
    const source = path.join(
      value.root,
      document.evidence.pendingScreenshot.path,
    );
    const target = path.join(
      value.root,
      document.evidence.cancelledScreenshot.path,
    );
    fs.copyFileSync(source, target);
    Object.assign(
      document.evidence.cancelledScreenshot,
      record(value.root, target),
    );
    assert.throws(
      () =>
        validateP20InstalledSession(document, binding(value), {
          repoRoot: value.root,
        }),
      /screenshots replay/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-20 rejects a missing restart persistence readback", () => {
  const value = fixture();
  try {
    const document = structuredClone(value.materialized.document);
    mutateArtifact(value, document.evidence.daemonTranscript, (payload) => {
      payload.events.find(
        (row) => row.phase === "restart-mission-get",
      ).result.mission.results = [];
    });
    assert.throws(
      () =>
        validateP20InstalledSession(document, binding(value), {
          repoRoot: value.root,
        }),
      /responses do not prove/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-20 rejects a substituted AT-SPI mission action", () => {
  const value = fixture();
  try {
    const document = structuredClone(value.materialized.document);
    mutateArtifact(value, document.evidence.uiTranscript, (payload) => {
      payload.actions.find(
        (row) => row.phase === "cancel-confirm",
      ).result.activation.name = "Cancel later";
    });
    assert.throws(
      () =>
        validateP20InstalledSession(document, binding(value), {
          repoRoot: value.root,
        }),
      /UI action 5 is invalid/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
