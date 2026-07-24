import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';
import { captureP10DashboardLayoutProof } from './capture-p10-dashboard-layout-proof.mjs';
import { pngCrc32, validatePng } from './lib/installed-ui-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import { materializeP10DashboardLayoutSession } from './materialize-p10-dashboard-layout-session.mjs';
import {
  P10_LAYOUTS,
  P10_PROOF_ROLE,
  P10_STATES,
  P10_VIEWPORTS,
  validateP10InstalledSession,
  validateP10Proof
} from './lib/p10-dashboard-layout-proof.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS, readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-10.mjs';

const HEAD = 'd'.repeat(40);
const RUN_ID = '67890';
const DIGEST = `sha256:${'e'.repeat(64)}`;
const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-aarch64';

function chunk(type, data) {
  const name = Buffer.from(type, 'ascii');
  const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length, 0); name.copy(output, 4); data.copy(output, 8);
  output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8);
  return output;
}
function png(width, height = 600, color = 2) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 2;
  const stride = width * 3;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    const base = y * (stride + 1);
    for (let x = 0; x < width; x += 1) {
      raw[base + 1 + x * 3] = color; raw[base + 2 + x * 3] = (color * 5) & 255; raw[base + 3 + x * 3] = (color * 11) & 255;
    }
  }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

function write(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return file;
}
function writeJson(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return { path: path.relative(root, file).split(path.sep).join('/'), sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length };
}

function attestation(root, inputRoot) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
  write(path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'), publicPem);
  const fileRecord = (installedPath, bytes, mode) => ({
    path: installedPath, type: 'file', sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length, mode, uid: 0, gid: 0
  });
  const manifest = createInstalledManifest({
    files: [
      fileRecord('/usr/bin/openburnbar-daemon', Buffer.from('daemon'), '0755'),
      fileRecord('/usr/bin/openburnbar-linux-desktop', Buffer.from('desktop'), '0755'),
      fileRecord('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicPem, '0644')
    ], packageVersion: '1.2.3', gitCommit: HEAD, packageArchitecture: 'aarch64', packageFormat: 'deb',
    firebaseAppId: '1:123:web:linux'
  });
  const manifestBytes = canonicalJsonBytes(manifest);
  const signatureBytes = signInstalledManifest(manifestBytes, privatePem, publicPem);
  const manifestFile = write(path.join(inputRoot, 'raw', 'installed-manifest.json'), manifestBytes);
  const signatureFile = write(path.join(inputRoot, 'raw', 'installed-manifest.json.sig'), signatureBytes);
  return { manifest: record(root, manifestFile), signature: record(root, signatureFile) };
}

function fixture() {
  const base = path.join(process.cwd(), '.tmp', 'p10-proof-tests');
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'case-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-10', ENVIRONMENT);
  const started = new Date(Date.now() - 60_000).toISOString();
  const ended = new Date(Date.now() - 1_000).toISOString();
  const installed = attestation(root, inputRoot);
  const captures = [];
  let captureIndex = 0;
  for (const layout of P10_LAYOUTS) for (const viewport of P10_VIEWPORTS) {
    const key = `${layout}-${viewport}`;
    const width = viewport === 'desktop' ? 1280 : 600;
    captureIndex += 1;
    const persistedAt = new Date(Date.parse(started) + captureIndex * 3 * 1_000).toISOString();
    const persistedPid = 1001 + captureIndex * 2;
    const windowId = String(80 + captureIndex);
    const screenshotFile = write(path.join(inputRoot, 'raw', `${key}.png`), png(width, 600, captureIndex));
    const screenshot = record(root, screenshotFile);
    const atspiFile = writeJson(path.join(inputRoot, 'raw', `${key}-atspi.json`), {
      producer: 'openburnbar-p10-native-dashboard-probe-v1', appPid: persistedPid, windowId,
      capturedAt: persistedAt, desktop: 'GNOME', displayServer: 'Wayland',
      manifestSha256: installed.manifest.sha256, layout, viewport,
      expectedName: `${layout[0].toUpperCase()}${layout.slice(1)} dashboard layout`,
      expectedNamePresent: true, nodeCount: 80, namedNodeCount: 40, actionableNodeCount: 12,
      namedSamples: [{ role: 'dashboard', name: `${layout} ${viewport}`, states: ['visible'], actions: ['focus'] }]
    });
    const atspi = record(root, atspiFile);
    const geometryFile = writeJson(path.join(inputRoot, 'raw', `${key}-geometry.json`), {
      producer: 'openburnbar-p10-live-geometry-probe-v1', capturedAt: new Date(Date.parse(started) + (captureIndex * 3) * 1_000).toISOString(),
      sourceAtspiSha256: atspi.sha256, nodesInspected: 80,
      clippedElements: [], overlaps: [], textOverflow: [], unreadableText: []
    });
    const geometry = record(root, geometryFile);
    const auditFile = writeJson(path.join(inputRoot, 'raw', `${key}-pixels.json`), {
      producer: 'openburnbar-p10-materializer-v1', screenshotSha256: screenshot.sha256,
      geometrySha256: geometry.sha256, width, height: 600, nonBlankPixelRatio: 1,
      clippedElementCount: 0, overlapFindingCount: 0, textOverflowCount: 0, unreadableTextCount: 0
    });
    const eventFile = writeJson(path.join(inputRoot, 'raw', `${key}-events.json`), {
      producer: 'openburnbar-p10-native-layout-probe-v1',
      events: ['layout-selected-atspi', 'app-relaunched', 'persisted-layout-readback']
        .map((kind, index) => ({
          appPid: index === 0 ? 1000 + captureIndex * 2 : 1001 + captureIndex * 2,
          windowId, at: new Date(Date.parse(started) + ((captureIndex - 1) * 3 + index + 1) * 1_000).toISOString(),
          desktop: 'GNOME', displayServer: 'Wayland', manifestSha256: installed.manifest.sha256,
          kind, layout, passed: true, viewport
        }))
    });
    const daemonFile = writeJson(path.join(inputRoot, 'raw', `${key}-daemon.json`), {
      producer: 'openburnbar-cli-live-dashboard-probe-v1', connected: true, fixtureMode: false,
      providerCount: 5, usagePointCount: 20
    });
    captures.push({
      layout, viewport, renderBackend: 'webkitgtk-installed-dashboard',
      events: record(root, eventFile), daemon: record(root, daemonFile),
      screenshot, atspi, geometry, pixelAudit: record(root, auditFile)
    });
  }
  const stateOrder = ['loading', 'populated', 'offline', 'error'];
  const stateEventFile = writeJson(path.join(inputRoot, 'raw', 'dashboard-state-events.json'), {
    producer: 'openburnbar-p10-native-state-probe-v1',
    events: stateOrder.map((state, index) => ({
      appPid: 9000, windowId: '99', at: new Date(Date.parse(started) + (40 + index) * 1_000).toISOString(),
      desktop: 'GNOME', displayServer: 'Wayland', manifestSha256: installed.manifest.sha256,
      state, passed: true
    }))
  });
  const stateSnapshots = stateOrder.map((state) => {
    const index = stateOrder.indexOf(state);
    const capturedAt = new Date(Date.parse(started) + (40 + index) * 1_000).toISOString();
    const stateFile = writeJson(path.join(inputRoot, 'raw', `dashboard-state-${state}-atspi.json`), {
      producer: 'openburnbar-p10-native-state-probe-v1', appPid: 9000, windowId: '99',
      capturedAt, desktop: 'GNOME', displayServer: 'Wayland', manifestSha256: installed.manifest.sha256,
      state, expectedNamePresent: true, ariaBusy: state === 'loading', layoutNamePresent: state === 'populated',
      statusRolePresent: state === 'offline', alertRolePresent: state === 'error'
    });
    return { state, atspi: record(root, stateFile) };
  });
  const session = {
    schemaVersion: 1, id: 'openburnbar-linux-p10-installed-session-v1', requirementId: 'P-10',
    environmentId: ENVIRONMENT, targetHead: HEAD, candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    package: { architecture: 'aarch64', format: 'deb', installed: true, manifest: installed.manifest, signature: installed.signature, source: 'verified-live-installed-candidate', version: '1.2.3' },
    desktop: { compositor: 'Mutter', desktop: 'GNOME', displayServer: 'Wayland', liveSession: true },
    capture: { startedAt: started, endedAt: ended, fixtureMode: false, method: 'installed-live-product-session' },
    captures,
    states: { eventLog: record(root, stateEventFile), snapshots: stateSnapshots }
  };
  const sessionReport = writeJson(path.join(inputRoot, 'p10-installed-dashboard-layout-session.json'), session);
  return { root, inputRoot, session, sessionReport, ended, installed };
}

function binding(value) {
  return {
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST,
    packageVersion: '1.2.3', manifestSha256: value.installed.manifest.sha256,
    manifestSignatureSha256: value.installed.signature.sha256
  };
}

function requirementContext(value, proofFile) {
  const subjectRoot = path.join(value.inputRoot, 'release-subjects');
  const aggregate = record(value.root, writeJson(path.join(subjectRoot, 'aggregate.json'), { passed: true }));
  const manifest = value.installed.manifest;
  const runtime = record(value.root, writeJson(path.join(subjectRoot, 'runtime.json'), { shellVersion: '1.2.3', daemonVersion: '1.2.3' }));
  const environment = record(value.root, writeJson(path.join(subjectRoot, 'environment.json'), {
    environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'aarch64', passed: true
  }));
  const signature = value.installed.signature;
  const nativePackage = record(value.root, write(path.join(subjectRoot, 'package.deb'), 'package\n'));
  const proof = record(value.root, proofFile);
  return {
    schemaVersion: 1, repoRoot: value.root, requirementId: 'P-10', checkId: 'p-10.dashboard-layouts',
    environmentId: ENVIRONMENT, targetHead: HEAD,
    releaseClosure: { document: {
      schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed', requirementId: 'P-10',
      environmentId: ENVIRONMENT, version: '1.2.3', blockers: [], architectures: [...RELEASE_ARCHITECTURES],
      supportEnvironments: [...SUPPORT_ENVIRONMENTS], selectedPackage: { architecture: 'aarch64', format: 'deb' },
      candidate: { runId: RUN_ID, artifactDigest: DIGEST }, packageManifestSignature: signature,
      proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P10_PROOF_ROLE, ...proof }]
    } },
    subjects: { release: aggregate, packageManifest: manifest, packages: [nativePackage], runtimes: [runtime], installation: [aggregate], environment, features: [] }
  };
}

test('P-10 collector accepts six installed layouts at desktop and compact widths', async () => {
  const value = fixture();
  try {
    const captured = captureP10DashboardLayoutProof({
      repoRoot: value.root, inputRoot: value.inputRoot, sessionReport: value.sessionReport,
      ...binding(value), resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 1_000)
    });
    assert.deepEqual(JSON.parse(fs.readFileSync(captured.registration, 'utf8')).artifacts, [
      { role: P10_PROOF_ROLE, path: 'feature-artifacts/dashboard-layouts-installed.json' }
    ]);
    const proofPath = path.relative(value.root, captured.output).split(path.sep).join('/');
    const result = validateP10Proof({ repoRoot: value.root, snapshot: readRegularSnapshot(value.root, proofPath, 'proof'), ...binding(value) });
    assert.equal(result.proof.claim.captureCount, 12);
    assert.equal(result.evidence.length, 79);
    assert.equal((await validateProductRequirement(requirementContext(value, captured.output))).status, 'passed');
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-10 rejects incomplete matrices, fixtures, false persistence, and visual defects', () => {
  for (const [label, mutate, pattern] of [
      ['missing viewport', (doc) => { doc.captures.pop(); }, /every dashboard layout/u],
      ['cross-environment replay', (doc) => { doc.captures[0].screenshot.path = doc.captures[0].screenshot.path.replace(ENVIRONMENT, 'fedora-kde-wayland-aarch64'); }, /evidence root/u],
      ['candidate mismatch', (doc) => { doc.candidate.runId = '999'; }, /selected release candidate/u],
      ['fixture content', (doc, value) => {
        const file = path.join(value.root, doc.captures[0].daemon.path);
        const daemon = JSON.parse(fs.readFileSync(file, 'utf8')); daemon.fixtureMode = true; writeJson(file, daemon);
        doc.captures[0].daemon = record(value.root, file);
      }, /live daemon content/u],
      ['persistence', (doc, value) => {
        const file = path.join(value.root, doc.captures[0].events.path);
        const events = JSON.parse(fs.readFileSync(file, 'utf8')); events.events[2].passed = false; writeJson(file, events);
        doc.captures[0].events = record(value.root, file);
      }, /relaunch persistence/u],
      ['states', (doc) => { doc.states.snapshots.pop(); }, /state transition evidence is incomplete/u],
      ['layout AT-SPI identity', (doc, value) => {
        const row = doc.captures[0];
        const file = path.join(value.root, row.atspi.path);
        const tree = JSON.parse(fs.readFileSync(file, 'utf8')); tree.appPid += 1; writeJson(file, tree);
        row.atspi = record(value.root, file);
      }, /selected installed dashboard layout/u],
      ['state AT-SPI identity', (doc, value) => {
        const row = doc.states.snapshots[0];
        const file = path.join(value.root, row.atspi.path);
        const tree = JSON.parse(fs.readFileSync(file, 'utf8')); tree.windowId = 'replayed'; writeJson(file, tree);
        row.atspi = record(value.root, file);
      }, /state lacks installed AT-SPI semantics/u],
      ['invalid png crc', (doc, value) => {
        const file = path.join(value.root, doc.captures[0].screenshot.path);
        const bytes = fs.readFileSync(file); bytes[50] ^= 0xff; fs.writeFileSync(file, bytes);
        doc.captures[0].screenshot = record(value.root, file);
      }, /PNG CRC/u],
      ['overlap', (doc, value) => {
        const row = doc.captures[0];
        const file = path.join(value.root, row.pixelAudit.path);
        const audit = JSON.parse(fs.readFileSync(file, 'utf8'));
        audit.overlapFindingCount = 1;
        writeJson(file, audit);
        row.pixelAudit = record(value.root, file);
      }, /nonblank, unclipped/u]
    ]) {
    const value = fixture();
    try {
      const doc = structuredClone(value.session);
      mutate(doc, value);
      assert.throws(() => validateP10InstalledSession(doc, binding(value), { repoRoot: value.root }), pattern, label);
    } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
});

test('P-10 PNG validation rejects oversized decode dimensions before inflation', () => {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(8192, 0); ihdr.writeUInt32BE(8192, 4); ihdr[8] = 8; ihdr[9] = 2;
  const oversized = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(Buffer.from([0]))), chunk('IEND', Buffer.alloc(0))
  ]);
  assert.throws(() => validatePng(oversized, 'oversized capture'), /format or dimensions are unsupported/u);
});

test('P-10 materializer derives layout evidence and pixel audits from live artifacts', () => {
  const value = fixture();
  try {
    const rawRoot = path.join(value.root, 'live-p10-layouts');
    fs.mkdirSync(rawRoot);
    const copy = (recordValue, name) => fs.copyFileSync(path.join(value.root, recordValue.path), path.join(rawRoot, name));
    copy(value.installed.manifest, 'installed-manifest.json');
    copy(value.installed.signature, 'installed-manifest.json.sig');
    for (const row of value.session.captures) {
      const key = `${row.layout}-${row.viewport}`;
      copy(row.events, `layout-${key}-events.json`); copy(row.daemon, `layout-${key}-daemon.json`);
      copy(row.screenshot, `layout-${key}.png`); copy(row.atspi, `layout-${key}-atspi.json`);
      copy(row.geometry, `layout-${key}-geometry.json`);
    }
    copy(value.session.states.eventLog, 'dashboard-state-events.json');
    for (const row of value.session.states.snapshots) copy(row.atspi, `dashboard-state-${row.state}-atspi.json`);
    fs.rmSync(value.inputRoot, { recursive: true, force: true });
    fs.mkdirSync(value.inputRoot, { recursive: true });
    const result = materializeP10DashboardLayoutSession({
      repoRoot: value.root, outputRoot: value.inputRoot, rawEvidenceDir: rawRoot,
      ...binding(value), compositor: 'Mutter', renderBackend: 'webkitgtk-installed-dashboard'
    }, {
      installedVerifier: () => ({ passed: true }),
      manifestPath: path.join(rawRoot, 'installed-manifest.json'),
      signaturePath: path.join(rawRoot, 'installed-manifest.json.sig')
    });
    assert.equal(result.document.captures.length, 12);
    assert.equal(result.document.captures[0].pixelAudit.path.includes(ENVIRONMENT), true);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-10 rejects forged and unsigned installed manifest signatures', () => {
  const value = fixture();
  try {
    for (const bytes of [Buffer.alloc(64, 9), Buffer.alloc(0)]) {
      const doc = structuredClone(value.session);
      const signatureFile = path.join(value.root, doc.package.signature.path);
      fs.writeFileSync(signatureFile, bytes);
      doc.package.signature = record(value.root, signatureFile);
      const forgedBinding = { ...binding(value), manifestSignatureSha256: doc.package.signature.sha256 };
      assert.throws(() => validateP10InstalledSession(doc, forgedBinding, { repoRoot: value.root }), /signature/u);
    }
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-10 rejects Xvfb, stale collection, and changed session bytes', () => {
  const value = fixture();
  try {
    const synthetic = structuredClone(value.session);
    synthetic.desktop.compositor = 'Xvfb';
    assert.throws(() => validateP10InstalledSession(synthetic, binding(value), { repoRoot: value.root }), /real Linux desktop/u);
    assert.throws(() => captureP10DashboardLayoutProof({
      repoRoot: value.root, inputRoot: value.inputRoot, sessionReport: value.sessionReport,
      ...binding(value), resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 20 * 60_000)
    }), /stale/u);
    const captured = captureP10DashboardLayoutProof({
      repoRoot: value.root, inputRoot: value.inputRoot, sessionReport: value.sessionReport,
      ...binding(value), resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 1_000)
    });
    fs.appendFileSync(value.sessionReport, '\n');
    const proofPath = path.relative(value.root, captured.output).split(path.sep).join('/');
    assert.throws(() => validateP10Proof({ repoRoot: value.root, snapshot: readRegularSnapshot(value.root, proofPath, 'proof'), ...binding(value) }), /bytes changed/u);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});
