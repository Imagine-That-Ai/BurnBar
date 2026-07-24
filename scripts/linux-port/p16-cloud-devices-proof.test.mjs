import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP16CloudDevicesProof } from "./capture-p16-cloud-devices-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP16InstalledSession,
  validateP16Proof,
} from "./lib/p16-cloud-devices-proof.mjs";
import { materializeP16CloudDevicesSession } from "./materialize-p16-cloud-devices-session.mjs";
import { runP16CloudDevicesWorkflow } from "./run-p16-native-cloud-devices-probes.mjs";

const HEAD = "1".repeat(40);
const RUN = "161616";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-x86_64";
const VERSION = "1.2.3";
const MARKER = "p16-0123456789abcdef";
const START = new Date(Date.now() - 60_000);
const END = new Date(Date.now() + 60_000);

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
  const width = 320;
  const height = 220;
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const at = y * (width * 3 + 1) + 1 + x * 3;
      raw[at] = (x + seed * 17) % 256;
      raw[at + 1] = (y + seed * 29) % 256;
      raw[at + 2] = (x + y + seed * 41) % 256;
    }
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
function attestation(root, directory) {
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
    manifestPath: write(
      path.join(directory, "installed-manifest.json"),
      manifest,
    ),
    signaturePath: write(
      path.join(directory, "installed-manifest.json.sig"),
      signature,
    ),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function mobileReceipt(file) {
  const at = new Date().toISOString();
  return json(file, {
    producer: "openburnbar-p16-physical-ipad-trust-cycle-v1",
    capturedAt: at,
    targetHead: HEAD,
    candidate: { runId: RUN, artifactDigest: DIGEST },
    physicalDevice: {
      platform: "iPadOS",
      simulator: false,
      bundleIdentifier: "com.openburnbar.app",
      appCheckAttested: true,
      deviceIdentifierHash: `sha256:${"4".repeat(64)}`,
    },
    linux: {
      marker: MARKER,
      deviceIdHash: `sha256:${hash("linux-device-16")}`,
      safetyFingerprintHash: `sha256:${hash("safety-fingerprint-16")}`,
    },
    events: [
      [1, "list", "listLinuxAppCheckDevices", "pending", false],
      [2, "approve", "approveLinuxAppCheckDevice", "approved", true],
      [3, "list", "listLinuxAppCheckDevices", "approved", false],
      [4, "revoke", "revokeLinuxAppCheckDevice", "revoked", true],
      [5, "list", "listLinuxAppCheckDevices", "revoked", false],
    ].map(([sequence, action, callable, state, signed]) => ({
      sequence,
      action,
      actionNonceHash: signed ? `sha256:${hash(`nonce-${sequence}`)}` : null,
      callable,
      state,
      observedAt: at,
      nonceBound: signed,
      signedActionProof: signed,
      signedActionProofHash: signed
        ? `sha256:${hash(`proof-${sequence}`)}`
        : null,
    })),
    restoration: {
      createdDeviceRevoked: true,
      noPendingMutation: true,
      trustedDeviceStateRestored: true,
    },
  });
}
function options(root) {
  return {
    rawOutputDir: path.join(root, "live/raw"),
    stateHome: path.join(root, "live/home"),
    coordinationDir: path.join(root, "coordination"),
    mobileReceipt: mobileReceipt(
      path.join(root, "ipad/p16-mobile-receipt.json"),
    ),
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    manifestSha256: "0".repeat(64),
    manifestSignatureSha256: "0".repeat(64),
    architecture: "x86_64",
    packageFormat: "deb",
    compositor: "Mutter",
    desktop: "GNOME",
    displayServer: "X11",
  };
}
function rawStatus(kind) {
  const common = {
    installationDeviceID: "linux-device-16",
    installationSafetyFingerprint: "safety-fingerprint-16",
  };
  if (kind === "pending")
    return {
      ...common,
      state: "awaiting-device-approval",
      phase: "awaiting-device-approval",
      signedIn: true,
      syncState: "local-only",
      deviceApprovalRequired: true,
    };
  if (["approved", "recovered", "restarted"].includes(kind))
    return {
      ...common,
      state: "ready",
      phase: "ready",
      signedIn: true,
      syncState: "cloud-ready",
      deviceApprovalRequired: false,
    };
  if (kind === "revoked")
    return {
      ...common,
      state: "device-rejected",
      phase: "device-rejected",
      signedIn: true,
      syncState: "local-only",
      deviceApprovalRequired: false,
    };
  return { errorVisible: true, optimisticSuccess: false };
}
function fakeDependencies(overrides = {}) {
  let daemon = false;
  let launched = false;
  let restored = 0;
  let clockCalls = 0;
  const statusText = {
    pending: "Approval pending",
    approved: "Cloud-ready approved",
    degraded: "Daemon unavailable error",
    recovered: "Recovered cloud-ready",
    revoked: "Device revoked unavailable",
  };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier() {},
    marker: MARKER,
    nonce: "3".repeat(32),
    clock() {
      clockCalls += 1;
      return clockCalls === 1 ? START : END;
    },
    identity: () => ({ packageName: "open-burn-bar", packageOwned: true }),
    desktopPids: () => [],
    daemonActive: () => daemon,
    async setDaemonActive(value) {
      daemon = value;
    },
    async launch() {
      launched = true;
    },
    async terminate() {
      launched = false;
    },
    async prepareTrustCycle() {},
    async publishTrustRequest() {},
    async publishRevocationReady() {},
    async awaitMobileReceipt() {},
    async waitStatus(kind) {
      return rawStatus(kind);
    },
    async reload() {},
    async restart() {},
    async capture(state, accessibility, image) {
      assert.equal(launched, true);
      write(
        image,
        png(
          { pending: 1, approved: 2, degraded: 3, recovered: 4, revoked: 5 }[
            state
          ],
        ),
      );
      json(accessibility, {
        producer: "openburnbar-p16-atspi-live-v1",
        capturedAt: new Date().toISOString(),
        application: "OpenBurnBar",
        route: "account",
        focusedName: "Account",
        statusText: statusText[state],
        namedNodes: [
          "Account",
          "Identity",
          "Sync",
          "Device",
          "Status",
          statusText[state],
        ],
      });
    },
    async restoreState() {
      restored += 1;
    },
    restored: () => restored,
    ...overrides,
  };
}
async function fixture() {
  const base = path.join(process.cwd(), ".tmp/p16-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const opts = options(root);
  const identity = attestation(root, path.join(root, "attestation"));
  Object.assign(opts, identity);
  const deps = fakeDependencies();
  const result = await runP16CloudDevicesWorkflow(opts, deps);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-16",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const materialized = materializeP16CloudDevicesSession(
    {
      ...opts,
      repoRoot: root,
      outputRoot: input,
      rawEvidenceDir: result.rawOutputDir,
    },
    {
      installedVerifier() {},
      manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath,
    },
  );
  return {
    root,
    opts,
    deps,
    input,
    session: materialized.document,
    sessionFile: materialized.output,
  };
}
function binding(value) {
  return { ...value.opts, repoRoot: value.root, candidateRunId: RUN };
}
function refresh(value, field, file) {
  value.session.evidence[field] = record(value.root, file);
}

test("P-16 closes the installed Linux cloud/device lifecycle with physical-iPad authority", async () => {
  const value = await fixture();
  try {
    assert.equal(value.deps.restored(), 1);
    assert.equal(
      validateP16InstalledSession(value.session, binding(value)).document
        .requirementId,
      "P-16",
    );
    const captured = captureP16CloudDevicesProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionFile,
      },
      { resolveHead: () => HEAD, now: () => new Date(END) },
    );
    assert.equal(captured.document.claim.physicalIPadAuthority, true);
    assert.equal(captured.document.claim.trustedDeviceApprovalRevocation, true);
    validateP16Proof({
      ...binding(value),
      snapshot: { bytes: fs.readFileSync(captured.output) },
    });
    assert.throws(
      () =>
        validateP16Proof({
          ...binding(value),
          candidateRunId: "999999",
          snapshot: { bytes: fs.readFileSync(captured.output) },
        }),
      /P-16/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-16 rejects leaks, replay, forged authority, stale provenance, optimistic recovery, and incomplete restoration", async () => {
  const mutations = [
    (value, native) => {
      native.refresh_token = "secret";
    },
    (value) => {
      value.session.marker.challenge = "f".repeat(64);
    },
    (_value, native) => {
      native.degradation.optimisticSuccess = true;
    },
    (_value, native) => {
      native.account.restarted.phase = "different";
    },
    (_value, native) => {
      native.restoration.cloudDevicesRestored = false;
    },
    (value, _native, mobile) => {
      mobile.physicalDevice.simulator = true;
    },
    (value, _native, mobile) => {
      mobile.events[1].callable = "linuxLocalApprove";
    },
    (value, _native, mobile) => {
      mobile.events[3].signedActionProof = false;
    },
    (value, _native, mobile) => {
      mobile.events[3].actionNonceHash = mobile.events[1].actionNonceHash;
    },
    (value, _native, mobile) => {
      mobile.linux.deviceIdHash = `sha256:${"9".repeat(64)}`;
    },
    (value, native) => {
      native.startedAt = "2020-01-01T00:00:00.000Z";
    },
    (value) => {
      const pending = path.join(
        value.root,
        value.session.evidence.pendingScreenshot.path,
      );
      const approved = path.join(
        value.root,
        value.session.evidence.approvedScreenshot.path,
      );
      fs.copyFileSync(pending, approved);
      refresh(value, "approvedScreenshot", approved);
    },
  ];
  for (const mutate of mutations) {
    const value = await fixture();
    try {
      const nativeFile = path.join(
        value.root,
        value.session.evidence.nativeTranscript.path,
      );
      const mobileFile = path.join(
        value.root,
        value.session.evidence.mobileReceipt.path,
      );
      const native = JSON.parse(fs.readFileSync(nativeFile, "utf8"));
      const mobile = JSON.parse(fs.readFileSync(mobileFile, "utf8"));
      mutate(value, native, mobile);
      json(nativeFile, native);
      json(mobileFile, mobile);
      refresh(value, "nativeTranscript", nativeFile);
      refresh(value, "mobileReceipt", mobileFile);
      assert.throws(
        () => validateP16InstalledSession(value.session, binding(value)),
        /P-16/u,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-16 workflow fails closed and aggregates restoration failures", async () => {
  const root = fs.mkdtempSync(path.join(process.cwd(), ".tmp/p16-workflow-"));
  const opts = options(root);
  try {
    const deps = fakeDependencies({
      async waitStatus(kind) {
        if (kind === "approved") return { ...rawStatus(kind), signedIn: false };
        return rawStatus(kind);
      },
      async restoreState() {
        throw new Error("forced restoration failure");
      },
    });
    await assert.rejects(
      () => runP16CloudDevicesWorkflow(opts, deps),
      (error) => error instanceof AggregateError && error.errors.length === 2,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("P-16 runner rejects a substituted mobile authority before evidence emission", async () => {
  const root = fs.mkdtempSync(path.join(process.cwd(), ".tmp/p16-authority-"));
  const opts = options(root);
  const substituted = JSON.parse(fs.readFileSync(opts.mobileReceipt, "utf8"));
  substituted.producer = "openburnbar-linux-self-approval-v1";
  json(opts.mobileReceipt, substituted);
  try {
    await assert.rejects(
      () => runP16CloudDevicesWorkflow(opts, fakeDependencies()),
      /physical-ipad/u,
    );
    assert.equal(
      fs.existsSync(
        path.join(opts.rawOutputDir, "cloud-devices-native-transcript.json"),
      ),
      false,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
