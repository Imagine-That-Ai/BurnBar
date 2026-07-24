import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP27NotificationsProof } from "./capture-p27-notifications-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP27InstalledSession,
  validateP27Proof,
} from "./lib/p27-notifications-proof.mjs";
import {
  readRegularSnapshot,
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
} from "./lib/product-proof-closure.mjs";
import { materializeP27NotificationsSession } from "./materialize-p27-notifications-session.mjs";
import { validateProductRequirement } from "./product-validators/P-27.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "272727";
const DIGEST = `sha256:${"3".repeat(64)}`;
const VERSION = "1.2.3";
const MARKER = "p27-fedcba0987654321";
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
  const width = 400;
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
      raw[at + 1] = (y + seed * 29) % 256;
      raw[at + 2] = (x + y + seed * 37) % 256;
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
        item(
          "/etc/xdg/autostart/openburnbar.desktop",
          Buffer.from(
            "[Desktop Entry]\nExec=openburnbar-linux-desktop --background\n",
          ),
          "0644",
        ),
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
    environmentId: value.environmentId,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    ...value.identity,
  };
}
function a11y(raw, mode, capturedAt) {
  const values = {
    open: ["OpenBurnBar Overview", "overview", false, "Overview dashboard"],
    reply: ["Message composer", "chat", true, "Message composer"],
    cold: ["Membership account", "account", false, "Membership link accepted"],
    warm: ["Provider model", "providers", false, "Provider model selected"],
  }[mode];
  return json(path.join(raw, `notification-${mode}-atspi.json`), {
    producer: "openburnbar-p27-atspi-live-v1",
    application: "OpenBurnBar",
    capturedAt,
    focusedName: values[0],
    route: values[1],
    composerFocused: values[2],
    statusText: values[3],
    namedNodes: Array.from({ length: 7 }, (_, index) => ({
      name: `${mode}-${index}`,
      role: "section",
      actions: [],
    })),
  });
}
function mutate(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const document = JSON.parse(fs.readFileSync(file));
  change(document);
  json(file, document);
  Object.assign(descriptor, record(value.root, file));
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p27-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "proof-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw, { mode: 0o700 });
  const environmentId = "ubuntu-24.04-gnome-x11-aarch64";
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-27",
    environmentId,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const now = Date.now();
  const startedAt = new Date(now - 120_000).toISOString();
  const endedAt = new Date(now - 60_000).toISOString();
  const runtime = json(
    path.join(raw, "notification-runtime-capabilities.json"),
    {
      sessionType: "x11",
      desktop: "GNOME",
      capabilities: [{ id: "native.notifications", state: "available" }],
    },
  );
  const runtimeSha = hash(fs.readFileSync(runtime));
  const action = (kind, route) => ({
    action: kind,
    route,
    notificationId: `${MARKER}-${kind}`,
    delivered: true,
    serverActionObserved: true,
    productEventObserved: true,
    uiOutcomeObserved: true,
  });
  const transcript = {
    producer: "openburnbar-p27-installed-notifications-probe-v1",
    marker: MARKER,
    startedAt,
    endedAt,
    runtime: {
      manifestSha256: runtimeSha,
      notificationState: "available",
      source: "installed-runtime-command",
    },
    compositor: { desktop: "GNOME", displayServer: "X11", sessionType: "x11" },
    adapter: {
      actionsSupported: true,
      capabilityCommand: "native_notification_capabilities",
      deliveryCommand: "native_notification_show",
      serverName: "GNOME Shell",
      serverVendor: "GNOME",
      serverVersion: "46",
    },
    notifications: {
      open: action("open", "overview"),
      reply: action("reply", "chat"),
    },
    deepLinks: [
      {
        kind: "oauth",
        uri: `http://127.0.0.1:49152/callback?code=${MARKER}-authorization-code&state=${"s".repeat(43)}`,
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        operationIdPresent: true,
        stateBound: true,
        wrongStateStatus: 400,
        callbackStatus: 200,
        replayRejected: true,
        route: "account",
        phase: "cold",
        accepted: true,
        ownerPid: 2727,
        singleInstance: false,
        transport: "loopback",
      },
      {
        kind: "membership",
        uri: "openburnbar://membership/success",
        route: "account",
        phase: "cold",
        accepted: true,
        ownerPid: 2727,
        singleInstance: true,
        transport: "single-instance",
      },
      {
        kind: "provider-model",
        uri: "openburnbar://providers?provider=openai&model=gpt-5.2-codex",
        route: "providers",
        phase: "warm",
        accepted: true,
        ownerPid: 2727,
        singleInstance: true,
        transport: "single-instance",
      },
    ],
    hostileLinks: Array.from({ length: 5 }, (_, index) => ({
      uri: `openburnbar://hostile-${index}`,
      accepted: false,
      reason: "single_instance_deep_link_rejected",
    })),
    lifecycle: {
      coldQueuedBeforeRenderer: true,
      coldActionDrainedOnce: true,
      coldNotificationId: `${MARKER}-cold-reply`,
      coldForwardCount: 1,
      coldForwardedBeforeWebDriverSession: true,
      coldPendingAfterDrain: 0,
      warmForwardedToOwner: true,
      warmForwardCount: 1,
      ownerPid: 2727,
    },
    autostart: {
      path: "/etc/xdg/autostart/openburnbar.desktop",
      exec: "openburnbar-linux-desktop --background",
      enabled: true,
      ownedByPackage: true,
      loginStartObserved: true,
      startedInBackground: true,
    },
    restoration: {
      autostartBeforeSha256: "a".repeat(64),
      autostartAfterSha256: "a".repeat(64),
      daemonWasActive: true,
      daemonActiveAfter: true,
      desktopPidsBefore: [],
      desktopPidsAfter: [],
      runtimeFilesBefore: [],
      runtimeFilesAfter: [],
    },
  };
  json(path.join(raw, "notification-native-transcript.json"), transcript);
  json(path.join(raw, "notification-marker.json"), {
    marker: MARKER,
    installed: {
      daemon: "/usr/bin/openburnbar-daemon",
      desktop: "/usr/bin/openburnbar-linux-desktop",
      autostart: "/etc/xdg/autostart/openburnbar.desktop",
      packageManager: "dpkg",
      packageName: "open-burn-bar",
      packageOwned: true,
    },
    runtimeManifest: {
      capturedFrom: "/usr/bin/openburnbar-linux-desktop --runtime-capabilities",
      notificationState: "available",
      sha256: runtimeSha,
    },
    safety: {
      fixtureMode: false,
      isolatedHome: true,
      preexistingDesktopProcesses: [],
      daemonRestored: true,
      desktopProcessesRestored: true,
      autostartRestored: true,
      singleInstanceStateRestored: true,
    },
  });
  for (const [index, mode] of ["open", "reply", "cold", "warm"].entries()) {
    write(path.join(raw, `notification-${mode}.png`), png(index + 1));
    a11y(raw, mode, new Date(now - 90_000).toISOString());
  }
  const materialized = materializeP27NotificationsSession(
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
    requirementId: "P-27",
    checkId: "p-27.notifications-and-deep-links",
    environmentId: value.environmentId,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-27",
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
          { role: "feature.notifications-deep-links-installed", ...proof },
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

test("P-27 materializes, captures, and validates the installed notification/deep-link closure", async () => {
  const value = fixture();
  try {
    const validated = validateP27InstalledSession(
      value.session,
      binding(value),
    );
    assert.equal(
      validated.transcript.notifications.reply.uiOutcomeObserved,
      true,
    );
    const captured = captureP27NotificationsProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date() },
    );
    const proof = validateP27Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-27 proof",
      ),
    });
    assert.equal(proof.proof.claim.actionableOpenAndReply, true);
    assert.equal(
      (await validateProductRequirement(context(value, captured.output)))
        .status,
      "passed",
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-27 rejects adapter substitution, hostile acceptance, replay, and failed restoration", () => {
  for (const [label, change, pattern] of [
    [
      "adapter",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.adapter.deliveryCommand = "notify-send";
        }),
      /product adapter/u,
    ],
    [
      "hostile",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.hostileLinks[0].accepted = true;
        }),
      /hostile/u,
    ],
    [
      "restoration",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.restoration.desktopPidsAfter = [99];
        }),
      /restore/u,
    ],
    [
      "link",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.deepLinks[2].uri += "&admin=true";
        }),
      /strictly accepted/u,
    ],
    [
      "OAuth state binding",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.deepLinks[0].wrongStateStatus = 200;
        }),
      /active one-shot PKCE/u,
    ],
    [
      "cold replay",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.lifecycle.coldActionDrainedOnce = false;
        }),
      /cold queue/u,
    ],
    [
      "cold forwarding count",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.lifecycle.coldForwardCount = 2;
        }),
      /cold queue/u,
    ],
    [
      "notification product event",
      (value) =>
        mutate(value, value.session.evidence.nativeTranscript, (doc) => {
          doc.notifications.open.productEventObserved = false;
        }),
      /notification action/u,
    ],
  ]) {
    const value = fixture();
    try {
      change(value);
      assert.throws(
        () => validateP27InstalledSession(value.session, binding(value)),
        pattern,
        label,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
  const value = fixture();
  try {
    const source = path.join(
      value.root,
      value.session.evidence.openScreenshot.path,
    );
    const target = path.join(
      value.root,
      value.session.evidence.replyScreenshot.path,
    );
    fs.copyFileSync(source, target);
    Object.assign(
      value.session.evidence.replyScreenshot,
      record(value.root, target),
    );
    assert.throws(
      () => validateP27InstalledSession(value.session, binding(value)),
      /replayed/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-27 rejects stale evidence, candidate forgery, and symlinked materializer output", () => {
  const stale = fixture();
  try {
    mutate(stale, stale.session.evidence.openAccessibility, (doc) => {
      doc.capturedAt = "2020-01-01T00:00:00.000Z";
    });
    assert.throws(
      () => validateP27InstalledSession(stale.session, binding(stale)),
      /outside the live session/u,
    );
  } finally {
    fs.rmSync(stale.root, { recursive: true, force: true });
  }
  const forged = fixture();
  try {
    const captured = captureP27NotificationsProof(
      {
        ...binding(forged),
        inputRoot: forged.input,
        sessionReport: forged.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date() },
    );
    const document = JSON.parse(fs.readFileSync(captured.output));
    document.candidate.runId = "999";
    json(captured.output, document);
    assert.throws(
      () =>
        validateP27Proof({
          ...binding(forged),
          snapshot: readRegularSnapshot(
            forged.root,
            path.relative(forged.root, captured.output),
            "forged",
          ),
        }),
      /candidate/u,
    );
  } finally {
    fs.rmSync(forged.root, { recursive: true, force: true });
  }
  const value = fixture();
  const target = path.join(value.root, "target");
  const linked = path.join(value.root, "linked");
  fs.mkdirSync(target, { mode: 0o700 });
  fs.symlinkSync(target, linked);
  try {
    assert.throws(
      () =>
        materializeP27NotificationsSession(
          {
            ...binding(value),
            outputRoot: linked,
            rawEvidenceDir: value.raw,
            compositor: "Mutter",
          },
          {
            installedVerifier: () => ({}),
            manifestPath: value.identity.manifestPath,
            signaturePath: value.identity.signaturePath,
          },
        ),
      /real owned/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
