import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP22DatabaseProof } from "./capture-p22-database-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP22InstalledSession,
  validateP22Proof,
} from "./lib/p22-database-proof.mjs";
import { materializeP22DatabaseSession } from "./materialize-p22-database-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-22.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "222222";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "p22-fedcba0987654321";
function write(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  fs.chmodSync(file, mode);
  return file;
}
function json(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
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
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return {
    path: path.relative(root, file).split(path.sep).join("/"),
    sha256: hash(bytes),
    size: bytes.length,
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
function mutate(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const payload = JSON.parse(fs.readFileSync(file));
  change(payload);
  json(file, payload);
  Object.assign(descriptor, record(value.root, file));
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p22-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "proof-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-22",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const start = Date.now() - 30_000;
  const at = (offset) => new Date(start + offset).toISOString();
  const projectDir = `/home/proof/project-${MARKER}`;
  const files = Array.from(
    { length: 14 },
    (_, index) => `record-${String(index).padStart(2, "0")}.ts`,
  );
  const query = `P22IndexedMarker_${MARKER.replace(/-/gu, "_")}`;
  const watcherQuery = `P22WatcherMarker_${MARKER.replace(/-/gu, "_")}`;
  const snapshotBytes = Buffer.from("encrypted-snapshot");
  const bundleBytes = Buffer.from("encrypted-recovery-bundle");
  const tamperedBytes = Buffer.from(bundleBytes);
  tamperedBytes[3] ^= 0xff;
  const meta = (file, bytes) => ({
    path: file,
    byteCount: bytes.length,
    sha256: hash(bytes),
    mode: "0600",
  });
  const snapshot = meta(`/private/proof/${MARKER}.snapshot`, snapshotBytes);
  const recoveryBundle = meta(
    `/private/proof/${MARKER}.recovery.obb`,
    bundleBytes,
  );
  const tamperedBundle = meta(
    `/private/proof/${MARKER}.tampered.obb`,
    tamperedBytes,
  );
  write(path.join(raw, "database-encrypted.snapshot"), snapshotBytes);
  write(path.join(raw, "database-recovery.obb"), bundleBytes);
  write(path.join(raw, "database-recovery-tampered.obb"), tamperedBytes);
  json(path.join(raw, "database-marker.json"), {
    marker: MARKER,
    projectDir,
    files,
    query,
    watcherQuery,
    snapshot,
    recoveryBundle,
    tamperedBundle,
    recoveryLimits: {
      destructiveKeyLossNotInduced: true,
      deviceTransferNotInduced: true,
      reason:
        "The live proof does not delete or replace a user's native keyring state.",
    },
  });
  const trust = (sourceTool) => ({
    sourceTool,
    untrustedContentWrapped: true,
  });
  const hits = (needle, count = 14) =>
    Array.from({ length: count }, (_, index) => ({
      filePath: files[index],
      snippet: `export const value = "${needle}";`,
      line: 1,
    }));
  const events = [];
  const push = (
    phase,
    method,
    request,
    result,
    offset,
    ok = true,
    error = null,
  ) =>
    events.push({ phase, at: at(offset), method, request, ok, error, result });
  push(
    "index",
    "daemon.code.index_project",
    {
      projectPath: projectDir,
      maxFiles: 2500,
      maxFileBytes: 512000,
      storageBudgetBytes: null,
    },
    { projectRoot: projectDir, indexedFiles: 14, chunkCount: 14 },
    1000,
  );
  push(
    "watch",
    "daemon.code.watch_project",
    {
      projectPath: projectDir,
      maxFiles: 2500,
      maxFileBytes: 512000,
      storageBudgetBytes: null,
      pollIntervalSeconds: 2,
    },
    { projectRoot: projectDir, watching: true },
    2000,
  );
  push(
    "search",
    "daemon.code.search",
    { query, projectPath: projectDir, limit: 50 },
    { hits: hits(query), trustSignal: trust("daemon.code.search") },
    3000,
  );
  push(
    "context",
    "daemon.code.context_pack",
    { query, projectPath: projectDir, limit: 10, maxBytes: 24000 },
    {
      hits: hits(query, 10),
      context: `Untrusted source data\n${query}`,
      trustSignal: trust("daemon.code.context_pack"),
    },
    4000,
  );
  push(
    "explore",
    "daemon.code.explore",
    { projectPath: projectDir, query: null, limit: 50, maxBytes: 24000 },
    { files: files.map((filePath) => ({ filePath })) },
    5000,
  );
  push(
    "index-status",
    "daemon.code.index_status",
    { projectPath: projectDir },
    { artifactCount: 14, databaseEncrypted: true },
    6000,
  );
  push(
    "recovery-ready",
    "daemon.database.recovery.status",
    {},
    { phase: "ready", canExport: true, databaseIntegrityVerified: true },
    7000,
  );
  push(
    "snapshot",
    "daemon.code.database_snapshot",
    { destinationPath: snapshot.path, maxBytes: 536870912 },
    { ...snapshot, databaseEncrypted: true, integrityCheck: "ok" },
    8000,
  );
  push(
    "restore",
    "daemon.code.database_restore",
    { snapshotPath: snapshot.path, maxBytes: 536870912 },
    { ...snapshot, databaseEncrypted: true, integrityCheck: "ok" },
    9000,
  );
  push(
    "watcher-reopen-search",
    "daemon.code.search",
    { query: watcherQuery, projectPath: projectDir, limit: 20 },
    { hits: hits(watcherQuery, 1), trustSignal: trust("daemon.code.search") },
    10000,
  );
  push(
    "bundle-export",
    "daemon.database.recovery_bundle.export",
    { destinationPath: recoveryBundle.path, passphraseRedacted: true },
    { byteCount: recoveryBundle.byteCount, formatVersion: 1 },
    11000,
  );
  push(
    "wrong-passphrase",
    "daemon.database.recovery_bundle.import",
    { sourcePath: recoveryBundle.path, passphraseRedacted: true },
    null,
    12000,
    false,
    "recovery bundle authentication failed",
  );
  push(
    "tampered-bundle",
    "daemon.database.recovery_bundle.import",
    { sourcePath: tamperedBundle.path, passphraseRedacted: true },
    null,
    13000,
    false,
    "recovery bundle authentication failed",
  );
  push(
    "bundle-import",
    "daemon.database.recovery_bundle.import",
    { sourcePath: recoveryBundle.path, passphraseRedacted: true },
    {
      stored: true,
      candidateKeyVerified: true,
      databaseIntegrityVerified: true,
      phase: "ready",
      restartRequired: true,
    },
    14000,
  );
  push(
    "restart-recovery-status",
    "daemon.database.recovery.status",
    {},
    { phase: "ready", databaseIntegrityVerified: true },
    15000,
  );
  push(
    "restart-search",
    "daemon.code.search",
    { query, projectPath: projectDir, limit: 50 },
    { hits: hits(query), trustSignal: trust("daemon.code.search") },
    16000,
  );
  json(path.join(raw, "database-daemon-transcript.json"), {
    producer: "openburnbar-p22-installed-database-daemon-probe-v1",
    transport: "installed daemon AF_UNIX RPC",
    events,
  });
  const observed = [
    { populated: true, indexedCorpus: true, inspectAction: true },
    { inspector: true, path: true, metadataOnly: true },
    { search: true, pageTwo: true, contextPack: true, trustWarning: true },
    { encrypted: true, snapshot: true, recovery: true, indexControl: true },
    { populated: true, indexedCorpus: true },
  ];
  json(path.join(raw, "database-ui-transcript.json"), {
    producer: "openburnbar-p22-installed-database-ui-probe-v1",
    events: ["atlas", "inspector", "retrieval", "system", "restart"].map(
      (phase, index) => ({
        phase,
        at: at(17000 + index * 1000),
        appPid: 2200 + (index === 4 ? 1 : 0),
        marker: MARKER,
        manifestSha256: identity.manifestSha256,
        observed: observed[index],
      }),
    ),
  });
  for (const [index, name] of [
    "database-atlas.png",
    "database-inspector.png",
    "database-retrieval.png",
    "database-system.png",
    "database-restart.png",
  ].entries())
    write(path.join(raw, name), png(index + 1));
  const materialized = materializeP22DatabaseSession(
    {
      ...binding({ root, identity }),
      outputRoot: input,
      rawEvidenceDir: raw,
      compositor: "Mutter",
    },
    {
      installedVerifier: () => ({}),
      manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath,
    },
  );
  return {
    root,
    raw,
    input,
    identity,
    session: materialized.document,
    sessionPath: materialized.output,
  };
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
    requirementId: "P-22",
    checkId: "p-22.database",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-22",
        environmentId: ENVIRONMENT,
        version: VERSION,
        blockers: [],
        architectures: [...RELEASE_ARCHITECTURES],
        supportEnvironments: [...SUPPORT_ENVIRONMENTS],
        selectedPackage: { architecture: "aarch64", format: "deb" },
        candidate: { runId: RUN_ID, artifactDigest: DIGEST },
        packageManifestSignature: value.session.package.signature,
        proofs: [
          { role: "aggregate-product-proof-closure", ...aggregate },
          { role: "feature.database-installed", ...proof },
        ],
      },
    },
    subjects: {
      release: aggregate,
      packageManifest: value.session.package.manifest,
      packages: [pkg],
      runtimes: [runtime],
      installation: [aggregate],
      environment,
      features: [],
    },
  };
}

test("P-22 proof materializes, captures, and validates installed Database evidence", async () => {
  const value = fixture();
  try {
    const validated = validateP22InstalledSession(
      value.session,
      binding(value),
    );
    assert.equal(validated.daemonEvents, 16);
    assert.equal(validated.indexedFiles, 14);
    assert.equal(validated.failClosedMutations, 2);
    const captured = captureP22DatabaseProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.now() + 60_000) },
    );
    const proof = validateP22Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-22 proof",
      ),
    });
    assert.equal(proof.proof.claim.passed, true);
    assert.equal(proof.proof.claim.nativeKeyRecoveryReady, true);
    assert.equal(proof.proof.claim.destructiveKeyLossNotInduced, true);
    const product = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(product.status, "passed");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-22 proof rejects plaintext, secret leakage, false fail-closed, and replayed UI evidence", () => {
  for (const change of [
    (value) =>
      mutate(value, value.session.evidence.daemonTranscript, (doc) => {
        doc.events[7].result.databaseEncrypted = false;
      }),
    (value) =>
      mutate(value, value.session.evidence.daemonTranscript, (doc) => {
        doc.events[2].result.trustSignal.untrustedContentWrapped = false;
      }),
    (value) =>
      mutate(value, value.session.evidence.daemonTranscript, (doc) => {
        doc.events[10].request.passphrase = "leaked";
      }),
    (value) =>
      mutate(value, value.session.evidence.daemonTranscript, (doc) => {
        doc.events[11].ok = true;
        doc.events[11].error = null;
        doc.events[11].result = { stored: true };
      }),
    (value) => {
      const file = path.join(
        value.root,
        value.session.evidence.snapshotArtifact.path,
      );
      fs.appendFileSync(file, "tamper");
    },
    (value) => {
      const file = path.join(
        value.root,
        value.session.evidence.recoveryBundleArtifact.path,
      );
      fs.chmodSync(file, 0o400);
    },
    (value) => {
      const source = path.join(
        value.root,
        value.session.evidence.atlasScreenshot.path,
      );
      const target = path.join(
        value.root,
        value.session.evidence.restartScreenshot.path,
      );
      fs.copyFileSync(source, target);
      Object.assign(
        value.session.evidence.restartScreenshot,
        record(value.root, target),
      );
    },
  ]) {
    const value = fixture();
    try {
      change(value);
      assert.throws(
        () => validateP22InstalledSession(value.session, binding(value)),
        /P-22/u,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});
