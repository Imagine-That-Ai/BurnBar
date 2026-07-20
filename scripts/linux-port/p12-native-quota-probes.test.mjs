import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';
import { pngCrc32 } from './lib/installed-ui-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import { materializeP12QuotaSession } from './materialize-p12-quota-session.mjs';
import { runP12NativeQuotaProbes } from './run-p12-native-quota-probes.mjs';

const HEAD = 'd'.repeat(40);
const SHA = 'e'.repeat(64);
const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-aarch64';
const BASE = Date.parse('2026-07-20T12:00:00Z');
const swift = (milliseconds) => milliseconds / 1000 - 978_307_200;

function chunk(type, data) {
  const name = Buffer.from(type); const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length); name.copy(output, 4); data.copy(output, 8);
  output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8); return output;
}
function png(color) {
  const width = 480; const height = 300; const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
    const index = y * (width * 3 + 1) + 1 + x * 3; raw[index] = color; raw[index + 1] = color * 2; raw[index + 2] = color * 3;
  }
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
function write(file, bytes) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); return file; }

function quotaHeaders(used) {
  return {
    'x-ratelimit-limit-requests': '100', 'x-ratelimit-remaining-requests': String(100 - used),
    'x-ratelimit-reset-requests': '2026-07-20T13:00:00.000Z', 'x-ratelimit-limit-tokens': '1000',
    'x-ratelimit-remaining-tokens': '580', 'x-ratelimit-reset-tokens': '2026-07-27T12:00:00.000Z'
  };
}

function quotaResponse(signalId, used, fetchedAt) {
  const headers = quotaHeaders(used);
  return { result: {
    signals: [{ id: signalId, providerID: 'openai', headers: Object.entries(headers).map(([name, value]) => ({ name, value })) }],
    snapshots: [{ providerID: { rawValue: 'openai' }, sourceId: `daemon.quota.signals:${signalId}`, sourceKind: 'provider', confidence: 'high',
      fetchedAt: swift(fetchedAt), updatedAt: swift(fetchedAt), buckets: [
        { key: 'traffic-requests-rate-limit', label: 'Request rate limit', usedPercent: used, resetsAt: swift(Date.parse(headers['x-ratelimit-reset-requests'])) },
        { key: 'traffic-tokens-rate-limit', label: 'Token rate limit', usedPercent: 42, resetsAt: swift(Date.parse(headers['x-ratelimit-reset-tokens'])) }
      ] }]
  } };
}

function harness(root, { samePid = false, sameRetry = false, restartDrift = false } = {}) {
  const outputDir = path.join(root, 'raw');
  const supportDir = path.join(root, 'support');
  fs.mkdirSync(outputDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(supportDir, { recursive: true, mode: 0o700 });
  let clock = BASE;
  let mode = 'provider_family_failover';
  let quotaIndex = 0;
  const retryUsed = sameRetry ? 27 : 35;
  const quota = [quotaResponse('signal-1', 27, BASE), quotaResponse('signal-2', retryUsed, BASE + 3000),
    quotaResponse('signal-2', restartDrift ? retryUsed + 1 : retryUsed, BASE + 3000)];
  const rpcClient = async (method, params) => {
    if (method === 'daemon.quota.signals.recent') return quota[quotaIndex++];
    if (method === 'daemon.config.get') return { result: { snapshot: { providers: [], routerMode: mode, telemetryEnabled: false, privacyOptIn: false, cloudSyncEnabled: false } } };
    if (method === 'daemon.config.update') { mode = params.snapshot.routerMode; return { result: { snapshot: structuredClone(params.snapshot) } }; }
    return { result: { ok: true } };
  };
  const gatewayHarness = {
    async exercise(phase) { const used = phase === 'initial' ? 27 : retryUsed; return { responseStatus: 200, requestCount: 1, quotaHeaders: quotaHeaders(used) }; },
    async close() {}
  };
  let launches = 0;
  const ui = {
    async launch() { launches += 1; return { pid: samePid ? 400 : 399 + launches, windowId: String(69 + launches) }; },
    async route() {}, async refresh() {}, stop() {},
    capture(state, app, at) {
      write(path.join(outputDir, state === 'live' ? 'quota-live.png' : 'quota-stale.png'), png(state === 'live' ? 20 : 40));
      const names = state === 'live' ? ['Subscription vault', 'OpenAI', 'Request rate limit', 'Failover policy'] : ['last available quota snapshot', 'Retry quota catalog'];
      return { producer: 'openburnbar-p12-native-quota-probe-v1', capturedAt: at, appPid: app.pid, windowId: app.windowId,
        manifestSha256: SHA, state: state === 'live' ? 'live' : 'stale-retained', expectedNames: names,
        namedSamples: names.map((name) => ({ role: 'label', name })) };
    }
  };
  return { outputDir, supportDir, dependencies: { platform: 'linux', desktopSession: true, installedVerifier: () => ({}),
    now: () => { clock += 1000; return clock; }, rpcClient, gatewayHarness, ui,
    daemonController: { stop() {}, async start() {}, async restart() {} } } };
}

function options(root, fixture) {
  return { repoRoot: root, outputDir: fixture.outputDir, supportDir: fixture.supportDir, environmentId: ENVIRONMENT,
    targetHead: HEAD, candidateRunId: '123', candidateArtifactDigest: `sha256:${'a'.repeat(64)}`, packageVersion: '1.2.3',
    manifestSha256: SHA, manifestSignatureSha256: 'f'.repeat(64), compositor: 'Mutter' };
}

function createRoot() {
  const base = path.join(process.cwd(), '.tmp/p12-native-tests'); fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'case-'));
  write(path.join(root, 'contracts/provider-ingestion-catalog.json'), fs.readFileSync('contracts/provider-ingestion-catalog.json'));
  return root;
}

test('P-12 native runner emits raw evidence accepted by the installed-session validator', async () => {
  const root = createRoot(); try {
    const fixture = harness(root);
    const result = await runP12NativeQuotaProbes(options(root, fixture), fixture.dependencies);
    assert.equal(result.bucketCount, 2);
    const rpc = JSON.parse(fs.readFileSync(path.join(result.output, 'quota-rpc-transcript.json')));
    assert.equal(typeof rpc.rows[0].response.result.snapshots[0].fetchedAt, 'number');
    assert.equal(rpc.rows[1].response.result.snapshots[0].sourceId, 'daemon.quota.signals:signal-2');

    const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
    const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' }); const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
    const file = (installedPath, bytes, mode) => ({ path: installedPath, type: 'file', sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length, mode, uid: 0, gid: 0 });
    const manifest = canonicalJsonBytes(createInstalledManifest({ files: [file('/usr/bin/openburnbar-daemon', Buffer.from('d'), '0755'),
      file('/usr/bin/openburnbar-linux-desktop', Buffer.from('u'), '0755'), file('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicPem, '0644')],
    packageVersion: '1.2.3', gitCommit: HEAD, packageArchitecture: 'aarch64', packageFormat: 'deb', firebaseAppId: '1:2:web:3' }));
    const signature = signInstalledManifest(manifest, privatePem, publicPem);
    const manifestSha256 = crypto.createHash('sha256').update(manifest).digest('hex');
    for (const name of ['quota-live-atspi.json', 'quota-stale-atspi.json']) {
      const filePath = path.join(result.output, name); const document = JSON.parse(fs.readFileSync(filePath));
      document.manifestSha256 = manifestSha256; fs.writeFileSync(filePath, `${JSON.stringify(document, null, 2)}\n`);
    }
    const interactionPath = path.join(result.output, 'quota-interactions.json');
    const interactions = JSON.parse(fs.readFileSync(interactionPath));
    for (const event of interactions.events) event.manifestSha256 = manifestSha256;
    fs.writeFileSync(interactionPath, `${JSON.stringify(interactions, null, 2)}\n`);
    const attest = path.join(root, 'attest'); const manifestPath = write(path.join(attest, 'installed-manifest.json'), manifest);
    const signaturePath = write(path.join(attest, 'installed-manifest.json.sig'), signature);
    write(path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'), publicPem);
    const outputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-12', ENVIRONMENT); fs.mkdirSync(outputRoot, { recursive: true });
    const materialized = materializeP12QuotaSession({ ...options(root, fixture), outputRoot, rawEvidenceDir: result.output,
      manifestSha256, manifestSignatureSha256: crypto.createHash('sha256').update(signature).digest('hex') },
    { installedVerifier: () => ({}), manifestPath, signaturePath });
    assert.equal(materialized.document.catalogs.stale.sha256.length, 64);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('P-12 native runner fails closed on seeded state, false retry, restart drift, and PID reuse', async () => {
  for (const [name, settings, mutate, pattern] of [
    ['seeded', {}, (fixture) => write(path.join(fixture.supportDir, 'quota-signals.jsonl'), '{}\n'), /pre-seeded/u],
    ['false retry', { sameRetry: true }, () => {}, /headers did not change/u],
    ['restart drift', { restartDrift: true }, () => {}, /persist across restart/u],
    ['PID reuse', { samePid: true }, () => {}, /old PID/u]
  ]) {
    const root = createRoot(); try {
      const fixture = harness(root, settings); mutate(fixture);
      await assert.rejects(runP12NativeQuotaProbes(options(root, fixture), fixture.dependencies), pattern, name);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  }
});

test('P-12 native runner refuses non-Linux execution', async () => {
  const root = createRoot(); try {
    const fixture = harness(root); fixture.dependencies.platform = 'darwin';
    await assert.rejects(runP12NativeQuotaProbes(options(root, fixture), fixture.dependencies), /must execute on Linux/u);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
