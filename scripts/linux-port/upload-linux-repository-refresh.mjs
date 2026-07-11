#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const productionRepositoryOrigin = 'https://downloads.burnbar.ai';
const channels = new Set(['stable', 'prerelease', 'nightly']);
const sha256Pattern = /^[a-f0-9]{64}$/u;
const versionPattern = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const commitPattern = /^[a-f0-9]{40}$/u;
const tokenPattern = /^[A-Za-z0-9._~+/=-]{32,4096}$/u;
const etagPattern = /^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u;
const closurePathPattern = /^(apt|rpm)\/[A-Za-z0-9._+~\/-]+$/u;
const maxClosureBytes = 1024 * 1024;
const maxClosureFiles = 512;
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

function parseClosure(bytes) {
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
      || ![1, 2].includes(closure.schemaVersion) || !channels.has(closure.channel)
      || !versionPattern.test(closure.version ?? '') || !commitPattern.test(closure.gitCommit ?? '')) {
    throw new Error('repository closure identity is invalid');
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

function walkRepository(root, directory = root) {
  const relatives = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name))) {
    const full = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`repository contains a symbolic link: ${path.relative(root, full)}`);
    if (entry.isDirectory()) relatives.push(...walkRepository(root, full));
    else if (entry.isFile()) relatives.push(path.relative(root, full).split(path.sep).join('/'));
    else throw new Error(`repository contains an unsupported filesystem entry: ${path.relative(root, full)}`);
  }
  return relatives;
}

async function hashFile(file) {
  const digest = crypto.createHash('sha256');
  let size = 0;
  for await (const chunk of fs.createReadStream(file)) {
    size += chunk.length;
    digest.update(chunk);
  }
  return { sha256: digest.digest('hex'), size };
}

function isSharedLeaf(relative) {
  return relative.endsWith('.deb') || relative.endsWith('.rpm') || relative.includes('/by-hash/')
    || (/^rpm\/(stable|prerelease|nightly)\/(aarch64|x86_64)\/repodata\/[^/]*-[^/]*$/u.test(relative));
}

function contentType(relative) {
  if (relative.endsWith('.json')) return 'application/json; charset=utf-8';
  if (relative.endsWith('.xml')) return 'application/xml';
  if (relative.endsWith('.gz')) return 'application/gzip';
  if (relative.endsWith('.deb')) return 'application/vnd.debian.binary-package';
  if (relative.endsWith('.rpm')) return 'application/x-rpm';
  if (relative.endsWith('.repo') || relative.endsWith('.sources')
      || relative.endsWith('/Release') || relative.endsWith('/InRelease')
      || relative.endsWith('/Packages')) return 'text/plain; charset=utf-8';
  return 'application/octet-stream';
}

function assertRepositoryOnlyKey(key, snapshotPrefix, allowShared) {
  const shared = allowShared && /^linux\/(apt|rpm)\/[A-Za-z0-9._+~\/-]+$/u.test(key);
  const snapshot = key.startsWith(`${snapshotPrefix}/`);
  const forbiddenNamespace = key.startsWith('linux/releases/') || key.startsWith('linux/update-feed')
    || key.startsWith('linux/repository-activations/') || key.includes('/latest-linux');
  if ((!shared && !snapshot) || key.includes('//')
      || key.split('/').some((part) => part === '.' || part === '..') || forbiddenNamespace) {
    throw new Error(`refusing non-repository immutable object key: ${key}`);
  }
}

async function responseJson(response, key) {
  const declared = response.headers.get('content-length');
  if (declared !== null && (!/^(0|[1-9][0-9]*)$/u.test(declared) || Number(declared) > 16 * 1024)) {
    throw new Error(`immutable upload returned an oversized response for ${key}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 16 * 1024) throw new Error(`immutable upload returned an oversized response for ${key}`);
  try {
    return JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new Error(`immutable upload returned invalid JSON for ${key}`);
  }
}

async function uploadObject(baseUrl, token, object, fetchImpl) {
  const response = await fetchImpl(new URL('/linux/repository-upload/immutable', baseUrl), {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${token}`,
      'X-OpenBurnBar-Object-Key': object.key,
      'X-OpenBurnBar-Object-Sha256': object.sha256,
      'Content-Type': object.contentType,
      'Content-Length': String(object.size)
    },
    body: fs.createReadStream(object.file),
    duplex: 'half',
    redirect: 'error'
  });
  if (![200, 201].includes(response.status)) {
    const body = await response.text();
    throw new Error(`immutable repository upload failed for ${object.key}: HTTP ${response.status}: ${body.slice(0, 500)}`);
  }
  const result = await responseJson(response, object.key);
  const keys = result && typeof result === 'object' && !Array.isArray(result) ? Object.keys(result).sort() : [];
  const validStatus = ['created', 'unchanged', 'verified-legacy'].includes(result?.status);
  const validHttpStatus = (result?.status === 'created' && response.status === 201)
    || (['unchanged', 'verified-legacy'].includes(result?.status) && response.status === 200);
  if (JSON.stringify(keys) !== JSON.stringify(['etag', 'key', 'schemaVersion', 'sha256', 'size', 'status'])
      || result.schemaVersion !== 1 || !validStatus || !validHttpStatus
      || result.key !== object.key || result.sha256 !== object.sha256 || result.size !== object.size
      || !etagPattern.test(result.etag ?? '')) {
    throw new Error(`immutable upload response does not bind the requested object: ${object.key}`);
  }
  return result;
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

export async function uploadLinuxRepositoryRefresh(options, fetchImpl = fetch) {
  if (typeof options.token !== 'string' || !tokenPattern.test(options.token)) {
    throw new Error('repository upload token must use the approved 32 to 4096 character alphabet');
  }
  if (!options.repositoryRoot) throw new Error('repository root is required');
  const baseUrl = repositoryBaseUrl(options.baseUrl ?? productionRepositoryOrigin, options.allowLocalTestOrigin);
  const repositoryRoot = path.resolve(options.repositoryRoot);
  const rootStat = fs.lstatSync(repositoryRoot);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('repository root must be a non-symbolic-link directory');
  const receiptPath = options.receiptPath ? path.resolve(options.receiptPath) : null;
  if (receiptPath && (receiptPath === repositoryRoot
      || (!path.relative(repositoryRoot, receiptPath).startsWith('..')
        && !path.isAbsolute(path.relative(repositoryRoot, receiptPath))))) {
    throw new Error('repository refresh upload receipt must be outside the repository root');
  }
  if (receiptPath && fs.existsSync(receiptPath)) throw new Error('repository refresh upload receipt already exists');

  const closurePath = path.join(repositoryRoot, 'repository-closure.json');
  const signaturePath = path.join(repositoryRoot, 'repository-closure.json.asc');
  const closureStat = fs.lstatSync(closurePath);
  const signatureStat = fs.lstatSync(signaturePath);
  if (!closureStat.isFile() || closureStat.isSymbolicLink()
      || closureStat.size === 0 || closureStat.size > maxClosureBytes) {
    throw new Error(`repository closure must be a regular 1-${maxClosureBytes}-byte file`);
  }
  if (!signatureStat.isFile() || signatureStat.isSymbolicLink()
      || signatureStat.size === 0 || signatureStat.size > maxClosureBytes) {
    throw new Error(`repository closure signature must be a regular 1-${maxClosureBytes}-byte file`);
  }
  const closureBytes = fs.readFileSync(closurePath);
  const closure = parseClosure(closureBytes);
  const snapshotId = crypto.createHash('sha256').update(closureBytes).digest('hex');
  const expected = new Set(['repository-closure.json', 'repository-closure.json.asc', ...closure.files.map((row) => row.file)]);
  if (fs.existsSync(path.join(repositoryRoot, 'repository-lifecycle.json'))) expected.add('repository-lifecycle.json');
  const actual = walkRepository(repositoryRoot);
  const unexpected = actual.filter((relative) => !expected.has(relative));
  const missing = [...expected].filter((relative) => !actual.includes(relative));
  if (unexpected.length > 0 || missing.length > 0) {
    throw new Error(`repository tree does not exactly match its closure (unexpected: ${unexpected.join(', ') || 'none'}; missing: ${missing.join(', ') || 'none'})`);
  }
  const local = new Map();
  for (const relative of actual) {
    const file = path.join(repositoryRoot, ...relative.split('/'));
    const identity = await hashFile(file);
    if (identity.size > maxObjectBytes) throw new Error(`repository object exceeds the upload limit: ${relative}`);
    const row = closure.files.find((item) => item.file === relative);
    if (row && (row.size !== identity.size || row.sha256 !== identity.sha256)) {
      throw new Error(`repository object does not match its closure: ${relative}`);
    }
    local.set(relative, { file, relative, ...identity, contentType: contentType(relative) });
  }

  const snapshotPrefix = `linux/repository-snapshots/${closure.channel}/${snapshotId}`;
  const shared = closure.files.filter((row) => isSharedLeaf(row.file)).map((row) => ({
    ...local.get(row.file), key: `linux/${row.file}`
  }));
  const snapshot = ['repository-closure.json', 'repository-closure.json.asc', ...closure.files.map((row) => row.file),
    ...(expected.has('repository-lifecycle.json') ? ['repository-lifecycle.json'] : [])].map((relative) => ({
    ...local.get(relative), key: `${snapshotPrefix}/${relative}`
  }));
  for (const object of shared) assertRepositoryOnlyKey(object.key, snapshotPrefix, true);
  for (const object of snapshot) assertRepositoryOnlyKey(object.key, snapshotPrefix, false);

  const operations = [];
  for (const object of [...shared, ...snapshot]) {
    const result = await uploadObject(baseUrl, options.token, object, fetchImpl);
    operations.push({ key: object.key, sha256: object.sha256, size: object.size, status: result.status, etag: result.etag });
  }
  const receipt = {
    schemaVersion: 1,
    operation: 'upload-linux-repository-refresh',
    channel: closure.channel,
    snapshotId,
    version: closure.version,
    sourceCommit: closure.gitCommit,
    sharedObjectCount: shared.length,
    snapshotObjectCount: snapshot.length,
    operationCount: operations.length,
    operations,
    completedAt: new Date().toISOString()
  };
  if (receiptPath) writeJsonCreateOnly(receiptPath, receipt);
  return receipt;
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`unexpected argument: ${argument}`);
    const next = argv[++index];
    if (!next || next.startsWith('--')) throw new Error(`missing value for ${argument}`);
    const key = argument.slice(2).replaceAll('-', '_');
    if (!['repository_root', 'receipt', 'base_url'].includes(key) || values[key] !== undefined) {
      throw new Error(`unsupported or duplicate argument: ${argument}`);
    }
    values[key] = next;
  }
  return values;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const workRoot = path.join(repoRoot, '.linux-refresh');
  const result = await uploadLinuxRepositoryRefresh({
    repositoryRoot: args.repository_root ?? process.env.OPENBURNBAR_LINUX_REPOSITORY_REFRESH_OUT
      ?? path.join(workRoot, 'refreshed-repository'),
    receiptPath: args.receipt ?? process.env.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_RECEIPT
      ?? path.join(workRoot, 'repository-upload.json'),
    baseUrl: args.base_url ?? process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? productionRepositoryOrigin,
    token: process.env.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
