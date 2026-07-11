#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import { validateActivationStatus } from './lib/linux-repository-activation.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const productionRepositoryOrigin = 'https://downloads.burnbar.ai';
const channels = new Set(['stable', 'prerelease', 'nightly']);
const sha256Pattern = /^[a-f0-9]{64}$/u;
const versionPattern = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const commitPattern = /^[a-f0-9]{40}$/u;
const tokenPattern = /^[A-Za-z0-9._~+/=-]{32,4096}$/u;
const closurePathPattern = /^(apt|rpm)\/[A-Za-z0-9._+~\/-]+$/u;
const maxClosureBytes = 1024 * 1024;
const maxClosureFiles = 512;
const maxSignatureBytes = 1024 * 1024;
const maxObjectBytes = 5 * 1024 * 1024 * 1024;

function repositoryBaseUrl(value, allowLocalTestOrigin) {
  if (value === productionRepositoryOrigin || value === `${productionRepositoryOrigin}/`) {
    return new URL(productionRepositoryOrigin);
  }
  const url = new URL(value);
  const isBareOrigin = url.username === '' && url.password === '' && url.pathname === '/'
    && url.search === '' && url.hash === '';
  if (!isBareOrigin) throw new Error('repository router URL must be a bare origin without credentials, path, query, or fragment');
  const isLocalTestOrigin = allowLocalTestOrigin === true && ['http:', 'https:'].includes(url.protocol)
    && (url.hostname === '127.0.0.1' || url.hostname === 'localhost');
  if (!isLocalTestOrigin) throw new Error(`repository router URL must use ${productionRepositoryOrigin}`);
  return url;
}

function validateClosure(bytes, expected) {
  if (bytes.length === 0 || bytes.length > maxClosureBytes) {
    throw new Error(`repository closure must contain 1-${maxClosureBytes} bytes`);
  }
  let closure;
  try {
    closure = JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new Error('repository closure is not valid JSON');
  }
  if (!closure || typeof closure !== 'object' || Array.isArray(closure)
      || ![1, 2].includes(closure.schemaVersion)
      || closure.channel !== expected.channel || !channels.has(closure.channel)
      || closure.version !== expected.version || !versionPattern.test(closure.version ?? '')
      || closure.gitCommit !== expected.sourceCommit || !commitPattern.test(closure.gitCommit ?? '')) {
    throw new Error('repository closure identity does not match the active parent snapshot');
  }
  if (!Array.isArray(closure.files) || closure.files.length === 0 || closure.files.length > maxClosureFiles) {
    throw new Error(`repository closure must contain 1-${maxClosureFiles} files`);
  }
  const seen = new Set();
  for (const row of closure.files) {
    const keys = row && typeof row === 'object' && !Array.isArray(row) ? Object.keys(row).sort() : [];
    if (JSON.stringify(keys) !== JSON.stringify(['file', 'sha256', 'size'])
        || typeof row.file !== 'string' || row.file.length > 500 || !closurePathPattern.test(row.file)
        || row.file.includes('//') || row.file.split('/').some((part) => part === '.' || part === '..')
        || !sha256Pattern.test(row.sha256 ?? '') || !Number.isSafeInteger(row.size)
        || row.size < 0 || row.size > maxObjectBytes || seen.has(row.file)) {
      throw new Error('repository closure contains an invalid or duplicate file record');
    }
    seen.add(row.file);
  }
  return closure;
}

async function boundedResponseBytes(response, label, maximum) {
  const declared = response.headers.get('content-length');
  if (declared !== null && (!/^(0|[1-9][0-9]*)$/u.test(declared) || Number(declared) > maximum)) {
    throw new Error(`${label} exceeds the ${maximum}-byte limit`);
  }
  if (!response.body) throw new Error(`${label} response has no body`);
  const chunks = [];
  let size = 0;
  for await (const chunk of Readable.fromWeb(response.body)) {
    size += chunk.length;
    if (size > maximum) throw new Error(`${label} exceeds the ${maximum}-byte limit`);
    chunks.push(chunk);
  }
  if (declared !== null && size !== Number(declared)) throw new Error(`${label} Content-Length does not match its bytes`);
  return Buffer.concat(chunks, size);
}

async function fetchStatus(baseUrl, channel, token, fetchImpl) {
  const url = new URL('/linux/repository-admin/status', baseUrl);
  url.searchParams.set('channel', channel);
  const response = await fetchImpl(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', 'Accept-Encoding': 'identity' },
    redirect: 'error'
  });
  if (!response.ok) throw new Error(`repository activation status failed: HTTP ${response.status}`);
  let body;
  try {
    body = JSON.parse((await boundedResponseBytes(response, 'repository activation status', 64 * 1024)).toString('utf8'));
  } catch (error) {
    if (error.message.startsWith('repository activation status')) throw error;
    throw new Error('repository activation status is not valid JSON');
  }
  const status = validateActivationStatus(body, channel, response.headers.get('etag'));
  if (status.status !== 'active' || status.active.channel !== channel
      || !commitPattern.test(status.active.sourceCommit ?? '')) {
    throw new Error('repository channel does not have a complete active parent snapshot');
  }
  return {
    channel,
    snapshotId: status.active.snapshotId,
    generation: status.active.generation,
    pointerEtag: status.currentPointerEtag,
    version: status.active.version,
    sourceCommit: status.active.sourceCommit
  };
}

function assertSameParent(before, after) {
  for (const field of ['channel', 'snapshotId', 'generation', 'pointerEtag', 'version', 'sourceCommit']) {
    if (before[field] !== after[field]) throw new Error(`active parent repository changed during acquisition (${field})`);
  }
}

async function fetchPreview(baseUrl, parent, relative, fetchImpl) {
  const url = new URL(`/linux/repository-preview/${parent.channel}/${parent.snapshotId}/${relative}`, baseUrl);
  const response = await fetchImpl(url, {
    headers: { Accept: '*/*', 'Accept-Encoding': 'identity' },
    redirect: 'error'
  });
  if (!response.ok) throw new Error(`repository preview fetch failed for ${relative}: HTTP ${response.status}`);
  if (response.headers.get('x-openburnbar-repository-snapshot') !== parent.snapshotId) {
    throw new Error(`repository preview snapshot header mismatch for ${relative}`);
  }
  return response;
}

async function downloadPreviewFile(baseUrl, parent, row, destination, fetchImpl) {
  const response = await fetchPreview(baseUrl, parent, row.file, fetchImpl);
  const declared = response.headers.get('content-length');
  if (declared !== null && (!/^(0|[1-9][0-9]*)$/u.test(declared) || Number(declared) !== row.size)) {
    throw new Error(`repository preview size mismatch for ${row.file} (Content-Length)`);
  }
  if (!response.body) throw new Error(`repository preview response has no body for ${row.file}`);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const digest = crypto.createHash('sha256');
  let size = 0;
  const verifier = new Transform({
    transform(chunk, _encoding, callback) {
      size += chunk.length;
      if (size > row.size) return callback(new Error(`repository preview size mismatch for ${row.file}`));
      digest.update(chunk);
      callback(null, chunk);
    }
  });
  await pipeline(Readable.fromWeb(response.body), verifier, fs.createWriteStream(destination, { flags: 'wx' }));
  if (size !== row.size) throw new Error(`repository preview size mismatch for ${row.file}`);
  if (digest.digest('hex') !== row.sha256) throw new Error(`repository preview checksum mismatch for ${row.file}`);
}

function writeJsonCreateOnly(outputPath, value) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const temporary = `${outputPath}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
    fs.linkSync(temporary, outputPath);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

export async function fetchLinuxRepositorySnapshot(options, fetchImpl = fetch) {
  const channel = options.channel;
  if (!channels.has(channel)) throw new Error('repository channel must be stable, prerelease, or nightly');
  if (typeof options.token !== 'string' || !tokenPattern.test(options.token)) {
    throw new Error('repository activation token must use the approved 32 to 4096 character alphabet');
  }
  if (!options.outputDirectory) throw new Error('repository snapshot output directory is required');
  const outputDirectory = path.resolve(options.outputDirectory);
  const receiptPath = options.receiptPath ? path.resolve(options.receiptPath) : null;
  if (receiptPath && (receiptPath === outputDirectory
      || (!path.relative(outputDirectory, receiptPath).startsWith('..')
        && !path.isAbsolute(path.relative(outputDirectory, receiptPath))))) {
    throw new Error('repository snapshot acquisition receipt must be outside the repository output');
  }
  if (fs.existsSync(outputDirectory)) throw new Error('repository snapshot output directory already exists');
  if (receiptPath && fs.existsSync(receiptPath)) throw new Error('repository snapshot acquisition receipt already exists');
  const baseUrl = repositoryBaseUrl(options.baseUrl ?? productionRepositoryOrigin, options.allowLocalTestOrigin);
  fs.mkdirSync(path.dirname(outputDirectory), { recursive: true });
  const staging = fs.mkdtempSync(path.join(path.dirname(outputDirectory), `.${path.basename(outputDirectory)}.fetch-`));
  let committed = false;
  try {
    const parent = await fetchStatus(baseUrl, channel, options.token, fetchImpl);
    const closureResponse = await fetchPreview(baseUrl, parent, 'repository-closure.json', fetchImpl);
    const closureBytes = await boundedResponseBytes(closureResponse, 'repository closure', maxClosureBytes);
    const closureSha256 = crypto.createHash('sha256').update(closureBytes).digest('hex');
    if (closureSha256 !== parent.snapshotId) throw new Error('repository closure checksum does not match the active parent snapshot');
    const closure = validateClosure(closureBytes, parent);
    fs.writeFileSync(path.join(staging, 'repository-closure.json'), closureBytes, { flag: 'wx' });

    const signatureResponse = await fetchPreview(baseUrl, parent, 'repository-closure.json.asc', fetchImpl);
    const signatureBytes = await boundedResponseBytes(signatureResponse, 'repository closure signature', maxSignatureBytes);
    if (signatureBytes.length === 0) throw new Error('repository closure signature is empty');
    fs.writeFileSync(path.join(staging, 'repository-closure.json.asc'), signatureBytes, { flag: 'wx' });

    for (const row of closure.files) {
      await downloadPreviewFile(baseUrl, parent, row, path.join(staging, ...row.file.split('/')), fetchImpl);
    }
    const finalParent = await fetchStatus(baseUrl, channel, options.token, fetchImpl);
    assertSameParent(parent, finalParent);

    const receipt = {
      schemaVersion: 1,
      operation: 'fetch-linux-repository-snapshot',
      ...parent,
      repositoryRoot: outputDirectory,
      closure: { sha256: closureSha256, size: closureBytes.length },
      signature: {
        sha256: crypto.createHash('sha256').update(signatureBytes).digest('hex'),
        size: signatureBytes.length
      },
      files: closure.files.map(({ file, sha256, size }) => ({ file, sha256, size })),
      fetchedAt: new Date().toISOString()
    };
    fs.renameSync(staging, outputDirectory);
    committed = true;
    try {
      if (receiptPath) writeJsonCreateOnly(receiptPath, receipt);
    } catch (error) {
      fs.rmSync(outputDirectory, { recursive: true, force: true });
      committed = false;
      throw error;
    }
    return receipt;
  } finally {
    if (!committed) fs.rmSync(staging, { recursive: true, force: true });
  }
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`unexpected argument: ${argument}`);
    const next = argv[++index];
    if (!next || next.startsWith('--')) throw new Error(`missing value for ${argument}`);
    const key = argument.slice(2).replaceAll('-', '_');
    if (!['channel', 'output', 'receipt', 'base_url'].includes(key) || values[key] !== undefined) {
      throw new Error(`unsupported or duplicate argument: ${argument}`);
    }
    values[key] = next;
  }
  return values;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const workRoot = path.join(repoRoot, '.linux-refresh');
  const result = await fetchLinuxRepositorySnapshot({
    channel: args.channel ?? process.env.OPENBURNBAR_LINUX_REPOSITORY_CHANNEL,
    outputDirectory: args.output ?? process.env.OPENBURNBAR_LINUX_REPOSITORY_PARENT_OUT
      ?? path.join(workRoot, 'parent-repository'),
    receiptPath: args.receipt ?? process.env.OPENBURNBAR_LINUX_REPOSITORY_SNAPSHOT_RECEIPT
      ?? path.join(workRoot, 'snapshot-acquisition.json'),
    baseUrl: args.base_url ?? process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? productionRepositoryOrigin,
    token: process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
