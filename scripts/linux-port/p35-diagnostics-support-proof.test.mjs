import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP35DiagnosticsSupportProof } from "./capture-p35-diagnostics-support-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from "./lib/linux-installed-manifest.mjs";
import { validateP35InstalledSession, validateP35Proof } from "./lib/p35-diagnostics-support-proof.mjs";
import { materializeP35DiagnosticsSupportSession } from "./materialize-p35-diagnostics-support-session.mjs";
import { runP35DiagnosticsSupportWorkflow } from "./run-p35-native-diagnostics-probes.mjs";

const HEAD = "1".repeat(40);
const RUN = "353535";
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
  const manifest = canonicalJsonBytes(createInstalledManifest({ files: [item("/usr/bin/openburnbar-daemon", Buffer.from("daemon"), "0755"), item("/usr/bin/openburnbar-linux-desktop", Buffer.from("desktop"), "0755"), item("/usr/share/openburnbar/attestation/release-ed25519.pub.pem", publicPem, "0644")], packageVersion: VERSION, gitCommit: HEAD, packageArchitecture: "x86_64", packageFormat: "deb", firebaseAppId: "1:2:web:3" }));
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return { manifestPath: write(path.join(directory, "installed-manifest.json"), manifest), signaturePath: write(path.join(directory, "installed-manifest.json.sig"), signature), manifestSha256: hash(manifest), manifestSignatureSha256: hash(signature) };
}
function options(root) {
  return { rawOutputDir: path.join(root, "live/raw"), stateHome: path.join(root, "live/home"), destinationDir: path.join(root, "live/destination"), environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN, candidateArtifactDigest: DIGEST, packageVersion: VERSION, manifestSha256: "0".repeat(64), manifestSignatureSha256: "0".repeat(64), compositor: "Mutter", desktop: "GNOME", displayServer: "X11" };
}
function fakeDependencies(options, overrides = {}) {
  let daemon = false; let launched = false; let restored = 0;
  const planted = "p35-planted-secret";
  const bundle = {
    schemaVersion: 1, exportedAt: 42, shellVersion: VERSION,
    daemonHealth: { ok: true, daemonVersion: VERSION, protocolVersion: 1 },
    package: { channel: "deb", manager: "dpkg", evidence: "dpkg-query:openburnbar" },
    runtime: { os: "linux", architecture: "x86_64", kernel: "6.8.0", sessionType: "x11", desktop: "GNOME", displayServer: "x11" },
    renderer: { shell: "tauri", webview: "webkitgtk", capabilities: ["support.diagnostics.export", "support.diagnostics.preview"] },
    included: ["shell version", "daemon health (ok, version, protocol)", "package channel and runtime facts", "renderer and capability facts", "export schema and file permissions"],
    excluded: ["provider API keys and credentials", "socket auth tokens", "provider response payloads", "user session content"],
  };
  const expected = { preview: "Diagnostics export", exported: "Export written", degraded: "Daemon unavailable", recovered: "Connected" };
  return {
    platform: "linux", desktopSession: true, installedVerifier() {}, marker: "p35-0123456789abcdef", nonce: "3".repeat(32), plantedSecrets: [planted],
    identity: () => ({ architecture: "x86_64", format: "deb", packageOwned: true }),
    desktopPids: () => [], daemonActive: () => daemon,
    async setDaemonActive(value) { daemon = value; }, async launch() { launched = true; }, async reloadSupport() {}, async waitForText() {},
    async capture(state, name, accessibility, image) {
      assert.equal(launched, true); assert.equal(name, expected[state]);
      write(image, png({ preview: 1, exported: 2, degraded: 3, recovered: 4 }[state]));
      json(accessibility, { schemaVersion: 1, capturedAt: new Date().toISOString(), application: "OpenBurnBar", route: "support", expectedName: name, expectedNamePresent: true, nodeCount: 30, namedNodeCount: 15, actionableNodeCount: 5, focusableNodeCount: 5, focusedNodes: [], roleCounts: { button: 5 }, namedSamples: [], actionableSamples: [], truncated: false, minimums: { nodes: 12, named: 6, actionable: 1 }, pass: true, failures: [], readinessAttempts: 1 });
    },
    async exportDiagnostics() { const file = path.join(options.destinationDir, "openburnbar-diagnostics-42.json"); const bytes = Buffer.from(`${JSON.stringify(bundle, null, 2)}\n`); write(file, bytes); return { path: file, preview: { schemaVersion: 1, byteCount: bytes.length, fileMode: "0600", included: bundle.included, excluded: bundle.excluded }, atomic: true, partialArtifacts: 0 }; },
    async reconnect(healthy) { return { healthy, visible: true, attemptCount: 1 }; }, async terminate() {}, async restoreState() { restored += 1; }, restored: () => restored,
    ...overrides,
  };
}
async function fixture() {
  const base = path.join(process.cwd(), ".tmp/p35-proof-tests"); fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-")); const opts = options(root); const identity = attestation(root, path.join(root, "attestation")); Object.assign(opts, identity); const deps = fakeDependencies(opts);
  const result = await runP35DiagnosticsSupportWorkflow(opts, deps);
  const input = path.join(root, "docs/linux-port/evidence/product-parity-inputs/P-35", ENVIRONMENT); fs.mkdirSync(input, { recursive: true });
  const materialized = materializeP35DiagnosticsSupportSession({ ...opts, repoRoot: root, outputRoot: input, rawEvidenceDir: result.rawOutputDir }, { installedVerifier() {}, manifestPath: identity.manifestPath, signaturePath: identity.signaturePath });
  return { root, opts, deps, input, session: materialized.document, sessionFile: materialized.output, nativeFile: path.join(input, materialized.document.evidence.nativeTranscript.path.split("/").at(-1) ?? "") };
}
function binding(value) { return { ...value.opts, repoRoot: value.root, candidateRunId: RUN }; }
function refresh(value, field, file) { value.session.evidence[field] = record(value.root, file); }

test("P-35 production contract proves export, degraded reconnect, recovery, and restoration", async () => {
  const value = await fixture();
  try {
    assert.equal(value.deps.restored(), 1);
    assert.equal(validateP35InstalledSession(value.session, binding(value), { repoRoot: value.root }).document.requirementId, "P-35");
    const captured = captureP35DiagnosticsSupportProof({ ...binding(value), inputRoot: value.input, sessionReport: value.sessionFile }, { resolveHead: () => HEAD, now: () => new Date() });
    assert.equal(captured.document.claim.metadataOnlyExport, true);
    validateP35Proof({ ...binding(value), snapshot: { bytes: fs.readFileSync(captured.output) } });
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test("P-35 rejects leakage, stale or replayed receipts, unsafe output, optimistic reconnect, forged provenance, and failed restoration", async () => {
  const mutations = [
    (value, native) => { const exportFile = path.join(value.root, value.session.evidence.exportBundle.path); const bundle = JSON.parse(fs.readFileSync(exportFile)); bundle.providerPayload = "sk-leaked"; json(exportFile, bundle); refresh(value, "exportBundle", exportFile); native.export.byteCount = fs.statSync(exportFile).size; native.export.sha256 = hash(fs.readFileSync(exportFile)); },
    (_value, native) => { native.startedAt = "2020-01-01T00:00:00.000Z"; },
    (value, native) => { value.session.marker.challenge = "f".repeat(64); native.challenge = value.session.marker.challenge; },
    (_value, native) => { native.export.mode = "0644"; },
    (_value, native) => { native.export.path = "/tmp/../unsafe.json"; },
    (_value, native) => { native.degradation.optimisticSuccess = true; },
    (value) => { value.session.marker.package.format = "rpm"; },
    (_value, native) => { native.restoration.isolatedStateRestored = false; },
  ];
  for (const mutate of mutations) {
    const value = await fixture();
    try {
      const nativeFile = path.join(value.root, value.session.evidence.nativeTranscript.path);
      const native = JSON.parse(fs.readFileSync(nativeFile)); mutate(value, native); json(nativeFile, native); refresh(value, "nativeTranscript", nativeFile);
      assert.throws(() => validateP35InstalledSession(value.session, binding(value), { repoRoot: value.root }), /P-35/u);
    } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
});

test("P-35 workflow fails closed on planted-secret leakage and aggregates restoration failure", async () => {
  const root = fs.mkdtempSync(path.join(process.cwd(), ".tmp/p35-workflow-")); const opts = options(root);
  try {
    const deps = fakeDependencies(opts, {
      async exportDiagnostics() { const file = path.join(opts.destinationDir, "openburnbar-diagnostics-42.json"); const bytes = Buffer.from(`${JSON.stringify({ providerPayload: "p35-planted-secret" })}\n`); write(file, bytes); return { path: file, preview: { schemaVersion: 1, byteCount: bytes.length, fileMode: "0600" }, atomic: true, partialArtifacts: 0 }; },
      async restoreState() { throw new Error("forced restoration failure"); },
    });
    await assert.rejects(() => runP35DiagnosticsSupportWorkflow(opts, deps), (error) => error instanceof AggregateError && error.errors.length === 2);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
