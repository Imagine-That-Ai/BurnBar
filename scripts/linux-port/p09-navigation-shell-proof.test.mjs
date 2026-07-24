import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';
import { captureP09NavigationShellProof } from './capture-p09-navigation-shell-proof.mjs';
import { pngCrc32 } from './lib/installed-ui-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import { materializeP09NavigationShellSession } from './materialize-p09-navigation-shell-session.mjs';
import {
  P09_PROOF_ROLE,
  P09_REQUIRED_ROUTES,
  validateP09InstalledSession,
  validateP09Proof
} from './lib/p09-navigation-shell-proof.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS, readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-09.mjs';

const HEAD = 'a'.repeat(40);
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';

function chunk(type, data) {
  const name = Buffer.from(type, 'ascii');
  const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length, 0); name.copy(output, 4); data.copy(output, 8);
  output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8);
  return output;
}

function png(width = 320, height = 200, color = 1) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 2;
  const stride = width * 3;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    const base = y * (stride + 1); raw[base] = 0;
    for (let x = 0; x < width; x += 1) {
      raw[base + 1 + x * 3] = color; raw[base + 2 + x * 3] = (color * 3) & 255; raw[base + 3 + x * 3] = (color * 7) & 255;
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
    ], packageVersion: '1.2.3', gitCommit: HEAD, packageArchitecture: 'x86_64', packageFormat: 'deb',
    firebaseAppId: '1:123:web:linux'
  });
  const manifestBytes = canonicalJsonBytes(manifest);
  const signatureBytes = signInstalledManifest(manifestBytes, privatePem, publicPem);
  const manifestFile = write(path.join(inputRoot, 'raw', 'installed-manifest.json'), manifestBytes);
  const signatureFile = write(path.join(inputRoot, 'raw', 'installed-manifest.json.sig'), signatureBytes);
  return { manifest: record(root, manifestFile), signature: record(root, signatureFile) };
}

function fixture() {
  const base = path.join(process.cwd(), '.tmp', 'p09-proof-tests');
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'case-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-09', ENVIRONMENT);
  const started = new Date(Date.now() - 60_000).toISOString();
  const ended = new Date(Date.now() - 1_000).toISOString();
  const installed = attestation(root, inputRoot);
  const samples = [];
  const labels = [
    'Overview', 'Insights', 'Database', 'Providers & models', 'Projects', 'Missions',
    'Activity & logs', 'Chat / Hermes', 'Memory', 'Settings', 'Account & sync', 'Updates',
    'Support & diagnostics', 'First-run setup', 'Pet companion', 'Text expansion',
    'Computer Use', 'Mercury', 'SmartHub / IoT'
  ];
  const routes = P09_REQUIRED_ROUTES.map((route, index) => {
    const capturedAt = new Date(Date.parse(started) + (index + 1) * 1_000).toISOString();
    const windowId = String(100 + index);
    samples.push(JSON.stringify({ name: 'route.navigation', ms: 20, at: ended, source: `packaged-ui-route-after-paint:${route}` }));
    const atspiFile = writeJson(path.join(inputRoot, 'raw', `atspi-${route}.json`), {
      producer: 'openburnbar-p09-native-route-probe-v1', appPid: 1234, windowId,
      capturedAt, desktop: 'GNOME', displayServer: 'X11', manifestSha256: installed.manifest.sha256,
      route, expectedName: labels[index], expectedNamePresent: true,
      nodeCount: 40, namedNodeCount: 20, actionableNodeCount: 8,
      namedSamples: [{ role: 'page', name: labels[index], states: ['visible'], actions: ['activate'] }]
    });
    const screenshotFile = write(path.join(inputRoot, 'raw', `route-${route}.png`), png(320, 200, index + 1));
    const windowFile = writeJson(path.join(inputRoot, 'raw', `window-${route}.json`), {
      producer: 'openburnbar-p09-native-route-window-probe-v1', appPid: 1234, windowId,
      capturedAt, desktop: 'GNOME', displayServer: 'X11', manifestSha256: installed.manifest.sha256,
      route, visible: true, focused: true, geometry: { x: index, y: index, width: 1280, height: 800 }
    });
    return {
      index, route, expectedName: labels[index], activated: true,
      appPid: 1234, windowId, capturedAt,
      navMethod: 'atspi-command-palette-actions', atspi: record(root, atspiFile),
      screenshot: record(root, screenshotFile), window: record(root, windowFile)
    };
  });
  const perfFile = write(path.join(inputRoot, 'raw', 'runtime-perf-samples.jsonl'), `${samples.join('\n')}\n`);
  const deepLinks = ['provider', 'model'].map((kind, index) => {
    const capturedAt = new Date(Date.parse(started) + (14 + index * 10) * 1_000).toISOString();
    const atspiFile = writeJson(path.join(inputRoot, 'raw', `deep-${kind}-atspi.json`), {
      producer: 'openburnbar-p09-native-deep-link-probe-v1', appPid: 1234, windowId: '44',
      capturedAt, desktop: 'GNOME', displayServer: 'X11', manifestSha256: installed.manifest.sha256,
      expectedName: 'Providers & models', expectedNamePresent: true, nodeCount: 40,
      namedNodeCount: 20, actionableNodeCount: 8,
      namedSamples: [{ role: 'page', name: `Providers ${kind}`, states: ['visible'], actions: ['focus'] }]
    });
    const screenshotFile = write(path.join(inputRoot, 'raw', `deep-${kind}.png`), png(320, 200, 30 + index));
    const uri = kind === 'model' ? 'openburnbar://providers?provider=codex&model=gpt-5' : 'openburnbar://providers?provider=codex';
    const eventFile = writeJson(path.join(inputRoot, 'raw', `deep-${kind}-events.json`), {
      producer: 'openburnbar-p09-native-deep-link-probe-v1',
      events: ['native-link-accepted', 'single-instance-forwarded', 'history-reload-restored', 'back-forward-restored', 'focus-restored']
        .map((eventKind, eventIndex) => ({
          appPid: 1234, windowId: '44', at: new Date(Date.parse(started) + (10 + index * 10 + eventIndex) * 1_000).toISOString(),
          desktop: 'GNOME', displayServer: 'X11', manifestSha256: installed.manifest.sha256,
          kind: eventKind, passed: true, uri
        }))
    });
    return {
      kind,
      uri,
      selectedProviderId: 'codex', selectedModelId: kind === 'model' ? 'gpt-5' : null,
      eventLog: record(root, eventFile), atspi: record(root, atspiFile), screenshot: record(root, screenshotFile)
    };
  });
  const windowFile = writeJson(path.join(inputRoot, 'raw', 'native-window-events.json'), {
    producer: 'openburnbar-p09-native-window-probe-v1',
    events: ['secondary-window-opened', 'secondary-window-closed-focus-restored', 'relaunch-state-restored', 'multi-monitor-geometry-restored', 'geometry-bounds-verified']
      .map((kind, index) => ({
        appPid: index < 2 ? 1234 : 5678, windowId: String(45 + index),
        at: new Date(Date.parse(started) + (35 + index) * 1_000).toISOString(), desktop: 'GNOME',
        displayServer: 'X11', manifestSha256: installed.manifest.sha256,
        kind, passed: true, geometry: { x: index, y: index, width: 900, height: 700 }
      }))
  });
  const session = {
    schemaVersion: 1, id: 'openburnbar-linux-p09-installed-session-v1', requirementId: 'P-09',
    environmentId: ENVIRONMENT, targetHead: HEAD, candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    package: { architecture: 'x86_64', format: 'deb', installed: true, manifest: installed.manifest, signature: installed.signature, source: 'verified-live-installed-candidate', version: '1.2.3' },
    desktop: { compositor: 'Mutter', desktop: 'GNOME', displayServer: 'X11', liveSession: true },
    capture: { startedAt: started, endedAt: ended, fixtureMode: false, method: 'installed-live-product-session' },
    navigation: { method: 'atspi-command-palette-actions', perfSamples: record(root, perfFile), routes },
    deepLinks,
    windows: record(root, windowFile)
  };
  const sessionReport = writeJson(path.join(inputRoot, 'p09-installed-navigation-shell-session.json'), session);
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
    environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'x86_64', passed: true
  }));
  const signature = value.installed.signature;
  const nativePackage = record(value.root, write(path.join(subjectRoot, 'package.deb'), 'package\n'));
  const proof = record(value.root, proofFile);
  return {
    schemaVersion: 1, repoRoot: value.root, requirementId: 'P-09', checkId: 'p-09.navigation-and-shell',
    environmentId: ENVIRONMENT, targetHead: HEAD,
    releaseClosure: { document: {
      schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed', requirementId: 'P-09',
      environmentId: ENVIRONMENT, version: '1.2.3', blockers: [], architectures: [...RELEASE_ARCHITECTURES],
      supportEnvironments: [...SUPPORT_ENVIRONMENTS], selectedPackage: { architecture: 'x86_64', format: 'deb' },
      candidate: { runId: RUN_ID, artifactDigest: DIGEST }, packageManifestSignature: signature,
      proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P09_PROOF_ROLE, ...proof }]
    } },
    subjects: { release: aggregate, packageManifest: manifest, packages: [nativePackage], runtimes: [runtime], installation: [aggregate], environment, features: [] }
  };
}

test('P-09 collector accepts exact signed installed route, deep-link, and window evidence', async () => {
  const value = fixture();
  try {
    const captured = captureP09NavigationShellProof({
      repoRoot: value.root, inputRoot: value.inputRoot, sessionReport: value.sessionReport,
      ...binding(value), resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 1_000)
    });
    assert.deepEqual(JSON.parse(fs.readFileSync(captured.registration, 'utf8')).artifacts, [
      { role: P09_PROOF_ROLE, path: 'feature-artifacts/navigation-shell-installed.json' }
    ]);
    const proofPath = path.relative(value.root, captured.output).split(path.sep).join('/');
    const result = validateP09Proof({ repoRoot: value.root, snapshot: readRegularSnapshot(value.root, proofPath, 'proof'), ...binding(value) });
    assert.equal(result.proof.claim.routeCount, 19);
    assert.equal(result.evidence.length, 67);
    assert.equal((await validateProductRequirement(requirementContext(value, captured.output))).status, 'passed');
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-09 rejects synthetic desktops, missing routes, bad deep links, and incomplete windows', () => {
  const value = fixture();
  try {
    for (const [label, mutate, pattern] of [
      ['synthetic desktop', (doc) => { doc.desktop.compositor = 'Xvfb'; }, /real Linux desktop/u],
      ['missing route', (doc) => { doc.navigation.routes.pop(); }, /every route/u],
      ['source navigation', (doc) => { doc.capture.method = 'source-only'; }, /stale, synthetic/u],
      ['cross-environment replay', (doc) => { doc.navigation.routes[0].screenshot.path = doc.navigation.routes[0].screenshot.path.replace(ENVIRONMENT, 'fedora-kde-wayland-x86_64'); }, /evidence root/u],
      ['candidate mismatch', (doc) => { doc.candidate.runId = '999'; }, /selected release candidate/u],
      ['deep-link destination', (doc) => { doc.deepLinks[1].uri = 'openburnbar://providers?provider=other&model=gpt-5'; }, /mismatched destination/u],
      ['window restore', (doc) => {
        const file = path.join(value.root, doc.windows.path);
        const events = JSON.parse(fs.readFileSync(file, 'utf8')); events.events[3].passed = false; writeJson(file, events);
        doc.windows = record(value.root, file);
      }, /restore behavior/u]
    ]) {
      const doc = structuredClone(value.session);
      mutate(doc);
      assert.throws(() => validateP09InstalledSession(doc, binding(value), { repoRoot: value.root }), pattern, label);
    }
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-09 rejects stale collection and changed source bytes', () => {
  const value = fixture();
  try {
    assert.throws(() => captureP09NavigationShellProof({
      repoRoot: value.root, inputRoot: value.inputRoot, sessionReport: value.sessionReport,
      ...binding(value), resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 20 * 60_000)
    }), /stale/u);
    const captured = captureP09NavigationShellProof({
      repoRoot: value.root, inputRoot: value.inputRoot, sessionReport: value.sessionReport,
      ...binding(value), resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 1_000)
    });
    fs.appendFileSync(value.sessionReport, '\n');
    const proofPath = path.relative(value.root, captured.output).split(path.sep).join('/');
    assert.throws(() => validateP09Proof({ repoRoot: value.root, snapshot: readRegularSnapshot(value.root, proofPath, 'proof'), ...binding(value) }), /bytes changed/u);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-09 rejects route, deep-link, and window artifacts with replayed native identity', () => {
  for (const [label, select, mutate, pattern] of [
    ['route AT-SPI PID', (doc) => doc.navigation.routes[0].atspi, (value) => { value.appPid += 1; }, /activated route through AT-SPI/u],
    ['route window manifest', (doc) => doc.navigation.routes[0].window, (value) => { value.manifestSha256 = '0'.repeat(64); }, /usable geometry/u],
    ['deep-link AT-SPI desktop', (doc) => doc.deepLinks[0].atspi, (value) => { value.desktop = 'KDE'; }, /accessible destination/u]
  ]) {
    const value = fixture();
    try {
      const doc = structuredClone(value.session);
      const artifact = select(doc);
      const file = path.join(value.root, artifact.path);
      const contents = JSON.parse(fs.readFileSync(file, 'utf8'));
      mutate(contents);
      writeJson(file, contents);
      Object.assign(artifact, record(value.root, file));
      assert.throws(() => validateP09InstalledSession(doc, binding(value), { repoRoot: value.root }), pattern, label);
    } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
});

test('P-09 materializer derives the session from installed shell artifacts', () => {
  const value = fixture();
  try {
    const shellRoot = path.join(value.root, 'live-p09-shell');
    fs.mkdirSync(shellRoot);
    const copy = (recordValue, name) => fs.copyFileSync(path.join(value.root, recordValue.path), path.join(shellRoot, name));
    copy(value.installed.manifest, 'installed-manifest.json');
    copy(value.installed.signature, 'installed-manifest.json.sig');
    copy(value.session.navigation.perfSamples, 'runtime-perf-samples.jsonl');
    const routes = value.session.navigation.routes.map((row) => {
      const atspi = `atspi-${row.route}.json`; const screenshot = `screenshot-${row.route}.png`; const xwininfo = `window-${row.route}.json`;
      copy(row.atspi, atspi); copy(row.screenshot, screenshot); copy(row.window, xwininfo);
      return {
        route: row.route, navMethod: row.navMethod, atspi, screenshot, xwininfo,
        surface: 'installed-tauri-native-session', appPid: row.appPid, windowId: row.windowId,
        capturedAt: row.capturedAt, desktop: 'GNOME', displayServer: 'X11',
        manifestSha256: value.installed.manifest.sha256
      };
    });
    writeJson(path.join(shellRoot, 'packaged-route-session-transcript.json'), {
      producer: 'openburnbar-p09-native-route-probe-v1', mode: 'packaged-desktop-route-navigation',
      surface: 'installed-tauri-native-session', environmentId: ENVIRONMENT, desktop: 'GNOME',
      displayServer: 'X11', manifestSha256: value.installed.manifest.sha256, appPid: 1234, routes
    });
    for (const row of value.session.deepLinks) {
      copy(row.eventLog, `p09-deep-link-${row.kind}-events.json`);
      copy(row.atspi, `p09-deep-link-${row.kind}-atspi.json`);
      copy(row.screenshot, `p09-deep-link-${row.kind}.png`);
    }
    copy(value.session.windows, 'p09-native-window-events.json');
    fs.rmSync(value.inputRoot, { recursive: true, force: true });
    fs.mkdirSync(value.inputRoot, { recursive: true });
    const result = materializeP09NavigationShellSession({
      repoRoot: value.root, outputRoot: value.inputRoot, shellEvidenceDir: shellRoot,
      ...binding(value), compositor: 'Mutter'
    }, {
      installedVerifier: () => ({ passed: true }),
      manifestPath: path.join(shellRoot, 'installed-manifest.json'),
      signaturePath: path.join(shellRoot, 'installed-manifest.json.sig')
    });
    assert.equal(result.document.navigation.routes.length, 19);
    assert.equal(result.document.deepLinks.length, 2);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-09 rejects forged and unsigned installed manifest signatures', () => {
  const value = fixture();
  try {
    for (const bytes of [Buffer.alloc(64, 9), Buffer.alloc(0)]) {
      const doc = structuredClone(value.session);
      const signatureFile = path.join(value.root, doc.package.signature.path);
      fs.writeFileSync(signatureFile, bytes);
      doc.package.signature = record(value.root, signatureFile);
      const forgedBinding = { ...binding(value), manifestSignatureSha256: doc.package.signature.sha256 };
      assert.throws(() => validateP09InstalledSession(doc, forgedBinding, { repoRoot: value.root }), /signature/u);
    }
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});
