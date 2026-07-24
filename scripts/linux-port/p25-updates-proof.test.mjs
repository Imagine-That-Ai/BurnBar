import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP25UpdatesProof } from "./capture-p25-updates-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP25InstalledSession,
  validateP25Proof,
} from "./lib/p25-updates-proof.mjs";
import { materializeP25UpdatesSession } from "./materialize-p25-updates-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-25.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "252525";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const PREVIOUS = "1.2.2";
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
function mutate(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const payload = JSON.parse(fs.readFileSync(file));
  change(payload);
  json(file, payload);
  Object.assign(descriptor, record(value.root, file));
}
function observed(phase) {
  const common = {
    updates: true,
    packageChannel: true,
    owner: true,
    shellVersion: true,
    daemonVersion: true,
  };
  if (phase === "available")
    return {
      ...common,
      available: true,
      targetVersion: true,
      verified: true,
      fresh: true,
      signedDownloadEnabled: true,
      safeActionActivated: true,
      shellDoesNotInstall: true,
    };
  if (phase === "current")
    return {
      ...common,
      current: true,
      verified: true,
      fresh: true,
      noDownloadAction: true,
      shellDoesNotInstall: true,
    };
  if (phase === "error")
    return {
      ...common,
      error: true,
      noEnabledDownload: true,
      noEnabledInstall: true,
      recovery: true,
    };
  return { ...common, restarted: true, guidance: true, daemonAligned: true };
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p25-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "proof-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-25",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const start = Date.now() - 60_000;
  const candidate = {
    version: VERSION,
    package: { file: "candidate.deb", sha256: "a".repeat(64), size: 101 },
    manifest: {
      file: "candidate-manifest.json",
      sha256: identity.manifestSha256,
      size: 102,
    },
    manifestSignature: {
      file: "candidate-manifest.sig",
      sha256: identity.manifestSignatureSha256,
      size: 64,
    },
    releaseCommit: HEAD,
    metadata: {
      name: "open-burn-bar",
      version: VERSION,
      architecture: "arm64",
    },
  };
  const previous = {
    version: PREVIOUS,
    package: { file: "previous.deb", sha256: "b".repeat(64), size: 103 },
    manifest: {
      file: "previous-manifest.json",
      sha256: "c".repeat(64),
      size: 104,
    },
    manifestSignature: {
      file: "previous-manifest.sig",
      sha256: "d".repeat(64),
      size: 64,
    },
    releaseCommit: "0".repeat(40),
    metadata: {
      name: "open-burn-bar",
      version: PREVIOUS,
      architecture: "arm64",
    },
    releaseTag: `linux-v${PREVIOUS}`,
  };
  json(path.join(raw, "updates-package-lifecycle.json"), {
    schemaVersion: 1,
    producer: "openburnbar-p25-native-package-lifecycle-v1",
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    environmentId: ENVIRONMENT,
    architecture: "aarch64",
    passed: true,
    packageChannel: "deb",
    manager: "apt",
    packageName: "open-burn-bar",
    candidate,
    previous,
    commands: [
      {
        phase: "install-previous",
        command: [
          "sudo",
          "apt-get",
          "install",
          "-y",
          "--reinstall",
          "--allow-downgrades",
          previous.package.file,
        ],
        exitCode: 0,
        installedVersion: PREVIOUS,
        packageSha256: previous.package.sha256,
        installedManifestSha256: previous.manifest.sha256,
        installedManifestSignatureSha256: previous.manifestSignature.sha256,
      },
      {
        phase: "update-candidate",
        command: [
          "sudo",
          "apt-get",
          "install",
          "-y",
          "--reinstall",
          candidate.package.file,
        ],
        exitCode: 0,
        installedVersion: VERSION,
        packageSha256: candidate.package.sha256,
        installedManifestSha256: candidate.manifest.sha256,
        installedManifestSignatureSha256: candidate.manifestSignature.sha256,
      },
      {
        phase: "rollback-previous",
        command: [
          "sudo",
          "apt-get",
          "install",
          "-y",
          "--reinstall",
          "--allow-downgrades",
          previous.package.file,
        ],
        exitCode: 0,
        installedVersion: PREVIOUS,
        packageSha256: previous.package.sha256,
        installedManifestSha256: previous.manifest.sha256,
        installedManifestSignatureSha256: previous.manifestSignature.sha256,
      },
      {
        phase: "restore-candidate",
        command: [
          "sudo",
          "apt-get",
          "install",
          "-y",
          "--reinstall",
          candidate.package.file,
        ],
        exitCode: 0,
        installedVersion: VERSION,
        packageSha256: candidate.package.sha256,
        installedManifestSha256: candidate.manifest.sha256,
        installedManifestSignatureSha256: candidate.manifestSignature.sha256,
      },
    ],
    networkOutage: {
      method: "process-local-invalid-https-proxy",
      endpoint: "127.0.0.1:9",
      priorEnvironment: { HTTPS_PROXY: null, https_proxy: null },
      restoredEnvironment: { HTTPS_PROXY: null, https_proxy: null },
      systemNetworkMutated: false,
      exactPriorStateRestored: true,
    },
    restoredCandidate: true,
    lifecycle: {
      update: { status: "passed", fromVersion: PREVIOUS, toVersion: VERSION },
      rollback: { status: "passed", fromVersion: VERSION, toVersion: PREVIOUS },
      dataPreservation: {
        status: "passed",
        sentinelSha256: "7".repeat(64),
        afterPreviousSha256: "7".repeat(64),
        afterUpdateSha256: "7".repeat(64),
        afterRollbackSha256: "7".repeat(64),
        afterRestoreSha256: "7".repeat(64),
      },
    },
    restoration: {
      status: "passed",
      installedVersion: VERSION,
      candidatePackageSha256: candidate.package.sha256,
      installedManifestSha256: candidate.manifest.sha256,
      installedManifestSignatureSha256: candidate.manifestSignature.sha256,
    },
  });
  for (const [index, phase] of [
    "available",
    "current",
    "error",
    "restart",
  ].entries()) {
    const expectedVersion = phase === "available" ? PREVIOUS : VERSION;
    json(path.join(raw, `updates-${phase}.json`), {
      schemaVersion: 1,
      phase,
      capturedAt: new Date(start + (index + 1) * 10_000).toISOString(),
      producer: "openburnbar-p25-installed-update-phase-v1",
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      manifestSha256: identity.manifestSha256,
      provenance: {
        packageSha256: (phase === "available" ? previous : candidate).package
          .sha256,
        manifestSha256: (phase === "available" ? previous : candidate).manifest
          .sha256,
        manifestSignatureSha256: (phase === "available" ? previous : candidate)
          .manifestSignature.sha256,
        releaseCommit: (phase === "available" ? previous : candidate)
          .releaseCommit,
      },
      packageVersion: VERSION,
      expectedVersion,
      advertisedVersion: phase === "available" ? VERSION : null,
      package: {
        channel: "deb",
        manager: "apt",
        owner: "apt/dpkg",
        version: expectedVersion,
      },
      appPid: 2500 + index,
      observed: observed(phase),
      action:
        phase === "available"
          ? {
              kind: "open-signed-download",
              activated: true,
              packageMutation: false,
            }
          : null,
      rollbackClaimed: false,
    });
    write(path.join(raw, `updates-${phase}.png`), png(index + 1));
  }
  const materialized = materializeP25UpdatesSession(
    {
      ...binding({ root, identity }),
      outputRoot: input,
      rawEvidenceDir: raw,
      compositor: "Mutter",
      previousVersion: PREVIOUS,
      packageChannel: "deb",
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
      shellVersion: VERSION,
      daemonVersion: VERSION,
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
  const lifecycleSteps = [
    "guiLaunch",
    "daemonLaunch",
    "versionReadback",
    "update",
    "rollback",
    "dataPreservation",
  ];
  const architectureSessions = record(
    value.root,
    json(path.join(subjects, "architecture-sessions.json"), {
      passed: true,
      sessions: RELEASE_ARCHITECTURES.map((architecture) => ({
        schemaVersion: 1,
        architecture,
        version: VERSION,
        gitCommit: HEAD,
        lifecycle: Object.fromEntries(
          lifecycleSteps.map((step) => [
            step,
            step === "update"
              ? {
                  status: "passed",
                  fromVersion: PREVIOUS,
                  toVersion: VERSION,
                }
              : step === "rollback"
                ? {
                    status: "passed",
                    fromVersion: VERSION,
                    toVersion: PREVIOUS,
                  }
                : { status: "passed" },
          ]),
        ),
        passed: true,
      })),
    }),
  );
  const packageSmoke = record(
    value.root,
    json(path.join(subjects, "package-smoke.json"), {
      passed: true,
      architectures: [...RELEASE_ARCHITECTURES],
      lifecycle: Object.fromEntries(
        lifecycleSteps.map((step) => [
          step,
          { status: "passed", architectures: [...RELEASE_ARCHITECTURES] },
        ]),
      ),
    }),
  );
  return {
    schemaVersion: 1,
    repoRoot: value.root,
    requirementId: "P-25",
    checkId: "p-25.updates",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-25",
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
          { role: "architecture-sessions", ...architectureSessions },
          { role: "package-smoke", ...packageSmoke },
          { role: "feature.updates-installed", ...proof },
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

test("P-25 materializes, captures, and validates signed update lifecycle evidence", async () => {
  const value = fixture();
  try {
    const session = validateP25InstalledSession(value.session, binding(value));
    assert.equal(session.nativeStates, 4);
    assert.equal(session.rollbackLifecycle, 1);
    const captured = captureP25UpdatesProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.now() + 60_000) },
    );
    const proof = validateP25Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-25 proof",
      ),
    });
    assert.equal(proof.proof.claim.shellPackageMutation, false);
    const result = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(result.status, "passed");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
test("P-25 rejects a synthetic package mutation or replayed UI state", () => {
  const mutation = fixture();
  const replay = fixture();
  try {
    mutate(mutation, mutation.session.evidence.availablePhase, (payload) => {
      payload.action.packageMutation = true;
    });
    assert.throws(
      () => validateP25InstalledSession(mutation.session, binding(mutation)),
      /unsafe or unproven/u,
    );
    const source = path.join(
      replay.root,
      replay.session.evidence.currentScreenshot.path,
    );
    const target = path.join(
      replay.root,
      replay.session.evidence.errorScreenshot.path,
    );
    fs.copyFileSync(source, target);
    Object.assign(
      replay.session.evidence.errorScreenshot,
      record(replay.root, target),
    );
    assert.throws(
      () => validateP25InstalledSession(replay.session, binding(replay)),
      /replayed/u,
    );
  } finally {
    fs.rmSync(mutation.root, { recursive: true, force: true });
    fs.rmSync(replay.root, { recursive: true, force: true });
  }
});
test("P-25 rejects blocked rollback and version substitution", () => {
  const rollback = fixture();
  const version = fixture();
  const advertised = fixture();
  try {
    mutate(rollback, rollback.session.evidence.lifecycle, (payload) => {
      payload.lifecycle.rollback.status = "blocked";
    });
    assert.throws(
      () => validateP25InstalledSession(rollback.session, binding(rollback)),
      /does not prove update/u,
    );
    mutate(version, version.session.evidence.availablePhase, (payload) => {
      payload.expectedVersion = VERSION;
      payload.package.version = VERSION;
    });
    assert.throws(
      () => validateP25InstalledSession(version.session, binding(version)),
      /package identity/u,
    );
    mutate(
      advertised,
      advertised.session.evidence.availablePhase,
      (payload) => {
        payload.advertisedVersion = PREVIOUS;
      },
    );
    assert.throws(
      () =>
        validateP25InstalledSession(advertised.session, binding(advertised)),
      /phase binding/u,
    );
  } finally {
    fs.rmSync(rollback.root, { recursive: true, force: true });
    fs.rmSync(version.root, { recursive: true, force: true });
    fs.rmSync(advertised.root, { recursive: true, force: true });
  }
});

test("P-25 rejects phase provenance substitution and incomplete network restoration", () => {
  const provenance = fixture();
  const network = fixture();
  const installedAttestation = fixture();
  try {
    mutate(
      provenance,
      provenance.session.evidence.availablePhase,
      (payload) => {
        payload.provenance.packageSha256 = "e".repeat(64);
      },
    );
    assert.throws(
      () =>
        validateP25InstalledSession(provenance.session, binding(provenance)),
      /authenticated installed package/u,
    );
    mutate(network, network.session.evidence.lifecycle, (payload) => {
      payload.networkOutage.restoredEnvironment.HTTPS_PROXY =
        "http://not-restored.invalid";
    });
    assert.throws(
      () => validateP25InstalledSession(network.session, binding(network)),
      /exact prior network environment/u,
    );
    mutate(
      installedAttestation,
      installedAttestation.session.evidence.lifecycle,
      (payload) => {
        payload.commands[0].installedManifestSha256 = "f".repeat(64);
      },
    );
    assert.throws(
      () =>
        validateP25InstalledSession(
          installedAttestation.session,
          binding(installedAttestation),
        ),
      /package-manager receipt/u,
    );
  } finally {
    fs.rmSync(provenance.root, { recursive: true, force: true });
    fs.rmSync(network.root, { recursive: true, force: true });
    fs.rmSync(installedAttestation.root, { recursive: true, force: true });
  }
});

test("P-25 product validator rejects a blocked architecture lifecycle", async () => {
  const value = fixture();
  try {
    const captured = captureP25UpdatesProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.now() + 60_000) },
    );
    const validationContext = context(value, captured.output);
    const descriptor = validationContext.releaseClosure.document.proofs.find(
      (proof) => proof.role === "architecture-sessions",
    );
    const file = path.join(value.root, descriptor.path);
    const sessions = JSON.parse(fs.readFileSync(file));
    sessions.sessions[0].lifecycle.rollback = {
      status: "blocked",
      reason: "no authenticated previous package",
    };
    json(file, sessions);
    Object.assign(descriptor, record(value.root, file));
    await assert.rejects(
      validateProductRequirement(validationContext),
      /requires real update, rollback/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
