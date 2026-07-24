import {
  DIGEST_PATTERN,
  HEAD_PATTERN,
  RUN_ID_PATTERN,
  SHA256_PATTERN,
  VERSION_PATTERN,
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope
} from './installed-ui-proof.mjs';
import { readRegularSnapshot } from './product-proof-closure.mjs';

export const P11_REQUIREMENT_ID = 'P-11';
export const P11_PROOF_ROLE = 'feature.usage-ingestion-installed';
export const P11_PROOF_FILENAME = 'usage-ingestion-installed.json';
export const P11_SESSION_FILENAME = 'p11-installed-usage-ingestion-session.json';

export const P11_SOURCE_CONTRACTS = Object.freeze([
  'contracts/provider-ingestion-catalog.json',
  'OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarProviderContracts.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarUsageRecorder.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCUsage.swift',
  'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarUsageRecorderTests.swift',
  'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarDaemonServerTests.swift',
  'tools/openburnbar-mcp/burnbar_usage_ledger.py'
]);

const SOURCE_MARKERS = Object.freeze({
  'contracts/provider-ingestion-catalog.json': ['providerId', 'usageDedupKey', 'ingestion'],
  'OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarProviderContracts.swift': ['BurnBarUsageEvent', 'BurnBarUsageConfidence', 'BurnBarRecordUsageRequest'],
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarUsageRecorder.swift': ['recordedKeys', 'usage_record_skipped_duplicate', 'recentUsage'],
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCUsage.swift': ['case .usageRecord:', 'case .usageRecent:'],
  'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarUsageRecorderTests.swift': ['testUsageRecorderIsIdempotentAcrossReinitialization', 'testUsageRecorderReadsHermesPythonShapedLedgerLine'],
  'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarDaemonServerTests.swift': ['testUsageRecordRPCAppendsAndRespectsIdempotency'],
  'tools/openburnbar-mcp/burnbar_usage_ledger.py': ['append_usage_record', '_try_record_via_daemon_socket', 'APPLE_REFERENCE_DATE_OFFSET']
});

const APPLE_REFERENCE_SECONDS = 978_307_200;
const MAX_CAPTURE_MS = 15 * 60 * 1000;
const PROVIDER = /^[a-z][a-z0-9_-]{1,63}$/u;
const MODEL = /^[A-Za-z0-9][A-Za-z0-9._:/-]{1,127}$/u;
const KEY = /^p11-[a-f0-9]{32}$/u;

function object(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value;
}

function timestamp(value, label) {
  const millis = Date.parse(value);
  if (typeof value !== 'string' || !Number.isFinite(millis) || !/^\d{4}-\d{2}-\d{2}T/u.test(value)) {
    throw new Error(`${label} must be an RFC3339 timestamp`);
  }
  return millis;
}

function exactEvent(event, label) {
  exactKeys(event, [
    'cacheCreationTokens', 'cacheReadTokens', 'confidence', 'cost', 'inputTokens',
    'modelID', 'outputTokens', 'projectName', 'providerID', 'reasoningTokens',
    'recordedAt', 'sessionID'
  ], label);
  if (!PROVIDER.test(event.providerID ?? '') || !MODEL.test(event.modelID ?? '')
      || event.confidence !== 'exact' || event.projectName !== 'P11 installed usage proof'
      || typeof event.sessionID !== 'string' || !event.sessionID.startsWith('p11-session-')) {
    throw new Error(`${label} identity or provenance is invalid`);
  }
  for (const field of ['inputTokens', 'outputTokens', 'cacheCreationTokens', 'cacheReadTokens', 'reasoningTokens']) {
    if (!Number.isSafeInteger(event[field]) || event[field] < 0) throw new Error(`${label}.${field} must be a non-negative integer`);
  }
  if (event.inputTokens + event.outputTokens + event.cacheCreationTokens + event.cacheReadTokens + event.reasoningTokens <= 0
      || !Number.isFinite(event.cost) || event.cost <= 0) {
    throw new Error(`${label} token/cost provenance is invalid`);
  }
  if (!Number.isFinite(event.recordedAt)) throw new Error(`${label}.recordedAt must use Swift reference-date seconds`);
  const unixMillis = (event.recordedAt + APPLE_REFERENCE_SECONDS) * 1_000;
  if (!Number.isFinite(unixMillis) || unixMillis < Date.UTC(2000, 0, 1)) {
    throw new Error(`${label}.recordedAt must be on or after 2000`);
  }
  return { event, unixMillis };
}

function sameEvent(actual, expected, label) {
  exactEvent(actual, label);
  const canonical = (value) => JSON.stringify(value, Object.keys(value).sort());
  if (canonical(actual) !== canonical(expected)) throw new Error(`${label} changed usage provenance`);
}

function artifactJson(repoRoot, record, environmentId, label) {
  const snapshot = validateArtifact(repoRoot, record, P11_REQUIREMENT_ID, environmentId, label, { mediaType: 'json', minimumBytes: 20 });
  return { record, snapshot, value: parseJson(snapshot.bytes, label) };
}

function artifactJsonl(repoRoot, record, environmentId, label, { allowEmpty = false } = {}) {
  const snapshot = validateArtifact(repoRoot, record, P11_REQUIREMENT_ID, environmentId, label, { minimumBytes: allowEmpty ? 0 : 2 });
  const lines = snapshot.bytes.toString('utf8').split('\n').filter(Boolean);
  if ((!allowEmpty && lines.length === 0) || (lines.length > 0 && !snapshot.bytes.toString('utf8').endsWith('\n'))) throw new Error(`${label} must be newline-terminated JSONL`);
  return { record, snapshot, rows: lines.map((line, index) => {
    try { return JSON.parse(line); } catch (error) { throw new Error(`${label} line ${index + 1} is invalid JSON: ${error.message}`); }
  }) };
}

function validateSourceEvidence(repoRoot, rows) {
  if (!Array.isArray(rows) || rows.length !== P11_SOURCE_CONTRACTS.length) throw new Error('P-11 source evidence is incomplete');
  const seen = new Set();
  for (const [index, row] of rows.entries()) {
    exactKeys(row, ['path', 'sha256'], `P-11 source evidence ${index}`);
    if (!P11_SOURCE_CONTRACTS.includes(row.path) || seen.has(row.path) || !SHA256_PATTERN.test(row.sha256 ?? '')) {
      throw new Error(`P-11 source evidence ${index} is invalid`);
    }
    seen.add(row.path);
    const snapshot = readRegularSnapshot(repoRoot, row.path, `P-11 source ${row.path}`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`P-11 source changed: ${row.path}`);
    const source = snapshot.bytes.toString('utf8');
    for (const marker of SOURCE_MARKERS[row.path]) if (!source.includes(marker)) throw new Error(`${row.path} is missing ${marker}`);
  }
}

function validateLedger(rows, key, event, expectedMatches, label) {
  const matching = rows.filter((row) => row?.idempotencyKey === key);
  if (matching.length !== expectedMatches) throw new Error(`${label} has ${matching.length} target rows; expected ${expectedMatches}`);
  for (const [index, row] of rows.entries()) {
    object(row, `${label} row ${index}`);
    if (typeof row.idempotencyKey !== 'string' || !row.idempotencyKey.trim() || !row.event) throw new Error(`${label} contains malformed ledger data`);
  }
  if (matching.length === 1) {
    exactKeys(matching[0], ['event', 'idempotencyKey'], `${label} target row`);
    sameEvent(matching[0].event, event, `${label} target event`);
  }
}

function transcriptRows(value, label) {
  exactKeys(value, ['producer', 'rows', 'transport'], label);
  if (value.producer !== 'openburnbar-p11-installed-rpc-runner-v1'
      || value.transport !== 'AF_UNIX newline-framed BurnBarRPC' || !Array.isArray(value.rows)) {
    throw new Error(`${label} is not a raw installed daemon transcript`);
  }
  return value.rows;
}

function responseResult(row, phase) {
  exactKeys(row, ['at', 'phase', 'request', 'response'], `P-11 RPC ${phase}`);
  timestamp(row.at, `P-11 RPC ${phase} timestamp`);
  if (row.phase !== phase || row.response?.error || !row.response?.result) throw new Error(`P-11 RPC ${phase} did not succeed`);
  return row.response.result;
}

function validateRpcTranscript(value, key, event, captureStart, captureEnd) {
  const rows = transcriptRows(value, 'P-11 usage RPC transcript');
  const phases = ['record-first', 'record-duplicate', 'recent-before-restart', 'recent-after-restart'];
  if (rows.length !== phases.length) throw new Error('P-11 usage RPC transcript has an unexpected operation count');
  for (const [index, phase] of phases.entries()) {
    const at = timestamp(rows[index]?.at, `P-11 RPC ${phase} timestamp`);
    if (at < captureStart || at > captureEnd) throw new Error(`P-11 RPC ${phase} is outside capture bounds`);
  }
  const first = responseResult(rows[0], phases[0]);
  const duplicate = responseResult(rows[1], phases[1]);
  for (const [row, phase] of [[rows[0], phases[0]], [rows[1], phases[1]]]) {
    if (row.request?.method !== 'daemon.usage.record' || row.request?.params?.idempotencyKey !== key) throw new Error(`P-11 ${phase} request is not canonical usage ingestion`);
    sameEvent(row.request.params.event, event, `P-11 ${phase} request event`);
  }
  if (first.inserted !== true || duplicate.inserted !== false || first.idempotencyKey !== key || duplicate.idempotencyKey !== key) {
    throw new Error('P-11 daemon idempotency result is invalid');
  }
  sameEvent(first.event, event, 'P-11 first response event');
  sameEvent(duplicate.event, event, 'P-11 duplicate response event');
  for (const [row, phase] of [[rows[2], phases[2]], [rows[3], phases[3]]]) {
    const result = responseResult(row, phase);
    if (row.request?.method !== 'daemon.usage.recent' || row.request?.params?.limit !== 500 || !Array.isArray(result.usage)) {
      throw new Error(`P-11 ${phase} is not a bounded daemon refresh`);
    }
    const matches = result.usage.filter((candidate) => {
      try { sameEvent(candidate, event, `P-11 ${phase} returned event`); return true; } catch { return false; }
    });
    if (matches.length !== 1) throw new Error(`P-11 ${phase} did not return exactly one canonical event`);
  }
}

function validateMalformed(value, key, captureStart, captureEnd) {
  exactKeys(value, ['producer', 'rows', 'transport'], 'P-11 malformed transcript');
  if (value.producer !== 'openburnbar-p11-installed-rpc-runner-v1' || value.transport !== 'AF_UNIX newline-framed BurnBarRPC'
      || !Array.isArray(value.rows) || value.rows.length !== 8) throw new Error('P-11 malformed transcript is incomplete');
  const expectedMessages = new Map([
    ['blank-provider', 'Invalid usage event: providerID must be nonblank and trimmed.'],
    ['control-model', 'Invalid usage event: modelID must not contain control characters.'],
    ['oversized-session', 'Invalid usage event: sessionID must not exceed 256 UTF-8 bytes.'],
    ['token-sum-overflow', 'Invalid usage event: token counts exceed the supported integer range.'],
    ['negative-token', 'Invalid usage event: inputTokens must be nonnegative.'],
    ['negative-cost', 'Invalid usage event: cost must be finite and nonnegative.'],
    ['out-of-range-timestamp', 'Invalid usage event: recordedAt must be on or after 2000 and no more than 15 seconds in the future.']
  ]);
  const cases = new Set([...expectedMessages.keys(), 'nonfinite-cost']);
  for (const row of value.rows) {
    exactKeys(row, ['at', 'case', 'ledger', 'recovery', 'request', 'response'], 'P-11 malformed row');
    const at = timestamp(row.at, 'P-11 malformed timestamp');
    const rejectedKey = `${key}-${row.case}`;
    const malformedEvent = row.request?.params?.event;
    const malformedShape = row.case === 'blank-provider' ? malformedEvent?.providerID === ''
      : row.case === 'control-model' ? typeof malformedEvent?.modelID === 'string' && /[\u0000-\u001f\u007f]/u.test(malformedEvent.modelID)
        : row.case === 'oversized-session' ? Buffer.byteLength(malformedEvent?.sessionID ?? '', 'utf8') > 256
          : row.case === 'token-sum-overflow' ? row.request?.encoding === 'utf8' && typeof row.request.rawBase64 === 'string'
            && Buffer.from(row.request.rawBase64, 'base64').toString('utf8').includes('"inputTokens":9223372036854775807')
            && Buffer.from(row.request.rawBase64, 'base64').toString('utf8').includes('"outputTokens":1')
            : row.case === 'negative-token' ? Number.isSafeInteger(malformedEvent?.inputTokens) && malformedEvent.inputTokens < 0
              : row.case === 'negative-cost' ? Number.isFinite(malformedEvent?.cost) && malformedEvent.cost < 0
                : row.case === 'out-of-range-timestamp' ? Number.isFinite(malformedEvent?.recordedAt)
                  && (malformedEvent.recordedAt + APPLE_REFERENCE_SECONDS) * 1_000 < Date.UTC(2000, 0, 1)
                  : row.request?.encoding === 'utf8' && typeof row.request.rawBase64 === 'string'
                    && Buffer.from(row.request.rawBase64, 'base64').toString('utf8').includes('"cost":1e309');
    const requestKey = ['nonfinite-cost', 'token-sum-overflow'].includes(row.case)
      ? Buffer.from(row.request.rawBase64, 'base64').toString('utf8').includes(`"idempotencyKey":"${rejectedKey}"`)
      : row.request?.method === 'daemon.usage.record' && row.request?.params?.idempotencyKey === rejectedKey;
    if (at < captureStart || at > captureEnd || !cases.delete(row.case) || !requestKey
        || !malformedShape || row.response?.error?.code !== -32602 || row.response.result !== undefined
        || (expectedMessages.has(row.case) && row.response.error.message !== expectedMessages.get(row.case))) {
      throw new Error('P-11 malformed input was not rejected by the installed daemon');
    }
    exactKeys(row.ledger, ['afterRecoveryBase64', 'afterRejectionBase64', 'beforeBase64'], `P-11 ${row.case} ledger evidence`);
    const before = Buffer.from(row.ledger.beforeBase64, 'base64');
    const rejected = Buffer.from(row.ledger.afterRejectionBase64, 'base64');
    const recovered = Buffer.from(row.ledger.afterRecoveryBase64, 'base64');
    if (!before.equals(rejected)) throw new Error(`P-11 ${row.case} rejection mutated the ledger`);
    const parseLedger = (bytes) => bytes.toString('utf8').split('\n').filter(Boolean).map(JSON.parse);
    if (parseLedger(before).some((entry) => entry.idempotencyKey === rejectedKey)) throw new Error(`P-11 ${row.case} key existed before rejection`);
    const recoveredRows = parseLedger(recovered).filter((entry) => entry.idempotencyKey === rejectedKey);
    if (recoveredRows.length !== 1) throw new Error(`P-11 ${row.case} rejected key was not reusable`);
    exactKeys(row.recovery, ['at', 'request', 'response'], `P-11 ${row.case} recovery`);
    const recoveryAt = timestamp(row.recovery.at, `P-11 ${row.case} recovery timestamp`);
    if (recoveryAt < at || recoveryAt > captureEnd || row.recovery.request?.method !== 'daemon.usage.record'
        || row.recovery.request?.params?.idempotencyKey !== rejectedKey || row.recovery.response?.result?.inserted !== true) {
      throw new Error(`P-11 ${row.case} rejected key recovery failed`);
    }
    sameEvent(row.recovery.request.params.event, row.recovery.response.result.event, `P-11 ${row.case} recovery event`);
  }
  if (cases.size) throw new Error('P-11 malformed rejection cases are incomplete');
}

function validateSubscription(value, captureStart, captureEnd) {
  exactKeys(value, ['producer', 'rows', 'transport'], 'P-11 subscription transcript');
  if (value.producer !== 'openburnbar-p11-installed-cli-runner-v1' || value.transport !== 'AF_UNIX newline-framed BurnBarRPC'
      || !Array.isArray(value.rows) || value.rows.length !== 3) throw new Error('P-11 subscription transcript is incomplete');
  const phases = ['start', 'resume-before-restart', 'resume-after-restart'];
  let previous = 0;
  let subscriptionID = null;
  for (const [index, phase] of phases.entries()) {
    const row = value.rows[index];
    exactKeys(row, ['at', 'phase', 'result'], `P-11 subscription ${phase}`);
    const at = timestamp(row.at, `P-11 subscription ${phase} timestamp`);
    if (index === 0) subscriptionID = row.result?.subscriptionID;
    if (typeof subscriptionID !== 'string' || !/^cli-health-[0-9A-Fa-f-]{36}$/u.test(subscriptionID)
        || at < captureStart || at > captureEnd || row.phase !== phase || row.result?.subscriptionID !== subscriptionID
        || !Number.isSafeInteger(row.result.seq) || row.result.seq <= previous || row.result.topic !== 'health') {
      throw new Error(`P-11 subscription ${phase} did not preserve refresh continuity`);
    }
    if (phase === 'resume-after-restart' && (row.result.disconnectDetected !== true || row.result.recoveredAfterRestart !== true)) {
      throw new Error('P-11 subscription did not recover after daemon restart');
    }
    previous = row.result.seq;
  }
}

export function validateP11InstalledSession(document, binding, { repoRoot = binding.repoRoot } = {}) {
  exactKeys(document, ['candidate', 'capture', 'desktop', 'environmentId', 'evidence', 'id', 'package', 'requirementId', 'schemaVersion', 'sourceEvidence', 'targetHead', 'usage'], 'P-11 session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p11-installed-usage-ingestion-v1'
      || document.requirementId !== P11_REQUIREMENT_ID || document.environmentId !== binding.environmentId
      || document.targetHead !== binding.targetHead || !HEAD_PATTERN.test(document.targetHead ?? '')) {
    throw new Error('P-11 session identity does not match the invocation');
  }
  const envelope = validateInstalledSessionEnvelope(document, binding, P11_REQUIREMENT_ID, 'P-11 session');
  if (envelope.endedAt - envelope.startedAt > MAX_CAPTURE_MS) throw new Error('P-11 capture exceeded its bounded duration');
  exactKeys(document.usage, ['event', 'idempotencyKey'], 'P-11 usage identity');
  if (!KEY.test(document.usage.idempotencyKey ?? '')) throw new Error('P-11 idempotency key is invalid');
  const normalized = exactEvent(document.usage.event, 'P-11 canonical event');
  if (normalized.unixMillis < envelope.startedAt - 60_000 || normalized.unixMillis > envelope.endedAt + 60_000) {
    throw new Error('P-11 canonical event timestamp is not capture-bound');
  }
  validateSourceEvidence(repoRoot, document.sourceEvidence);
  exactKeys(document.evidence, ['ledgerAfterDuplicate', 'ledgerAfterInsert', 'ledgerAfterRestart', 'ledgerBefore', 'malformedTranscript', 'rpcTranscript', 'subscriptionTranscript'], 'P-11 evidence');
  const records = [];
  for (const field of ['ledgerBefore', 'ledgerAfterInsert', 'ledgerAfterDuplicate', 'ledgerAfterRestart']) {
    const value = artifactJsonl(repoRoot, document.evidence[field], document.environmentId, `P-11 ${field}`, { allowEmpty: field === 'ledgerBefore' });
    validateLedger(value.rows, document.usage.idempotencyKey, document.usage.event, field === 'ledgerBefore' ? 0 : 1, `P-11 ${field}`);
    records.push(value.record);
  }
  const rpc = artifactJson(repoRoot, document.evidence.rpcTranscript, document.environmentId, 'P-11 RPC transcript');
  validateRpcTranscript(rpc.value, document.usage.idempotencyKey, document.usage.event, envelope.startedAt, envelope.endedAt);
  records.push(rpc.record);
  const malformed = artifactJson(repoRoot, document.evidence.malformedTranscript, document.environmentId, 'P-11 malformed transcript');
  validateMalformed(malformed.value, document.usage.idempotencyKey, envelope.startedAt, envelope.endedAt);
  records.push(malformed.record);
  const subscription = artifactJson(repoRoot, document.evidence.subscriptionTranscript, document.environmentId, 'P-11 subscription transcript');
  validateSubscription(subscription.value, envelope.startedAt, envelope.endedAt);
  records.push(subscription.record);
  const paths = [...envelope.attestation, ...records].map((record) => record.path);
  if (new Set(paths).size !== paths.length) throw new Error('P-11 evidence artifacts must be unique');
  return { document, evidence: [...envelope.attestation, ...records], startedAt: envelope.startedAt, endedAt: envelope.endedAt };
}

export function buildP11Proof({ session, sessionRecord, collectedAt }) {
  return {
    schemaVersion: 1,
    requirementId: P11_REQUIREMENT_ID,
    role: P11_PROOF_ROLE,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    packageVersion: session.package.version,
    collectedAt,
    source: sessionRecord,
    claim: {
      providerID: session.usage.event.providerID,
      idempotencyKey: session.usage.idempotencyKey,
      exactProvenance: true,
      duplicateSuppressed: true,
      malformedRejected: true,
      restartDurable: true,
      subscriptionRecovered: true
    }
  };
}

export function validateP11Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, 'P-11 proof');
  exactKeys(proof, ['candidate', 'claim', 'collectedAt', 'environmentId', 'packageVersion', 'requirementId', 'role', 'schemaVersion', 'source', 'targetHead'], 'P-11 proof');
  if (proof.schemaVersion !== 1 || proof.requirementId !== P11_REQUIREMENT_ID || proof.role !== P11_PROOF_ROLE
      || proof.environmentId !== binding.environmentId || proof.targetHead !== binding.targetHead
      || proof.packageVersion !== binding.packageVersion || proof.candidate.runId !== String(binding.candidateRunId)
      || proof.candidate.artifactDigest !== binding.candidateArtifactDigest) throw new Error('P-11 proof binding is invalid');
  const source = validateArtifact(repoRoot, proof.source, P11_REQUIREMENT_ID, proof.environmentId, 'P-11 proof source', { mediaType: 'json', minimumBytes: 500 });
  const validated = validateP11InstalledSession(parseJson(source.bytes, 'P-11 proof source'), { ...binding, repoRoot }, { repoRoot });
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(proof.claim, ['duplicateSuppressed', 'exactProvenance', 'idempotencyKey', 'malformedRejected', 'providerID', 'restartDurable', 'subscriptionRecovered'], 'P-11 claim');
  for (const field of ['duplicateSuppressed', 'exactProvenance', 'malformedRejected', 'restartDurable', 'subscriptionRecovered']) {
    if (proof.claim[field] !== true) throw new Error(`P-11 proof claim ${field} is false`);
  }
  if (proof.claim.idempotencyKey !== validated.document.usage.idempotencyKey || proof.claim.providerID !== validated.document.usage.event.providerID) {
    throw new Error('P-11 proof claim does not match the validated session');
  }
  return { proof, source, evidence: validated.evidence };
}

export function assertP11Binding(binding) {
  if (!HEAD_PATTERN.test(binding.targetHead ?? '') || !RUN_ID_PATTERN.test(String(binding.candidateRunId))
      || !DIGEST_PATTERN.test(binding.candidateArtifactDigest ?? '') || !VERSION_PATTERN.test(binding.packageVersion ?? '')
      || !SHA256_PATTERN.test(binding.manifestSha256 ?? '') || !SHA256_PATTERN.test(binding.manifestSignatureSha256 ?? '')) {
    throw new Error('P-11 invocation binding is invalid');
  }
}
