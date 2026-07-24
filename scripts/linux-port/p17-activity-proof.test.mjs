import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';
import { captureP17ActivityProof } from './capture-p17-activity-proof.mjs';
import { pngCrc32 } from './lib/installed-ui-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import { P17_PROOF_ROLE, validateP17InstalledSession, validateP17Proof } from './lib/p17-activity-proof.mjs';
import { materializeP17ActivitySession } from './materialize-p17-activity-session.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS, readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-17.mjs';

const HEAD = '8'.repeat(40); const RUN_ID = '171717'; const DIGEST = `sha256:${'9'.repeat(64)}`;
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-aarch64'; const VERSION = '1.2.3';
const SESSION_ID = '123e4567-e89b-42d3-a456-426614174017'; const SOURCE_ID = `Codex:${SESSION_ID}`;
const MARKER = 'P17-fedcba0987654321';

function write(file, bytes, mode) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); if (mode) fs.chmodSync(file, mode); return file; }
function json(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function hash(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function record(root, file) { const bytes = fs.readFileSync(file); return { path: path.relative(root, file).split(path.sep).join('/'), sha256: hash(bytes), size: bytes.length }; }
function chunk(type, data) { const name = Buffer.from(type); const output = Buffer.alloc(data.length + 12); output.writeUInt32BE(data.length); name.copy(output, 4); data.copy(output, 8); output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8); return output; }
function png(seed) {
  const width = 480; const height = 300; const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) { const at = y * (width * 3 + 1) + 1 + x * 3; raw[at] = (x + seed) % 256; raw[at + 1] = (y * 2 + seed) % 256; raw[at + 2] = (x + y + seed) % 256; }
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw, { level: 0 })), chunk('IEND', Buffer.alloc(0))]);
}
function row(provider, providerSessionID, marker = MARKER) {
  return { id: `${provider}:${providerSessionID}`, provider, model: provider === 'Codex' ? 'gpt-5.5' : 'fixture-model',
    startedAt: '2026-07-20T12:00:00Z', tokens: 444, costUsd: 0.0123, title: `${marker} activity proof`,
    sourceID: `${provider}:${providerSessionID}`, providerSessionID, projectName: 'OpenBurnBar', bodyMD: `Persisted session body for ${marker}` };
}
function attestation(root, raw) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' }); const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
  write(path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'), publicPem);
  const item = (installedPath, bytes, mode) => ({ path: installedPath, type: 'file', sha256: hash(bytes), size: bytes.length, mode, uid: 0, gid: 0 });
  const manifest = canonicalJsonBytes(createInstalledManifest({ files: [item('/usr/bin/openburnbar-daemon', Buffer.from('daemon'), '0755'),
    item('/usr/bin/openburnbar-linux-desktop', Buffer.from('desktop'), '0755'), item('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicPem, '0644')],
  packageVersion: VERSION, gitCommit: HEAD, packageArchitecture: 'aarch64', packageFormat: 'deb', firebaseAppId: '1:2:web:3' }));
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return { manifestPath: write(path.join(raw, 'installed-manifest.json'), manifest), signaturePath: write(path.join(raw, 'installed-manifest.json.sig'), signature),
    manifestSha256: hash(manifest), manifestSignatureSha256: hash(signature) };
}
function binding(value) { return { repoRoot: value.root, environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
  candidateArtifactDigest: DIGEST, packageVersion: VERSION, ...value.identity }; }
function mutateArtifact(value, document, descriptor, change) {
  const file = path.join(value.root, descriptor.path); const payload = JSON.parse(fs.readFileSync(file)); change(payload); json(file, payload);
  descriptor.sha256 = record(value.root, file).sha256; descriptor.size = record(value.root, file).size;
}

function fixture() {
  const base = path.join(process.cwd(), '.tmp/p17-proof-tests'); fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'case-')); const raw = path.join(root, 'raw'); fs.mkdirSync(raw);
  const input = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-17', ENVIRONMENT); fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw); const started = Date.now() - 20_000; const at = (offset) => new Date(started + offset).toISOString();
  const ambiguous = `ambiguous-${SESSION_ID}`; const sessions = [row('Codex', SESSION_ID), row('Codex', ambiguous, 'ambiguous'), row('Claude Code', ambiguous, 'ambiguous')];
  json(path.join(raw, 'activity-seed.json'), { schemaVersion: 1, producer: 'openburnbar-p17-database-seed-v1', sourceID: SOURCE_ID,
    providerSessionID: SESSION_ID, ambiguousSessionID: ambiguous, marker: MARKER, title: sessions[0].title, body: sessions[0].bodyMD,
    createdAt: at(0), databaseSha256: '1'.repeat(64), usageLedgerSha256: '2'.repeat(64), sessionFileSha256: '3'.repeat(64) });
  const history = { historyComplete: true, historyLimit: 500, nextCursor: null, sessions, totalCount: sessions.length };
  const search = { plan: { mode: 'retrieve', lexicalFTSQuery: MARKER, semanticText: MARKER, aggregatePatterns: [], note: null },
    aggregateOccurrenceCount: null, hits: [{ chunkID: 'chunk', sourceKind: 'conversation', sourceID: SOURCE_ID, title: sessions[0].title,
      snippet: `Indexed ${MARKER}`, provider: 'Codex', projectName: 'OpenBurnBar' }], degradedMessage: null, semanticSearchPerformed: false, semanticHitCount: null };
  const replay = { kind: 'native', argv: ['codex', 'resume', SESSION_ID], briefingMD: `# Resume\nComposite ID: \`${SOURCE_ID}\`\n${MARKER}` };
  const error = (errorCode) => ({ kind: 'error', errorCode, errorRecovery: 'Use an exact provider-qualified source identifier.' });
  const docs = [history, search, replay, error('session_not_found'), error('ambiguous_session'), history, search, replay];
  const phases = ['history-initial', 'search-initial', 'replay-initial', 'replay-missing', 'replay-ambiguous', 'history-after-restart', 'search-after-restart', 'replay-after-restart'];
  const args = [['activity','history','--limit','500'], ['activity','search',MARKER,'--limit','10'], ['activity','replay',SOURCE_ID],
    ['activity','replay',`Codex:missing-${MARKER}`], ['activity','replay',ambiguous], ['activity','history','--limit','500'],
    ['activity','search',MARKER,'--limit','10'], ['activity','replay',SOURCE_ID]];
  json(path.join(raw, 'activity-cli-transcript.json'), { producer: 'openburnbar-p17-installed-cli-probe-v1', transport: 'installed OpenBurnBar CLI over AF_UNIX',
    rows: phases.map((phase, index) => ({ phase, at: at(1000 + index * 1000), args: args[index], status: index === 3 || index === 4 ? 1 : 0,
      stdout: `${JSON.stringify(docs[index])}\n`, stderr: '', document: docs[index] })) });
  const loaded = sessions[0]; const loadedIndex = { id: loaded.id, provider: loaded.provider, model: loaded.model, startedAt: loaded.startedAt,
    tokens: loaded.tokens, costUsd: loaded.costUsd, title: loaded.title, sourceID: loaded.sourceID, providerSessionID: loaded.providerSessionID, projectName: loaded.projectName };
  json(path.join(raw, 'activity-loaded.json'), { version: 1, generatedAt: at(9000), scope: 'loaded-session-index', source: 'live daemon session index', loadedCount: 1, sessions: [loadedIndex] });
  write(path.join(raw, 'activity-loaded.md'), `# Activity Export\n\n${MARKER} persisted Activity summary.\n\nProvider: Codex\n`.repeat(2));
  json(path.join(raw, 'activity-history.json'), { version: 1, generatedAt: at(9000), scope: 'daemon-session-history', source: 'live daemon session index',
    loadedCount: sessions.length, historyComplete: true, historyLimit: 500, sessions });
  const events = [
    { kind: 'populated-replay-export', at: at(9000), appPid: 501, marker: MARKER, sourceID: SOURCE_ID, bodyObserved: true,
      loadedJSON: { byteCount: 200, sha256: '4'.repeat(64) }, loadedMarkdown: { byteCount: 200, sha256: '5'.repeat(64) },
      historyJSON: { byteCount: 500, sha256: '6'.repeat(64) }, manifestSha256: identity.manifestSha256 },
    { kind: 'failure-retained', at: at(10_000), appPid: 501, marker: MARKER, bodyRetained: true, failureExposed: true, manifestSha256: identity.manifestSha256 },
    { kind: 'restart-durable', at: at(11_000), appPid: 502, marker: MARKER, sourceID: SOURCE_ID, searchObserved: true, bodyObserved: true, manifestSha256: identity.manifestSha256 }
  ];
  json(path.join(raw, 'activity-interactions.json'), { producer: 'openburnbar-p17-installed-ui-probe-v1', events });
  const atspi = (when, pid, stale = false) => ({ producer: 'openburnbar-p17-atspi-control-v1', capturedAt: when,
    appPid: pid, manifestSha256: identity.manifestSha256, marker: MARKER, nodes: ['Persisted session body', MARKER,
      stale ? 'Retry session body' : 'Reload session body', 'Resume session', ...(stale ? ['Error showing the last successful body'] : [])]
      .map((name) => ({ name, role: 'label', actions: [], states: [] })) });
  json(path.join(raw, 'activity-initial-atspi.json'), atspi(at(9000), 501));
  json(path.join(raw, 'activity-stale-atspi.json'), atspi(at(10_000), 501, true));
  json(path.join(raw, 'activity-restart-atspi.json'), atspi(at(11_000), 502));
  write(path.join(raw, 'activity-initial.png'), png(1)); write(path.join(raw, 'activity-stale.png'), png(2)); write(path.join(raw, 'activity-restart.png'), png(3));
  const materialized = materializeP17ActivitySession({ repoRoot: root, outputRoot: input, rawEvidenceDir: raw,
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST,
    packageVersion: VERSION, ...identity, compositor: 'Mutter' }, { installedVerifier: () => ({}),
    manifestPath: identity.manifestPath, signaturePath: identity.signaturePath });
  return { root, raw, input, identity, materialized, endedAt: at(11_000) };
}

function context(value, proofFile) {
  const subjects = path.join(value.input, 'release-subjects');
  const aggregate = record(value.root, json(path.join(subjects, 'aggregate.json'), { passed: true }));
  const runtime = record(value.root, json(path.join(subjects, 'runtime.json'), { daemonVersion: VERSION, shellVersion: VERSION }));
  const environment = record(value.root, json(path.join(subjects, 'environment.json'), { environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'aarch64', passed: true }));
  const pkg = record(value.root, write(path.join(subjects, 'package.deb'), 'package\n')); const proof = record(value.root, proofFile);
  return { schemaVersion: 1, repoRoot: value.root, requirementId: 'P-17', checkId: 'p-17.activity', environmentId: ENVIRONMENT, targetHead: HEAD,
    releaseClosure: { document: { schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed', requirementId: 'P-17', environmentId: ENVIRONMENT,
      version: VERSION, blockers: [], architectures: [...RELEASE_ARCHITECTURES], supportEnvironments: [...SUPPORT_ENVIRONMENTS], selectedPackage: { architecture: 'aarch64', format: 'deb' },
      candidate: { runId: RUN_ID, artifactDigest: DIGEST }, packageManifestSignature: value.materialized.document.package.signature,
      proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P17_PROOF_ROLE, ...proof }] } },
    subjects: { release: aggregate, packageManifest: value.materialized.document.package.manifest, packages: [pkg], runtimes: [runtime], installation: [aggregate], environment, features: [] } };
}

test('P-17 materializer, capture, and product validator close one signed installed Activity session', async () => {
  const value = fixture();
  try {
    const captured = captureP17ActivityProof({ inputRoot: value.input, sessionReport: value.materialized.output, ...binding(value) },
      { resolveHead: () => HEAD, now: () => new Date(Date.parse(value.endedAt) + 1000) });
    const validated = validateP17Proof({ repoRoot: value.root, snapshot: readRegularSnapshot(value.root,
      path.relative(value.root, captured.output), 'P-17 proof'), ...binding(value) });
    assert.equal(validated.cliRows, 8); assert.equal(validated.sourceID, SOURCE_ID);
    assert.equal((await validateProductRequirement(context(value, captured.output))).status, 'passed');
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-17 rejects semantic mutation, replayed UI, forged signatures, stale proof, and changed bytes', () => {
  const cases = [
    ['body mutation', (value, doc) => mutateArtifact(value, doc, doc.cliTranscript, (payload) => { const row = payload.rows[5]; row.document.sessions[0].bodyMD = 'forged'; row.stdout = `${JSON.stringify(row.document)}\n`; }), /persisted source and body/u],
    ['search source mutation', (value, doc) => mutateArtifact(value, doc, doc.cliTranscript, (payload) => { const row = payload.rows[1]; row.document.hits[0].sourceID = 'Codex:wrong'; row.stdout = `${JSON.stringify(row.document)}\n`; }), /exact indexed source/u],
    ['native argv mutation', (value, doc) => mutateArtifact(value, doc, doc.cliTranscript, (payload) => { const row = payload.rows[2]; row.document.argv[0] = 'sh'; row.stdout = `${JSON.stringify(row.document)}\n`; }), /native resume readback/u],
    ['false missing success', (value, doc) => mutateArtifact(value, doc, doc.cliTranscript, (payload) => { payload.rows[3].status = 0; }), /successful installed CLI call/u],
    ['secret export field', (value, doc) => mutateArtifact(value, doc, doc.exports.loadedJson, (payload) => { payload.sessions[0].apiKey = 'secret'; }), /non-allowlisted/u],
    ['incomplete history', (value, doc) => mutateArtifact(value, doc, doc.exports.fullHistoryJson, (payload) => { payload.historyComplete = false; }), /incomplete/u],
    ['failure hidden', (value, doc) => mutateArtifact(value, doc, doc.interactions, (payload) => { payload.events[1].failureExposed = false; }), /failure retention/u],
    ['PID reused', (value, doc) => mutateArtifact(value, doc, doc.interactions, (payload) => { payload.events[2].appPid = payload.events[0].appPid; }), /restart durability/u],
    ['screenshot replay', (_value, doc) => { doc.ui.restartScreenshot = doc.ui.initialScreenshot; }, /reuses an evidence artifact|replayed/u]
  ];
  for (const [label, change, pattern] of cases) {
    const value = fixture(); try { const document = structuredClone(value.materialized.document); change(value, document);
      assert.throws(() => validateP17InstalledSession(document, binding(value), { repoRoot: value.root }), pattern, label);
    } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
  const forged = fixture(); try {
    const document = structuredClone(forged.materialized.document); const file = path.join(forged.root, document.package.signature.path);
    fs.writeFileSync(file, Buffer.alloc(64, 7)); document.package.signature = record(forged.root, file);
    assert.throws(() => validateP17InstalledSession(document, { ...binding(forged), manifestSignatureSha256: document.package.signature.sha256 }, { repoRoot: forged.root }), /signature/u);
  } finally { fs.rmSync(forged.root, { recursive: true, force: true }); }
  const changed = fixture(); try {
    fs.appendFileSync(path.join(changed.root, changed.materialized.document.exports.loadedMarkdown.path), 'changed');
    assert.throws(() => validateP17InstalledSession(changed.materialized.document, binding(changed), { repoRoot: changed.root }), /bytes changed/u);
  } finally { fs.rmSync(changed.root, { recursive: true, force: true }); }
  const stale = fixture(); try {
    assert.throws(() => captureP17ActivityProof({ inputRoot: stale.input, sessionReport: stale.materialized.output, ...binding(stale) },
      { resolveHead: () => HEAD, now: () => new Date(Date.parse(stale.endedAt) + 20 * 60_000) }), /stale/u);
  } finally { fs.rmSync(stale.root, { recursive: true, force: true }); }
});

test('P-17 rejects cross-environment paths and semantically mutated emitted claims', async () => {
  const cross = fixture(); try {
    const document = structuredClone(cross.materialized.document);
    document.ui.restartAtspi.path = document.ui.restartAtspi.path.replace(ENVIRONMENT, 'fedora-42-kde-wayland-aarch64');
    assert.throws(() => validateP17InstalledSession(document, binding(cross), { repoRoot: cross.root }), /evidence root/u);
  } finally { fs.rmSync(cross.root, { recursive: true, force: true }); }
  const claim = fixture(); try {
    const captured = captureP17ActivityProof({ inputRoot: claim.input, sessionReport: claim.materialized.output, ...binding(claim) },
      { resolveHead: () => HEAD, now: () => new Date(Date.parse(claim.endedAt) + 1000) });
    const proof = JSON.parse(fs.readFileSync(captured.output)); proof.claim.cliRows += 1; fs.writeFileSync(captured.output, `${JSON.stringify(proof, null, 2)}\n`);
    await assert.rejects(validateProductRequirement(context(claim, captured.output)), /claim is not derived/u);
  } finally { fs.rmSync(claim.root, { recursive: true, force: true }); }
});
