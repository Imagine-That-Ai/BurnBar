import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP19ProjectsProof } from "./capture-p19-projects-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  P19_PROOF_ROLE,
  validateP19InstalledSession,
  validateP19Proof,
} from "./lib/p19-projects-proof.mjs";
import { materializeP19ProjectsSession } from "./materialize-p19-projects-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-19.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "191919";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "p19-fedcba0987654321";

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
  const width = 480;
  const height = 300;
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
      raw[at + 1] = (y * 2 + seed) % 256;
      raw[at + 2] = (x + y + seed) % 256;
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
    signaturePath: write(path.join(raw, "installed-manifest.json.sig"), signature),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function project(slug, displayName, alias) {
  return {
    id: `project:${slug}`,
    projectSlug: slug,
    displayName,
    summary: `summary ${slug}`,
    status: "healthy",
    preferredCadence: "weekly",
    aliases: [alias],
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
    metadata: { p19_marker: MARKER },
  };
}
function event(phase, at, method, request, result) {
  return { phase, at, method, request, ok: true, error: null, result };
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
function mutateArtifact(value, document, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const payload = JSON.parse(fs.readFileSync(file));
  change(payload);
  json(file, payload);
  Object.assign(descriptor, record(value.root, file));
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p19-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-19",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const started = Date.now() - 20_000;
  const at = (offset) => new Date(started + offset).toISOString();
  const sourceSlug = `${MARKER}-source`;
  const targetSlug = `${MARKER}-target`;
  const sourceAlias = `${MARKER}:source-alias`;
  const sourceProject = project(sourceSlug, `P19 Source ${MARKER}`, sourceAlias);
  const targetProject = project(
    targetSlug,
    `P19 Target ${MARKER}`,
    `${MARKER}:target-alias`,
  );
  const marker = {
    marker: MARKER,
    sourceSlug,
    targetSlug,
    sourceAlias,
    sourceProject,
    targetProject,
  };
  json(path.join(raw, "projects-marker.json"), marker);
  const reassign = {
    sourceProjectSlug: sourceSlug,
    targetProjectSlug: targetSlug,
    updatedReferenceCount: 2,
  };
  const mission = {
    id: `mission-${MARKER}`,
    projectSlug: sourceSlug,
  };
  const reassignedMission = { ...mission, projectSlug: targetSlug };
  const events = [
    event("source-upserted", at(1000), "daemon.controller.project.upsert", { project: sourceProject }, { project: sourceProject }),
    event("target-upserted", at(2000), "daemon.controller.project.upsert", { project: targetProject }, { project: targetProject }),
    event("initial-list", at(3000), "daemon.controller.project.list", { includePaused: true, limit: 100 }, { projects: [sourceProject, targetProject] }),
    event("source-get-by-alias", at(4000), "daemon.controller.project.get", { projectSlug: sourceAlias }, { project: sourceProject }),
    event("associated-mission-created", at(5000), "daemon.mission.create", {
      projectSlug: sourceSlug,
      title: `P19 associated mission ${MARKER}`,
      summary: `Verify durable project reassignment ${MARKER}`,
      createdBy: "linux-parity-p19",
      recommendation: "review",
      metadata: { p19_marker: MARKER },
    }, { mission }),
    event("source-deleted", at(6000), "daemon.controller.project.delete", { projectSlug: sourceSlug }, { projectSlug: sourceSlug, deleted: true }),
    event("deleted-source-reassigned", at(7000), "daemon.controller.project.reassign", { sourceProjectSlug: sourceAlias, targetProjectSlug: targetSlug }, reassign),
    event("reassigned-mission-get", at(8000), "daemon.mission.get", { missionID: mission.id }, { mission: reassignedMission }),
    event("post-delete-list", at(9000), "daemon.controller.project.list", { includePaused: true, limit: 100 }, { projects: [targetProject] }),
    event("post-delete-get", at(10_000), "daemon.controller.project.get", { projectSlug: sourceSlug }, { project: null }),
    event("restart-list", at(11_000), "daemon.controller.project.list", { includePaused: true, limit: 100 }, { projects: [targetProject] }),
    event("restart-get-deleted", at(12_000), "daemon.controller.project.get", { projectSlug: sourceAlias }, { project: null }),
    event("restart-mission-get", at(13_000), "daemon.mission.get", { missionID: mission.id }, { mission: reassignedMission }),
    {
      phase: "restart-upsert-rejected-by-tombstone",
      at: at(14_000),
      method: "daemon.controller.project.upsert",
      request: { project: sourceProject },
      ok: false,
      error: `project deleted: ${sourceSlug}`,
      result: null,
    },
    event("restart-reassign-from-tombstone", at(15_000), "daemon.controller.project.reassign", { sourceProjectSlug: sourceAlias, targetProjectSlug: targetSlug }, { ...reassign, updatedReferenceCount: 0 }),
  ];
  json(path.join(raw, "projects-daemon-transcript.json"), {
    producer: "openburnbar-p19-installed-projects-daemon-probe-v1",
    transport: "installed daemon AF_UNIX RPC",
    events,
  });
  json(path.join(raw, "projects-ui-transcript.json"), {
    producer: "openburnbar-p19-installed-projects-ui-probe-v1",
    events: [
      {
        phase: "initial",
        at: at(4500),
        appPid: 1901,
        marker: MARKER,
        sourceSlug,
        targetSlug,
        manifestSha256: identity.manifestSha256,
        observed: { sourceVisible: true, targetVisible: true, detailsAction: true, registerAction: true },
      },
      {
        phase: "restart-list",
        at: at(15_500),
        appPid: 1902,
        marker: MARKER,
        sourceSlug,
        targetSlug,
        manifestSha256: identity.manifestSha256,
        observed: { sourceAbsent: true, targetVisible: true, detailsAction: true },
      },
      {
        phase: "restart-detail",
        at: at(16_000),
        appPid: 1902,
        marker: MARKER,
        sourceSlug,
        targetSlug,
        manifestSha256: identity.manifestSha256,
        observed: { targetVisible: true, historyVisible: true },
      },
    ],
  });
  write(path.join(raw, "projects-initial.png"), png(19));
  write(path.join(raw, "projects-restart.png"), png(20));
  const materialized = materializeP19ProjectsSession(
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
  return { root, raw, input, identity, materialized, endedAt: at(16_000) };
}

function context(value, proofFile) {
  const subjects = path.join(value.input, "release-subjects");
  const aggregate = record(value.root, json(path.join(subjects, "aggregate.json"), { passed: true }));
  const runtime = record(value.root, json(path.join(subjects, "runtime.json"), { daemonVersion: VERSION, shellVersion: VERSION }));
  const environment = record(value.root, json(path.join(subjects, "environment.json"), { environmentId: ENVIRONMENT, targetHead: HEAD, architecture: "aarch64", passed: true }));
  const pkg = record(value.root, write(path.join(subjects, "package.deb"), "package\n"));
  const proof = record(value.root, proofFile);
  return {
    schemaVersion: 1,
    repoRoot: value.root,
    requirementId: "P-19",
    checkId: "p-19.projects",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-19",
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
          { role: P19_PROOF_ROLE, ...proof },
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

test("P-19 materializer, capture, and product validator close a signed installed Projects lifecycle", async () => {
  const value = fixture();
  try {
    const captured = captureP19ProjectsProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.materialized.output,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.parse(value.endedAt) + 1) },
    );
    const validated = validateP19Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(value.root, record(value.root, captured.output).path, "P-19 proof"),
    });
    assert.equal(validated.proof.claim.associatedReferences, 2);
    assert.equal(validated.proof.claim.daemonEvents, 15);
    assert.equal(validated.proof.claim.tombstoneRejections, 1);
    const result = await validateProductRequirement(context(value, captured.output));
    assert.equal(result.status, "passed");
    assert.equal(result.requirementId, "P-19");
    assert.deepEqual(JSON.parse(fs.readFileSync(captured.registration)).artifacts, [
      { role: P19_PROOF_ROLE, path: "feature-artifacts/p19-installed-projects-proof.json" },
    ]);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-19 rejects tombstone, reassignment, UI, and screenshot mutations", () => {
  const cases = [
    {
      label: "tombstone resurrection",
      mutate(value, document) {
        mutateArtifact(value, document, document.evidence.daemonTranscript, (payload) => {
          const row = payload.events.find((event) => event.phase === "restart-upsert-rejected-by-tombstone");
          row.ok = true;
          row.error = null;
          row.result = { project: document.marker.sourceProject };
        });
      },
      pattern: /tombstone/u,
    },
    {
      label: "reassignment substitution",
      mutate(value, document) {
        mutateArtifact(value, document, document.evidence.daemonTranscript, (payload) => {
          payload.events.find((event) => event.phase === "deleted-source-reassigned").result.targetProjectSlug = "substituted";
        });
      },
      pattern: /reassigned/u,
    },
    {
      label: "zero migrated associations",
      mutate(value, document) {
        mutateArtifact(value, document, document.evidence.daemonTranscript, (payload) => {
          payload.events.find(
            (event) => event.phase === "deleted-source-reassigned",
          ).result.updatedReferenceCount = 0;
        });
      },
      pattern: /deleted-source-reassigned/u,
    },
    {
      label: "mission association not migrated",
      mutate(value, document) {
        mutateArtifact(value, document, document.evidence.daemonTranscript, (payload) => {
          payload.events.find(
            (event) => event.phase === "reassigned-mission-get",
          ).result.mission.projectSlug = document.marker.sourceSlug;
        });
      },
      pattern: /reassigned association/u,
    },
    {
      label: "UI mutation",
      mutate(value, document) {
        mutateArtifact(value, document, document.evidence.uiTranscript, (payload) => {
          payload.events[1].observed.sourceAbsent = false;
        });
      },
      pattern: /Projects UI/u,
    },
  ];
  for (const row of cases) {
    const value = fixture();
    try {
      const document = structuredClone(value.materialized.document);
      row.mutate(value, document);
      assert.throws(
        () => validateP19InstalledSession(document, binding(value), { repoRoot: value.root }),
        row.pattern,
        row.label,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-19 capture rejects stale evidence and changed source bytes", () => {
  const value = fixture();
  try {
    assert.throws(
      () =>
        captureP19ProjectsProof(
          {
            ...binding(value),
            inputRoot: value.input,
            sessionReport: value.materialized.output,
          },
          { resolveHead: () => "f".repeat(40) },
        ),
      /target HEAD/u,
    );
    const captured = captureP19ProjectsProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.materialized.output,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.parse(value.endedAt) + 1) },
    );
    fs.appendFileSync(value.materialized.output, " \n");
    assert.throws(
      () =>
        validateP19Proof({
          ...binding(value),
          snapshot: readRegularSnapshot(value.root, record(value.root, captured.output).path, "P-19 proof"),
        }),
      /bytes changed|sha256|size/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
