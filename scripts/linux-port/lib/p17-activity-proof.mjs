import crypto from 'node:crypto';
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng
} from './installed-ui-proof.mjs';

export const P17_REQUIREMENT_ID = 'P-17';
export const P17_PROOF_ROLE = 'feature.activity-installed';
export const P17_PROOF_FILENAME = 'p17-installed-activity-proof.json';
export const P17_SESSION_FILENAME = 'p17-installed-activity-session.json';

const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const MARKER_PATTERN = /^P17-[a-f0-9]{16}$/u;

function fail(message) { throw new Error(message); }
function artifact(repoRoot, environmentId, record, label, options = {}) {
  return validateArtifact(repoRoot, record, P17_REQUIREMENT_ID, environmentId, label, options);
}

function validateSeed(snapshot, captureStart) {
  const value = parseJson(snapshot.bytes, 'P-17 seed');
  exactKeys(value, ['ambiguousSessionID', 'body', 'createdAt', 'databaseSha256', 'marker', 'producer', 'providerSessionID',
    'schemaVersion', 'sessionFileSha256', 'sourceID', 'title', 'usageLedgerSha256'], 'P-17 seed');
  const createdAt = Date.parse(value.createdAt);
  if (value.schemaVersion !== 1 || value.producer !== 'openburnbar-p17-database-seed-v1'
      || !MARKER_PATTERN.test(value.marker ?? '') || value.sourceID !== `Codex:${value.providerSessionID}`
      || value.ambiguousSessionID !== `ambiguous-${value.providerSessionID}`
      || typeof value.title !== 'string' || !value.title.includes(value.marker)
      || typeof value.body !== 'string' || !value.body.includes(value.marker)
      || !Number.isFinite(createdAt) || createdAt > captureStart || captureStart - createdAt > 10 * 60 * 1000
      || ![value.databaseSha256, value.usageLedgerSha256, value.sessionFileSha256].every((hash) => SHA256_PATTERN.test(hash))) {
    fail('P-17 seed is not a bounded, uniquely identified persisted Activity source');
  }
  return value;
}

function parseTranscriptResult(row, label, expectedStatus = 0) {
  if (row.status !== expectedStatus || row.stderr !== '' || typeof row.stdout !== 'string' || !row.stdout.trim()) {
    fail(`${label} was not a successful installed CLI call`);
  }
  let parsed;
  try { parsed = JSON.parse(row.stdout); } catch { fail(`${label} stdout is not JSON`); }
  if (JSON.stringify(parsed) !== JSON.stringify(row.document)) fail(`${label} parsed document does not match stdout bytes`);
  return parsed;
}

function validateHistory(document, seed, label) {
  exactKeys(document, ['historyComplete', 'historyLimit', 'nextCursor', 'sessions', 'totalCount'], label);
  if (document.historyComplete !== true || document.nextCursor !== null || document.historyLimit !== 500
      || !Number.isSafeInteger(document.totalCount) || document.totalCount < 3
      || !Array.isArray(document.sessions) || document.sessions.length !== document.totalCount) fail(`${label} is incomplete`);
  const rows = document.sessions.filter((row) => row.sourceID === seed.sourceID);
  if (rows.length !== 1 || rows[0].providerSessionID !== seed.providerSessionID || rows[0].provider !== 'Codex'
      || rows[0].model !== 'gpt-5.5' || typeof rows[0].bodyMD !== 'string' || !rows[0].bodyMD.includes(seed.marker)) {
    fail(`${label} does not contain the exact persisted source and body`);
  }
  return rows[0];
}

function validateSearch(document, seed, label) {
  if (!Array.isArray(document?.hits)) fail(`${label} has no hits`);
  const matches = document.hits.filter((hit) => hit.sourceID === seed.sourceID);
  if (matches.length !== 1 || matches[0].sourceKind !== 'conversation' || matches[0].provider !== 'Codex'
      || typeof matches[0].title !== 'string' || !matches[0].title.includes(seed.marker)
      || typeof matches[0].snippet !== 'string' || !matches[0].snippet.includes(seed.marker)) fail(`${label} did not resolve the exact indexed source`);
  return matches[0];
}

function validateReplay(document, seed, label) {
  if (document?.kind !== 'native' || !Array.isArray(document.argv) || document.argv[0] !== 'codex'
      || document.argv[1] !== 'resume' || !document.argv.includes(seed.providerSessionID)
      || typeof document.briefingMD !== 'string' || !document.briefingMD.includes(seed.marker)
      || !document.briefingMD.includes(`Composite ID: \`${seed.sourceID}\``)
      || document.pid !== undefined) fail(`${label} is not a daemon-validated, non-launching native resume readback`);
  return document;
}

function validateCli(snapshot, seed, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, 'P-17 CLI transcript');
  exactKeys(value, ['producer', 'rows', 'transport'], 'P-17 CLI transcript');
  const phases = ['history-initial', 'search-initial', 'replay-initial', 'replay-missing', 'replay-ambiguous',
    'history-after-restart', 'search-after-restart', 'replay-after-restart'];
  if (value.producer !== 'openburnbar-p17-installed-cli-probe-v1'
      || value.transport !== 'installed OpenBurnBar CLI over AF_UNIX'
      || !Array.isArray(value.rows) || value.rows.length !== phases.length) fail('P-17 CLI transcript is incomplete');
  let previous = -Infinity;
  const documents = new Map();
  for (const [index, row] of value.rows.entries()) {
    exactKeys(row, ['args', 'at', 'document', 'phase', 'status', 'stderr', 'stdout'], `P-17 CLI row ${index}`);
    const at = Date.parse(row.at);
    if (row.phase !== phases[index] || !Number.isFinite(at) || at <= previous || at < captureStart || at > captureEnd
        || !Array.isArray(row.args) || row.args[0] !== 'activity') fail(`P-17 CLI ${phases[index]} is invalid`);
    previous = at;
    const expectedStatus = row.phase === 'replay-missing' || row.phase === 'replay-ambiguous' ? 1 : 0;
    documents.set(row.phase, parseTranscriptResult(row, `P-17 CLI ${row.phase}`, expectedStatus));
  }
  const initialHistory = validateHistory(documents.get('history-initial'), seed, 'P-17 initial history');
  const restartHistory = validateHistory(documents.get('history-after-restart'), seed, 'P-17 restart history');
  validateSearch(documents.get('search-initial'), seed, 'P-17 initial search');
  validateSearch(documents.get('search-after-restart'), seed, 'P-17 restart search');
  const initialReplay = validateReplay(documents.get('replay-initial'), seed, 'P-17 initial replay');
  const restartReplay = validateReplay(documents.get('replay-after-restart'), seed, 'P-17 restart replay');
  for (const [phase, code] of [['replay-missing', 'session_not_found'], ['replay-ambiguous', 'ambiguous_session']]) {
    const result = documents.get(phase);
    if (result?.kind !== 'error' || result.errorCode !== code || typeof result.errorRecovery !== 'string' || !result.errorRecovery) {
      fail(`P-17 ${phase} did not fail closed`);
    }
  }
  if (initialHistory.bodyMD !== restartHistory.bodyMD || initialReplay.briefingMD !== restartReplay.briefingMD) {
    fail('P-17 persisted history or replay body changed across daemon restart');
  }
  return value;
}

const INDEX_SESSION_KEYS = ['costUsd', 'id', 'model', 'projectName', 'provider', 'providerSessionID', 'sourceID', 'startedAt', 'title', 'tokens'];
const HISTORY_SESSION_KEYS = [...INDEX_SESSION_KEYS, 'bodyMD'];

function exactOptionalKeys(value, expected, label) {
  const actual = Object.keys(value).sort();
  const allowed = [...expected].sort();
  if (actual.some((key) => !allowed.includes(key))) fail(`${label} contains a non-allowlisted field`);
}

function validateLoadedExport(snapshot, seed) {
  const value = parseJson(snapshot.bytes, 'P-17 loaded JSON export');
  exactKeys(value, ['generatedAt', 'loadedCount', 'scope', 'sessions', 'source', 'version'], 'P-17 loaded JSON export');
  if (value.version !== 1 || value.scope !== 'loaded-session-index' || value.source !== 'live daemon session index'
      || !Array.isArray(value.sessions) || value.loadedCount !== value.sessions.length || value.sessions.length !== 1) {
    fail('P-17 loaded JSON export has the wrong scope');
  }
  exactOptionalKeys(value.sessions[0], INDEX_SESSION_KEYS, 'P-17 loaded JSON session');
  if (value.sessions[0].providerSessionID !== seed.providerSessionID || value.sessions[0].sourceID !== seed.sourceID
      || !value.sessions[0].title.includes(seed.marker) || 'bodyMD' in value.sessions[0]) fail('P-17 loaded export leaked body or lost source identity');
  return value;
}

function validateHistoryExport(snapshot, seed) {
  const value = parseJson(snapshot.bytes, 'P-17 full history export');
  exactKeys(value, ['generatedAt', 'historyComplete', 'historyLimit', 'loadedCount', 'scope', 'sessions', 'source', 'version'], 'P-17 full history export');
  if (value.version !== 1 || value.scope !== 'daemon-session-history' || value.source !== 'live daemon session index'
      || value.historyComplete !== true || value.historyLimit !== 500 || !Array.isArray(value.sessions)
      || value.loadedCount !== value.sessions.length || value.sessions.length < 3) fail('P-17 full history export is incomplete');
  const ids = new Set();
  for (const [index, row] of value.sessions.entries()) {
    exactOptionalKeys(row, HISTORY_SESSION_KEYS, `P-17 history session ${index}`);
    if (typeof row.sourceID !== 'string' || ids.has(row.sourceID) || typeof row.bodyMD !== 'string' || !row.bodyMD) {
      fail('P-17 full history export contains a duplicate identity or missing body');
    }
    ids.add(row.sourceID);
  }
  const exact = value.sessions.find((row) => row.sourceID === seed.sourceID);
  if (!exact || exact.providerSessionID !== seed.providerSessionID || !exact.bodyMD.includes(seed.marker)) fail('P-17 history export lost the exact body');
  return value;
}

function validateMarkdown(snapshot, seed) {
  const text = snapshot.bytes.toString('utf8');
  if (!text.includes(seed.marker) || !/Activity Export/u.test(text)
      || /(?:usage-events\.jsonl|index\.sqlite|\.codex\/sessions|authToken|apiKey)/iu.test(text)) {
    fail('P-17 Markdown export is missing the marker or contains a non-allowlisted path/secret field');
  }
  return text;
}

function validateAtspi(snapshot, label, seed, manifestSha256, captureStart, captureEnd, expectedPid, mode) {
  const value = parseJson(snapshot.bytes, label);
  exactKeys(value, ['appPid', 'capturedAt', 'manifestSha256', 'marker', 'nodes', 'producer'], label);
  const capturedAt = Date.parse(value.capturedAt);
  const names = Array.isArray(value.nodes) ? value.nodes.map((row) => String(row?.name ?? '')).join('\n') : '';
  const expected = ['Persisted session body', seed.marker, mode === 'stale' ? 'Retry session body' : 'Reload session body', 'Resume session'];
  if (value.producer !== 'openburnbar-p17-atspi-control-v1' || value.manifestSha256 !== manifestSha256
      || value.marker !== seed.marker || value.appPid !== expectedPid || !Number.isFinite(capturedAt)
      || capturedAt < captureStart - 1_000 || capturedAt > captureEnd + 1_000 || expected.some((name) => !names.includes(name))) {
    fail(`${label} lacks installed Activity accessibility/body semantics`);
  }
  if (mode === 'stale' && !names.includes('showing the last successful body')) fail('P-17 stale AT-SPI does not expose retained-body failure truth');
  return value;
}

function validateInteractions(snapshot, seed, manifestSha256, captureStart, captureEnd) {
  const value = parseJson(snapshot.bytes, 'P-17 interactions');
  exactKeys(value, ['events', 'producer'], 'P-17 interactions');
  const kinds = ['populated-replay-export', 'failure-retained', 'restart-durable'];
  if (value.producer !== 'openburnbar-p17-installed-ui-probe-v1' || !Array.isArray(value.events)
      || value.events.length !== kinds.length) fail('P-17 interaction sequence is incomplete');
  let previous = -Infinity;
  for (const [index, event] of value.events.entries()) {
    const at = Date.parse(event.at);
    if (event.kind !== kinds[index] || event.marker !== seed.marker || event.manifestSha256 !== manifestSha256
        || !Number.isSafeInteger(event.appPid) || event.appPid < 2 || !Number.isFinite(at)
        || at <= previous || at < captureStart || at > captureEnd) fail(`P-17 interaction ${index} is not live-session-bound`);
    previous = at;
  }
  if (value.events[0].bodyObserved !== true || value.events[1].bodyRetained !== true || value.events[1].failureExposed !== true
      || value.events[2].searchObserved !== true || value.events[2].bodyObserved !== true
      || value.events[0].appPid === value.events[2].appPid || value.events[0].sourceID !== seed.sourceID
      || value.events[2].sourceID !== seed.sourceID) fail('P-17 interactions do not prove failure retention and restart durability');
  return value;
}

export function validateP17InstalledSession(document, binding, { repoRoot }) {
  exactKeys(document, ['candidate', 'capture', 'cliTranscript', 'desktop', 'environmentId', 'exports', 'id', 'interactions',
    'package', 'requirementId', 'schemaVersion', 'seed', 'targetHead', 'ui'], 'P-17 installed session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p17-installed-activity-session-v1') fail('P-17 installed session schema is unsupported');
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P17_REQUIREMENT_ID, 'P-17 installed session');
  const seedRecord = artifact(repoRoot, binding.environmentId, document.seed, 'P-17 seed', { mediaType: 'json', minimumBytes: 200 });
  const seed = validateSeed(seedRecord, envelope.startedAt);
  const cliRecord = artifact(repoRoot, binding.environmentId, document.cliTranscript, 'P-17 CLI transcript', { mediaType: 'json', minimumBytes: 500 });
  const cli = validateCli(cliRecord, seed, envelope.startedAt, envelope.endedAt);
  exactKeys(document.exports, ['fullHistoryJson', 'loadedJson', 'loadedMarkdown'], 'P-17 exports');
  const loadedJson = artifact(repoRoot, binding.environmentId, document.exports.loadedJson, 'P-17 loaded JSON export', { mediaType: 'json', minimumBytes: 100 });
  const loadedMarkdown = artifact(repoRoot, binding.environmentId, document.exports.loadedMarkdown, 'P-17 loaded Markdown export', { minimumBytes: 100 });
  const historyJson = artifact(repoRoot, binding.environmentId, document.exports.fullHistoryJson, 'P-17 full history export', { mediaType: 'json', minimumBytes: 200 });
  validateLoadedExport(loadedJson, seed);
  validateMarkdown(loadedMarkdown, seed);
  validateHistoryExport(historyJson, seed);
  const interactionsRecord = artifact(repoRoot, binding.environmentId, document.interactions, 'P-17 interactions', { mediaType: 'json', minimumBytes: 300 });
  const interactions = validateInteractions(interactionsRecord, seed, binding.manifestSha256, envelope.startedAt, envelope.endedAt);
  exactKeys(document.ui, ['initialAtspi', 'initialScreenshot', 'restartAtspi', 'restartScreenshot', 'staleAtspi', 'staleScreenshot'], 'P-17 UI');
  const uiRecords = {};
  for (const name of ['initialAtspi', 'staleAtspi', 'restartAtspi']) {
    uiRecords[name] = artifact(repoRoot, binding.environmentId, document.ui[name], `P-17 ${name}`, { mediaType: 'json', minimumBytes: 200 });
  }
  validateAtspi(uiRecords.initialAtspi, 'P-17 initial AT-SPI', seed, binding.manifestSha256, envelope.startedAt, envelope.endedAt, interactions.events[0].appPid, 'initial');
  validateAtspi(uiRecords.staleAtspi, 'P-17 stale AT-SPI', seed, binding.manifestSha256, envelope.startedAt, envelope.endedAt, interactions.events[1].appPid, 'stale');
  validateAtspi(uiRecords.restartAtspi, 'P-17 restart AT-SPI', seed, binding.manifestSha256, envelope.startedAt, envelope.endedAt, interactions.events[2].appPid, 'restart');
  const pngHashes = new Set();
  for (const name of ['initialScreenshot', 'staleScreenshot', 'restartScreenshot']) {
    const record = artifact(repoRoot, binding.environmentId, document.ui[name], `P-17 ${name}`, { mediaType: 'png', minimumBytes: 1024 });
    const pixels = validatePng(record.bytes, `P-17 ${name}`);
    if (pixels.nonBlankPixelRatio < 0.05) fail(`P-17 ${name} is blank`);
    pngHashes.add(crypto.createHash('sha256').update(pixels.pixels).digest('hex'));
  }
  if (pngHashes.size !== 3) fail('P-17 screenshots are replayed instead of three live states');
  const evidence = [...envelope.attestation, document.seed, document.cliTranscript, document.interactions,
    ...Object.values(document.exports), ...Object.values(document.ui)];
  if (new Set(evidence.map((row) => row.path)).size !== evidence.length) fail('P-17 reuses an evidence artifact');
  return { document, evidence, endedAt: envelope.endedAt, sourceID: seed.sourceID, marker: seed.marker, cliRows: cli.rows.length };
}

export function buildP17Proof({ session, sessionRecord, collectedAt, sourceID, cliRows }) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p17-activity-proof-v1',
    requirementId: P17_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: 'live-installed-activity-session', ...sessionRecord },
    claim: {
      passed: true,
      sourceID,
      cliRows,
      populatedSearch: true,
      persistedBodyReplay: true,
      nativeResumeReadback: true,
      allowlistedExports: true,
      failureRetention: true,
      restartDurability: true,
      accessibility: true
    }
  };
}

export function validateP17Proof({ repoRoot, snapshot, environmentId, targetHead, candidateRunId, candidateArtifactDigest,
  packageVersion, manifestSha256, manifestSignatureSha256 }) {
  const proof = parseJson(snapshot.bytes, 'P-17 proof');
  exactKeys(proof, ['candidate', 'claim', 'collectedAt', 'environmentId', 'id', 'requirementId', 'schemaVersion', 'source', 'targetHead'], 'P-17 proof');
  if (proof.schemaVersion !== 1 || proof.id !== 'openburnbar-linux-p17-activity-proof-v1'
      || proof.requirementId !== P17_REQUIREMENT_ID || proof.environmentId !== environmentId || proof.targetHead !== targetHead) fail('P-17 proof identity is invalid');
  exactKeys(proof.source, ['method', 'path', 'sha256', 'size'], 'P-17 proof source');
  if (proof.source.method !== 'live-installed-activity-session') fail('P-17 proof source is not live');
  const sourceRecord = { path: proof.source.path, sha256: proof.source.sha256, size: proof.source.size };
  const source = artifact(repoRoot, environmentId, sourceRecord, 'P-17 source session', { mediaType: 'json', minimumBytes: 300 });
  const validated = validateP17InstalledSession(parseJson(source.bytes, 'P-17 source session'), {
    environmentId, targetHead, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256
  }, { repoRoot });
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(proof.claim, ['accessibility', 'allowlistedExports', 'cliRows', 'failureRetention', 'nativeResumeReadback', 'passed',
    'persistedBodyReplay', 'populatedSearch', 'restartDurability', 'sourceID'], 'P-17 claim');
  if (proof.claim.passed !== true || proof.claim.sourceID !== validated.sourceID || proof.claim.cliRows !== validated.cliRows
      || ['accessibility', 'allowlistedExports', 'failureRetention', 'nativeResumeReadback', 'persistedBodyReplay', 'populatedSearch', 'restartDurability']
        .some((key) => proof.claim[key] !== true)) fail('P-17 claim is not derived from its source session');
  return { ...validated, source: sourceRecord };
}
