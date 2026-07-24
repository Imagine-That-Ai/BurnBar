import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP29TextExpansionProof } from "./capture-p29-text-expansion-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  P29_PROOF_ROLE,
  validateP29InstalledSession,
  validateP29Proof,
} from "./lib/p29-text-expansion-proof.mjs";
import { materializeP29TextExpansionSession } from "./materialize-p29-text-expansion-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-29.mjs";

const HEAD = "1".repeat(40);
const RUN = "292929";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-x86_64";
const VERSION = "1.2.3";
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function write(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  fs.chmodSync(file, mode);
  return file;
}
function json(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
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
  const width = 360;
  const height = 240;
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1)
    for (let x = 0; x < width; x += 1) {
      const at = y * (width * 3 + 1) + 1 + x * 3;
      raw[at] = (x + seed * 17) % 256;
      raw[at + 1] = (y + seed * 23) % 256;
      raw[at + 2] = (x + y + seed * 31) % 256;
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
      packageArchitecture: "x86_64",
      packageFormat: "deb",
      firebaseAppId: "1:2:web:3",
    }),
  );
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return {
    manifest: record(
      root,
      write(path.join(raw, "installed-manifest.json"), manifest),
    ),
    signature: record(
      root,
      write(path.join(raw, "installed-manifest.json.sig"), signature),
    ),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function fixture() {
  const base = path.join(process.cwd(), ".tmp/p29-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-29",
    ENVIRONMENT,
  );
  const raw = path.join(input, "raw");
  fs.mkdirSync(raw, { recursive: true });
  fs.chmodSync(raw, 0o700);
  const identity = attestation(root, raw);
  const at = (seconds) =>
    new Date(Date.now() - 60_000 + seconds * 1000).toISOString();
  const marker = {
    producer: "openburnbar-p29-installed-probe-v1",
    marker: "p29-0123456789abcdef",
    installedDaemon: "/usr/libexec/openburnbar-daemon-launch",
    installedDesktop: "/usr/bin/openburnbar-linux-desktop",
    packageOwned: true,
  };
  const native = {
    producer: marker.producer,
    marker: marker.marker,
    startedAt: at(0),
    endedAt: at(30),
    atspiApplication: "OpenBurnBar",
    keyring: {
      backend: "secret-service",
      reachable: true,
      keyCreated: true,
      keyRemovedForProbe: true,
      keyRestored: true,
    },
    engine: {
      backend: "ibus",
      engineID: "org.openburnbar.TextExpansion",
      reachable: true,
      registration: "registered",
      securePolicy: "deny-unless-inspectable-and-explicitly-nonsecure",
      manifestSha256: "3".repeat(64),
      cancellationStopped: true,
      killSwitchStopped: true,
      selectedEngine: "openburnbar",
      previousEngine: "xkb:us::eng",
      previousEngineRestored: true,
    },
    store: {
      path: "/home/test/.local/share/OpenBurnBar/text-expansion-v1.obbsealed",
      mode: "0600",
      ownerUid: process.getuid(),
      symlink: false,
      containsPlaintext: false,
      ciphertextSha256: "4".repeat(64),
    },
    operations: {
      consent: {
        inAppOnly: true,
        systemIMEEnabled: true,
        declinedGlobalCapture: true,
        persisted: true,
      },
      create: { mutated: true, readback: true, revisionAdvanced: true },
      edit: { mutated: true, readback: true, revisionAdvanced: true },
      delete: { mutated: true, readback: true, revisionAdvanced: true },
      import: { mutated: true, readback: true, revisionAdvanced: true },
      expand: {
        expanded: true,
        replacementMatched: true,
        triggerOnly: true,
        inputMethod: "ibus",
        fieldApplication: "OpenBurnBar P29 IBus Probe",
        fieldRole: "text",
        probePID: 2900,
        before: "",
        after: "expanded-p29-0123456789abcdef-edited ",
      },
      secureField: {
        denied: true,
        inspectable: true,
        isSecureField: true,
        inputMethod: "ibus",
        fieldApplication: "OpenBurnBar P29 IBus Probe",
        fieldRole: "password text",
        probePID: 2900,
        before: "",
        after: "&&0123456789abcdef ",
        replacementPresent: false,
      },
    },
    persistence: {
      consentAfterRestart: true,
      snippetAfterRestart: true,
      corruptionFailedClosed: true,
      missingKeyFailedClosed: true,
    },
    safety: {
      fixtureModeFalse: true,
      noGlobalCapture: true,
      noKeyboardPayload: true,
      noClipboardPayload: true,
      noSurroundingTextPayload: true,
    },
    restoration: {
      daemonService: true,
      desktopProcesses: true,
      engineStopped: true,
      keyring: true,
      originalStore: true,
      snippets: true,
    },
  };
  const markerRecord = record(
    root,
    json(path.join(raw, "marker.json"), marker),
  );
  const nativeRecord = record(
    root,
    json(path.join(raw, "native.json"), native),
  );
  const stateFields = [
    ["consent", "consent"],
    ["created", "created"],
    ["edited", "edited"],
    ["expanded", "expanded"],
    ["secureDenied", "secure-denied"],
    ["restored", "restored"],
  ];
  const evidence = { nativeTranscript: nativeRecord };
  stateFields.forEach(([field, name], index) => {
    evidence[`${field}Screenshot`] = record(
      root,
      write(path.join(raw, `${name}.png`), png(index + 1)),
    );
    evidence[`${field}Accessibility`] = record(
      root,
      json(path.join(raw, `${name}-atspi.json`), {
        application: ["expanded", "secure-denied"].includes(name)
          ? "OpenBurnBar P29 IBus Probe"
          : "OpenBurnBar",
        route: ["expanded", "secure-denied"].includes(name)
          ? "ibus-field-probe"
          : "text-expansion",
        pass: true,
        nodes: Array.from({ length: 8 }, (_, node) => ({
          name: `${name}-${node}`,
          role: "entry",
        })),
      }),
    );
  });
  const session = {
    schemaVersion: 1,
    id: "openburnbar-linux-p29-installed-text-expansion-session-v1",
    requirementId: "P-29",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: { runId: RUN, artifactDigest: DIGEST },
    package: {
      architecture: "x86_64",
      format: "deb",
      installed: true,
      manifest: identity.manifest,
      signature: identity.signature,
      source: "verified-live-installed-candidate",
      version: VERSION,
    },
    desktop: {
      compositor: "Mutter",
      desktop: "GNOME",
      displayServer: "X11",
      liveSession: true,
    },
    capture: {
      startedAt: native.startedAt,
      endedAt: native.endedAt,
      fixtureMode: false,
      method: "installed-live-product-session",
    },
    marker,
    evidence,
  };
  const sessionFile = json(
    path.join(input, "p29-installed-text-expansion-session.json"),
    session,
  );
  return {
    root,
    input,
    raw,
    session,
    sessionFile,
    nativeFile: path.join(root, nativeRecord.path),
    identity,
  };
}
function binding(value) {
  return {
    repoRoot: value.root,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    manifestSha256: value.identity.manifestSha256,
    manifestSignatureSha256: value.identity.manifestSignatureSha256,
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
      architecture: "x86_64",
      passed: true,
    }),
  );
  const packageArtifact = record(
    value.root,
    write(path.join(subjects, "package.deb"), "package\n"),
  );
  const proof = record(value.root, proofFile);
  return {
    schemaVersion: 1,
    repoRoot: value.root,
    requirementId: "P-29",
    checkId: "p-29.text-expansion",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-29",
        environmentId: ENVIRONMENT,
        version: VERSION,
        blockers: [],
        architectures: [...RELEASE_ARCHITECTURES],
        supportEnvironments: [...SUPPORT_ENVIRONMENTS],
        selectedPackage: { architecture: "x86_64", format: "deb" },
        candidate: { runId: RUN, artifactDigest: DIGEST },
        packageManifestSignature: value.session.package.signature,
        proofs: [
          { role: "aggregate-product-proof-closure", ...aggregate },
          { role: P29_PROOF_ROLE, ...proof },
        ],
      },
    },
    subjects: {
      release: aggregate,
      packageManifest: value.session.package.manifest,
      packages: [packageArtifact],
      runtimes: [runtime],
      installation: [aggregate],
      environment,
      features: [],
    },
  };
}

test("P-29 validates and captures exact installed text-expansion proof", async () => {
  const value = fixture();
  try {
    const checked = validateP29InstalledSession(value.session, binding(value), {
      repoRoot: value.root,
    });
    assert.equal(checked.operationCount, 7);
    const captured = captureP29TextExpansionProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionFile,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.now()) },
    );
    assert.equal(captured.document.claim.secureFieldFailClosed, true);
    validateP29Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-29 proof",
      ),
    });
    const validation = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(validation.status, "passed");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-29 accepts and restores an already-selected OpenBurnBar IBus engine", () => {
  const value = fixture();
  try {
    const native = JSON.parse(fs.readFileSync(value.nativeFile));
    native.engine.previousEngine = "openburnbar";
    json(value.nativeFile, native);
    value.session.evidence.nativeTranscript = record(value.root, value.nativeFile);
    assert.equal(
      validateP29InstalledSession(value.session, binding(value), { repoRoot: value.root }).operationCount,
      7,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-29 rejects forged security, persistence, accessibility, screenshot, and candidate facts", () => {
  const mutations = [
    (value) => {
      value.session.candidate.runId = "1";
    },
    (value) => {
      value.session.marker.packageOwned = false;
    },
    (value) => {
      const native = JSON.parse(fs.readFileSync(value.nativeFile));
      native.engine.registration = "engine_missing";
      json(value.nativeFile, native);
      value.session.evidence.nativeTranscript = record(
        value.root,
        value.nativeFile,
      );
    },
    (value) => {
      const native = JSON.parse(fs.readFileSync(value.nativeFile));
      native.engine.previousEngineRestored = false;
      json(value.nativeFile, native);
      value.session.evidence.nativeTranscript = record(
        value.root,
        value.nativeFile,
      );
    },
    (value) => {
      const native = JSON.parse(fs.readFileSync(value.nativeFile));
      native.operations.expand.after = "&&0123456789abcdef ";
      json(value.nativeFile, native);
      value.session.evidence.nativeTranscript = record(
        value.root,
        value.nativeFile,
      );
    },
    (value) => {
      const native = JSON.parse(fs.readFileSync(value.nativeFile));
      native.operations.secureField.after = "expanded-p29-0123456789abcdef-edited ";
      native.operations.secureField.replacementPresent = true;
      json(value.nativeFile, native);
      value.session.evidence.nativeTranscript = record(
        value.root,
        value.nativeFile,
      );
    },
    (value) => {
      const native = JSON.parse(fs.readFileSync(value.nativeFile));
      native.persistence.missingKeyFailedClosed = false;
      json(value.nativeFile, native);
      value.session.evidence.nativeTranscript = record(
        value.root,
        value.nativeFile,
      );
    },
    (value) => {
      value.session.evidence.restoredScreenshot =
        value.session.evidence.expandedScreenshot;
    },
    (value) => {
      const file = path.join(
        value.root,
        value.session.evidence.createdAccessibility.path,
      );
      json(file, {
        application: "OpenBurnBar",
        route: "text-expansion",
        pass: false,
        nodes: [],
      });
      value.session.evidence.createdAccessibility = record(value.root, file);
    },
  ];
  for (const mutate of mutations) {
    const value = fixture();
    try {
      mutate(value);
      assert.throws(
        () =>
          validateP29InstalledSession(value.session, binding(value), {
            repoRoot: value.root,
          }),
        /P-29|installed session/u,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-29 materializer rejects output escape and raw-directory symlinks", () => {
  const value = fixture();
  const outside = fs.mkdtempSync(path.join(process.cwd(), ".tmp/p29-outside-"));
  const alias = path.join(value.root, "raw-alias");
  fs.symlinkSync(value.raw, alias);
  const options = {
    ...binding(value),
    rawEvidenceDir: value.raw,
    outputRoot: outside,
    compositor: "Mutter",
  };
  try {
    assert.throws(
      () =>
        materializeP29TextExpansionSession(options, {
          installedVerifier: () => {},
        }),
      /inside the repository/u,
    );
    assert.throws(
      () =>
        materializeP29TextExpansionSession(
          {
            ...options,
            outputRoot: value.input,
            rawEvidenceDir: alias,
          },
          { installedVerifier: () => {} },
        ),
      /canonical owner-only directory/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
  }
});
