import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { inspectLinuxRepositoryFreshness } from './inspect-linux-repository-freshness.mjs';

const CHANNEL = 'stable';
const FINGERPRINT = 'A'.repeat(40);

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-freshness-'));
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'gpg'), `#!${process.execPath}\nconst args=process.argv.slice(2);if(args.includes('--verify'))process.stdout.write('[GNUPG:] VALIDSIG ${FINGERPRINT} 0 0 0 0 0 0 0 0 ${FINGERPRINT}\\n');\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'gpgconf'), `#!${process.execPath}\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'repository.asc'), 'public\n');
  const now = new Date('2026-07-11T12:00:00.000Z');
  const releaseDate = new Date(now.getTime() - 72 * 60 * 60 * 1000);
  const validUntil = new Date(releaseDate.getTime() + 168 * 60 * 60 * 1000);
  const files = new Map([
    [`apt/dists/${CHANNEL}/Release`, Buffer.from(`Date: ${releaseDate.toUTCString()}\nValid-Until: ${validUntil.toUTCString()}\n`)],
    [`apt/dists/${CHANNEL}/InRelease`, Buffer.from('inrelease\n')],
    [`apt/dists/${CHANNEL}/Release.gpg`, Buffer.from('release-signature\n')]
  ]);
  const closureBytes = Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    channel: CHANNEL,
    version: '1.2.3',
    gitCommit: 'b'.repeat(40),
    packageSetRootSha256: 'c'.repeat(64),
    signing: { signingFingerprint: FINGERPRINT },
    repositories: { apt: { releaseDate: releaseDate.toISOString(), validUntil: validUntil.toISOString() } },
    files: [...files].map(([file, bytes]) => ({
      file, sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length
    }))
  })}\n`);
  const snapshotId = crypto.createHash('sha256').update(closureBytes).digest('hex');
  const configPath = path.join(root, 'config.json');
  fs.writeFileSync(configPath, `${JSON.stringify({
    repositoryMetadata: {
      aptValidForHours: 168,
      refreshCheckIntervalHours: 6,
      refreshWhenRemainingHours: 96,
      criticalRemainingHours: 48,
      activationMinimumRemainingHours: 24
    },
    signing: { status: 'configured', publicKey: 'repository.asc', signingFingerprint: FINGERPRINT }
  })}\n`);
  return { root, bin, now, files, closureBytes, snapshotId, configPath };
}

function fetcher(value, options = {}) {
  let statusReads = 0;
  return async (url) => {
    const pathname = new URL(url).pathname;
    if (pathname === '/linux/repository-admin/status') {
      statusReads += 1;
      const generation = options.race && statusReads === 2 ? 8 : 7;
      const etag = `"${String(generation).repeat(32)}"`;
      return new Response(JSON.stringify({
        schemaVersion: 1,
        status: 'active',
        channel: CHANNEL,
        activation: { channel: CHANNEL, snapshotId: value.snapshotId, generation },
        pointerEtag: etag
      }), { status: 200, headers: { ETag: etag, 'Content-Type': 'application/json' } });
    }
    const relative = pathname.split(`/${value.snapshotId}/`)[1];
    const bytes = relative === 'repository-closure.json' ? value.closureBytes
      : relative === 'repository-closure.json.asc' ? Buffer.from('closure-signature\n')
        : value.files.get(relative);
    return new Response(bytes, {
      status: bytes ? 200 : 404,
      headers: { 'X-OpenBurnBar-Repository-Snapshot': value.snapshotId }
    });
  };
}

test('freshness inspector verifies exact active closure and reports the refresh threshold without private key access', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const previousPath = process.env.PATH;
  process.env.PATH = `${value.bin}:${previousPath}`;
  t.after(() => { process.env.PATH = previousPath; });
  const result = await inspectLinuxRepositoryFreshness({
    repoRoot: value.root,
    channel: CHANNEL,
    token: 'x'.repeat(32),
    baseUrl: 'http://localhost:8123',
    allowLocalTestOrigin: true,
    configPath: value.configPath,
    now: value.now
  }, fetcher(value));
  assert.equal(result.passed, true);
  assert.equal(result.status, 'active');
  assert.equal(result.refreshRequired, true);
  assert.equal(result.critical, false);
  assert.equal(result.remainingHours, 96);
  assert.equal(result.current.snapshotId, value.snapshotId);
});

test('freshness inspector fails closed when the repository pointer changes during inspection', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const previousPath = process.env.PATH;
  process.env.PATH = `${value.bin}:${previousPath}`;
  t.after(() => { process.env.PATH = previousPath; });
  await assert.rejects(inspectLinuxRepositoryFreshness({
    repoRoot: value.root,
    channel: CHANNEL,
    token: 'x'.repeat(32),
    baseUrl: 'http://localhost:8123',
    allowLocalTestOrigin: true,
    configPath: value.configPath,
    now: value.now
  }, fetcher(value, { race: true })), /changed during/u);
});

test('freshness inspector treats an authenticated inactive channel as a key-free no-op', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const config = JSON.parse(fs.readFileSync(value.configPath, 'utf8'));
  config.signing = { status: 'unconfigured', publicKey: null, signingFingerprint: null };
  fs.writeFileSync(value.configPath, `${JSON.stringify(config)}\n`);
  const result = await inspectLinuxRepositoryFreshness({
    repoRoot: value.root,
    channel: CHANNEL,
    token: 'x'.repeat(32),
    baseUrl: 'http://localhost:8123',
    allowLocalTestOrigin: true,
    configPath: value.configPath,
    now: value.now
  }, async () => new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: CHANNEL }), {
    status: 404,
    headers: { 'Content-Type': 'application/json' }
  }));
  assert.deepEqual(result, {
    schemaVersion: 1,
    passed: true,
    channel: CHANNEL,
    status: 'inactive',
    refreshRequired: false,
    critical: false,
    releaseDate: null,
    validUntil: null,
    remainingHours: null
  });
});

test('freshness inspector rejects generic and unbound 404 responses instead of silently skipping refresh', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const options = {
    repoRoot: value.root,
    channel: CHANNEL,
    token: 'x'.repeat(32),
    baseUrl: 'http://localhost:8123',
    allowLocalTestOrigin: true,
    configPath: value.configPath,
    now: value.now
  };
  await assert.rejects(
    inspectLinuxRepositoryFreshness(options, async () => new Response('not found', { status: 404 })),
    /not valid JSON/u
  );
  await assert.rejects(
    inspectLinuxRepositoryFreshness(options, async () => new Response(JSON.stringify({
      schemaVersion: 1,
      status: 'inactive',
      channel: CHANNEL,
      pointerEtag: `"${'a'.repeat(32)}"`,
      deactivation: {}
    }), { status: 404, headers: { ETag: `"${'b'.repeat(32)}"` } })),
    /not pointer-bound/u
  );
});
