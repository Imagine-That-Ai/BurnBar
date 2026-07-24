import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP33ReliabilityProof } from "./capture-p33-reliability-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from "./lib/linux-installed-manifest.mjs";
import { validateP33InstalledSession, validateP33Proof } from "./lib/p33-reliability-proof.mjs";
import { materializeP33ReliabilitySession } from "./materialize-p33-reliability-session.mjs";
import { runP33ReliabilityWorkflow } from "./run-p33-native-reliability-probes.mjs";

const HEAD = "1".repeat(40);
const RUN = "333333";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-x86_64";
const VERSION = "1.2.3";
function hash(bytes) { return crypto.createHash("sha256").update(bytes).digest("hex"); }
function write(file, bytes, mode = 0o600) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); fs.chmodSync(file, mode); return file; }
function json(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function record(root, file) { const bytes = fs.readFileSync(file); return { path: path.relative(root, file).split(path.sep).join("/"), sha256: hash(bytes), size: bytes.length }; }
function chunk(type, data) { const name = Buffer.from(type); const output = Buffer.alloc(data.length + 12); output.writeUInt32BE(data.length); name.copy(output, 4); data.copy(output, 8); output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8); return output; }
function png(seed) {
  const width = 320; const height = 220; const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) { const at = y * (width * 3 + 1) + 1 + x * 3; raw[at] = (x + seed * 19) % 256; raw[at + 1] = (y + seed * 29) % 256; raw[at + 2] = (x + y + seed * 37) % 256; }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", zlib.deflateSync(raw, { level: 0 })), chunk("IEND", Buffer.alloc(0))]);
}
function attestation(root, directory) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  const privatePem = privateKey.export({ type: "pkcs8", format: "pem" });
  const publicPem = publicKey.export({ type: "spki", format: "pem" });
  write(path.join(root, "packaging/linux/openburnbar-linux-ed25519.pub.pem"), publicPem);
  const item = (installedPath, bytes, mode) => ({ path: installedPath, type: "file", sha256: hash(bytes), size: bytes.length, mode, uid: 0, gid: 0 });
  const manifest = canonicalJsonBytes(createInstalledManifest({ files: [item("/usr/bin/openburnbar-cli", Buffer.from("cli"), "0755"), item("/usr/bin/openburnbar-daemon", Buffer.from("daemon"), "0755"), item("/usr/bin/openburnbar-linux-desktop", Buffer.from("desktop"), "0755"), item("/usr/share/openburnbar/attestation/release-ed25519.pub.pem", publicPem, "0644")], packageVersion: VERSION, gitCommit: HEAD, packageArchitecture: "x86_64", packageFormat: "deb", firebaseAppId: "1:2:web:3" }));
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return { manifestPath: write(path.join(directory, "installed-manifest.json"), manifest), signaturePath: write(path.join(directory, "installed-manifest.json.sig"), signature), manifestSha256: hash(manifest), manifestSignatureSha256: hash(signature) };
}
function options(root) {
  return { rawOutputDir: path.join(root, "live/raw"), stateHome: path.join(root, "live/home"), environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN, candidateArtifactDigest: DIGEST, packageVersion: VERSION, manifestSha256: "0".repeat(64), manifestSignatureSha256: "0".repeat(64), compositor: "Mutter", desktop: "GNOME", displayServer: "X11" };
}
function fakeDependencies(_options, overrides = {}) {
  let daemon = false; let portal = false; let network = false; let launched = false; let restored = 0;
  const expected = { healthy: "Connected", degraded: "Daemon unavailable", recovered: "Connected", relaunched: "Connected" };
  return {
    platform: "linux", desktopSession: true, installedVerifier() {}, marker: "p33-0123456789abcdef", nonce: "3".repeat(32),
    identity: () => ({ architecture: "x86_64", format: "deb", cliVersion: VERSION, daemonVersion: VERSION, os: "linux", sessionType: "x11", displayServer: "X11", desktop: "GNOME", packageOwned: true }),
    daemonActive: () => daemon, async setDaemonActive(value) { daemon = value; },
    portalActive: () => portal, async setPortalActive(value) { portal = value; },
    networkEnabled: () => network, async setNetworkEnabled(value) { network = value; return { attemptsWhileOffline: 0 }; },
    desktopPids: () => [], async launch() { launched = true; }, async terminate() { launched = false; },
    async capture(state, name, accessibility, image) {
      assert.equal(launched, true); assert.equal(name, expected[state]);
      write(image, png({ healthy: 1, degraded: 2, recovered: 3, relaunched: 4 }[state]));
      json(accessibility, { schemaVersion: 1, capturedAt: new Date().toISOString(), application: "OpenBurnBar", route: "support", expectedName: name, expectedNamePresent: true, nodeCount: 30, namedNodeCount: 15, actionableNodeCount: 5, focusableNodeCount: 5, focusedNodes: [], roleCounts: { button: 5 }, namedSamples: [], actionableSamples: [], truncated: false, minimums: { nodes: 12, named: 6, actionable: 1 }, pass: true, failures: [], readinessAttempts: 1 });
    },
    async startSubscription() { return { id: "subscription-health-1", topic: "health", seq: 1, cursor: "1", backpressure: "bounded", disconnectDetected: false, recoveredAfterRestart: false, terminalStateDelivered: false }; },
    async resumeSubscription(previous) { return { ...previous, seq: previous.seq + 1, cursor: String(previous.seq + 1), disconnectDetected: true, recoveredAfterRestart: true }; },
    async stallSocket() { return { stallMillis: 3_000, timedOut: true, backoffMillis: [1_000, 2_000, 4_000], singleFlight: true, duplicateEvents: 0 }; },
    async suspendResume() { return { elapsedMillis: 2_000, recoveryMillis: 100 }; },
    async clockCycle() { return { changeMillis: 120_000, recoveryMillis: 100, restored: true }; },
    async keyringCycle() { return { lockedObserved: true, recoveryMillis: 100, restored: true }; },
    async databaseCycle() { return { lockedObserved: true, recoveryMillis: 100 }; },
    async scaleExercise() { return { rows10k: { requested: 10_000, returned: 10_000, latencyMillis: 100, bytes: 1_100_000 }, rows100k: { requested: 100_000, returned: 100_000, latencyMillis: 1_000, bytes: 11_000_000 }, largeTranscriptBytes: 11_000_000 }; },
    async pressureExercise() { return { lowMemoryRecovery: true, softwareRenderingRecovery: true }; },
    async soak() { return { durationMillis: 1_800_001, idleCycles: 60, useCycles: 60, healthFailures: 0, rssGrowthBytes: 1_024 }; },
    async restoreState() { restored += 1; }, restored: () => restored,
    ...overrides,
  };
}
async function fixture() {
  const base = path.join(process.cwd(), ".tmp/p33-proof-tests"); fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-")); const opts = options(root); const identity = attestation(root, path.join(root, "attestation")); Object.assign(opts, identity); const deps = fakeDependencies(opts);
  const result = await runP33ReliabilityWorkflow(opts, deps);
  const input = path.join(root, "docs/linux-port/evidence/product-parity-inputs/P-33", ENVIRONMENT); fs.mkdirSync(input, { recursive: true });
  const materialized = materializeP33ReliabilitySession({ ...opts, repoRoot: root, outputRoot: input, rawEvidenceDir: result.rawOutputDir }, { installedVerifier() {}, manifestPath: identity.manifestPath, signaturePath: identity.signaturePath });
  return { root, opts, deps, input, session: materialized.document, sessionFile: materialized.output };
}
function binding(value) { return { ...value.opts, repoRoot: value.root, candidateRunId: RUN }; }
function rewriteNative(value, mutate) {
  const file = path.join(value.root, value.session.evidence.nativeTranscript.path);
  const native = JSON.parse(fs.readFileSync(file)); mutate(native); json(file, native); value.session.evidence.nativeTranscript = record(value.root, file);
}

test("P-33 proves installed restart, lifecycle, pressure, soak, and exact restoration", async () => {
  const value = await fixture();
  try {
    assert.equal(value.deps.restored(), 1);
    assert.equal(validateP33InstalledSession(value.session, binding(value)).document.requirementId, "P-33");
    const captured = captureP33ReliabilityProof({ ...binding(value), inputRoot: value.input, sessionReport: value.sessionFile }, { resolveHead: () => HEAD, now: () => new Date() });
    assert.equal(captured.document.claim.longIdleUseStability, true);
    validateP33Proof({ ...binding(value), snapshot: { bytes: fs.readFileSync(captured.output) } });
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test("P-33 rejects stale, forged, partial, optimistic, replayed, and unrestored reliability receipts", async () => {
  const mutations = [
    (value) => rewriteNative(value, (native) => { native.startedAt = "2020-01-01T00:00:00.000Z"; }),
    (value) => { value.session.marker.package.format = "rpm"; },
    (value) => rewriteNative(value, (native) => { native.subscription.resumedSeq = native.subscription.initialSeq; }),
    (value) => rewriteNative(value, (native) => { native.subscription.duplicateEvents = 1; }),
    (value) => rewriteNative(value, (native) => { native.faultRecovery.stallTimedOut = false; }),
    (value) => rewriteNative(value, (native) => { native.environmentRecovery.attemptsWhileOffline = 1; }),
    (value) => rewriteNative(value, (native) => { native.environmentRecovery.clockChangeMillis = 5_000; }),
    (value) => rewriteNative(value, (native) => { native.scale.rows100k.returned = 99_999; }),
    (value) => rewriteNative(value, (native) => { native.soak.durationMillis = 1_799_999; }),
    (value) => rewriteNative(value, (native) => { native.soak.rssGrowthBytes = 67_108_865; }),
    (value) => rewriteNative(value, (native) => { native.restoration.networkEnabledAfter = !native.restoration.networkEnabledBefore; }),
  ];
  for (const mutate of mutations) {
    const value = await fixture();
    try { mutate(value); assert.throws(() => validateP33InstalledSession(value.session, binding(value)), /P-33/u); }
    finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
});

test("P-33 materialization rejects extra raw artifacts and capture refuses replay", async () => {
  const value = await fixture();
  try {
    const captured = captureP33ReliabilityProof({ ...binding(value), inputRoot: value.input, sessionReport: value.sessionFile }, { resolveHead: () => HEAD, now: () => new Date() });
    assert.ok(fs.existsSync(captured.output));
    assert.throws(() => captureP33ReliabilityProof({ ...binding(value), inputRoot: value.input, sessionReport: value.sessionFile }, { resolveHead: () => HEAD, now: () => new Date() }), /refuses to replace/u);
    const raw = path.join(value.root, "raw-extra"); fs.mkdirSync(raw, { mode: 0o700 });
    for (const name of fs.readdirSync(value.opts.rawOutputDir)) fs.copyFileSync(path.join(value.opts.rawOutputDir, name), path.join(raw, name));
    write(path.join(raw, "forged.json"), "{}\n");
    const output = path.join(value.root, "docs/linux-port/evidence/product-parity-inputs/P-33/extra"); fs.mkdirSync(output, { recursive: true });
    assert.throws(() => materializeP33ReliabilitySession({ ...value.opts, repoRoot: value.root, outputRoot: output, rawEvidenceDir: raw }, { installedVerifier() {} }), /exactly/u);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test("P-33 workflow aggregates primary and restoration failures", async () => {
  const root = fs.mkdtempSync(path.join(process.cwd(), ".tmp/p33-workflow-")); const opts = options(root);
  try {
    const deps = fakeDependencies(opts, { async stallSocket() { throw new Error("forced socket failure"); }, async restoreState() { throw new Error("forced restoration failure"); } });
    await assert.rejects(() => runP33ReliabilityWorkflow(opts, deps), (error) => error instanceof AggregateError && error.errors.length >= 2);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
