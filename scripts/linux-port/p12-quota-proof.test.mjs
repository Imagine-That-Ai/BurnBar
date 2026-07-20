import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';
import { captureP12QuotaProof } from './capture-p12-quota-proof.mjs';
import { pngCrc32 } from './lib/installed-ui-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import { P12_PROOF_ROLE, validateP12InstalledSession, validateP12Proof } from './lib/p12-quota-proof.mjs';
import { materializeP12QuotaSession } from './materialize-p12-quota-session.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS, readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-12.mjs';

const HEAD = 'c'.repeat(40); const RUN_ID = '12345'; const DIGEST = `sha256:${'b'.repeat(64)}`;
const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-aarch64';
function chunk(type, data) { const name = Buffer.from(type); const out = Buffer.alloc(data.length + 12); out.writeUInt32BE(data.length); name.copy(out, 4); data.copy(out, 8); out.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8); return out; }
function png(color) { const width = 480; const height = 300; const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 2; const raw = Buffer.alloc((width * 3 + 1) * height); for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) { const at = y * (width * 3 + 1) + 1 + x * 3; raw[at] = color; raw[at + 1] = color * 2; raw[at + 2] = color * 3; } return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]); }
function write(file, bytes) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); return file; }
function json(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function record(root, file) { const bytes = fs.readFileSync(file); return { path: path.relative(root, file).split(path.sep).join('/'), sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length }; }

function fixture() {
  const base = path.join(process.cwd(), '.tmp/p12-proof-tests'); fs.mkdirSync(base, { recursive: true }); const root = fs.mkdtempSync(path.join(base, 'case-'));
  const input = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-12', ENVIRONMENT); const raw = path.join(root, 'live'); fs.mkdirSync(raw);
  write(path.join(root, 'contracts/provider-ingestion-catalog.json'), fs.readFileSync('contracts/provider-ingestion-catalog.json'));
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519'); const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' }); const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
  write(path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'), publicPem);
  const f = (installedPath, bytes, mode) => ({ path: installedPath, type: 'file', sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length, mode, uid: 0, gid: 0 });
  const manifestBytes = canonicalJsonBytes(createInstalledManifest({ files: [f('/usr/bin/openburnbar-daemon', Buffer.from('d'), '0755'), f('/usr/bin/openburnbar-linux-desktop', Buffer.from('u'), '0755'), f('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicPem, '0644')], packageVersion: '1.2.3', gitCommit: HEAD, packageArchitecture: 'aarch64', packageFormat: 'deb', firebaseAppId: '1:2:web:3' }));
  const signatureBytes = signInstalledManifest(manifestBytes, privatePem, publicPem); write(path.join(raw, 'installed-manifest.json'), manifestBytes); write(path.join(raw, 'installed-manifest.json.sig'), signatureBytes);
  const started = Date.now() - 20_000; const times = Array.from({ length: 11 }, (_, i) => new Date(started + i * 1000).toISOString());
  const providers = [{ providerId: 'claude', sourceId: 'claudeCode', aliases: ['anthropic', 'claude-code'], sourceKind: 'localSession', confidence: 'medium', buckets: [{ id: 'five-hour', label: '5h', usedPct: 27, resetsAt: new Date(started + 3_600_000).toISOString(), state: 'ok' }, { id: 'seven-day', label: '7 day', usedPct: 42, resetsAt: new Date(started + 604_800_000).toISOString(), state: 'ok' }] }];
  const catalog = (capturedAt, mode = 'provider_family_failover') => ({ producer: 'openburnbar-p12-daemon-rpc-probe-v1', capturedAt, routerMode: mode, providers });
  json(path.join(raw, 'quota-catalog-initial.json'), catalog(times[0])); json(path.join(raw, 'quota-catalog-retry.json'), catalog(times[3])); json(path.join(raw, 'quota-catalog-restart.json'), catalog(times[10]));
  const kinds = ['catalog-loaded','refresh-failed','stale-catalog-retained','retry-succeeded','mode-read-before','mode-updated','mode-readback','mode-rolled-back','mode-rollback-readback','app-restarted','catalog-persisted-readback'];
  json(path.join(raw, 'quota-interactions.json'), { producer: 'openburnbar-p12-native-quota-probe-v1', events: kinds.map((kind, i) => ({ kind, at: times[i], appPid: i < 9 ? 400 : 401, windowId: i < 9 ? '70' : '71', manifestSha256: crypto.createHash('sha256').update(manifestBytes).digest('hex'), mode: i >= 5 && i <= 6 ? 'same_model_failover' : 'provider_family_failover' })) });
  const atspi = (state, at, pid, window) => ({ producer: 'openburnbar-p12-native-quota-probe-v1', capturedAt: at, appPid: pid, windowId: window, manifestSha256: crypto.createHash('sha256').update(manifestBytes).digest('hex'), state, expectedNames: state === 'live' ? ['Subscription vault', 'Claude Code', '5h', 'Failover policy'] : ['last available quota snapshot', 'Retry quota catalog'], namedSamples: (state === 'live' ? ['Subscription vault','Claude Code','5h','Failover policy'] : ['last available quota snapshot','Retry quota catalog']).map((name) => ({ role: 'label', name })) });
  json(path.join(raw, 'quota-live-atspi.json'), atspi('live', times[1], 400, '70')); json(path.join(raw, 'quota-stale-atspi.json'), atspi('stale-retained', times[2], 400, '70'));
  write(path.join(raw, 'quota-live.png'), png(20)); write(path.join(raw, 'quota-stale.png'), png(40)); fs.mkdirSync(input, { recursive: true });
  const manifestSha256 = crypto.createHash('sha256').update(manifestBytes).digest('hex'); const manifestSignatureSha256 = crypto.createHash('sha256').update(signatureBytes).digest('hex');
  const binding = { environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST, packageVersion: '1.2.3', manifestSha256, manifestSignatureSha256 };
  const result = materializeP12QuotaSession({ repoRoot: root, outputRoot: input, rawEvidenceDir: raw, ...binding, compositor: 'Mutter' }, { installedVerifier: () => ({}), manifestPath: path.join(raw, 'installed-manifest.json'), signaturePath: path.join(raw, 'installed-manifest.json.sig') });
  return { root, input, raw, binding, result, ended: times[10] };
}

function requirementContext(value, proofFile) {
  const subjects = path.join(value.input, 'release-subjects');
  const aggregate = record(value.root, json(path.join(subjects, 'aggregate.json'), { passed: true }));
  const runtime = record(value.root, json(path.join(subjects, 'runtime.json'), { daemonVersion: '1.2.3', shellVersion: '1.2.3' }));
  const environment = record(value.root, json(path.join(subjects, 'environment.json'), { environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'aarch64', passed: true }));
  const nativePackage = record(value.root, write(path.join(subjects, 'package.deb'), 'package\n'));
  const proof = record(value.root, proofFile); const manifest = value.result.document.package.manifest; const signature = value.result.document.package.signature;
  return { schemaVersion: 1, repoRoot: value.root, requirementId: 'P-12', checkId: 'p-12.quota', environmentId: ENVIRONMENT, targetHead: HEAD,
    releaseClosure: { document: { schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed', requirementId: 'P-12', environmentId: ENVIRONMENT, version: '1.2.3', blockers: [], architectures: [...RELEASE_ARCHITECTURES], supportEnvironments: [...SUPPORT_ENVIRONMENTS], selectedPackage: { architecture: 'aarch64', format: 'deb' }, candidate: { runId: RUN_ID, artifactDigest: DIGEST }, packageManifestSignature: signature, proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P12_PROOF_ROLE, ...proof }] } },
    subjects: { release: aggregate, packageManifest: manifest, packages: [nativePackage], runtimes: [runtime], installation: [aggregate], environment, features: [] } };
}

test('P-12 capture accepts installed quota retention, retry, failover rollback, and restart proof', async () => {
  const value = fixture(); try {
    const captured = captureP12QuotaProof({ repoRoot: value.root, inputRoot: value.input, sessionReport: value.result.output, ...value.binding }, { resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 1000) });
    assert.equal(JSON.parse(fs.readFileSync(captured.registration)).artifacts[0].role, P12_PROOF_ROLE);
    const proof = readRegularSnapshot(value.root, path.relative(value.root, captured.output), 'proof');
    assert.equal(validateP12Proof({ repoRoot: value.root, snapshot: proof, ...value.binding }).bucketCount, 2);
    assert.equal((await validateProductRequirement(requirementContext(value, captured.output))).status, 'passed');
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-12 rejects mutation, replay, false rollback, stale capture, and forged signatures', () => {
  for (const [label, mutate, pattern] of [
    ['alias drift', (doc, value) => { const file = path.join(value.root, doc.catalogs.initial.path); const data = JSON.parse(fs.readFileSync(file)); data.providers[0].aliases = ['forged']; json(file, data); doc.catalogs.initial = record(value.root, file); }, /canonical provider/u],
    ['bucket loss', (doc, value) => { const file = path.join(value.root, doc.catalogs.retry.path); const data = JSON.parse(fs.readFileSync(file)); data.providers[0].buckets.pop(); json(file, data); doc.catalogs.retry = record(value.root, file); }, /two quota buckets/u],
    ['replay', (doc) => { doc.ui.staleScreenshot = doc.ui.liveScreenshot; }, /replayed|reuses an evidence artifact/u],
    ['false rollback', (doc, value) => { const file = path.join(value.root, doc.interactionEvents.path); const data = JSON.parse(fs.readFileSync(file)); data.events[8].mode = 'same_model_failover'; json(file, data); doc.interactionEvents = record(value.root, file); }, /rollback/u],
    ['forged signature', (doc, value) => { const file = path.join(value.root, doc.package.signature.path); fs.writeFileSync(file, Buffer.alloc(64, 7)); doc.package.signature = record(value.root, file); }, /signature/u]
  ]) { const value = fixture(); try { const doc = structuredClone(value.result.document); mutate(doc, value); assert.throws(() => validateP12InstalledSession(doc, { ...value.binding, manifestSignatureSha256: doc.package.signature.sha256 }, { repoRoot: value.root }), pattern, label); } finally { fs.rmSync(value.root, { recursive: true, force: true }); } }
  const value = fixture(); try { assert.throws(() => captureP12QuotaProof({ repoRoot: value.root, inputRoot: value.input, sessionReport: value.result.output, ...value.binding }, { resolveHead: () => HEAD, now: () => new Date(Date.parse(value.ended) + 20 * 60_000) }), /stale/u); } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-12 materializer rejects changed raw artifacts and cross-environment paths', () => {
  const value = fixture(); try {
    const document = structuredClone(value.result.document); const file = path.join(value.root, document.catalogs.restart.path); fs.appendFileSync(file, ' ');
    assert.throws(() => validateP12InstalledSession(document, value.binding, { repoRoot: value.root }), /bytes changed/u);
    document.catalogs.restart.path = document.catalogs.restart.path.replace(ENVIRONMENT, 'fedora-kde-wayland-aarch64');
    assert.throws(() => validateP12InstalledSession(document, value.binding, { repoRoot: value.root }), /evidence root/u);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});
