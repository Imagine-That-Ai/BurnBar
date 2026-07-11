#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PRODUCTION_ORIGIN = 'https://downloads.burnbar.ai';
const CHANNELS = new Set(['stable', 'prerelease', 'nightly']);
const SHA256 = /^[a-f0-9]{64}$/u;
const ETAG = /^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const COMMIT = /^[a-f0-9]{40}$/u;
const ACTOR = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,96}|[A-Za-z0-9_-]{0,91}\[bot\])$/u;
const RUN_URL = /^https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/actions\/runs\/[1-9][0-9]*(?:\/attempts\/[1-9][0-9]*)?$/u;

function baseOrigin(value, allowLocalTestOrigin) {
  const url = new URL(value);
  if (url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('repository origin must be a bare origin');
  }
  if (url.origin === PRODUCTION_ORIGIN) return url.origin;
  if (allowLocalTestOrigin && ['127.0.0.1', 'localhost'].includes(url.hostname)) return url.origin;
  throw new Error(`repository origin must use ${PRODUCTION_ORIGIN}`);
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function validateActive(value, response, channel) {
  const record = value?.activation;
  const etag = response.headers.get('etag');
  if (value?.schemaVersion !== 1 || value.status !== 'active' || value.channel !== channel
      || !record || record.channel !== channel || !SHA256.test(record.snapshotId ?? '')
      || !Number.isSafeInteger(record.generation) || record.generation <= 0
      || !ETAG.test(value.pointerEtag ?? '') || etag !== value.pointerEtag) {
    throw new Error('repository status is malformed or pointer-unbound');
  }
  return { snapshotId: record.snapshotId, generation: record.generation, pointerEtag: value.pointerEtag };
}

function exactPointer(left, right) {
  return left.snapshotId === right.snapshotId && left.generation === right.generation
    && left.pointerEtag === right.pointerEtag;
}

function exactKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

function validateInactive(value, response, channel) {
  if (value?.schemaVersion !== 1 || value.status !== 'inactive' || value.channel !== channel) {
    throw new Error('repository inactive status is malformed');
  }
  if (value.deactivation === undefined) {
    if (!exactKeys(value, ['schemaVersion', 'status', 'channel'])) {
      throw new Error('repository inactive status has an invalid field set');
    }
    return { inactive: true };
  }
  if (!exactKeys(value, ['schemaVersion', 'status', 'channel', 'deactivation', 'pointerEtag'])
      || !ETAG.test(value.pointerEtag ?? '') || response.headers.get('etag') !== value.pointerEtag) {
    throw new Error('repository inactive tombstone is not pointer-bound');
  }
  const record = value.deactivation;
  const recordKeys = [
    'schemaVersion', 'status', 'channel', 'generation', 'previousSnapshotId', 'previousVersion',
    'previousSourceCommit', 'fallbackMode', 'deactivatedAt', 'actor', 'runUrl', 'reason'
  ];
  if (!exactKeys(record, recordKeys) || record.schemaVersion !== 1 || record.status !== 'inactive'
      || record.channel !== channel || !Number.isSafeInteger(record.generation) || record.generation <= 1
      || !SHA256.test(record.previousSnapshotId ?? '') || !VERSION.test(record.previousVersion ?? '')
      || !COMMIT.test(record.previousSourceCommit ?? '')
      || !['legacy-direct-r2', 'disabled'].includes(record.fallbackMode)
      || !Number.isFinite(Date.parse(record.deactivatedAt ?? '')) || !ACTOR.test(record.actor ?? '')
      || (record.runUrl !== null && !RUN_URL.test(record.runUrl ?? ''))
      || typeof record.reason !== 'string' || record.reason.length < 8 || record.reason.length > 500
      || record.reason.trim() !== record.reason || /[\u0000-\u001f\u007f]/u.test(record.reason)) {
    throw new Error('repository inactive tombstone is malformed');
  }
  return { inactive: true, pointerEtag: value.pointerEtag, deactivation: record };
}

function verifyOpenPgp({ publicKeyPath, signaturePath = null, inputPath, signingFingerprint }) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-refresh-inspect-gpg-'));
  fs.chmodSync(home, 0o700);
  try {
    const imported = spawnSync('gpg', ['--homedir', home, '--batch', '--import', publicKeyPath], { encoding: 'utf8' });
    if (imported.status !== 0) throw new Error('repository public key import failed');
    const verified = spawnSync('gpg', [
      '--homedir', home, '--batch', '--status-fd', '1', '--verify',
      ...(signaturePath ? [signaturePath, inputPath] : [inputPath])
    ], { encoding: 'utf8' });
    const fingerprints = String(verified.stdout).split('\n')
      .map((line) => line.match(/^\[GNUPG:\]\s+VALIDSIG\s+([A-F0-9]{40,64})(?:\s|$)/u)?.[1])
      .filter(Boolean);
    if (verified.status !== 0 || fingerprints.length !== 1 || fingerprints[0] !== signingFingerprint) {
      throw new Error('repository OpenPGP signature does not match the pinned signing subkey');
    }
  } finally {
    spawnSync('gpgconf', ['--homedir', home, '--kill', 'all'], { stdio: 'ignore' });
    fs.rmSync(home, { recursive: true, force: true });
  }
}

export async function inspectLinuxRepositoryFreshness(options, fetchImpl = fetch) {
  if (!CHANNELS.has(options.channel)) throw new Error('freshness channel is invalid');
  if (typeof options.token !== 'string' || !/^[A-Za-z0-9._~+/=-]{32,4096}$/u.test(options.token)) {
    throw new Error('repository activation token is invalid');
  }
  const origin = baseOrigin(options.baseUrl ?? PRODUCTION_ORIGIN, options.allowLocalTestOrigin === true);
  const config = JSON.parse(fs.readFileSync(options.configPath, 'utf8'));
  const expectedPolicy = {
    aptValidForHours: 168,
    refreshCheckIntervalHours: 6,
    refreshWhenRemainingHours: 96,
    criticalRemainingHours: 48,
    activationMinimumRemainingHours: 24
  };
  if (Object.entries(expectedPolicy).some(([field, expected]) => config.repositoryMetadata?.[field] !== expected)) {
    throw new Error('repository freshness policy is missing or noncanonical');
  }
  const headers = { Authorization: `Bearer ${options.token}`, Accept: 'application/json' };
  const statusUrl = `${origin}/linux/repository-admin/status?channel=${options.channel}`;
  const readStatus = async () => {
    const response = await fetchImpl(statusUrl, { headers, redirect: 'error' });
    if (response.status === 404) {
      let value;
      try { value = await response.json(); } catch { throw new Error('repository inactive status is not valid JSON'); }
      return validateInactive(value, response, options.channel);
    }
    if (!response.ok) throw new Error(`repository status failed: HTTP ${response.status}`);
    return validateActive(await response.json(), response, options.channel);
  };
  const before = await readStatus();
  if (before.inactive) {
    return {
      schemaVersion: 1,
      passed: true,
      channel: options.channel,
      status: 'inactive',
      refreshRequired: false,
      critical: false,
      releaseDate: null,
      validUntil: null,
      remainingHours: null
    };
  }
  if (config.signing?.status !== 'configured' || !config.signing.publicKey
      || !/^[A-F0-9]{40,64}$/u.test(config.signing.signingFingerprint ?? '')) {
    throw new Error('repository signing identity is not configured');
  }
  const publicKeyPath = path.resolve(options.repoRoot, config.signing.publicKey);
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-refresh-inspect-'));
  try {
    const preview = `${origin}/linux/repository-preview/${options.channel}/${before.snapshotId}`;
    const download = async (relative) => {
      const response = await fetchImpl(`${preview}/${relative}`, { redirect: 'error' });
      if (!response.ok || response.headers.get('x-openburnbar-repository-snapshot') !== before.snapshotId) {
        throw new Error(`repository preview failed for ${relative}`);
      }
      return Buffer.from(await response.arrayBuffer());
    };
    const closureBytes = await download('repository-closure.json');
    if (sha256(closureBytes) !== before.snapshotId) throw new Error('active closure hash does not match the pointer snapshot');
    const closure = JSON.parse(closureBytes.toString('utf8'));
    if (![1, 2].includes(closure.schemaVersion) || closure.channel !== options.channel
        || closure.signing?.signingFingerprint !== config.signing.signingFingerprint) {
      throw new Error('active closure identity or signing key is invalid');
    }
    const signatureBytes = await download('repository-closure.json.asc');
    const closurePath = path.join(temporary, 'repository-closure.json');
    const signaturePath = `${closurePath}.asc`;
    fs.writeFileSync(closurePath, closureBytes);
    fs.writeFileSync(signaturePath, signatureBytes);
    verifyOpenPgp({ publicKeyPath, signaturePath, inputPath: closurePath, signingFingerprint: config.signing.signingFingerprint });
    const aptRoots = new Map();
    for (const relative of [
      `apt/dists/${options.channel}/Release`,
      `apt/dists/${options.channel}/InRelease`,
      `apt/dists/${options.channel}/Release.gpg`
    ]) {
      const row = closure.files?.find((item) => item.file === relative);
      const bytes = await download(relative);
      if (!row || row.sha256 !== sha256(bytes) || row.size !== bytes.length) {
        throw new Error(`active apt root does not match closure: ${relative}`);
      }
      const file = path.join(temporary, path.basename(relative));
      fs.writeFileSync(file, bytes);
      aptRoots.set(path.basename(relative), file);
    }
    verifyOpenPgp({
      publicKeyPath,
      signaturePath: aptRoots.get('Release.gpg'),
      inputPath: aptRoots.get('Release'),
      signingFingerprint: config.signing.signingFingerprint
    });
    verifyOpenPgp({
      publicKeyPath,
      inputPath: aptRoots.get('InRelease'),
      signingFingerprint: config.signing.signingFingerprint
    });
    const after = await readStatus();
    if (after.inactive || !exactPointer(before, after)) throw new Error('repository pointer changed during freshness inspection');
    const releaseDate = Date.parse(closure.repositories?.apt?.releaseDate ?? '');
    const validUntil = Date.parse(closure.repositories?.apt?.validUntil ?? '');
    const releaseText = fs.readFileSync(aptRoots.get('Release'), 'utf8');
    const signedReleaseDate = Date.parse(releaseText.match(/^Date:\s*(.+)$/mu)?.[1] ?? '');
    const signedValidUntil = Date.parse(releaseText.match(/^Valid-Until:\s*(.+)$/mu)?.[1] ?? '');
    const now = options.now instanceof Date ? options.now : new Date();
    if (!Number.isFinite(releaseDate) || !Number.isFinite(validUntil)
        || signedReleaseDate !== releaseDate || signedValidUntil !== validUntil
        || validUntil - releaseDate !== config.repositoryMetadata.aptValidForHours * 60 * 60 * 1000
        || releaseDate > now.getTime() + 5 * 60 * 1000) {
      throw new Error('active apt validity window is invalid');
    }
    const remainingHours = (validUntil - now.getTime()) / (60 * 60 * 1000);
    return {
      schemaVersion: 1,
      passed: true,
      channel: options.channel,
      status: 'active',
      refreshRequired: remainingHours <= config.repositoryMetadata.refreshWhenRemainingHours,
      critical: remainingHours <= config.repositoryMetadata.criticalRemainingHours,
      releaseDate: new Date(releaseDate).toISOString(),
      validUntil: new Date(validUntil).toISOString(),
      remainingHours,
      current: before,
      version: closure.version,
      sourceCommit: closure.gitCommit,
      packageSetRootSha256: closure.packageSetRootSha256
    };
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`unexpected argument: ${argument}`);
    const next = argv[++index];
    if (!next || next.startsWith('--')) throw new Error(`missing value for ${argument}`);
    values[argument.slice(2).replaceAll('-', '_')] = next;
  }
  return values;
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, file);
  } finally { fs.rmSync(temporary, { force: true }); }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const token = process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN;
  const result = await inspectLinuxRepositoryFreshness({
    repoRoot,
    channel: args.channel,
    token,
    baseUrl: process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? PRODUCTION_ORIGIN,
    configPath: path.resolve(args.config ?? path.join(repoRoot, 'packaging/linux/distribution-channels.json'))
  });
  if (args.output) atomicJson(path.resolve(args.output), result);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
