import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP28SmartHubProof } from "./capture-p28-smarthub-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP28InstalledSession,
  validateP28Proof,
} from "./lib/p28-smarthub-proof.mjs";
import {
  readRegularSnapshot,
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
} from "./lib/product-proof-closure.mjs";
import { materializeP28SmartHubSession } from "./materialize-p28-smarthub-session.mjs";
import { validateProductRequirement } from "./product-validators/P-28.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "282828";
const DIGEST = `sha256:${"2".repeat(64)}`;
const VERSION = "1.2.3";
const MARKER = "p28-fedcba0987654321";
const NONCE = "a".repeat(48);

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

function canonicalHash(value) {
  return hash(Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
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
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const at = y * (width * 3 + 1) + 1 + x * 3;
      raw[at] = (x + seed * 13) % 256;
      raw[at + 1] = (y + seed * 19) % 256;
      raw[at + 2] = (x + y + seed * 23) % 256;
    }
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function installedIdentity() {
  return {
    cli: "/usr/bin/openburnbar-cli",
    daemonLauncher: "/usr/libexec/openburnbar-daemon-launch",
    desktop: "/usr/bin/openburnbar-linux-desktop",
    packageManager: "dpkg",
    packageName: "openburnbar",
    packageOwned: true,
    executablePackages: {
      "/usr/bin/openburnbar-cli": "openburnbar",
      "/usr/libexec/openburnbar-daemon-launch": "openburnbar",
      "/usr/bin/openburnbar-linux-desktop": "openburnbar",
    },
  };
}

function attestation(root, raw, architecture = "aarch64", format = "deb") {
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
        item("/usr/bin/openburnbar-cli", Buffer.from("cli"), "0755"),
        item("/usr/bin/openburnbar-daemon", Buffer.from("daemon"), "0755"),
        item(
          "/usr/bin/openburnbar-linux-desktop",
          Buffer.from("desktop"),
          "0755",
        ),
        item(
          "/usr/libexec/openburnbar-daemon-launch",
          Buffer.from("launcher"),
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

function status(healthy) {
  return {
    adapter: "smart_hub_bridge",
    status: healthy ? "bridge_control_ok" : "blocked_bridge_not_reachable",
    blocker: healthy ? "" : "Start the Linux SmartHub bridge and retry.",
    health_probe: "curl http://127.0.0.1:8787/health",
    health_response: healthy ? '{"ok":true}' : "",
    control_probe: "curl -X POST http://127.0.0.1:8787/api/display",
    control_response: healthy ? '{"accepted":true}' : "",
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

function fixture() {
  const environmentId = "ubuntu-24.04-gnome-wayland-aarch64";
  const base = path.join(process.cwd(), ".tmp/p28-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "proof-"));
  const raw = path.join(root, "runner-raw");
  fs.mkdirSync(raw, { mode: 0o700 });
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-28",
    environmentId,
  );
  fs.mkdirSync(input, { recursive: true });
  const attestRoot = path.join(root, "attestation");
  fs.mkdirSync(attestRoot, { mode: 0o700 });
  const identity = attestation(root, attestRoot);
  const startedAt = new Date(Date.now() - 60_000).toISOString();
  const endedAt = new Date(Date.now() - 20_000).toISOString();
  const advertised = {
    service_type: "_openburnbar-peer._tcp",
    instance: "OpenBurnBar-p28-live",
    txt: {
      transport: "unix-domain",
      daemon_version: VERSION,
      protocol_version: "1",
      platform: "linux",
      pairing: "mdns",
    },
  };
  const matchedPeer = {
    instanceName: advertised.instance,
    hostName: "p28.local",
    port: 8787,
    txt: { ...advertised.txt },
  };
  const discovery = [
    {
      adapter: "smart_hub_bridge",
      serviceType: "_openburnbar-peer._tcp",
      instances: [advertised.instance],
      rawTranscript: "live avahi resolved transcript",
      status: "ok",
      blocker: null,
    },
  ];
  const peer = {
    producer: "openburnbar-p28-live-peer-manifest-v1",
    marker: MARKER,
    nonce: NONCE,
    capturedAt: new Date(Date.parse(startedAt) + 1_000).toISOString(),
    source: {
      advertise:
        "/usr/bin/openburnbar-cli local-peer advertise-metadata --json",
      browse: "/usr/bin/openburnbar-cli local-peer browse --json --timeout 3",
      discovery: "/usr/bin/openburnbar-cli devices discover smarthub --json",
    },
    serviceType: "_openburnbar-peer._tcp",
    platform: "linux",
    discoveryMethod: "mdns-avahi",
    transport: advertised.txt.transport,
    protocolVersion: advertised.txt.protocol_version,
    daemonVersion: advertised.txt.daemon_version,
    advertised,
    matchedPeer,
    discovery,
  };
  json(path.join(raw, "smarthub-peer-manifest.json"), peer);
  const runtimeManifest = {
    schemaVersion: 1,
    daemonVersion: VERSION,
    sessionType: "wayland",
    desktop: "GNOME",
    capabilities: [
      {
        id: "smarthub.control",
        state: "available",
        source: "trusted-cli",
      },
    ],
  };
  const marker = {
    producer: "openburnbar-p28-installed-marker-v1",
    marker: MARKER,
    nonce: NONCE,
    installed: installedIdentity(),
    runtimeManifestSha256: canonicalHash(runtimeManifest),
    peerManifestSha256: canonicalHash(peer),
    safety: {
      fixtureMode: false,
      isolatedHome: true,
      isolatedSupport: true,
      preexistingProcesses: {
        desktopPids: [],
        daemonPids: [2810],
        bridgePids: [2890],
        daemonActive: true,
      },
      exactDesktopProcessesRestored: true,
      exactBridgeProcessesRestored: true,
      daemonServiceStateRestored: true,
    },
  };
  json(path.join(raw, "smarthub-marker.json"), marker);
  const captures = {};
  const statusByState = {
    discovered: advertised.instance,
    controlled: "bridge_control_ok",
    degraded: "blocked_bridge_not_reachable",
    recovered: "bridge_control_ok",
  };
  const primaryPid = 2800;
  const relaunchPid = 2801;
  for (const [index, state] of [
    "discovered",
    "controlled",
    "degraded",
    "recovered",
  ].entries()) {
    const capturedAt = new Date(
      Date.parse(startedAt) + 3_000 + index * 5_000,
    ).toISOString();
    const atspi = {
      producer: "openburnbar-p28-atspi-live-v1",
      marker: MARKER,
      nonce: NONCE,
      state,
      capturedAt,
      application: "OpenBurnBar",
      desktopPid: state === "recovered" ? relaunchPid : primaryPid,
      route: "smarthub",
      selectedOperation: state === "discovered" ? "discover" : "status",
      focusedName: "Run operation",
      statusText: statusByState[state],
      nodes: [
        {
          name: "SmartHub / IoT",
          role: "section",
          actions: [],
          states: [],
        },
        {
          name: "Operation",
          role: "combo box",
          actions: ["select"],
          states: [],
        },
        {
          name: "Run operation",
          role: "push button",
          actions: ["press"],
          states: ["focused"],
        },
        ...Array.from({ length: 6 }, (_, node) => ({
          name: `${state}-node-${node}`,
          role: "label",
          actions: [],
          states: [],
        })),
      ],
    };
    const atspiFile = json(
      path.join(raw, `smarthub-${state}-atspi.json`),
      atspi,
    );
    const screenshotFile = write(
      path.join(raw, `smarthub-${state}.png`),
      png(index + 1),
    );
    captures[state] = {
      atspiSha256: hash(fs.readFileSync(atspiFile)),
      screenshotSha256: hash(fs.readFileSync(screenshotFile)),
      capturedAt,
      focusedName: atspi.focusedName,
      statusText: atspi.statusText,
    };
  }
  const transcript = {
    producer: "openburnbar-p28-installed-smarthub-native-v1",
    marker: MARKER,
    nonce: NONCE,
    startedAt,
    endedAt,
    installed: installedIdentity(),
    runtime: {
      manifest: runtimeManifest,
      sha256: canonicalHash(runtimeManifest),
      capability: runtimeManifest.capabilities[0],
    },
    peerManifest: {
      sha256: canonicalHash(peer),
      instance: advertised.instance,
      endpoint: `${matchedPeer.hostName}:${matchedPeer.port}`,
    },
    compositor: {
      desktop: "GNOME",
      displayServer: "wayland",
      display: null,
      waylandDisplay: "wayland-0",
      sessionId: "4",
      dbusSessionBus: true,
    },
    session: {
      fixtureMode: false,
      isolatedHome: true,
      isolatedSupport: true,
      primaryDesktopPid: primaryPid,
      relaunchDesktopPid: relaunchPid,
    },
    operations: {
      discovery: { result: discovery, peer: matchedPeer },
      controlled: status(true),
      degraded: status(false),
      recovered: status(true),
      recovery: {
        bridgeResumed: true,
        daemonRestarted: true,
        desktopRestarted: true,
        peerIdentityPersisted: true,
        healthRecovered: true,
        controlRecovered: true,
        staleHealthyResultBlocked: true,
      },
    },
    accessibility: {
      route: "smarthub",
      actionableControls: true,
      focusRestored: true,
      liveStatusObserved: true,
      captures,
    },
    restoration: {
      daemonWasActive: true,
      daemonActiveAfter: true,
      desktopPidsBefore: [],
      desktopPidsAfter: [],
      bridgePidsBefore: [2890],
      bridgePidsAfter: [2890],
      exactDesktopProcessesRestored: true,
      exactBridgeProcessesRestored: true,
      daemonServiceStateRestored: true,
    },
  };
  json(path.join(raw, "smarthub-native-transcript.json"), transcript);
  const materialized = materializeP28SmartHubSession(
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
    identity,
    environmentId,
    session: materialized.document,
    sessionPath: materialized.output,
  };
}

function mutateArtifact(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const document = JSON.parse(fs.readFileSync(file));
  change(document);
  json(file, document);
  Object.assign(descriptor, record(value.root, file));
  return document;
}

function context(value, proofFile, { duplicate = false } = {}) {
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
  const featureRows = [
    { role: "aggregate-product-proof-closure", ...aggregate },
    { role: "feature.smarthub-installed", ...proof },
  ];
  if (duplicate)
    featureRows.push({ role: "feature.smarthub-installed", ...proof });
  return {
    schemaVersion: 1,
    repoRoot: value.root,
    requirementId: "P-28",
    checkId: "p-28.smarthub",
    environmentId: value.environmentId,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-28",
        environmentId: value.environmentId,
        version: VERSION,
        blockers: [],
        architectures: [...RELEASE_ARCHITECTURES],
        supportEnvironments: [...SUPPORT_ENVIRONMENTS],
        selectedPackage: { architecture: "aarch64", format: "deb" },
        candidate: { runId: RUN_ID, artifactDigest: DIGEST },
        packageManifestSignature: value.session.package.signature,
        proofs: featureRows,
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

function capture(value) {
  return captureP28SmartHubProof(
    {
      ...binding(value),
      inputRoot: value.input,
      sessionReport: value.sessionPath,
    },
    { resolveHead: () => HEAD, now: () => new Date() },
  );
}

test("P-28 materializes, captures, and validates exact installed SmartHub proof", async () => {
  const value = fixture();
  try {
    const session = validateP28InstalledSession(value.session, binding(value));
    assert.equal(
      session.transcript.operations.recovered.status,
      "bridge_control_ok",
    );
    assert.equal(session.evidence.length, 13);
    const captured = capture(value);
    const proof = validateP28Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-28 proof",
      ),
    });
    assert.equal(proof.proof.claim.honestCapabilityLoss, true);
    const result = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(result.status, "passed");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 rejects peer, provenance, replay, recovery, and restoration mutations", () => {
  const mutations = [
    {
      pattern: /production CLI contracts/u,
      apply(value) {
        const peer = mutateArtifact(
          value,
          value.session.evidence.peerManifest,
          (document) => {
            document.source.browse = "/tmp/fake-peer-browser";
          },
        );
        value.session.marker.peerManifestSha256 = canonicalHash(peer);
        mutateArtifact(
          value,
          value.session.evidence.nativeTranscript,
          (document) => {
            document.peerManifest.sha256 = canonicalHash(peer);
          },
        );
        const markerFile = path.join(
          value.root,
          value.session.evidence.marker.path,
        );
        json(markerFile, value.session.marker);
        Object.assign(
          value.session.evidence.marker,
          record(value.root, markerFile),
        );
      },
    },
    {
      pattern: /screenshots.*replayed/u,
      apply(value) {
        const source = path.join(
          value.root,
          value.session.evidence.discoveredScreenshot.path,
        );
        const target = path.join(
          value.root,
          value.session.evidence.controlledScreenshot.path,
        );
        fs.copyFileSync(source, target);
        Object.assign(
          value.session.evidence.controlledScreenshot,
          record(value.root, target),
        );
        mutateArtifact(
          value,
          value.session.evidence.nativeTranscript,
          (document) => {
            document.accessibility.captures.controlled.screenshotSha256 = hash(
              fs.readFileSync(target),
            );
          },
        );
      },
    },
    {
      pattern: /stale, replayed, or not state-bound/u,
      apply(value) {
        const atspi = mutateArtifact(
          value,
          value.session.evidence.degradedAccessibility,
          (document) => {
            document.capturedAt = "2020-01-01T00:00:00.000Z";
          },
        );
        mutateArtifact(
          value,
          value.session.evidence.nativeTranscript,
          (document) => {
            document.accessibility.captures.degraded.atspiSha256 =
              value.session.evidence.degradedAccessibility.sha256;
            document.accessibility.captures.degraded.capturedAt =
              atspi.capturedAt;
          },
        );
      },
    },
    {
      pattern: /recovery is partial/u,
      apply(value) {
        mutateArtifact(
          value,
          value.session.evidence.nativeTranscript,
          (document) => {
            document.operations.recovery.controlRecovered = false;
          },
        );
      },
    },
    {
      pattern: /exact process restoration failed/u,
      apply(value) {
        mutateArtifact(
          value,
          value.session.evidence.nativeTranscript,
          (document) => {
            document.restoration.bridgePidsAfter = [9999];
          },
        );
      },
    },
  ];
  for (const mutation of mutations) {
    const value = fixture();
    try {
      mutation.apply(value);
      assert.throws(
        () => validateP28InstalledSession(value.session, binding(value)),
        mutation.pattern,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-28 rejects installed launcher and emitted candidate substitution", () => {
  const installed = fixture();
  const candidate = fixture();
  try {
    installed.session.marker.installed.daemonLauncher =
      "/usr/bin/openburnbar-daemon";
    assert.throws(
      () => validateP28InstalledSession(installed.session, binding(installed)),
      /canonical package-owned/u,
    );
    const captured = capture(candidate);
    const proof = JSON.parse(fs.readFileSync(captured.output));
    proof.candidate.runId = "999999";
    json(captured.output, proof);
    assert.throws(
      () =>
        validateP28Proof({
          ...binding(candidate),
          snapshot: readRegularSnapshot(
            candidate.root,
            path.relative(candidate.root, captured.output),
            "P-28 forged proof",
          ),
        }),
      /candidate binding/u,
    );
  } finally {
    fs.rmSync(installed.root, { recursive: true, force: true });
    fs.rmSync(candidate.root, { recursive: true, force: true });
  }
});

test("P-28 materializer rejects extra raw evidence, wrong compositor, and replay output", () => {
  const extra = fixture();
  try {
    assert.throws(
      () =>
        materializeP28SmartHubSession(
          {
            ...binding(extra),
            outputRoot: extra.input,
            rawEvidenceDir: extra.raw,
            compositor: "Mutter",
          },
          {
            installedVerifier: () => ({}),
            manifestPath: extra.identity.manifestPath,
            signaturePath: extra.identity.signaturePath,
          },
        ),
      /output (?:session|evidence) already exists/u,
    );
    const freshRoot = path.join(
      extra.root,
      "docs/linux-port/evidence/product-parity-inputs/P-28",
      "ubuntu-24.04-gnome-wayland-aarch64-fresh",
    );
    fs.mkdirSync(freshRoot, { recursive: true });
    write(path.join(extra.raw, "unexpected.txt"), "unexpected\n");
    assert.throws(
      () =>
        materializeP28SmartHubSession(
          {
            ...binding(extra),
            outputRoot: freshRoot,
            rawEvidenceDir: extra.raw,
            compositor: "KWin",
          },
          {
            installedVerifier: () => ({}),
            manifestPath: extra.identity.manifestPath,
            signaturePath: extra.identity.signaturePath,
          },
        ),
      /compositor|exactly the native runner artifacts/u,
    );
  } finally {
    fs.rmSync(extra.root, { recursive: true, force: true });
  }
});

test("P-28 product validator rejects duplicate owned proof roles", async () => {
  const value = fixture();
  try {
    const captured = capture(value);
    await assert.rejects(
      validateProductRequirement(
        context(value, captured.output, { duplicate: true }),
      ),
      /must occur exactly once/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 capture and materializer reject symlink substitution", () => {
  const captureValue = fixture();
  const materializeValue = fixture();
  try {
    const reportLink = path.join(captureValue.input, "linked-session.json");
    fs.symlinkSync(captureValue.sessionPath, reportLink);
    assert.throws(
      () =>
        captureP28SmartHubProof(
          {
            ...binding(captureValue),
            inputRoot: captureValue.input,
            sessionReport: reportLink,
          },
          { resolveHead: () => HEAD, now: () => new Date() },
        ),
      /owned regular file/u,
    );

    const replaced = path.join(
      materializeValue.raw,
      "smarthub-controlled-atspi.json",
    );
    const outside = path.join(materializeValue.root, "outside-atspi.json");
    fs.copyFileSync(replaced, outside);
    fs.rmSync(replaced);
    fs.symlinkSync(outside, replaced);
    const freshOutput = path.join(materializeValue.input, "symlink-attempt");
    fs.mkdirSync(freshOutput, { mode: 0o700 });
    assert.throws(
      () =>
        materializeP28SmartHubSession(
          {
            ...binding(materializeValue),
            outputRoot: freshOutput,
            rawEvidenceDir: materializeValue.raw,
            compositor: "Mutter",
          },
          {
            installedVerifier: () => ({}),
            manifestPath: materializeValue.identity.manifestPath,
            signaturePath: materializeValue.identity.signaturePath,
          },
        ),
      /ELOOP|symbolic link|safe immutable artifact/u,
    );
  } finally {
    fs.rmSync(captureValue.root, { recursive: true, force: true });
    fs.rmSync(materializeValue.root, { recursive: true, force: true });
  }
});
