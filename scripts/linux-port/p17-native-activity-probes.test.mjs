import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';
import { pngCrc32 } from './lib/installed-ui-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import { materializeP17ActivitySession } from './materialize-p17-activity-session.mjs';
import { runP17NativeActivityProbes } from './run-p17-native-activity-probes.mjs';

const HEAD = '7'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-aarch64';
const MARKER = 'P17-1234567890abcdef';
const SESSION_ID = '123e4567-e89b-42d3-a456-426614174000';

function write(file, bytes, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  if (mode) fs.chmodSync(file, mode);
  return file;
}
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function chunk(type, data) {
  const name = Buffer.from(type); const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length); name.copy(output, 4); data.copy(output, 8);
  output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8); return output;
}
function png(seed) {
  const width = 480; const height = 300; const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
    const index = y * (width * 3 + 1) + 1 + x * 3;
    raw[index] = (x + seed) % 256; raw[index + 1] = (y + seed * 3) % 256; raw[index + 2] = (x + y + seed * 7) % 256;
  }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(raw, { level: 0 })), chunk('IEND', Buffer.alloc(0))]);
}
function session(provider, providerSessionID, marker = MARKER) {
  return { id: `${provider}:${providerSessionID}`, provider, model: provider === 'Codex' ? 'gpt-5.5' : 'fixture-model',
    startedAt: '2026-07-20T00:00:00Z', tokens: 444, costUsd: 0.0123, title: `${marker} activity proof`,
    sourceID: `${provider}:${providerSessionID}`, providerSessionID, projectName: 'OpenBurnBar',
    bodyMD: `Persisted session body for ${marker}` };
}
function tree(marker, stale = false) {
  const names = ['Activity & logs', `${marker} activity proof`, 'Persisted session body', marker,
    stale ? 'Retry session body' : 'Reload session body', 'Resume session'];
  if (stale) names.push('Could not reload; showing the last successful body.');
  return { producer: 'openburnbar-p17-atspi-control-v1', capturedAt: new Date().toISOString(),
    nodes: names.map((name) => ({ name, role: 'label', actions: [], states: [] })) };
}
function attestation(root) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
  write(path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'), publicPem);
  const file = (installedPath, bytes, mode) => ({ path: installedPath, type: 'file', sha256: sha256(bytes), size: bytes.length, mode, uid: 0, gid: 0 });
  const manifest = canonicalJsonBytes(createInstalledManifest({ files: [
    file('/usr/bin/openburnbar-daemon', Buffer.from('daemon'), '0755'),
    file('/usr/bin/openburnbar-linux-desktop', Buffer.from('desktop'), '0755'),
    file('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicPem, '0644')
  ], packageVersion: '1.2.3', gitCommit: HEAD, packageArchitecture: 'aarch64', packageFormat: 'deb', firebaseAppId: '1:2:web:3' }));
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return { manifestPath: write(path.join(root, 'attest/installed-manifest.json'), manifest),
    signaturePath: write(path.join(root, 'attest/installed-manifest.json.sig'), signature),
    manifestSha256: sha256(manifest), manifestSignatureSha256: sha256(signature) };
}

function fixture(root, { samePid = false, badSearch = false, falseMissing = false } = {}) {
  const rawOutputDir = path.join(root, 'raw'); const supportDir = path.join(root, 'support');
  const homeDir = path.join(root, 'home'); const downloadDir = path.join(root, 'downloads');
  for (const directory of [rawOutputDir, supportDir, homeDir, downloadDir]) fs.mkdirSync(directory, { mode: 0o700 });
  const tokenFile = write(path.join(supportDir, 'daemon-token'), `${'d'.repeat(64)}\n`, 0o600);
  const indexDatabase = path.join(supportDir, 'index.sqlite');
  const primary = session('Codex', SESSION_ID); const ambiguous = `ambiguous-${SESSION_ID}`;
  const rows = [primary, session('Codex', ambiguous, 'ambiguous'), session('Claude Code', ambiguous, 'ambiguous')];
  const history = { sessions: rows, nextCursor: null, historyComplete: true, historyLimit: 500, totalCount: rows.length };
  const search = { plan: { mode: 'retrieve' }, aggregateOccurrenceCount: null, hits: [{ chunkID: 'chunk', sourceKind: 'conversation',
    sourceID: badSearch ? 'Codex:wrong' : primary.sourceID, title: primary.title, snippet: `Indexed ${MARKER}`,
    provider: 'Codex', projectName: 'OpenBurnBar' }], degradedMessage: null, semanticSearchPerformed: false, semanticHitCount: null };
  const replay = { kind: 'native', argv: ['codex', 'resume', SESSION_ID], briefingMD: `# Resume\n\nComposite ID: \`${primary.sourceID}\`\n\n${MARKER}` };
  const error = (code) => ({ kind: 'error', errorCode: code, errorRecovery: 'Choose an exact composite source identifier.' });
  let launches = 0;
  const ui = {
    async launch() { launches += 1; return { pid: samePid ? 501 : 500 + launches, windowID: String(700 + launches) }; },
    async stop() {}, async route() {}, async assertMarker() { return tree(MARKER); }, async expandAndLoad() { return tree(MARKER); },
    async search() { return tree(MARKER); }, async reloadBody() {}, async retryBody() {}, snapshot() { return tree(MARKER, true); },
    async exportLoaded(format) {
      const sessions = [{ id: primary.id, provider: primary.provider, model: primary.model, startedAt: primary.startedAt,
        tokens: primary.tokens, costUsd: primary.costUsd, title: primary.title, sourceID: primary.sourceID,
        providerSessionID: primary.providerSessionID, projectName: primary.projectName }];
      if (format === 'json') write(path.join(rawOutputDir, 'activity-loaded.json'), `${JSON.stringify({ version: 1, generatedAt: new Date().toISOString(),
        scope: 'loaded-session-index', source: 'live daemon session index', loadedCount: 1, sessions }, null, 2)}\n`);
      else write(path.join(rawOutputDir, 'activity-loaded.md'), `# Activity Export\n\n${MARKER} session details and summary.\n`.repeat(3));
      return { byteCount: 200, sha256: 'a'.repeat(64) };
    },
    async exportHistory() {
      write(path.join(rawOutputDir, 'activity-history.json'), `${JSON.stringify({ version: 1, generatedAt: new Date().toISOString(),
        scope: 'daemon-session-history', source: 'live daemon session index', loadedCount: rows.length,
        historyComplete: true, historyLimit: 500, sessions: rows }, null, 2)}\n`);
      return { byteCount: 500, sha256: 'b'.repeat(64) };
    },
    screenshot(state) { const file = write(path.join(rawOutputDir, `activity-${state}.png`), png({ initial: 1, stale: 2, restart: 3 }[state])); return { file }; }
  };
  const dependencies = {
    platform: 'linux', desktopSession: true, installedVerifier: () => ({}), desktopProcessIDs: () => [],
    sessionID: SESSION_ID, marker: MARKER,
    seed() {
      write(indexDatabase, crypto.randomBytes(128), 0o600);
      write(path.join(supportDir, 'usage-events.jsonl'), '{}\n', 0o600);
      const sessionFile = write(path.join(homeDir, '.codex/sessions/2026/07/20/session.jsonl'), '{}\n', 0o600);
      return { schemaVersion: 1, producer: 'openburnbar-p17-database-seed-v1', sourceID: primary.sourceID,
        providerSessionID: SESSION_ID, ambiguousSessionID: ambiguous, marker: MARKER, title: primary.title,
        body: primary.bodyMD, createdAt: new Date(Date.now() - 1000).toISOString(), sessionFile };
    },
    daemon: { async prepare() {}, async stop() {}, async start() {}, async restart() {}, async restore() {} },
    cli(args) {
      let document; let status = 0;
      if (args[1] === 'history') document = history;
      else if (args[1] === 'search') document = search;
      else if (args[2]?.startsWith('Codex:missing-')) { document = falseMissing ? replay : error('session_not_found'); status = falseMissing ? 0 : 1; }
      else if (args[2] === ambiguous) { document = error('ambiguous_session'); status = 1; }
      else document = replay;
      return { args, status, stdout: `${JSON.stringify(document)}\n`, stderr: '', document };
    }, ui
  };
  return { rawOutputDir, supportDir, homeDir, downloadDir, tokenFile, indexDatabase, dependencies };
}
function options(value, identity) {
  return { ...value, environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: '1717',
    candidateArtifactDigest: `sha256:${'a'.repeat(64)}`, packageVersion: '1.2.3', ...identity, compositor: 'Mutter',
    socketPath: path.join(value.supportDir, 'daemon.sock') };
}

test('P-17 native runner emits a signed materializable installed Activity session', async () => {
  const root = fs.mkdtempSync(path.join(process.cwd(), '.tmp/p17-native-tests-'));
  try {
    const value = fixture(root); const identity = attestation(root);
    const result = await runP17NativeActivityProbes(options(value, identity), value.dependencies);
    assert.equal(result.sourceID, `Codex:${SESSION_ID}`);
    assert.equal(
      fs.readFileSync(path.join(value.homeDir, '.config/user-dirs.dirs'), 'utf8'),
      `XDG_DOWNLOAD_DIR="${value.downloadDir}"\n`
    );
    const transcript = JSON.parse(fs.readFileSync(path.join(result.output, 'activity-cli-transcript.json')));
    assert.deepEqual(transcript.rows.map((row) => row.status), [0, 0, 0, 1, 1, 0, 0, 0]);
    const outputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-17', ENVIRONMENT);
    fs.mkdirSync(outputRoot, { recursive: true });
    const materialized = materializeP17ActivitySession({ repoRoot: root, outputRoot, rawEvidenceDir: result.output,
      ...options(value, identity) }, { installedVerifier: () => ({}), manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath });
    assert.equal(materialized.document.requirementId, 'P-17');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('P-17 native runner fails closed on unsafe state and false product behavior', async () => {
  for (const [label, settings, mutate, pattern] of [
    ['wrong platform', {}, (value) => { value.dependencies.platform = 'darwin'; }, /must execute on Linux/u],
    ['existing desktop', {}, (value) => { value.dependencies.desktopProcessIDs = () => [99]; }, /pre-existing installed desktop/u],
    ['support permissions', {}, (value) => fs.chmodSync(value.supportDir, 0o755), /owner-only real directory/u],
    ['unsafe download path', {}, (value) => {
      const unsafe = `${value.downloadDir}\ninjected`;
      fs.renameSync(value.downloadDir, unsafe);
      value.downloadDir = unsafe;
    }, /cannot be encoded/u],
    ['PID reuse', { samePid: true }, () => {}, /reused the initial process/u],
    ['wrong source search', { badSearch: true }, () => {}, /exact source/u],
    ['missing source accepted', { falseMissing: true }, () => {}, /did not fail closed/u]
  ]) {
    const root = fs.mkdtempSync(path.join(process.cwd(), '.tmp/p17-native-tests-'));
    try {
      const value = fixture(root, settings); mutate(value);
      await assert.rejects(runP17NativeActivityProbes(options(value, {
        manifestSha256: '1'.repeat(64), manifestSignatureSha256: '2'.repeat(64)
      }), value.dependencies), pattern, label);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  }
});
