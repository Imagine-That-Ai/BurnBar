#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const productionOrigin = 'https://downloads.burnbar.ai';
const channels = new Set(['stable', 'prerelease', 'nightly']);
const sha256Pattern = /^[a-f0-9]{64}$/u;
const tokenPattern = /^[A-Za-z0-9._~+/=-]{32,4096}$/u;
const etagPattern = /^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u;
const safeBasenamePattern = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$/u;
const maxObjectBytes = 16 * 1024 * 1024;
const maxResponseBytes = 16 * 1024;
const attestationType = 'https://openburnbar.dev/attestations/linux-repository-refresh/v1';
const attestationIssuer = 'https://token.actions.githubusercontent.com';
const attestationIdentity = 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-repository-refresh.yml@refs/heads/main';
const allowedEvidenceFiles = new Set([
  'latest-linux-feed-check.json',
  'repository-freshness.json',
  'repository-refresh-build.json',
  'repository-refresh-feed-rebind.json',
  'repository-refresh-feed-verification.json',
  'repository-refresh-fetch.json',
  'repository-refresh-predicate.json',
  'repository-refresh-preview-lifecycle.json',
  'repository-refresh-public-lifecycle.json',
  'repository-refresh-public-verification.json',
  'repository-refresh-transaction.json',
  'repository-refresh-transaction.json.sigstore.json',
  'repository-refresh-upload.json'
]);

function baseOrigin(value, allowLocalTestOrigin) {
  const url = new URL(value);
  if (url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('repository evidence upload origin must be a bare origin');
  }
  if (url.origin === productionOrigin) return url;
  if (allowLocalTestOrigin === true && ['127.0.0.1', 'localhost'].includes(url.hostname)
      && ['http:', 'https:'].includes(url.protocol)) return url;
  throw new Error(`repository evidence upload must use ${productionOrigin}`);
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function safeBasename(file) {
  const name = path.basename(file);
  if (!safeBasenamePattern.test(name) || name === '.' || name === '..' || name.includes('..')) {
    throw new Error(`repository evidence file has an unsafe basename: ${name}`);
  }
  return name;
}

function regularFile(file, label) {
  let stat;
  try { stat = fs.lstatSync(file); } catch { throw new Error(`${label} is missing: ${file}`); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 || stat.size > maxObjectBytes) {
    throw new Error(`${label} must be a non-symbolic-link file containing 1-${maxObjectBytes} bytes`);
  }
  return stat;
}

function readJson(file, label) {
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { throw new Error(`${label} is not valid JSON`); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`);
  return value;
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
  }
  return value;
}

function embeddedAttestationPredicate(bundlePath) {
  const bundle = readJson(bundlePath, 'repository refresh Sigstore bundle');
  const acceptedMediaTypes = new Set([
    'application/vnd.dev.sigstore.bundle.v0.3+json',
    'application/vnd.dev.sigstore.bundle+json;version=0.3'
  ]);
  const envelope = bundle.dsseEnvelope;
  if (!acceptedMediaTypes.has(bundle.mediaType) || !envelope || typeof envelope !== 'object'
      || envelope.payloadType !== 'application/vnd.in-toto+json'
      || !Array.isArray(envelope.signatures) || envelope.signatures.length !== 1
      || typeof envelope.payload !== 'string'
      || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(envelope.payload)) {
    throw new Error('repository refresh Sigstore bundle has an invalid DSSE envelope');
  }
  let statement;
  try { statement = JSON.parse(Buffer.from(envelope.payload, 'base64').toString('utf8')); } catch {
    throw new Error('repository refresh Sigstore bundle payload is not a valid in-toto statement');
  }
  if (!statement || typeof statement !== 'object' || Array.isArray(statement)
      || statement.predicateType !== attestationType
      || !statement.predicate || typeof statement.predicate !== 'object' || Array.isArray(statement.predicate)) {
    throw new Error('repository refresh Sigstore statement has an invalid predicate');
  }
  return statement.predicate;
}

async function fileIdentity(file, role) {
  const digest = crypto.createHash('sha256');
  let size = 0;
  for await (const chunk of fs.createReadStream(file)) {
    size += chunk.length;
    if (size > maxObjectBytes) throw new Error(`repository evidence input exceeds ${maxObjectBytes} bytes: ${file}`);
    digest.update(chunk);
  }
  return { file: safeBasename(file), role, sha256: digest.digest('hex'), size, source: file };
}

function publicIdentity(row) {
  return { file: row.file, role: row.role, sha256: row.sha256, size: row.size };
}

function receiptIdentity(row) {
  return { file: row.file, sha256: row.sha256, size: row.size };
}

function exactRows(actual, expected, label) {
  const normalize = (rows) => [...rows].sort((left, right) => left.file.localeCompare(right.file));
  if (JSON.stringify(normalize(actual ?? [])) !== JSON.stringify(normalize(expected))) {
    throw new Error(`${label} does not bind the exact immutable input closure`);
  }
}

function writeJsonCreateOnly(output, value) {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const temporary = `${output}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.linkSync(temporary, output);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

async function responseJson(response, key) {
  const declared = response.headers.get('content-length');
  if (declared !== null && (!/^(0|[1-9][0-9]*)$/u.test(declared) || Number(declared) > maxResponseBytes)) {
    throw new Error(`immutable evidence upload returned an oversized response for ${key}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > maxResponseBytes) throw new Error(`immutable evidence upload returned an oversized response for ${key}`);
  try { return JSON.parse(bytes.toString('utf8')); } catch {
    throw new Error(`immutable evidence upload returned invalid JSON for ${key}`);
  }
}

async function uploadObject(origin, token, object, fetchImpl) {
  const response = await fetchImpl(new URL('/linux/repository-upload/immutable', origin), {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${token}`,
      'X-OpenBurnBar-Object-Key': object.key,
      'X-OpenBurnBar-Object-Sha256': object.sha256,
      'Content-Type': object.file.endsWith('.json')
        ? 'application/json; charset=utf-8' : 'application/pgp-signature',
      'Content-Length': String(object.size)
    },
    body: fs.createReadStream(object.source),
    duplex: 'half',
    redirect: 'error'
  });
  if (![200, 201].includes(response.status)) {
    const body = await response.text();
    throw new Error(`immutable evidence upload failed for ${object.key}: HTTP ${response.status}: ${body.slice(0, 500)}`);
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
    throw new Error(`immutable evidence upload response does not bind the requested object: ${object.key}`);
  }
  return result;
}

export function verifyRefreshAttestation({ bundlePath, transactionPath }, spawnImpl = spawnSync) {
  const result = spawnImpl('cosign', [
    'verify-blob-attestation',
    '--bundle', bundlePath,
    '--type', attestationType,
    '--certificate-identity', attestationIdentity,
    '--certificate-oidc-issuer', attestationIssuer,
    transactionPath
  ], { encoding: 'utf8', maxBuffer: 1024 * 1024 });
  if (result.error || result.status !== 0) {
    const detail = String(result.stderr ?? result.error?.message ?? '').trim().slice(0, 500);
    throw new Error(`repository refresh Sigstore attestation verification failed${detail ? `: ${detail}` : ''}`);
  }
  return { type: attestationType, issuer: attestationIssuer, identity: attestationIdentity };
}

export async function uploadLinuxRepositoryRefreshEvidence(options, fetchImpl = fetch) {
  if (typeof options.token !== 'string' || !tokenPattern.test(options.token)) {
    throw new Error('repository evidence upload token must use the approved 32 to 4096 character alphabet');
  }
  const origin = baseOrigin(options.baseUrl ?? productionOrigin, options.allowLocalTestOrigin);
  const evidenceRoot = path.resolve(options.evidenceRoot ?? '');
  let rootStat;
  try { rootStat = fs.lstatSync(evidenceRoot); } catch { throw new Error('repository evidence root is missing'); }
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    throw new Error('repository evidence root must be a non-symbolic-link directory');
  }
  const manifestPath = path.resolve(options.manifestPath ?? path.join(evidenceRoot, 'repository-refresh-evidence-closure.json'));
  if (path.dirname(manifestPath) !== evidenceRoot || safeBasename(manifestPath) !== 'repository-refresh-evidence-closure.json') {
    throw new Error('repository evidence closure must use its canonical basename directly inside the evidence root');
  }
  if (fs.existsSync(manifestPath)) throw new Error('repository evidence closure already exists');
  const receiptPath = path.resolve(options.receiptPath ?? '');
  if (!options.receiptPath || isWithin(evidenceRoot, receiptPath)) {
    throw new Error('repository evidence upload receipt must be outside the evidence input root');
  }
  if (fs.existsSync(receiptPath)) throw new Error('repository evidence upload receipt already exists');

  const externalFiles = [
    ['activation-receipt', path.resolve(options.activationReceiptPath ?? '')],
    ['repository-closure', path.resolve(options.repositoryClosurePath ?? '')],
    ['repository-closure-signature', path.resolve(options.repositoryClosureSignaturePath ?? '')]
  ];
  for (const [role, file] of externalFiles) {
    if (!options[role === 'activation-receipt' ? 'activationReceiptPath'
      : role === 'repository-closure' ? 'repositoryClosurePath' : 'repositoryClosureSignaturePath']) {
      throw new Error(`${role} path is required`);
    }
    if (isWithin(evidenceRoot, file)) throw new Error(`${role} must be outside the evidence input root`);
    regularFile(file, role);
  }

  const evidenceEntries = fs.readdirSync(evidenceRoot, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name));
  const evidencePaths = [];
  for (const entry of evidenceEntries) {
    const file = path.join(evidenceRoot, entry.name);
    safeBasename(file);
    if (entry.isSymbolicLink() || !entry.isFile() || !allowedEvidenceFiles.has(entry.name)) {
      throw new Error(`repository evidence root contains an unsupported entry: ${entry.name}`);
    }
    regularFile(file, 'repository evidence file');
    readJson(file, `repository evidence file ${entry.name}`);
    evidencePaths.push(file);
  }
  const requiredEvidence = [
    'repository-refresh-transaction.json',
    'repository-refresh-predicate.json',
    'repository-refresh-transaction.json.sigstore.json'
  ];
  for (const name of requiredEvidence) {
    if (!evidenceEntries.some((entry) => entry.name === name)) {
      throw new Error(`repository evidence root is missing required attestation input: ${name}`);
    }
  }

  const evidenceRows = await Promise.all(evidencePaths.map((file) => fileIdentity(file, 'evidence')));
  const externalRows = await Promise.all(externalFiles.map(([role, file]) => fileIdentity(file, role)));
  const names = [...evidenceRows, ...externalRows].map((row) => row.file);
  if (new Set(names).size !== names.length) throw new Error('repository evidence inputs have duplicate basenames');

  const closureRow = externalRows.find((row) => row.role === 'repository-closure');
  const closure = readJson(closureRow.source, 'refreshed repository closure');
  if (closure.schemaVersion !== 2 || closure.refresh?.kind !== 'apt-expiry' || !channels.has(closure.channel)
      || !sha256Pattern.test(closure.refresh?.previousSnapshotId ?? '')
      || !sha256Pattern.test(closure.packageSetRootSha256 ?? '')
      || !Number.isFinite(Date.parse(closure.repositories?.apt?.releaseDate ?? ''))
      || !Number.isFinite(Date.parse(closure.repositories?.apt?.validUntil ?? ''))
      || crypto.createHash('sha256').update(fs.readFileSync(closureRow.source)).digest('hex') !== closureRow.sha256) {
    throw new Error('refreshed repository closure identity is invalid');
  }
  const snapshotId = closureRow.sha256;
  const activationRow = externalRows.find((row) => row.role === 'activation-receipt');
  const activation = readJson(activationRow.source, 'repository activation receipt');
  const activationRecord = activation.result?.activation;
  if (activation.dryRun !== false || activationRecord?.mode !== 'refresh'
      || activationRecord.channel !== closure.channel || activationRecord.snapshotId !== snapshotId
      || activationRecord.version !== closure.version || activationRecord.sourceCommit !== closure.gitCommit
      || !Number.isSafeInteger(activationRecord.generation) || activationRecord.generation < 1) {
    throw new Error('repository activation receipt does not bind the refreshed closure');
  }

  const transactionFile = path.join(evidenceRoot, 'repository-refresh-transaction.json');
  const transaction = readJson(transactionFile, 'repository refresh transaction');
  const expectedPreviousSnapshotId = closure.refresh?.previousSnapshotId;
  if (transaction.schemaVersion !== 1 || transaction.operation !== 'linux-repository-metadata-refresh'
      || transaction.channel !== closure.channel || transaction.snapshotId !== snapshotId
      || transaction.activationGeneration !== activationRecord.generation
      || transaction.version !== closure.version || transaction.sourceCommit !== closure.gitCommit
      || transaction.previousSnapshotId !== expectedPreviousSnapshotId
      || activationRecord.previousSnapshotId !== expectedPreviousSnapshotId
      || transaction.packageSetRootSha256 !== closure.packageSetRootSha256
      || transaction.releaseDate !== closure.repositories?.apt?.releaseDate
      || transaction.validUntil !== closure.repositories?.apt?.validUntil
      || !/^[a-f0-9]{40}$/u.test(transaction.toolCommit ?? '')
      || !/^https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/actions\/runs\/[1-9][0-9]*$/u.test(transaction.runUrl ?? '')) {
    throw new Error('repository refresh transaction identity is invalid');
  }
  exactRows(transaction.transactionInputs, externalRows.map(receiptIdentity), 'repository refresh transaction inputs');
  const receiptRows = evidenceRows.filter((row) => !requiredEvidence.includes(row.file));
  exactRows(transaction.receipts, receiptRows.map(receiptIdentity), 'repository refresh transaction receipts');
  const transactionRow = evidenceRows.find((row) => row.file === 'repository-refresh-transaction.json');
  const predicate = readJson(
    path.join(evidenceRoot, 'repository-refresh-predicate.json'),
    'repository refresh attestation predicate'
  );
  if (JSON.stringify(Object.keys(predicate).sort()) !== JSON.stringify(['predicateType', 'subject', 'transaction'])
      || predicate.predicateType !== attestationType
      || JSON.stringify(predicate.subject) !== JSON.stringify(receiptIdentity(transactionRow))
      || JSON.stringify(predicate.transaction) !== JSON.stringify(transaction)) {
    throw new Error('repository refresh attestation predicate does not bind the exact transaction');
  }
  const bundlePath = path.join(evidenceRoot, 'repository-refresh-transaction.json.sigstore.json');
  const signedPredicate = embeddedAttestationPredicate(bundlePath);
  if (JSON.stringify(canonicalValue(signedPredicate)) !== JSON.stringify(canonicalValue(predicate))) {
    throw new Error('repository refresh Sigstore statement predicate does not equal the local predicate');
  }
  const attestation = await (options.verifyAttestation ?? verifyRefreshAttestation)({
    bundlePath,
    transactionPath: transactionFile
  });
  if (attestation?.type !== attestationType || attestation?.issuer !== attestationIssuer
      || attestation?.identity !== attestationIdentity) {
    throw new Error('repository refresh Sigstore verifier did not prove the pinned workflow identity');
  }
  for (const file of [
    'repository-refresh-transaction.json',
    'repository-refresh-predicate.json',
    'repository-refresh-transaction.json.sigstore.json'
  ]) {
    const before = evidenceRows.find((row) => row.file === file);
    const after = await fileIdentity(path.join(evidenceRoot, file), before.role);
    if (after.sha256 !== before.sha256 || after.size !== before.size) {
      throw new Error(`repository refresh attestation input changed during verification: ${file}`);
    }
  }

  const generation = activationRecord.generation;
  const prefix = `linux/repository-refresh-evidence/${closure.channel}/${snapshotId}/${generation}`;
  const closureDocument = {
    schemaVersion: 1,
    operation: 'linux-repository-refresh-evidence',
    channel: closure.channel,
    version: closure.version,
    sourceCommit: closure.gitCommit,
    snapshotId,
    activationGeneration: generation,
    attestation,
    prefix,
    transactionManifest: receiptIdentity(transactionRow),
    files: [...evidenceRows, ...externalRows].map(publicIdentity)
      .sort((left, right) => left.file.localeCompare(right.file))
  };
  writeJsonCreateOnly(manifestPath, closureDocument);
  const manifestRow = await fileIdentity(manifestPath, 'evidence-closure');
  const uploadRows = [...evidenceRows, ...externalRows, manifestRow].map((row) => ({
    ...row,
    key: `${prefix}/${row.file}`
  }));
  const operations = [];
  for (const row of uploadRows) {
    const result = await uploadObject(origin, options.token, row, fetchImpl);
    operations.push({ key: row.key, sha256: row.sha256, size: row.size, status: result.status, etag: result.etag });
  }
  const receipt = {
    schemaVersion: 1,
    operation: 'upload-linux-repository-refresh-evidence',
    channel: closure.channel,
    snapshotId,
    activationGeneration: generation,
    prefix,
    evidenceClosure: receiptIdentity(manifestRow),
    objectCount: operations.length,
    operations,
    completedAt: new Date().toISOString()
  };
  writeJsonCreateOnly(receiptPath, receipt);
  return receipt;
}

function parseArgs(argv) {
  const values = {};
  const allowed = new Set([
    'evidence_root', 'activation_receipt', 'repository_closure', 'repository_closure_signature',
    'manifest', 'receipt', 'base_url'
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`unexpected argument: ${argument}`);
    const next = argv[++index];
    if (!next || next.startsWith('--')) throw new Error(`missing value for ${argument}`);
    const key = argument.slice(2).replaceAll('-', '_');
    if (!allowed.has(key) || values[key] !== undefined) throw new Error(`unsupported or duplicate argument: ${argument}`);
    values[key] = next;
  }
  return values;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const releaseOut = process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-refresh');
  const repositoryOut = process.env.OPENBURNBAR_LINUX_REPOSITORY_OUT ?? path.join(releaseOut, 'repositories');
  const evidenceRoot = args.evidence_root ?? process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT;
  const result = await uploadLinuxRepositoryRefreshEvidence({
    evidenceRoot,
    activationReceiptPath: args.activation_receipt ?? path.join(releaseOut, 'repository-activation.json'),
    repositoryClosurePath: args.repository_closure ?? path.join(repositoryOut, 'repository-closure.json'),
    repositoryClosureSignaturePath: args.repository_closure_signature ?? path.join(repositoryOut, 'repository-closure.json.asc'),
    manifestPath: args.manifest ?? path.join(evidenceRoot ?? '', 'repository-refresh-evidence-closure.json'),
    receiptPath: args.receipt ?? path.join(releaseOut, 'repository-refresh-evidence-upload.json'),
    baseUrl: args.base_url ?? process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? productionOrigin,
    token: process.env.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
