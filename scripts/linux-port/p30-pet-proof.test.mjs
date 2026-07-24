import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP30PetProof } from "./capture-p30-pet-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP30InstalledSession,
  validateP30Proof,
} from "./lib/p30-pet-proof.mjs";
import {
  readRegularSnapshot,
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
} from "./lib/product-proof-closure.mjs";
import { materializeP30PetSession } from "./materialize-p30-pet-session.mjs";
import { validateProductRequirement } from "./product-validators/P-30.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "303030";
const DIGEST = `sha256:${"3".repeat(64)}`;
const VERSION = "1.2.3";
const MARKER = "p30-fedcba0987654321";

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
      raw[at] = (x + seed * 7) % 256;
      raw[at + 1] = (y * 2 + seed * 11) % 256;
      raw[at + 2] = (x + y + seed * 13) % 256;
    }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
function attestation(root, raw, architecture, format) {
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
      packageArchitecture: architecture,
      packageFormat: format,
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
function a11y(file, status, shortcut, seed, capturedAt) {
  return json(file, {
    producer: "openburnbar-p30-atspi-live-v1",
    application: "OpenBurnBar",
    capturedAt,
    focusedName: "Pet companion contained preview",
    statusText: status,
    ariaKeyshortcuts: shortcut,
    namedNodes: Array.from({ length: 7 }, (_, index) => ({
      name: `pet-${seed}-${index}`,
      role: "section",
      actions: [],
    })),
  });
}
function binding(value) {
  return {
    repoRoot: value.root,
    environmentId: value.environmentId,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    ...value.identity,
  };
}
function mutate(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const document = JSON.parse(fs.readFileSync(file));
  change(document);
  json(file, document);
  Object.assign(descriptor, record(value.root, file));
}

function fixture(displayServer = "X11") {
  const environmentId =
    displayServer === "X11"
      ? "ubuntu-24.04-gnome-x11-aarch64"
      : "ubuntu-24.04-gnome-wayland-aarch64";
  const base = path.join(process.cwd(), ".tmp/p30-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "proof-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw, { mode: 0o700 });
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-30",
    environmentId,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw, "aarch64", "deb");
  const x11 = displayServer === "X11";
  const shortcut = x11
    ? "Ctrl+Alt+Super+P"
    : "unavailable-on-contained-fallback";
  const runtime = {
    schemaVersion: 1,
    capturedAt: "2026-07-20T19:00:00.000Z",
    desktop: "GNOME",
    sessionType: displayServer.toLowerCase(),
    capabilities: [
      {
        id: "pet.overlay",
        state: x11 ? "available" : "degraded",
        source: "desktop-session-probe",
        reason: x11 ? "X11 available" : "Wayland contained fallback",
        substitute: x11
          ? null
          : "Use the contained draggable companion window.",
      },
    ],
  };
  const runtimeFile = json(
    path.join(raw, "pet-runtime-capabilities.json"),
    runtime,
  );
  const runtimeSha = hash(fs.readFileSync(runtimeFile));
  json(path.join(raw, "pet-marker.json"), {
    marker: MARKER,
    installed: {
      daemon: "/usr/bin/openburnbar-daemon",
      desktop: "/usr/bin/openburnbar-linux-desktop",
      packageManager: "dpkg",
      packageName: "openburnbar",
      packageOwned: true,
    },
    runtimeManifest: {
      capturedFrom: "/usr/bin/openburnbar-linux-desktop --runtime-capabilities",
      petOverlayState: x11 ? "available" : "degraded",
      sha256: runtimeSha,
    },
    safety: {
      fixtureMode: false,
      isolatedHome: true,
      preexistingDesktopProcesses: [],
      daemonRestored: true,
      desktopProcessesRestored: true,
    },
  });
  const startedAt = new Date(Date.now() - 50_000).toISOString();
  const endedAt = new Date(Date.now() - 20_000).toISOString();
  json(path.join(raw, "pet-native-transcript.json"), {
    producer: "openburnbar-p30-installed-pet-probe-v1",
    marker: MARKER,
    startedAt,
    endedAt,
    runtime: {
      manifestSha256: runtimeSha,
      petOverlayState: x11 ? "available" : "degraded",
      source: "installed-runtime-command",
    },
    compositor: {
      desktop: "GNOME",
      displayServer,
      mode: x11 ? "x11-native-overlay" : "wayland-contained-fallback",
      nativeWindowContract: x11 ? "tauri-x11-companion-v1" : "none",
    },
    interactions: {
      summon: {
        shortcut: "Ctrl+Alt+Super+P",
        ariaKeyshortcuts: shortcut,
        globalShortcut: x11,
        mode: x11 ? "native-global" : "focused-contained-fallback",
        routeFocused: true,
      },
      selection: {
        selected: true,
        cleared: true,
        statusAfterSelect: "Contained pet selected in this window.",
        statusAfterClear: "Contained pet selection cleared.",
      },
      keyboardReposition: {
        before: "0,0",
        after: "16,16",
        reset: "0,0",
        focused: true,
        status: "Contained preview moved with the keyboard (16,16).",
      },
      pointerReposition: {
        before: "0,0",
        after: "50,30",
        status: "Contained preview moved with pointer drag (50,30).",
      },
      clickThrough: {
        supported: x11,
        enabled: x11,
        restored: x11,
        nativeWindowObserved: x11,
      },
    },
    accessibility: {
      focusObserved: true,
      liveStatusObserved: true,
      shortcutMetadataObserved: true,
    },
    relaunch: {
      oldPid: 3000,
      newPid: 3001,
      nativeTierSame: true,
      fallbackAvailable: true,
      staleInteractionCleared: true,
    },
    restoration: {
      daemonWasActive: true,
      daemonActiveAfter: true,
      desktopPidsBefore: [],
      desktopPidsAfter: [],
    },
  });
  const states = [
    ["initial", "Contained preview summoned in this window."],
    ["selected", "Contained pet selected in this window."],
    ["moved", "Contained preview moved with pointer drag (50,30)."],
    ["relaunch", "Contained preview summoned after relaunch."],
  ];
  states.forEach(([name, status], index) => {
    write(path.join(raw, `pet-${name}.png`), png(index + 1));
    a11y(
      path.join(raw, `pet-${name}-atspi.json`),
      status,
      shortcut,
      index + 1,
      new Date(Date.parse(startedAt) + (index + 1) * 1_000).toISOString(),
    );
  });
  const materialized = materializeP30PetSession(
    {
      ...binding({ root, environmentId, identity }),
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
    environmentId,
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
      environmentId: value.environmentId,
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
    requirementId: "P-30",
    checkId: "p-30.pet-companion",
    environmentId: value.environmentId,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-30",
        environmentId: value.environmentId,
        version: VERSION,
        blockers: [],
        architectures: [...RELEASE_ARCHITECTURES],
        supportEnvironments: [...SUPPORT_ENVIRONMENTS],
        selectedPackage: { architecture: "aarch64", format: "deb" },
        candidate: { runId: RUN_ID, artifactDigest: DIGEST },
        packageManifestSignature: value.session.package.signature,
        proofs: [
          { role: "aggregate-product-proof-closure", ...aggregate },
          { role: "feature.pet-companion-installed", ...proof },
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

test("P-30 materializes, captures, and validates candidate-bound X11 evidence", async () => {
  const value = fixture();
  try {
    const validated = validateP30InstalledSession(
      value.session,
      binding(value),
    );
    assert.equal(validated.tier.x11, true);
    const captured = captureP30PetProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date() },
    );
    const proof = validateP30Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-30 proof",
      ),
    });
    assert.equal(proof.proof.claim.nativeOverlayProven, true);
    assert.equal(proof.proof.claim.containedFallbackProven, false);
    const result = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(result.status, "passed");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-30 validates the honest Wayland contained fallback", () => {
  const value = fixture("Wayland");
  try {
    const validated = validateP30InstalledSession(
      value.session,
      binding(value),
    );
    assert.equal(validated.tier.x11, false);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-30 rejects screenshot and AT-SPI replay", () => {
  const screenshot = fixture();
  const accessibility = fixture();
  try {
    const source = path.join(
      screenshot.root,
      screenshot.session.evidence.initialScreenshot.path,
    );
    const target = path.join(
      screenshot.root,
      screenshot.session.evidence.selectedScreenshot.path,
    );
    fs.copyFileSync(source, target);
    Object.assign(
      screenshot.session.evidence.selectedScreenshot,
      record(screenshot.root, target),
    );
    assert.throws(
      () =>
        validateP30InstalledSession(screenshot.session, binding(screenshot)),
      /replayed/u,
    );
    const a11ySource = path.join(
      accessibility.root,
      accessibility.session.evidence.initialAccessibility.path,
    );
    const a11yTarget = path.join(
      accessibility.root,
      accessibility.session.evidence.selectedAccessibility.path,
    );
    fs.copyFileSync(a11ySource, a11yTarget);
    Object.assign(
      accessibility.session.evidence.selectedAccessibility,
      record(accessibility.root, a11yTarget),
    );
    assert.throws(
      () =>
        validateP30InstalledSession(
          accessibility.session,
          binding(accessibility),
        ),
      /replayed/u,
    );
  } finally {
    fs.rmSync(screenshot.root, { recursive: true, force: true });
    fs.rmSync(accessibility.root, { recursive: true, force: true });
  }
});

test("P-30 rejects stale AT-SPI and a forged proof candidate", () => {
  const accessibility = fixture();
  const candidate = fixture();
  try {
    mutate(
      accessibility,
      accessibility.session.evidence.initialAccessibility,
      (value) => {
        value.capturedAt = "2020-01-01T00:00:00.000Z";
      },
    );
    assert.throws(
      () =>
        validateP30InstalledSession(
          accessibility.session,
          binding(accessibility),
        ),
      /outside the live session/u,
    );
    const captured = captureP30PetProof(
      {
        ...binding(candidate),
        inputRoot: candidate.input,
        sessionReport: candidate.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date() },
    );
    const proof = JSON.parse(fs.readFileSync(captured.output));
    proof.candidate.runId = "999999";
    json(captured.output, proof);
    assert.throws(
      () =>
        validateP30Proof({
          ...binding(candidate),
          snapshot: readRegularSnapshot(
            candidate.root,
            path.relative(candidate.root, captured.output),
            "P-30 forged proof",
          ),
        }),
      /candidate binding/u,
    );
  } finally {
    fs.rmSync(accessibility.root, { recursive: true, force: true });
    fs.rmSync(candidate.root, { recursive: true, force: true });
  }
});

test("P-30 rejects optimistic Wayland, forged interactions, and failed restoration", () => {
  const wayland = fixture("Wayland");
  const interaction = fixture();
  const restoration = fixture();
  try {
    wayland.session.marker.runtimeManifest.petOverlayState = "available";
    assert.throws(
      () => validateP30InstalledSession(wayland.session, binding(wayland)),
      /optimistically/u,
    );
    mutate(
      interaction,
      interaction.session.evidence.nativeTranscript,
      (value) => {
        value.interactions.clickThrough.restored = false;
      },
    );
    assert.throws(
      () =>
        validateP30InstalledSession(interaction.session, binding(interaction)),
      /click-through/u,
    );
    mutate(
      restoration,
      restoration.session.evidence.nativeTranscript,
      (value) => {
        value.restoration.desktopPidsAfter = [99];
      },
    );
    assert.throws(
      () =>
        validateP30InstalledSession(restoration.session, binding(restoration)),
      /restore/u,
    );
  } finally {
    for (const value of [wayland, interaction, restoration])
      fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-30 materializer rejects escaped and symlinked output roots", () => {
  const value = fixture();
  const outside = fs.mkdtempSync(
    path.join(process.cwd(), ".tmp/p30-proof-tests/outside-"),
  );
  fs.chmodSync(outside, 0o700);
  const target = path.join(value.root, "target");
  const linked = path.join(value.root, "linked");
  fs.mkdirSync(target, { mode: 0o700 });
  fs.symlinkSync(target, linked);
  const options = (outputRoot) => ({
    ...binding(value),
    outputRoot,
    rawEvidenceDir: value.raw,
    compositor: "Mutter",
  });
  const deps = {
    installedVerifier: () => ({}),
    manifestPath: value.identity.manifestPath,
    signaturePath: value.identity.signaturePath,
  };
  try {
    assert.throws(
      () => materializeP30PetSession(options(outside), deps),
      /confined/u,
    );
    assert.throws(
      () => materializeP30PetSession(options(linked), deps),
      /real owned/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
  }
});
