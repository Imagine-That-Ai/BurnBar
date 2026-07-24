import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { captureP11UsageIngestionProof } from './capture-p11-usage-ingestion-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import {
  P11_PROOF_ROLE,
  P11_SOURCE_CONTRACTS,
  validateP11InstalledSession,
  validateP11Proof
} from './lib/p11-usage-ingestion-proof.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS, readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { materializeP11UsageIngestionSession } from './materialize-p11-usage-ingestion-session.mjs';
import { validateProductRequirement } from './product-validators/P-11.mjs';
import { runP11UsageIngestionSession } from './run-p11-usage-ingestion-session.mjs';

const HEAD = 'b'.repeat(40);
const RUN_ID = '112233';
const DIGEST = `sha256:${'c'.repeat(64)}`;
const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-aarch64';
const VERSION = '1.2.3';
const KEY = `p11-${'d'.repeat(32)}`;
const NOW = Date.now();
const REFERENCE_SECONDS = NOW / 1_000 - 978_307_200;

const EVENT = Object.freeze({
  providerID: 'hermes', modelID: 'minimax-m2.7-highspeed', inputTokens: 420, outputTokens: 170,
  cacheCreationTokens: 12, cacheReadTokens: 34, reasoningTokens: 56, cost: 0.01234,
  recordedAt: REFERENCE_SECONDS, sessionID: 'p11-session-live-001', projectName: 'P11 installed usage proof', confidence: 'exact'
});

function write(file, bytes) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); return file; }
function json(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function jsonl(file, rows) { return write(file, `${rows.map((row) => JSON.stringify(row)).join('\n')}\n`); }
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return { path: path.relative(root, file).split(path.sep).join('/'), sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length };
}

function sourceTree(root) {
  const markerContent = {
    'contracts/provider-ingestion-catalog.json': '{"providerId":"hermes","usageDedupKey":"key","ingestion":"local-parser"}',
    'OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarProviderContracts.swift': 'BurnBarUsageEvent BurnBarUsageConfidence BurnBarRecordUsageRequest',
    'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarUsageRecorder.swift': 'recordedKeys usage_record_skipped_duplicate recentUsage',
    'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCUsage.swift': 'case .usageRecord: case .usageRecent:',
    'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarUsageRecorderTests.swift': 'testUsageRecorderIsIdempotentAcrossReinitialization testUsageRecorderReadsHermesPythonShapedLedgerLine',
    'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarDaemonServerTests.swift': 'testUsageRecordRPCAppendsAndRespectsIdempotency',
    'tools/openburnbar-mcp/burnbar_usage_ledger.py': 'append_usage_record _try_record_via_daemon_socket APPLE_REFERENCE_DATE_OFFSET'
  };
  for (const source of P11_SOURCE_CONTRACTS) write(path.join(root, source), `${markerContent[source]}\n`);
  return P11_SOURCE_CONTRACTS.map((source) => ({ path: source, sha256: record(root, path.join(root, source)).sha256 }));
}

function attestation(root, inputRoot) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
  write(path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'), publicPem);
  const item = (installedPath, bytes, mode) => ({
    path: installedPath, type: 'file', sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length, mode, uid: 0, gid: 0
  });
  const manifest = createInstalledManifest({
    files: [
      item('/usr/bin/openburnbar-daemon', Buffer.from('daemon'), '0755'),
      item('/usr/bin/openburnbar-linux-desktop', Buffer.from('desktop'), '0755'),
      item('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicPem, '0644')
    ], packageVersion: VERSION, gitCommit: HEAD, packageArchitecture: 'aarch64', packageFormat: 'deb', firebaseAppId: '1:123:web:linux'
  });
  const manifestBytes = canonicalJsonBytes(manifest);
  const signatureBytes = signInstalledManifest(manifestBytes, privatePem, publicPem);
  return {
    manifest: record(root, write(path.join(inputRoot, 'raw/installed-manifest.json'), manifestBytes)),
    signature: record(root, write(path.join(inputRoot, 'raw/installed-manifest.json.sig'), signatureBytes))
  };
}

function fixture() {
  const base = path.join(process.cwd(), '.tmp', 'p11-proof-tests');
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'case-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-11', ENVIRONMENT);
  const raw = path.join(inputRoot, 'raw');
  const sourceEvidence = sourceTree(root);
  const installed = attestation(root, inputRoot);
  const target = { idempotencyKey: KEY, event: { ...EVENT } };
  const ledgerBefore = record(root, write(path.join(raw, 'ledger-before.jsonl'), ''));
  const ledgerAfterInsert = record(root, jsonl(path.join(raw, 'ledger-after-insert.jsonl'), [target]));
  const ledgerAfterDuplicate = record(root, jsonl(path.join(raw, 'ledger-after-duplicate.jsonl'), [target]));
  const ledgerAfterRestart = record(root, jsonl(path.join(raw, 'ledger-after-restart.jsonl'), [target]));
  const at = (offset) => new Date(NOW - 60_000 + offset * 1_000).toISOString();
  const recordRow = (phase, inserted, offset) => ({
    at: at(offset), phase,
    request: { method: 'daemon.usage.record', params: { idempotencyKey: KEY, event: { ...EVENT } } },
    response: { result: { idempotencyKey: KEY, inserted, event: { ...EVENT } } }
  });
  const recentRow = (phase, offset) => ({
    at: at(offset), phase, request: { method: 'daemon.usage.recent', params: { limit: 500 } },
    response: { result: { usage: [{ ...EVENT }] } }
  });
  const rpc = {
    producer: 'openburnbar-p11-installed-rpc-runner-v1', transport: 'AF_UNIX newline-framed BurnBarRPC',
    rows: [recordRow('record-first', true, 1), recordRow('record-duplicate', false, 2), recentRow('recent-before-restart', 3), recentRow('recent-after-restart', 7)]
  };
  const malformedMessages = {
    'blank-provider': 'Invalid usage event: providerID must be nonblank and trimmed.',
    'control-model': 'Invalid usage event: modelID must not contain control characters.',
    'oversized-session': 'Invalid usage event: sessionID must not exceed 256 UTF-8 bytes.',
    'token-sum-overflow': 'Invalid usage event: token counts exceed the supported integer range.',
    'negative-token': 'Invalid usage event: inputTokens must be nonnegative.',
    'negative-cost': 'Invalid usage event: cost must be finite and nonnegative.',
    'out-of-range-timestamp': 'Invalid usage event: recordedAt must be on or after 2000 and no more than 15 seconds in the future.'
  };
  const malformedLedgerRows = [target];
  const malformedRows = [];
  for (const [index, name] of ['blank-provider', 'control-model', 'oversized-session', 'token-sum-overflow', 'nonfinite-cost', 'negative-token', 'negative-cost', 'out-of-range-timestamp'].entries()) {
    const rejectedKey = `${KEY}-${name}`;
    const event = { ...EVENT };
    if (name === 'blank-provider') event.providerID = '';
    if (name === 'control-model') event.modelID = 'bad\nmodel';
    if (name === 'oversized-session') event.sessionID = 'x'.repeat(257);
    if (name === 'negative-token') event.inputTokens = -1;
    if (name === 'negative-cost') event.cost = -0.01;
    if (name === 'out-of-range-timestamp') event.recordedAt = -978_307_200;
    const raw = name === 'token-sum-overflow'
      ? `{"id":"raw-overflow","method":"daemon.usage.record","params":{"idempotencyKey":"${rejectedKey}","event":{"inputTokens":9223372036854775807,"outputTokens":1}}}`
      : `{"id":"raw-nonfinite","method":"daemon.usage.record","params":{"idempotencyKey":"${rejectedKey}","event":{"cost":1e309}}}`;
    const beforeBytes = Buffer.from(`${malformedLedgerRows.map((row) => JSON.stringify(row)).join('\n')}\n`);
    const recoveryEvent = { ...EVENT, sessionID: `p11-session-recovery-${name}` };
    const recoveryRecord = { idempotencyKey: rejectedKey, event: recoveryEvent };
    malformedLedgerRows.push(recoveryRecord);
    const recoveredBytes = Buffer.from(`${malformedLedgerRows.map((row) => JSON.stringify(row)).join('\n')}\n`);
    malformedRows.push({
      at: at(4 + index), case: name,
      request: ['token-sum-overflow', 'nonfinite-cost'].includes(name)
        ? { encoding: 'utf8', rawBase64: Buffer.from(raw).toString('base64') }
        : { method: 'daemon.usage.record', params: { idempotencyKey: rejectedKey, event } },
      response: { id: name === 'nonfinite-cost' ? 'invalid-request' : `invalid-${name}`, error: { code: -32602, message: malformedMessages[name] ?? 'The data is not in the correct format.' } },
      recovery: {
        at: at(4 + index + 0.25), request: { method: 'daemon.usage.record', params: { idempotencyKey: rejectedKey, event: recoveryEvent } },
        response: { result: { idempotencyKey: rejectedKey, inserted: true, event: recoveryEvent } }
      },
      ledger: { beforeBase64: beforeBytes.toString('base64'), afterRejectionBase64: beforeBytes.toString('base64'), afterRecoveryBase64: recoveredBytes.toString('base64') }
    });
  }
  const malformed = {
    producer: 'openburnbar-p11-installed-rpc-runner-v1', transport: 'AF_UNIX newline-framed BurnBarRPC', rows: malformedRows
  };
  const subscription = {
    producer: 'openburnbar-p11-installed-cli-runner-v1', transport: 'AF_UNIX newline-framed BurnBarRPC',
    rows: [
      { at: at(1), phase: 'start', result: { subscriptionID: 'cli-health-123e4567-e89b-42d3-a456-426614174000', topic: 'health', seq: 1 } },
      { at: at(3), phase: 'resume-before-restart', result: { subscriptionID: 'cli-health-123e4567-e89b-42d3-a456-426614174000', topic: 'health', seq: 2 } },
      { at: at(8), phase: 'resume-after-restart', result: { subscriptionID: 'cli-health-123e4567-e89b-42d3-a456-426614174000', topic: 'health', seq: 3, disconnectDetected: true, recoveredAfterRestart: true } }
    ]
  };
  const rpcTranscript = record(root, json(path.join(raw, 'usage-rpc-transcript.json'), rpc));
  const malformedTranscript = record(root, json(path.join(raw, 'usage-malformed-transcript.json'), malformed));
  const subscriptionTranscript = record(root, json(path.join(raw, 'usage-subscription-transcript.json'), subscription));
  const session = {
    schemaVersion: 1, id: 'openburnbar-linux-p11-installed-usage-ingestion-v1', requirementId: 'P-11', environmentId: ENVIRONMENT,
    targetHead: HEAD, candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    package: { architecture: 'aarch64', format: 'deb', installed: true, manifest: installed.manifest, signature: installed.signature, source: 'verified-live-installed-candidate', version: VERSION },
    desktop: { compositor: 'Mutter', desktop: 'GNOME', displayServer: 'Wayland', liveSession: true },
    capture: { startedAt: at(0), endedAt: at(13), fixtureMode: false, method: 'installed-live-product-session' },
    usage: { idempotencyKey: KEY, event: { ...EVENT } }, sourceEvidence,
    evidence: { ledgerBefore, ledgerAfterInsert, ledgerAfterDuplicate, ledgerAfterRestart, rpcTranscript, malformedTranscript, subscriptionTranscript }
  };
  const sessionReport = json(path.join(inputRoot, 'p11-installed-usage-ingestion-session.json'), session);
  return { root, inputRoot, raw, installed, session, sessionReport, endedAt: session.capture.endedAt };
}

function binding(value) {
  return { repoRoot: value.root, environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST, packageVersion: VERSION, manifestSha256: value.installed.manifest.sha256, manifestSignatureSha256: value.installed.signature.sha256 };
}

function context(value, proofFile) {
  const subjects = path.join(value.inputRoot, 'release-subjects');
  const aggregate = record(value.root, json(path.join(subjects, 'aggregate.json'), { passed: true }));
  const runtime = record(value.root, json(path.join(subjects, 'runtime.json'), { shellVersion: VERSION, daemonVersion: VERSION }));
  const environment = record(value.root, json(path.join(subjects, 'environment.json'), { environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'aarch64', passed: true }));
  const pkg = record(value.root, write(path.join(subjects, 'package.deb'), 'deb\n'));
  const proof = record(value.root, proofFile);
  return {
    schemaVersion: 1, repoRoot: value.root, requirementId: 'P-11', checkId: 'p-11.usage-ingestion', environmentId: ENVIRONMENT, targetHead: HEAD,
    releaseClosure: { document: {
      schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed', requirementId: 'P-11', environmentId: ENVIRONMENT,
      version: VERSION, blockers: [], architectures: [...RELEASE_ARCHITECTURES], supportEnvironments: [...SUPPORT_ENVIRONMENTS],
      selectedPackage: { architecture: 'aarch64', format: 'deb' }, candidate: { runId: RUN_ID, artifactDigest: DIGEST },
      packageManifestSignature: value.installed.signature,
      proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P11_PROOF_ROLE, ...proof }]
    } },
    subjects: { release: aggregate, packageManifest: value.installed.manifest, packages: [pkg], runtimes: [runtime], installation: [aggregate], environment, features: [] }
  };
}

test('P-11 validates installed daemon ingestion, idempotency, provenance, restart, and refresh continuity', async () => {
  const value = fixture();
  try {
    const captured = captureP11UsageIngestionProof({
      inputRoot: value.inputRoot, sessionReport: value.sessionReport, ...binding(value), resolveHead: () => HEAD,
      now: () => new Date(Date.parse(value.endedAt) + 1_000)
    });
    assert.deepEqual(JSON.parse(fs.readFileSync(captured.registration, 'utf8')).artifacts, [{ role: P11_PROOF_ROLE, path: 'feature-artifacts/usage-ingestion-installed.json' }]);
    const relative = path.relative(value.root, captured.output).split(path.sep).join('/');
    const validated = validateP11Proof({ repoRoot: value.root, snapshot: readRegularSnapshot(value.root, relative, 'P-11 proof'), ...binding(value) });
    assert.equal(validated.evidence.length, 9);
    assert.equal((await validateProductRequirement(context(value, captured.output))).status, 'passed');
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-11 rejects replay, duplicate, provenance, malformed, restart, and subscription mutations', () => {
  const cases = [
    ['candidate', (doc) => { doc.candidate.runId = '999'; }, /selected release candidate|invoked requirement/u],
    ['duplicate accepted', (doc, value) => mutateJson(value, doc.evidence.rpcTranscript, (payload) => { payload.rows[1].response.result.inserted = true; }), /idempotency/u],
    ['token provenance', (doc) => { doc.usage.event.inputTokens = -1; }, /non-negative/u],
    ['cost provenance', (doc) => { doc.usage.event.cost = 0; }, /token\/cost/u],
    ['timestamp provenance', (doc) => { doc.usage.event.recordedAt -= 86_400; }, /capture-bound/u],
    ['malformed accepted', (doc, value) => mutateJson(value, doc.evidence.malformedTranscript, (payload) => { payload.rows[0].response = { result: { inserted: true } }; }), /malformed input/u],
    ['wrong invalid-params code', (doc, value) => mutateJson(value, doc.evidence.malformedTranscript, (payload) => { payload.rows[1].response.error.code = -32603; }), /malformed input/u],
    ['unstable error taxonomy', (doc, value) => mutateJson(value, doc.evidence.malformedTranscript, (payload) => { payload.rows[2].response.error.message = 'invalid'; }), /malformed input/u],
    ['rejection mutated ledger', (doc, value) => mutateJson(value, doc.evidence.malformedTranscript, (payload) => { payload.rows[3].ledger.afterRejectionBase64 = payload.rows[3].ledger.afterRecoveryBase64; }), /mutated the ledger/u],
    ['rejected key consumed', (doc, value) => mutateJson(value, doc.evidence.malformedTranscript, (payload) => { payload.rows[4].recovery.response.result.inserted = false; }), /recovery failed/u],
    ['nonfinite raw request changed', (doc, value) => mutateJson(value, doc.evidence.malformedTranscript, (payload) => {
      payload.rows[4].request.rawBase64 = Buffer.from(Buffer.from(payload.rows[4].request.rawBase64, 'base64').toString('utf8').replace('1e309', '1')).toString('base64');
    }), /malformed input/u],
    ['duplicate ledger row', (doc, value) => mutateJsonl(value, doc.evidence.ledgerAfterDuplicate, (rows) => { rows.push(structuredClone(rows[0])); }), /target rows/u],
    ['restart lost row', (doc, value) => mutateJsonl(value, doc.evidence.ledgerAfterRestart, (rows) => rows.pop()), /target rows|non-empty hashed/u],
    ['restart refresh lost', (doc, value) => mutateJson(value, doc.evidence.rpcTranscript, (payload) => { payload.rows[3].response.result.usage = []; }), /exactly one canonical/u],
    ['subscription recovery', (doc, value) => mutateJson(value, doc.evidence.subscriptionTranscript, (payload) => { payload.rows[2].result.recoveredAfterRestart = false; }), /recover after daemon restart/u],
    ['source drift', (doc, value) => { fs.appendFileSync(path.join(value.root, doc.sourceEvidence[0].path), 'changed\n'); }, /source changed/u]
  ];
  for (const [label, mutate, pattern] of cases) {
    const value = fixture();
    try {
      const document = structuredClone(value.session);
      mutate(document, value);
      assert.throws(() => validateP11InstalledSession(document, binding(value), { repoRoot: value.root }), pattern, label);
    } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
});

test('P-11 validator rejects semantic proof mutation', async () => {
  const value = fixture();
  try {
    const captured = captureP11UsageIngestionProof({
      inputRoot: value.inputRoot, sessionReport: value.sessionReport, ...binding(value), resolveHead: () => HEAD,
      now: () => new Date(Date.parse(value.endedAt) + 1_000)
    });
    const proof = JSON.parse(fs.readFileSync(captured.output, 'utf8'));
    proof.claim.providerID = 'forged-provider';
    json(captured.output, proof);
    await assert.rejects(
      () => validateProductRequirement(context(value, captured.output)),
      /claim does not match/u
    );
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

function mutateJson(value, artifact, mutate) {
  const file = path.join(value.root, artifact.path);
  const payload = JSON.parse(fs.readFileSync(file, 'utf8'));
  mutate(payload);
  json(file, payload);
  Object.assign(artifact, record(value.root, file));
}

function mutateJsonl(value, artifact, mutate) {
  const file = path.join(value.root, artifact.path);
  const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(JSON.parse);
  mutate(rows);
  jsonl(file, rows);
  Object.assign(artifact, record(value.root, file));
}

test('P-11 executable materializer derives identity from raw RPC and revalidates every copied artifact', () => {
  const value = fixture();
  try {
    const liveRaw = path.join(value.root, 'live-p11');
    fs.mkdirSync(liveRaw);
    for (const file of fs.readdirSync(value.raw)) fs.copyFileSync(path.join(value.raw, file), path.join(liveRaw, file));
    const manifestPath = path.join(liveRaw, 'installed-manifest.json');
    const signaturePath = path.join(liveRaw, 'installed-manifest.json.sig');
    fs.copyFileSync(path.join(value.root, value.installed.manifest.path), manifestPath);
    fs.copyFileSync(path.join(value.root, value.installed.signature.path), signaturePath);
    fs.rmSync(value.inputRoot, { recursive: true, force: true });
    fs.mkdirSync(value.inputRoot, { recursive: true });
    const materialized = materializeP11UsageIngestionSession({
      outputRoot: value.inputRoot, rawEvidenceDir: liveRaw, compositor: 'Mutter', ...binding(value)
    }, {
      installedVerifier: () => ({ contract: { architecture: 'aarch64', format: 'deb', desktop: 'gnome', session: 'wayland' } }),
      manifestPath, signaturePath
    });
    assert.equal(materialized.document.usage.idempotencyKey, KEY);
    assert.equal(materialized.document.usage.event.providerID, 'hermes');
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-11 live runner invokes installed RPC, CLI, ledger, and restart dependencies to produce materializable raw evidence', async () => {
  const value = fixture();
  try {
    const rawOutput = path.join(value.root, 'runner-raw');
    fs.mkdirSync(rawOutput, { mode: 0o700 });
    const tokenFile = write(path.join(value.root, 'daemon-token'), `${'a'.repeat(64)}\n`);
    fs.chmodSync(tokenFile, 0o600);
    const ledgerRows = [];
    let restarted = false;
    let sequence = 0;
    const bytes = () => Buffer.from(ledgerRows.length ? `${ledgerRows.map((row) => JSON.stringify(row)).join('\n')}\n` : '');
    const message = (params) => {
      const event = params.event;
      if (event.providerID === '') return 'Invalid usage event: providerID must be nonblank and trimmed.';
      if (event.modelID.includes('\n')) return 'Invalid usage event: modelID must not contain control characters.';
      if (Buffer.byteLength(event.sessionID) > 256) return 'Invalid usage event: sessionID must not exceed 256 UTF-8 bytes.';
      if (event.inputTokens < 0) return 'Invalid usage event: inputTokens must be nonnegative.';
      if (event.cost < 0) return 'Invalid usage event: cost must be finite and nonnegative.';
      if ((event.recordedAt + 978_307_200) * 1_000 < Date.UTC(2000, 0, 1)) return 'Invalid usage event: recordedAt must be on or after 2000 and no more than 15 seconds in the future.';
      return null;
    };
    const rpcClient = async (method, params) => {
      if (method === 'daemon.usage.recent') return { result: { usage: ledgerRows.map((row) => row.event) } };
      const invalid = message(params);
      if (invalid) return { error: { code: -32602, message: invalid } };
      const exists = ledgerRows.some((row) => row.idempotencyKey === params.idempotencyKey);
      if (!exists) ledgerRows.push({ idempotencyKey: params.idempotencyKey, event: params.event });
      return { result: { idempotencyKey: params.idempotencyKey, inserted: !exists, event: params.event } };
    };
    const rawRpcClient = async (payload) => ({
      id: payload.includes('1e309') ? 'invalid-request' : 'raw-overflow',
      error: {
        code: -32602,
        message: payload.includes('1e309')
          ? 'The data is not in the correct format.'
          : 'Invalid usage event: token counts exceed the supported integer range.'
      }
    });
    const cliRunner = (args) => {
      sequence += 1;
      const id = args[0] === 'subscribe' ? 'cli-health-123e4567-e89b-42d3-a456-426614174000' : args[1];
      return [
        `subscription_id=${id}`, 'topic=health', `seq=${sequence}`,
        `disconnect_detected=${restarted}`, `recovered_after_restart=${restarted}`
      ].join('\n');
    };
    const options = { rawOutputDir: rawOutput, ledgerPath: path.join(value.root, 'isolated-ledger.jsonl'), socketPath: '/run/user/1000/openburnbar/daemon.sock', tokenFile, ...binding(value) };
    const ran = await runP11UsageIngestionSession(options, {
      installedVerifier: () => ({ contract: { architecture: 'aarch64', format: 'deb', desktop: 'gnome', session: 'wayland' } }),
      rpcClient, rawRpcClient, readLedger: bytes, cliRunner,
      restartDaemon: () => { restarted = true; }
    });
    assert.equal(fs.readdirSync(ran.output).sort().length, 7);
    const manifestPath = path.join(value.root, 'runner-manifest.json');
    const signaturePath = path.join(value.root, 'runner-manifest.json.sig');
    fs.copyFileSync(path.join(value.root, value.installed.manifest.path), manifestPath);
    fs.copyFileSync(path.join(value.root, value.installed.signature.path), signaturePath);
    const materializedRoot = path.join(value.root, 'docs/linux-port/evidence/product-parity-inputs/P-11', ENVIRONMENT);
    fs.rmSync(materializedRoot, { recursive: true, force: true });
    fs.mkdirSync(materializedRoot, { recursive: true });
    const result = materializeP11UsageIngestionSession({ outputRoot: materializedRoot, rawEvidenceDir: ran.output, compositor: 'Mutter', ...binding(value) }, {
      installedVerifier: () => ({ contract: { architecture: 'aarch64', format: 'deb', desktop: 'gnome', session: 'wayland' } }), manifestPath, signaturePath
    });
    assert.equal(result.document.usage.idempotencyKey, ran.idempotencyKey);
    assert.equal(result.document.evidence.rpcTranscript.size > 100, true);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-11 live runner fails closed when daemon rejection, ledger stability, or restart recovery is false', async () => {
  for (const [label, mode, pattern] of [
    ['accepted malformed input', 'accept', /not rejected/u],
    ['malformed write changed ledger', 'mutate-ledger', /mutated the ledger/u],
    ['restart failed', 'restart', /restart failed/u],
    ['subscription did not recover', 'subscription', /did not recover/u]
  ]) {
    const value = fixture();
    try {
      const rawOutput = path.join(value.root, `runner-failure-${mode}`);
      fs.mkdirSync(rawOutput, { mode: 0o700 });
      const tokenFile = write(path.join(value.root, `token-${mode}`), `${'e'.repeat(64)}\n`);
      fs.chmodSync(tokenFile, 0o600);
      const ledgerRows = [];
      let restarted = false;
      let sequence = 0;
      const readLedger = () => Buffer.from(ledgerRows.length ? `${ledgerRows.map((row) => JSON.stringify(row)).join('\n')}\n` : '');
      const rpcClient = async (method, params) => {
        if (method === 'daemon.usage.recent') return { result: { usage: ledgerRows.map((row) => row.event) } };
        const invalid = params.event.providerID === '' || params.event.modelID.includes('\n') || Buffer.byteLength(params.event.sessionID) > 256
          || params.event.inputTokens < 0 || params.event.cost < 0 || (params.event.recordedAt + 978_307_200) * 1_000 < Date.UTC(2000, 0, 1);
        if (invalid) {
          if (mode === 'mutate-ledger') ledgerRows.push({ idempotencyKey: params.idempotencyKey, event: params.event });
          return mode === 'accept' ? { result: { idempotencyKey: params.idempotencyKey, inserted: true, event: params.event } } : { error: { code: -32602, message: 'invalid' } };
        }
        const exists = ledgerRows.some((row) => row.idempotencyKey === params.idempotencyKey);
        if (!exists) ledgerRows.push({ idempotencyKey: params.idempotencyKey, event: params.event });
        return { result: { idempotencyKey: params.idempotencyKey, inserted: !exists, event: params.event } };
      };
      const rawRpcClient = async () => ({ error: { code: -32602, message: 'invalid' } });
      const cliRunner = (args) => {
        sequence += 1;
        const id = args[0] === 'subscribe' ? 'cli-health-123e4567-e89b-42d3-a456-426614174000' : args[1];
        return [`subscription_id=${id}`, 'topic=health', `seq=${sequence}`, `disconnect_detected=${restarted}`, `recovered_after_restart=${restarted && mode !== 'subscription'}`].join('\n');
      };
      await assert.rejects(() => runP11UsageIngestionSession({
        rawOutputDir: rawOutput, ledgerPath: path.join(value.root, 'isolated.jsonl'), socketPath: '/tmp/test.sock', tokenFile, ...binding(value)
      }, {
        installedVerifier: () => ({}), rpcClient, rawRpcClient, readLedger, cliRunner,
        restartDaemon: () => { if (mode === 'restart') throw new Error('restart failed'); restarted = true; }
      }), pattern, label);
    } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
});

test('P-11 rejects forged installed manifest signatures and stale proof collection', () => {
  const value = fixture();
  try {
    fs.writeFileSync(path.join(value.root, value.session.package.signature.path), Buffer.alloc(64, 7));
    value.session.package.signature = record(value.root, path.join(value.root, value.session.package.signature.path));
    assert.throws(() => validateP11InstalledSession(value.session, { ...binding(value), manifestSignatureSha256: value.session.package.signature.sha256 }, { repoRoot: value.root }), /signature/u);
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  const stale = fixture();
  try {
    assert.throws(() => captureP11UsageIngestionProof({
      inputRoot: stale.inputRoot, sessionReport: stale.sessionReport, ...binding(stale), resolveHead: () => HEAD,
      now: () => new Date(Date.parse(stale.endedAt) + 20 * 60_000)
    }), /stale/u);
  } finally { fs.rmSync(stale.root, { recursive: true, force: true }); }
});
