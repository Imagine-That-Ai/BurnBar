import crypto from 'node:crypto';
import fs from 'node:fs';
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng
} from './installed-ui-proof.mjs';

export const P12_REQUIREMENT_ID = 'P-12';
export const P12_PROOF_ROLE = 'p-12-installed-quota-proof';
export const P12_PROOF_FILENAME = 'p12-installed-quota-proof.json';
export const P12_SESSION_FILENAME = 'p12-installed-quota-session.json';

const MODES = new Set(['provider_family_failover', 'same_model_failover']);
const SOURCES = new Set(['provider', 'officialAPI', 'localCLI', 'localSession', 'manualEstimate', 'unavailable']);
const CONFIDENCE = new Set(['high', 'medium', 'low', 'stale']);
const STATES = new Set(['ok', 'cooling_down', 'missing_credential', 'exhausted', 'unknown']);

function fail(message) { throw new Error(message); }
function artifact(repoRoot, environmentId, record, label, options = {}) {
  return validateArtifact(repoRoot, record, P12_REQUIREMENT_ID, environmentId, label, options);
}

function canonicalProviders(repoRoot) {
  const manifest = JSON.parse(fs.readFileSync(`${repoRoot}/contracts/provider-ingestion-catalog.json`, 'utf8'));
  if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.providers)) fail('P-12 canonical provider manifest is invalid');
  return new Map(manifest.providers.map((row) => [row.providerId, row]));
}

function rawProviderID(value) {
  if (typeof value?.providerID === 'string') return value.providerID;
  if (typeof value?.providerID?.rawValue === 'string') return value.providerID.rawValue;
  return typeof value?.provider === 'string' ? value.provider : null;
}

function rawUsedPct(bucket) {
  if (typeof bucket?.usedPercent === 'number') return bucket.usedPercent;
  if (typeof bucket?.usedPct === 'number') return bucket.usedPct;
  if (typeof bucket?.usedValue === 'number' && typeof bucket?.limitValue === 'number' && bucket.limitValue > 0) {
    return bucket.usedValue / bucket.limitValue * 100;
  }
  return null;
}

function validateRpcTranscript(snapshot, canonical, captureStart, captureEnd) {
  const document = parseJson(snapshot.bytes, 'P-12 quota RPC transcript');
  exactKeys(document, ['producer', 'rows', 'transport'], 'P-12 quota RPC transcript');
  const phases = ['initial', 'retry', 'restart'];
  if (document.producer !== 'openburnbar-p12-native-quota-probe-v1'
      || document.transport !== 'AF_UNIX newline-framed BurnBarRPC'
      || !Array.isArray(document.rows) || document.rows.length !== phases.length) fail('P-12 quota RPC transcript is incomplete');
  const snapshots = new Map();
  for (const [index, row] of document.rows.entries()) {
    exactKeys(row, ['at', 'phase', 'request', 'response'], `P-12 quota RPC row ${index}`);
    const at = Date.parse(row.at);
    if (row.phase !== phases[index] || !Number.isFinite(at) || at < captureStart || at > captureEnd
        || row.request?.method !== 'daemon.quota.signals.recent' || row.request?.params?.limit !== 200
        || row.response?.error || !Array.isArray(row.response?.result?.snapshots)) fail(`P-12 quota RPC ${phases[index]} is not a successful installed-daemon read`);
    const byProvider = new Map();
    for (const raw of row.response.result.snapshots) {
      const providerId = rawProviderID(raw);
      if (!canonical.has(providerId) || byProvider.has(providerId)
          || typeof raw.sourceId !== 'string' || !/^daemon\.quota\.signals:[^\s:]+$/u.test(raw.sourceId)) fail(`P-12 quota RPC ${phases[index]} has invalid provider provenance`);
      byProvider.set(providerId, raw);
    }
    snapshots.set(row.phase, byProvider);
  }
  return { document, snapshots };
}

function quotaHeaderMap(signal) {
  return Object.fromEntries((signal?.headers ?? []).map((header) => [String(header?.name ?? '').toLowerCase(), String(header?.value ?? '')]));
}

function validateGatewayTranscript(snapshot, rpc, canonical, captureStart, captureEnd) {
  const document = parseJson(snapshot.bytes, 'P-12 gateway transcript');
  exactKeys(document, ['producer', 'rows', 'transport'], 'P-12 gateway transcript');
  const phases = ['initial', 'retry'];
  if (document.producer !== 'openburnbar-p12-native-quota-probe-v1'
      || document.transport !== 'HTTP/1.1 loopback OpenBurnBar gateway'
      || !Array.isArray(document.rows) || document.rows.length !== phases.length) fail('P-12 gateway transcript is incomplete');
  const signalIds = new Set();
  const quotaFingerprints = new Set();
  for (const [index, row] of document.rows.entries()) {
    exactKeys(row, ['at', 'phase', 'request', 'response', 'signalId', 'upstream'], `P-12 gateway row ${index}`);
    exactKeys(row.request, ['method', 'model', 'path'], `P-12 gateway request ${index}`);
    exactKeys(row.response, ['status'], `P-12 gateway response ${index}`);
    exactKeys(row.upstream, ['quotaHeaders', 'requestCount', 'status'], `P-12 upstream response ${index}`);
    const at = Date.parse(row.at);
    const rpcRow = rpc.rows.find((candidate) => candidate.phase === row.phase);
    const signal = rpcRow?.response?.result?.signals?.find((candidate) => candidate.id === row.signalId);
    const snapshotSource = rpcRow?.response?.result?.snapshots?.find((candidate) => candidate.sourceId === `daemon.quota.signals:${row.signalId}`);
    const headers = quotaHeaderMap(signal);
    if (row.phase !== phases[index] || !Number.isFinite(at) || at < captureStart || at > captureEnd
        || row.request.method !== 'POST' || !['/v1/chat/completions', '/v1/responses', '/v1/messages'].includes(row.request.path)
        || typeof row.request.model !== 'string' || !row.request.model || row.response.status !== 200
        || row.upstream.status !== 200 || row.upstream.requestCount !== 1 || !row.upstream.quotaHeaders
        || typeof row.upstream.quotaHeaders !== 'object' || Array.isArray(row.upstream.quotaHeaders)
        || !signal || !snapshotSource || !canonical.has(rawProviderID(snapshotSource))) fail(`P-12 gateway ${phases[index]} is not bound to a persisted quota signal`);
    exactKeys(row.upstream.quotaHeaders, ['x-ratelimit-limit-requests', 'x-ratelimit-limit-tokens', 'x-ratelimit-remaining-requests', 'x-ratelimit-remaining-tokens', 'x-ratelimit-reset-requests', 'x-ratelimit-reset-tokens'], `P-12 upstream quota headers ${index}`);
    for (const [name, value] of Object.entries(row.upstream.quotaHeaders)) {
      if (headers[name] !== value) fail(`P-12 gateway ${phases[index]} quota headers do not match the daemon signal`);
    }
    signalIds.add(row.signalId);
    quotaFingerprints.add(JSON.stringify(row.upstream.quotaHeaders));
  }
  if (signalIds.size !== phases.length || quotaFingerprints.size !== phases.length) fail('P-12 retry did not persist a distinct bounded gateway quota signal');
  return document;
}

function validateCatalog(snapshot, label, canonical, captureStart, captureEnd, provenance, sourceSha256, rawSnapshots = null) {
  const document = parseJson(snapshot.bytes, label);
  exactKeys(document, ['capturedAt', 'producer', 'provenance', 'providers', 'routerMode', 'sourceSha256'], label);
  const capturedAt = Date.parse(document.capturedAt);
  if (document.producer !== 'openburnbar-p12-daemon-rpc-probe-v1' || !Number.isFinite(capturedAt)
      || capturedAt < captureStart || capturedAt > captureEnd || !MODES.has(document.routerMode)
      || document.provenance !== provenance || document.sourceSha256 !== sourceSha256
      || !Array.isArray(document.providers) || document.providers.length < 1) fail(`${label} is not a live daemon quota catalog`);
  const ids = new Set();
  let bucketCount = 0;
  for (const [index, provider] of document.providers.entries()) {
    exactKeys(provider, ['aliases', 'buckets', 'confidence', 'providerId', 'sourceId', 'sourceKind'], `${label} provider ${index}`);
    const expected = canonical.get(provider.providerId);
    if (!expected || typeof provider.sourceId !== 'string' || !/^daemon\.quota\.signals:[^\s:]+$/u.test(provider.sourceId)
        || !Array.isArray(provider.aliases) || JSON.stringify(provider.aliases) !== JSON.stringify(expected.aliases)
        || !SOURCES.has(provider.sourceKind) || !CONFIDENCE.has(provider.confidence)
        || ids.has(provider.providerId) || !Array.isArray(provider.buckets)
        || (provenance === 'live-daemon' && provider.confidence === 'stale')) fail(`${label} has non-canonical provider identity or provenance`);
    ids.add(provider.providerId);
    const raw = rawSnapshots?.get(provider.providerId);
    if (rawSnapshots && (!raw || raw.sourceId !== provider.sourceId || raw.sourceKind !== provider.sourceKind
        || raw.confidence !== provider.confidence)) fail(`${label} is not bound to its raw daemon quota snapshot`);
    for (const [bucketIndex, bucket] of provider.buckets.entries()) {
      exactKeys(bucket, ['id', 'label', 'resetsAt', 'state', 'usedPct'], `${label} bucket ${index}.${bucketIndex}`);
      const reset = Date.parse(bucket.resetsAt);
      if (typeof bucket.id !== 'string' || !bucket.id || typeof bucket.label !== 'string' || !bucket.label
          || typeof bucket.usedPct !== 'number' || bucket.usedPct < 0 || bucket.usedPct > 100
          || !STATES.has(bucket.state) || !Number.isFinite(reset)) fail(`${label} has an invalid quota bucket/window`);
      if (raw) {
        const rawBucket = raw.buckets?.find((candidate) => (candidate.key ?? candidate.id) === bucket.id);
        const usedPct = rawUsedPct(rawBucket);
        if (!rawBucket || rawBucket.label !== bucket.label || usedPct === null || Math.abs(usedPct - bucket.usedPct) > 0.0001
            || rawBucket.resetsAt !== bucket.resetsAt) fail(`${label} quota bucket is not bound to raw daemon values`);
      }
      bucketCount += 1;
    }
  }
  if (bucketCount < 2) fail(`${label} must prove at least two quota buckets/windows`);
  return { document, capturedAt, bucketCount };
}

function validateEvents(snapshot, identity, captureStart, captureEnd, catalogs) {
  const document = parseJson(snapshot.bytes, 'P-12 interaction events');
  exactKeys(document, ['events', 'producer'], 'P-12 interaction events');
  const kinds = [
    'catalog-loaded', 'refresh-failed', 'stale-catalog-retained', 'retry-succeeded',
    'mode-read-before', 'mode-updated', 'mode-readback', 'mode-rolled-back',
    'mode-rollback-readback', 'app-restarted', 'catalog-persisted-readback'
  ];
  if (document.producer !== 'openburnbar-p12-native-quota-probe-v1'
      || !Array.isArray(document.events) || document.events.length !== kinds.length) fail('P-12 interaction sequence is incomplete');
  let previous = -Infinity;
  for (const [index, event] of document.events.entries()) {
    exactKeys(event, ['appPid', 'at', 'catalogSha256', 'kind', 'manifestSha256', 'mode', 'windowId'], `P-12 event ${index}`);
    const at = Date.parse(event.at);
    if (event.kind !== kinds[index] || !Number.isSafeInteger(event.appPid) || event.appPid < 2
        || typeof event.windowId !== 'string' || !event.windowId || event.manifestSha256 !== identity.manifestSha256
        || !Number.isFinite(at) || at <= previous || at < captureStart || at > captureEnd) fail(`P-12 event ${index} is not live-session-bound`);
    if (event.kind.includes('mode-') && !MODES.has(event.mode)) fail(`P-12 event ${index} has an invalid mode`);
    previous = at;
  }
  const events = document.events;
  if (events[4].mode !== events[7].mode || events[4].mode !== events[8].mode
      || events[5].mode === events[4].mode || events[5].mode !== events[6].mode
      || events[9].appPid === events[0].appPid || events[10].appPid !== events[9].appPid) fail('P-12 failover rollback or restart readback is false');
  const expectedCatalogs = [catalogs.initial, catalogs.stale, catalogs.stale, catalogs.retry,
    catalogs.retry, catalogs.retry, catalogs.retry, catalogs.retry, catalogs.retry, catalogs.retry, catalogs.restart];
  for (const [index, event] of events.entries()) {
    if (event.catalogSha256 !== expectedCatalogs[index].sha256) fail(`P-12 event ${index} is not bound to its catalog bytes`);
  }
  for (const [eventIndex, catalog] of [[0, catalogs.initial], [2, catalogs.stale], [3, catalogs.retry], [10, catalogs.restart]]) {
    if (events[eventIndex].at !== catalog.capturedAt) fail(`P-12 event ${eventIndex} is not bound to its catalog timestamp`);
  }
  return document;
}

function validateAtspi(snapshot, label, identity, expectedState, captureStart, captureEnd) {
  const document = parseJson(snapshot.bytes, label);
  exactKeys(document, ['appPid', 'capturedAt', 'expectedNames', 'manifestSha256', 'namedSamples', 'producer', 'state', 'windowId'], label);
  const at = Date.parse(document.capturedAt);
  const names = Array.isArray(document.namedSamples) ? document.namedSamples.map((row) => String(row.name ?? '')).join('\n') : '';
  if (document.producer !== 'openburnbar-p12-native-quota-probe-v1' || document.state !== expectedState
      || document.manifestSha256 !== identity.manifestSha256 || !Number.isSafeInteger(document.appPid)
      || !document.windowId || !Number.isFinite(at) || at < captureStart || at > captureEnd
      || !Array.isArray(document.expectedNames) || document.expectedNames.some((name) => !names.includes(name))) fail(`${label} lacks installed quota accessibility semantics`);
  return document;
}

export function validateP12InstalledSession(document, binding, { repoRoot }) {
  exactKeys(document, ['candidate', 'capture', 'catalogs', 'desktop', 'environmentId', 'gatewayTranscript', 'id', 'interactionEvents', 'package', 'quotaRpcTranscript', 'requirementId', 'schemaVersion', 'targetHead', 'ui'], 'P-12 installed session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p12-installed-quota-session-v1') fail('P-12 installed session schema is unsupported');
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P12_REQUIREMENT_ID, 'P-12 installed session');
  exactKeys(document.catalogs, ['initial', 'retry', 'restart', 'stale'], 'P-12 catalogs');
  const canonical = canonicalProviders(repoRoot);
  const initialRecord = artifact(repoRoot, binding.environmentId, document.catalogs.initial, 'P-12 initial catalog', { mediaType: 'json', minimumBytes: 100 });
  const staleRecord = artifact(repoRoot, binding.environmentId, document.catalogs.stale, 'P-12 stale catalog', { mediaType: 'json', minimumBytes: 100 });
  const retryRecord = artifact(repoRoot, binding.environmentId, document.catalogs.retry, 'P-12 retry catalog', { mediaType: 'json', minimumBytes: 100 });
  const restartRecord = artifact(repoRoot, binding.environmentId, document.catalogs.restart, 'P-12 restart catalog', { mediaType: 'json', minimumBytes: 100 });
  const rpcRecord = artifact(repoRoot, binding.environmentId, document.quotaRpcTranscript, 'P-12 quota RPC transcript', { mediaType: 'json', minimumBytes: 200 });
  const rpc = validateRpcTranscript(rpcRecord, canonical, envelope.startedAt, envelope.endedAt);
  const gatewayRecord = artifact(repoRoot, binding.environmentId, document.gatewayTranscript, 'P-12 gateway transcript', { mediaType: 'json', minimumBytes: 200 });
  validateGatewayTranscript(gatewayRecord, rpc.document, canonical, envelope.startedAt, envelope.endedAt);
  const initial = validateCatalog(initialRecord, 'P-12 initial catalog', canonical, envelope.startedAt, envelope.endedAt, 'live-daemon', rpcRecord.sha256, rpc.snapshots.get('initial'));
  const stale = validateCatalog(staleRecord, 'P-12 stale catalog', canonical, envelope.startedAt, envelope.endedAt, 'retained-after-refresh-failure', initialRecord.sha256);
  const retry = validateCatalog(retryRecord, 'P-12 retry catalog', canonical, envelope.startedAt, envelope.endedAt, 'live-daemon', rpcRecord.sha256, rpc.snapshots.get('retry'));
  const restart = validateCatalog(restartRecord, 'P-12 restart catalog', canonical, envelope.startedAt, envelope.endedAt, 'live-daemon', rpcRecord.sha256, rpc.snapshots.get('restart'));
  if (JSON.stringify(initial.document.providers) !== JSON.stringify(stale.document.providers)) fail('P-12 stale catalog did not retain the last usable quota values');
  if (JSON.stringify(retry.document.providers) !== JSON.stringify(restart.document.providers)) fail('P-12 retry quota data did not persist across restart');
  if (initial.document.routerMode !== restart.document.routerMode) fail('P-12 failover mode did not persist after rollback and restart');
  const eventRecord = artifact(repoRoot, binding.environmentId, document.interactionEvents, 'P-12 interaction events', { mediaType: 'json', minimumBytes: 200 });
  const identity = { manifestSha256: binding.manifestSha256 };
  const interactions = validateEvents(eventRecord, identity, envelope.startedAt, envelope.endedAt, {
    initial: { sha256: document.catalogs.initial.sha256, capturedAt: initial.document.capturedAt },
    stale: { sha256: document.catalogs.stale.sha256, capturedAt: stale.document.capturedAt },
    retry: { sha256: document.catalogs.retry.sha256, capturedAt: retry.document.capturedAt },
    restart: { sha256: document.catalogs.restart.sha256, capturedAt: restart.document.capturedAt }
  });
  if (interactions.events[4].mode !== initial.document.routerMode
      || interactions.events[8].mode !== restart.document.routerMode) {
    fail('P-12 daemon catalog modes do not match mutation and rollback readback');
  }
  exactKeys(document.ui, ['liveAtspi', 'liveScreenshot', 'staleAtspi', 'staleScreenshot'], 'P-12 UI evidence');
  const liveAtspi = artifact(repoRoot, binding.environmentId, document.ui.liveAtspi, 'P-12 live AT-SPI', { mediaType: 'json', minimumBytes: 100 });
  const staleAtspi = artifact(repoRoot, binding.environmentId, document.ui.staleAtspi, 'P-12 stale AT-SPI', { mediaType: 'json', minimumBytes: 100 });
  const liveTree = validateAtspi(liveAtspi, 'P-12 live AT-SPI', identity, 'live', envelope.startedAt, envelope.endedAt);
  const staleTree = validateAtspi(staleAtspi, 'P-12 stale AT-SPI', identity, 'stale-retained', envelope.startedAt, envelope.endedAt);
  if (liveTree.appPid !== interactions.events[0].appPid || liveTree.windowId !== interactions.events[0].windowId
      || staleTree.appPid !== interactions.events[2].appPid || staleTree.windowId !== interactions.events[2].windowId) {
    fail('P-12 AT-SPI states are not bound to the interaction process and window');
  }
  const livePng = artifact(repoRoot, binding.environmentId, document.ui.liveScreenshot, 'P-12 live screenshot', { mediaType: 'png', minimumBytes: 1024 });
  const stalePng = artifact(repoRoot, binding.environmentId, document.ui.staleScreenshot, 'P-12 stale screenshot', { mediaType: 'png', minimumBytes: 1024 });
  const livePixels = validatePng(livePng.bytes, 'P-12 live screenshot');
  const stalePixels = validatePng(stalePng.bytes, 'P-12 stale screenshot');
  if (livePixels.nonBlankPixelRatio < 0.05 || stalePixels.nonBlankPixelRatio < 0.05
      || crypto.createHash('sha256').update(livePixels.pixels).digest('hex') === crypto.createHash('sha256').update(stalePixels.pixels).digest('hex')) fail('P-12 screenshots are blank or replayed');
  const evidence = [...envelope.attestation, document.catalogs.initial, document.catalogs.stale, document.catalogs.retry, document.catalogs.restart, document.gatewayTranscript, document.quotaRpcTranscript,
    document.interactionEvents, document.ui.liveAtspi, document.ui.liveScreenshot, document.ui.staleAtspi, document.ui.staleScreenshot];
  if (new Set(evidence.map((row) => row.path)).size !== evidence.length) fail('P-12 reuses an evidence artifact');
  return { document, evidence, endedAt: envelope.endedAt, providerCount: initial.document.providers.length, bucketCount: initial.bucketCount };
}

export function buildP12Proof({ session, sessionRecord, collectedAt, providerCount, bucketCount }) {
  return {
    schemaVersion: 1, id: 'openburnbar-linux-p12-quota-proof-v1', requirementId: P12_REQUIREMENT_ID,
    environmentId: session.environmentId, targetHead: session.targetHead, candidate: session.candidate, collectedAt,
    source: { method: 'live-installed-quota-session', ...sessionRecord },
    claim: { passed: true, providerCount, bucketCount, failureRetention: true, retry: true, failoverRollback: true, restartPersistence: true, accessibility: true }
  };
}

export function validateP12Proof({ repoRoot, snapshot, environmentId, targetHead, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256 }) {
  const proof = parseJson(snapshot.bytes, 'P-12 proof');
  exactKeys(proof, ['candidate', 'claim', 'collectedAt', 'environmentId', 'id', 'requirementId', 'schemaVersion', 'source', 'targetHead'], 'P-12 proof');
  if (proof.schemaVersion !== 1 || proof.id !== 'openburnbar-linux-p12-quota-proof-v1' || proof.requirementId !== P12_REQUIREMENT_ID
      || proof.environmentId !== environmentId || proof.targetHead !== targetHead) fail('P-12 proof identity is invalid');
  exactKeys(proof.source, ['method', 'path', 'sha256', 'size'], 'P-12 proof source');
  if (proof.source.method !== 'live-installed-quota-session') fail('P-12 proof source is not live');
  const sourceRecord = { path: proof.source.path, sha256: proof.source.sha256, size: proof.source.size };
  const source = artifact(repoRoot, environmentId, sourceRecord, 'P-12 source session', { mediaType: 'json', minimumBytes: 200 });
  const validated = validateP12InstalledSession(parseJson(source.bytes, 'P-12 source session'), {
    environmentId, targetHead, candidateRunId, candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256
  }, { repoRoot });
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(proof.claim, ['accessibility', 'bucketCount', 'failoverRollback', 'failureRetention', 'passed', 'providerCount', 'restartPersistence', 'retry'], 'P-12 claim');
  if (proof.claim.passed !== true || proof.claim.providerCount !== validated.providerCount || proof.claim.bucketCount !== validated.bucketCount
      || ['accessibility', 'failoverRollback', 'failureRetention', 'restartPersistence', 'retry'].some((key) => proof.claim[key] !== true)) fail('P-12 claim is not derived from its source session');
  return { ...validated, source: sourceRecord };
}
