import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP26TrayProof } from "./capture-p26-tray-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP26InstalledSession,
  validateP26Proof,
} from "./lib/p26-tray-proof.mjs";
import { materializeP26TraySession } from "./materialize-p26-tray-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-26.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "262626";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "p26-fedcba0987654321";
const ROUTES = [
  ["dashboard", "Open dashboard", "Overview"],
  ["chat", "Open chat", "Chat / Hermes"],
  ["usage", "Open usage", "Insights"],
  ["updates", "Open updates", "Updates"],
  ["settings", "Open settings", "Settings"],
];
const ACTIONS = [
  ...ROUTES.map(([phase, label]) => [phase, label]),
  ["reopen", "Open dashboard"],
  ["refresh", "Refresh status"],
  ["reconnect", "Reconnect daemon"],
  ["quit", "Quit OpenBurnBar"],
];
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
function menu(usage, daemon = "connected") {
  return [
    ["Open dashboard", true],
    ["Open chat", true],
    ["Open usage", true],
    ["Open updates", true],
    ["Open settings", true],
    [
      daemon === "connected"
        ? `Daemon: connected - p26-installed-${VERSION}`
        : "Daemon: offline",
      false,
    ],
    [`Recent usage: ${usage} tokens - $0.01`, false],
    ["Updates: up to date", false],
    ["Refresh status", true],
    ["Reconnect daemon", true],
    ["Quit OpenBurnBar", true],
  ].map(([label, enabled], index) => ({ id: index + 1, label, enabled }));
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
  const base = path.join(process.cwd(), ".tmp/p26-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "proof-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw, { mode: 0o700 });
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-26",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const start = Date.now() - 60_000;
  const at = (offset) => new Date(start + offset).toISOString();
  json(path.join(raw, "tray-marker.json"), {
    marker: MARKER,
    installedExecutable: "/usr/bin/openburnbar-linux-desktop",
    autostart: {
      path: "/etc/xdg/autostart/openburnbar.desktop",
      exec: "openburnbar-linux-desktop --background",
      packageOwned: true,
      manager: "dpkg",
      packageName: "openburnbar",
      sha256: "a".repeat(64),
    },
    safety: {
      fixtureMode: false,
      isolatedDaemon: true,
      preexistingDesktopProcesses: 0,
      daemonServiceRestored: true,
      desktopProcessesRestored: true,
    },
  });
  json(path.join(raw, "tray-native-transcript.json"), {
    producer: "openburnbar-p26-installed-tray-probe-v1",
    marker: MARKER,
    startedAt: at(0),
    endedAt: at(30_000),
    background: {
      pid: 2600,
      command: "/usr/bin/openburnbar-linux-desktop --background",
      noVisibleWindow: true,
      processAlive: true,
      trayRegistered: true,
    },
    tray: {
      protocol: "AppIndicator",
      service: ":1.26",
      path: "/org/ayatana/NotificationItem/openburnbar",
      menuPath: "/org/ayatana/NotificationItem/openburnbar/Menu",
      tooltip: "OpenBurnBar — Linux desktop assistant",
      initialMenu: menu(42),
      initialMenuRevision: 10,
      refreshedMenu: menu(43),
      refreshedMenuRevision: 11,
      disconnectedMenu: menu(43, "offline"),
      disconnectedMenuRevision: 12,
      reconnectedMenu: menu(43),
      reconnectedMenuRevision: 13,
    },
    actions: ACTIONS.map(([phase, label], index) => ({
      phase,
      at: at(2_000 + index * 2_000),
      label,
      menuId: menu(42).find((item) => item.label === label).id,
      dbusReply: `method return sender=:1.26 sequence=${index}`,
    })),
    routes: ROUTES.map(([route, , accessibleName], index) => ({
      route,
      at: at(3_000 + index * 2_000),
      accessibleName,
      appPid: 2600,
      manifestSha256: identity.manifestSha256,
      visible: true,
    })),
    accessibility: {
      atspiApplication: "OpenBurnBar",
      keyboardFocusObserved: true,
      semanticMenuItems: 8,
      menuItemsEnabled: true,
    },
    daemon: {
      beforeHealth: "connected",
      beforeReconnectHealth: "disconnected",
      afterReconnectHealth: "connected",
      usageState: "Recent usage: 42 tokens - $0.01",
      updateState: "Updates: up to date",
    },
    persistence: {
      windowHideLeftProcessAlive: true,
      reopenSamePid: true,
      quitTerminated: true,
      relaunchPid: 2601,
      relaunchRegistration: ":1.27/org/ayatana/NotificationItem/openburnbar",
      relaunchNoVisibleWindow: true,
      trayReregistered: true,
      distinctRegistration: true,
      relaunchTerminated: true,
    },
    restoration: {
      daemonWasActive: true,
      daemonActiveAfter: true,
      desktopPidsBefore: [],
      desktopPidsAfter: [],
    },
  });
  ["background", "dashboard", "chat", "usage", "updates", "settings"].forEach(
    (name, index) => write(path.join(raw, `tray-${name}.png`), png(index + 1)),
  );
  ROUTES.forEach(([route, , accessibleName], index) =>
    json(path.join(raw, `tray-${route}-atspi.json`), {
      schemaVersion: 1,
      producer: "openburnbar-atspi-live-v1",
      application: "OpenBurnBar",
      route,
      expectedName: accessibleName,
      expectedNamePresent: true,
      pass: true,
      namedSamples: [
        {
          name: accessibleName,
          role: "heading",
          states: index === 0 ? ["focused"] : [],
        },
        { name: `Native ${route} content`, role: "section", states: [] },
      ],
    }),
  );
  const materialized = materializeP26TraySession(
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
    requirementId: "P-26",
    checkId: "p-26.tray-and-native-shell",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-26",
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
          { role: "feature.tray-native-shell-installed", ...proof },
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

test("P-26 materializes, captures, and validates candidate-bound tray evidence", async () => {
  const value = fixture();
  try {
    const validated = validateP26InstalledSession(
      value.session,
      binding(value),
    );
    assert.equal(validated.actionCount, 9);
    assert.equal(validated.routeCount, 5);
    const captured = captureP26TrayProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.now() + 1_000) },
    );
    const proof = validateP26Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-26 proof",
      ),
    });
    assert.equal(proof.proof.claim.backgroundPersistence, true);
    const result = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(result.status, "passed");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-26 rejects substituted tray actions and failed restoration", () => {
  const action = fixture();
  const restoration = fixture();
  try {
    mutate(action, action.session.evidence.nativeTranscript, (payload) => {
      payload.actions[1].label = "Open dashboard";
    });
    assert.throws(
      () => validateP26InstalledSession(action.session, binding(action)),
      /action chat/u,
    );
    mutate(
      restoration,
      restoration.session.evidence.nativeTranscript,
      (payload) => {
        payload.restoration.daemonActiveAfter = false;
      },
    );
    assert.throws(
      () =>
        validateP26InstalledSession(restoration.session, binding(restoration)),
      /restore/u,
    );
  } finally {
    fs.rmSync(action.root, { recursive: true, force: true });
    fs.rmSync(restoration.root, { recursive: true, force: true });
  }
});

test("P-26 rejects replayed screenshots and substituted AT-SPI routes", () => {
  const replay = fixture();
  const atspi = fixture();
  try {
    const source = path.join(
      replay.root,
      replay.session.evidence.dashboardScreenshot.path,
    );
    const target = path.join(
      replay.root,
      replay.session.evidence.chatScreenshot.path,
    );
    fs.copyFileSync(source, target);
    Object.assign(
      replay.session.evidence.chatScreenshot,
      record(replay.root, target),
    );
    assert.throws(
      () => validateP26InstalledSession(replay.session, binding(replay)),
      /replay/u,
    );
    mutate(atspi, atspi.session.evidence.updatesAccessibility, (payload) => {
      payload.namedSamples[0].name = "Settings";
    });
    assert.throws(
      () => validateP26InstalledSession(atspi.session, binding(atspi)),
      /Updates/u,
    );
  } finally {
    fs.rmSync(replay.root, { recursive: true, force: true });
    fs.rmSync(atspi.root, { recursive: true, force: true });
  }
});

test("P-26 rejects non-packaged autostart and stale menu status", () => {
  const startup = fixture();
  const status = fixture();
  try {
    startup.session.marker.autostart.exec = "openburnbar-linux-desktop";
    assert.throws(
      () => validateP26InstalledSession(startup.session, binding(startup)),
      /autostart/u,
    );
    mutate(status, status.session.evidence.nativeTranscript, (payload) => {
      payload.tray.initialMenu.find((item) =>
        item.label.startsWith("Recent usage:"),
      ).label = "Recent usage: unavailable";
    });
    assert.throws(
      () => validateP26InstalledSession(status.session, binding(status)),
      /live daemon, usage, or update/u,
    );
  } finally {
    fs.rmSync(startup.root, { recursive: true, force: true });
    fs.rmSync(status.root, { recursive: true, force: true });
  }
});

test("P-26 rejects substituted menu IDs and replayed tray registration", () => {
  const action = fixture();
  const registration = fixture();
  try {
    mutate(action, action.session.evidence.nativeTranscript, (payload) => {
      payload.actions[0].menuId = 99;
    });
    assert.throws(
      () => validateP26InstalledSession(action.session, binding(action)),
      /action dashboard/u,
    );
    mutate(
      registration,
      registration.session.evidence.nativeTranscript,
      (payload) => {
        payload.persistence.relaunchRegistration = `${payload.tray.service}${payload.tray.path}`;
      },
    );
    assert.throws(
      () =>
        validateP26InstalledSession(
          registration.session,
          binding(registration),
        ),
      /persistence/u,
    );
  } finally {
    fs.rmSync(action.root, { recursive: true, force: true });
    fs.rmSync(registration.root, { recursive: true, force: true });
  }
});

test("P-26 rejects noncanonical labels, package ownership, and replayed menu revisions", () => {
  const label = fixture();
  const owner = fixture();
  const revision = fixture();
  const reconnect = fixture();
  try {
    mutate(label, label.session.evidence.nativeTranscript, (payload) => {
      payload.tray.initialMenu.find((item) =>
        item.label.startsWith("Daemon: connected"),
      ).label = "Daemon: connected";
    });
    assert.throws(
      () => validateP26InstalledSession(label.session, binding(label)),
      /initial menu/u,
    );
    owner.session.marker.autostart.packageName = "substitute";
    assert.throws(
      () => validateP26InstalledSession(owner.session, binding(owner)),
      /autostart/u,
    );
    mutate(revision, revision.session.evidence.nativeTranscript, (payload) => {
      payload.tray.refreshedMenuRevision = payload.tray.initialMenuRevision;
    });
    assert.throws(
      () => validateP26InstalledSession(revision.session, binding(revision)),
      /revisions/u,
    );
    mutate(
      reconnect,
      reconnect.session.evidence.nativeTranscript,
      (payload) => {
        payload.daemon.beforeReconnectHealth = "connected";
      },
    );
    assert.throws(
      () => validateP26InstalledSession(reconnect.session, binding(reconnect)),
      /state is not live/u,
    );
  } finally {
    for (const value of [label, owner, revision, reconnect])
      fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-26 materializer rejects escaped and symlinked evidence paths", () => {
  const value = fixture();
  const outsideOutput = fs.mkdtempSync(
    path.join(process.cwd(), ".tmp/p26-proof-tests/materializer-outside-"),
  );
  fs.chmodSync(outsideOutput, 0o700);
  const linkedOutputTarget = path.join(value.root, "linked-output-target");
  const linkedOutput = path.join(value.root, "linked-output");
  const unsafeOutput = path.join(value.root, "unsafe-output");
  fs.mkdirSync(linkedOutputTarget, { mode: 0o700 });
  fs.symlinkSync(linkedOutputTarget, linkedOutput);
  fs.mkdirSync(unsafeOutput, { mode: 0o700 });
  fs.symlinkSync(linkedOutputTarget, path.join(unsafeOutput, "raw"));
  const options = (outputRoot) => ({
    ...binding(value),
    outputRoot,
    rawEvidenceDir: value.raw,
    compositor: "Mutter",
  });
  const dependencies = {
    installedVerifier: () => ({}),
    manifestPath: value.identity.manifestPath,
    signaturePath: value.identity.signaturePath,
  };
  try {
    assert.throws(
      () => materializeP26TraySession(options(outsideOutput), dependencies),
      /confined to the repository/u,
    );
    assert.throws(
      () => materializeP26TraySession(options(linkedOutput), dependencies),
      /canonical/u,
    );
    assert.throws(
      () => materializeP26TraySession(options(unsafeOutput), dependencies),
      /copied evidence.*canonical/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
    fs.rmSync(outsideOutput, { recursive: true, force: true });
  }
});
