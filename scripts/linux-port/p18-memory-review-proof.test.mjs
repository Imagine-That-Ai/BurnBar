import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP18MemoryReviewProof } from "./capture-p18-memory-review-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  P18_PROOF_ROLE,
  validateP18InstalledSession,
  validateP18Proof,
} from "./lib/p18-memory-review-proof.mjs";
import { materializeP18MemoryReviewSession } from "./materialize-p18-memory-review-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-18.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "181818";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "P18-fedcba0987654321";
const MEMORY_ID = `mem_${"3".repeat(32)}`;
const REJECTED_ID = `mem_${"4".repeat(32)}`;

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
    signaturePath: write(
      path.join(raw, "installed-manifest.json.sig"),
      signature,
    ),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
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
function memoryHit(id, body, status) {
  return {
    memoryID: id,
    projectID: "project-p18",
    kind: "note",
    scope: "personal",
    confidence: 0.97,
    bodyRedacted: body,
    tags: ["p18-proof"],
    sourcePath: null,
    snippet: body,
    rank: status === "approved" ? 0.1 : null,
    reviewStatus: status,
  };
}
function event(phase, at, method, request, result) {
  return { phase, at, method, request, ok: true, error: null, result };
}
function recallRequest(includeQuarantined, includeForgotten) {
  return {
    query: MARKER,
    includeCrossProject: false,
    includeQuarantined,
    includeForgotten,
  };
}
function mutateArtifact(value, document, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const payload = JSON.parse(fs.readFileSync(file));
  change(payload);
  json(file, payload);
  const updated = record(value.root, file);
  descriptor.sha256 = updated.sha256;
  descriptor.size = updated.size;
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p18-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-18",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const started = Date.now() - 20_000;
  const at = (offset) => new Date(started + offset).toISOString();
  const body = `Durable preference ${MARKER}`;
  const rejectedBody = `Rejected candidate ${MARKER}`;
  const marker = {
    marker: MARKER,
    memoryID: MEMORY_ID,
    rejectedMemoryID: REJECTED_ID,
    projectID: "project-p18",
    body,
    rejectedBody,
  };
  json(path.join(raw, "memory-marker.json"), marker);
  const audit = [
    ["memory.remember", MEMORY_ID, ["review_status:quarantined"]],
    ["memory.review_status", MEMORY_ID, ["review_status:approved"]],
    ["memory.remember", REJECTED_ID, ["review_status:quarantined"]],
    ["memory.review_status", REJECTED_ID, ["review_status:rejected"]],
    [
      "memory.forget",
      MEMORY_ID,
      ["local body delete", "review_status:forgotten"],
    ],
  ].map(([action, subjectID, labels], index) => ({
    seq: index + 1,
    ts: at(5000 + index),
    actor: "openburnbar-daemon",
    action,
    domain: "memory",
    projectID: "project-p18",
    subjectID,
    labels,
    prevHash: index === 0 ? null : String(index).repeat(64),
    hash: String(index + 1).repeat(64),
  }));
  const events = [
    event(
      "quarantine-created",
      at(1000),
      "daemon.memory.remember",
      { text: body, reviewStatus: "quarantined" },
      {
        traceID: "t1",
        projectID: "project-p18",
        memoryID: MEMORY_ID,
        auditHash: "1".repeat(64),
      },
    ),
    event(
      "normal-recall-excludes-quarantine",
      at(2000),
      "daemon.memory.recall",
      recallRequest(false, false),
      { traceID: "t2", projectID: "project-p18", hits: [] },
    ),
    event(
      "review-feed-includes-quarantine",
      at(3000),
      "daemon.memory.recall",
      recallRequest(true, true),
      {
        traceID: "t3",
        projectID: "project-p18",
        hits: [memoryHit(MEMORY_ID, body, "quarantined")],
      },
    ),
    event(
      "approved",
      at(4000),
      "daemon.memory.review_status",
      { memoryID: MEMORY_ID, status: "approved" },
      {
        traceID: "t4",
        projectID: "project-p18",
        memoryID: MEMORY_ID,
        status: "approved",
        auditHash: "2".repeat(64),
      },
    ),
    event(
      "normal-recall-includes-approved",
      at(5000),
      "daemon.memory.recall",
      recallRequest(false, false),
      {
        traceID: "t5",
        projectID: "project-p18",
        hits: [memoryHit(MEMORY_ID, body, "approved")],
      },
    ),
    event(
      "rejected-candidate-created",
      at(5500),
      "daemon.memory.remember",
      { text: rejectedBody, reviewStatus: "quarantined" },
      {
        traceID: "t6",
        projectID: "project-p18",
        memoryID: REJECTED_ID,
        auditHash: "3".repeat(64),
      },
    ),
    event(
      "rejected",
      at(6000),
      "daemon.memory.review_status",
      { memoryID: REJECTED_ID, status: "rejected" },
      {
        traceID: "t7",
        projectID: "project-p18",
        memoryID: REJECTED_ID,
        status: "rejected",
        auditHash: "4".repeat(64),
      },
    ),
    event(
      "normal-recall-excludes-rejected",
      at(7000),
      "daemon.memory.recall",
      recallRequest(false, false),
      {
        traceID: "t8",
        projectID: "project-p18",
        hits: [memoryHit(MEMORY_ID, body, "approved")],
      },
    ),
    event(
      "forgotten",
      at(8000),
      "daemon.memory.forget",
      { memoryID: MEMORY_ID, requireCloudDelete: false },
      {
        traceID: "t9",
        projectID: "project-p18",
        memoryID: MEMORY_ID,
        localDeleted: true,
        cloudDeletePending: false,
        auditHash: "5".repeat(64),
      },
    ),
    event(
      "forgotten-tombstone",
      at(9000),
      "daemon.memory.recall",
      recallRequest(true, true),
      {
        traceID: "t10",
        projectID: "project-p18",
        hits: [memoryHit(MEMORY_ID, "", "forgotten")],
      },
    ),
    event(
      "restart-readback",
      at(10_000),
      "daemon.memory.recall",
      recallRequest(true, true),
      {
        traceID: "t11",
        projectID: "project-p18",
        hits: [
          memoryHit(MEMORY_ID, "", "forgotten"),
          memoryHit(REJECTED_ID, rejectedBody, "rejected"),
        ],
      },
    ),
    event(
      "audit-readback",
      at(11_000),
      "daemon.memory.audit_trail",
      { limit: 50 },
      {
        traceID: "t12",
        projectID: "project-p18",
        events: [...audit].reverse(),
      },
    ),
  ];
  json(path.join(raw, "memory-daemon-transcript.json"), {
    producer: "openburnbar-p18-installed-daemon-probe-v1",
    transport: "installed daemon AF_UNIX RPC",
    events,
  });
  json(path.join(raw, "memory-ui-transcript.json"), {
    producer: "openburnbar-p18-installed-ui-probe-v1",
    events: [
      {
        phase: "pending",
        at: at(3500),
        appPid: 801,
        marker: MARKER,
        memoryID: MEMORY_ID,
        manifestSha256: identity.manifestSha256,
        observed: {
          body: true,
          approveAction: true,
          rejectAction: true,
          auditVisible: true,
        },
      },
      {
        phase: "approved",
        at: at(5500),
        appPid: 801,
        marker: MARKER,
        memoryID: MEMORY_ID,
        manifestSha256: identity.manifestSha256,
        observed: { status: "approved", forgetAction: true },
      },
      {
        phase: "rejected-forgotten",
        at: at(9500),
        appPid: 801,
        marker: MARKER,
        memoryID: MEMORY_ID,
        manifestSha256: identity.manifestSha256,
        observed: {
          rejectedStatus: true,
          forgottenStatus: true,
          forgottenBodyAbsent: true,
        },
      },
      {
        phase: "restart",
        at: at(12_000),
        appPid: 802,
        marker: MARKER,
        memoryID: MEMORY_ID,
        manifestSha256: identity.manifestSha256,
        observed: {
          rejectedStatus: true,
          forgottenStatus: true,
          auditVisible: true,
        },
      },
    ],
  });
  write(path.join(raw, "memory-initial.png"), png(18));
  write(path.join(raw, "memory-restart.png"), png(19));
  const materialized = materializeP18MemoryReviewSession(
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
  return { root, raw, input, identity, materialized, endedAt: at(12_000) };
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
    requirementId: "P-18",
    checkId: "p-18.memory-review",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-18",
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
          { role: P18_PROOF_ROLE, ...proof },
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

test("P-18 materializer, capture, and product validator close a signed installed memory lifecycle", async () => {
  const value = fixture();
  try {
    const captured = captureP18MemoryReviewProof(
      {
        inputRoot: value.input,
        sessionReport: value.materialized.output,
        ...binding(value),
      },
      {
        resolveHead: () => HEAD,
        now: () => new Date(Date.parse(value.endedAt) + 1000),
      },
    );
    const validated = validateP18Proof({
      repoRoot: value.root,
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-18 proof",
      ),
      ...binding(value),
    });
    assert.equal(validated.proof.claim.daemonEvents, 12);
    assert.equal(validated.proof.claim.auditEvents, 5);
    assert.equal(
      (await validateProductRequirement(context(value, captured.output)))
        .status,
      "passed",
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-18 rejects semantic mutation, replay, stale evidence, and forged signatures", () => {
  const cases = [
    [
      "quarantine leaked",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.daemonTranscript, (payload) => {
          payload.events[1].result.hits.push(
            memoryHit(MEMORY_ID, `Durable preference ${MARKER}`, "quarantined"),
          );
        }),
      /leaked/u,
    ],
    [
      "body changed",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.daemonTranscript, (payload) => {
          payload.events[2].result.hits[0].bodyRedacted = "forged";
        }),
      /exact quarantined body/u,
    ],
    [
      "approved absent",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.daemonTranscript, (payload) => {
          payload.events[4].result.hits = [];
        }),
      /approved memory/u,
    ],
    [
      "rejected leaked",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.daemonTranscript, (payload) => {
          payload.events[7].result.hits.push(
            memoryHit(REJECTED_ID, `Rejected candidate ${MARKER}`, "rejected"),
          );
        }),
      /rejected candidate leaked/u,
    ],
    [
      "forgotten body retained",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.daemonTranscript, (payload) => {
          payload.events[9].result.hits[0].bodyRedacted = "secret";
        }),
      /body-free metadata tombstone/u,
    ],
    [
      "audit broken",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.daemonTranscript, (payload) => {
          payload.events[11].result.events[0].prevHash = null;
        }),
      /audit chain/u,
    ],
    [
      "UI action absent",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.uiTranscript, (payload) => {
          payload.events[0].observed.approveAction = false;
        }),
      /accessible review lifecycle/u,
    ],
    [
      "PID reused",
      (value, doc) =>
        mutateArtifact(value, doc, doc.evidence.uiTranscript, (payload) => {
          payload.events[3].appPid = payload.events[0].appPid;
        }),
      /reused/u,
    ],
    [
      "screenshot replay",
      (_value, doc) => {
        doc.evidence.restartScreenshot = doc.evidence.initialScreenshot;
      },
      /reuses an evidence artifact|replay/u,
    ],
  ];
  for (const [label, change, pattern] of cases) {
    const value = fixture();
    try {
      const document = structuredClone(value.materialized.document);
      change(value, document);
      assert.throws(
        () =>
          validateP18InstalledSession(document, binding(value), {
            repoRoot: value.root,
          }),
        pattern,
        label,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
  const forged = fixture();
  try {
    const document = structuredClone(forged.materialized.document);
    const file = path.join(forged.root, document.package.signature.path);
    fs.writeFileSync(file, Buffer.alloc(64, 7));
    document.package.signature = record(forged.root, file);
    assert.throws(
      () =>
        validateP18InstalledSession(
          document,
          {
            ...binding(forged),
            manifestSignatureSha256: document.package.signature.sha256,
          },
          { repoRoot: forged.root },
        ),
      /signature/u,
    );
  } finally {
    fs.rmSync(forged.root, { recursive: true, force: true });
  }
});

test("P-18 capture rejects stale evidence and changed source bytes", () => {
  const stale = fixture();
  try {
    assert.throws(
      () =>
        captureP18MemoryReviewProof(
          {
            inputRoot: stale.input,
            sessionReport: stale.materialized.output,
            ...binding(stale),
          },
          {
            resolveHead: () => HEAD,
            now: () => new Date(Date.parse(stale.endedAt) + 20 * 60_000),
          },
        ),
      /stale/u,
    );
  } finally {
    fs.rmSync(stale.root, { recursive: true, force: true });
  }
  const changed = fixture();
  try {
    fs.appendFileSync(
      path.join(
        changed.root,
        changed.materialized.document.evidence.uiTranscript.path,
      ),
      "changed",
    );
    assert.throws(
      () =>
        validateP18InstalledSession(
          changed.materialized.document,
          binding(changed),
          { repoRoot: changed.root },
        ),
      /bytes changed/u,
    );
  } finally {
    fs.rmSync(changed.root, { recursive: true, force: true });
  }
});
