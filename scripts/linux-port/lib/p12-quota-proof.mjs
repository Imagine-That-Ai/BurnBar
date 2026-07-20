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

function validateCatalog(snapshot, label, canonical, captureStart, captureEnd) {
  const document = parseJson(snapshot.bytes, label);
  exactKeys(document, ['capturedAt', 'producer', 'providers', 'routerMode'], label);
  const capturedAt = Date.parse(document.capturedAt);
  if (document.producer !== 'openburnbar-p12-daemon-rpc-probe-v1' || !Number.isFinite(capturedAt)
      || capturedAt < captureStart || capturedAt > captureEnd || !MODES.has(document.routerMode)
      || !Array.isArray(document.providers) || document.providers.length < 1) fail(`${label} is not a live daemon quota catalog`);
  const ids = new Set();
  let bucketCount = 0;
  for (const [index, provider] of document.providers.entries()) {
    exactKeys(provider, ['aliases', 'buckets', 'confidence', 'providerId', 'sourceId', 'sourceKind'], `${label} provider ${index}`);
    const expected = canonical.get(provider.providerId);
    if (!expected || provider.sourceId !== expected.agentProviderCase
        || !Array.isArray(provider.aliases) || JSON.stringify(provider.aliases) !== JSON.stringify(expected.aliases)
        || !SOURCES.has(provider.sourceKind) || !CONFIDENCE.has(provider.confidence)
        || ids.has(provider.providerId) || !Array.isArray(provider.buckets)) fail(`${label} has non-canonical provider identity or provenance`);
    ids.add(provider.providerId);
    for (const [bucketIndex, bucket] of provider.buckets.entries()) {
      exactKeys(bucket, ['id', 'label', 'resetsAt', 'state', 'usedPct'], `${label} bucket ${index}.${bucketIndex}`);
      const reset = Date.parse(bucket.resetsAt);
      if (typeof bucket.id !== 'string' || !bucket.id || typeof bucket.label !== 'string' || !bucket.label
          || typeof bucket.usedPct !== 'number' || bucket.usedPct < 0 || bucket.usedPct > 100
          || !STATES.has(bucket.state) || !Number.isFinite(reset)) fail(`${label} has an invalid quota bucket/window`);
      bucketCount += 1;
    }
  }
  if (bucketCount < 2) fail(`${label} must prove at least two quota buckets/windows`);
  return { document, capturedAt, bucketCount };
}

function validateEvents(snapshot, identity, captureStart, captureEnd) {
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
    exactKeys(event, ['appPid', 'at', 'kind', 'manifestSha256', 'mode', 'windowId'], `P-12 event ${index}`);
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
  exactKeys(document, ['candidate', 'capture', 'catalogs', 'desktop', 'environmentId', 'id', 'interactionEvents', 'package', 'requirementId', 'schemaVersion', 'targetHead', 'ui'], 'P-12 installed session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p12-installed-quota-session-v1') fail('P-12 installed session schema is unsupported');
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P12_REQUIREMENT_ID, 'P-12 installed session');
  exactKeys(document.catalogs, ['initial', 'retry', 'restart'], 'P-12 catalogs');
  const canonical = canonicalProviders(repoRoot);
  const initialRecord = artifact(repoRoot, binding.environmentId, document.catalogs.initial, 'P-12 initial catalog', { mediaType: 'json', minimumBytes: 100 });
  const retryRecord = artifact(repoRoot, binding.environmentId, document.catalogs.retry, 'P-12 retry catalog', { mediaType: 'json', minimumBytes: 100 });
  const restartRecord = artifact(repoRoot, binding.environmentId, document.catalogs.restart, 'P-12 restart catalog', { mediaType: 'json', minimumBytes: 100 });
  const initial = validateCatalog(initialRecord, 'P-12 initial catalog', canonical, envelope.startedAt, envelope.endedAt);
  const retry = validateCatalog(retryRecord, 'P-12 retry catalog', canonical, envelope.startedAt, envelope.endedAt);
  const restart = validateCatalog(restartRecord, 'P-12 restart catalog', canonical, envelope.startedAt, envelope.endedAt);
  const stable = (value) => JSON.stringify(value.providers);
  if (stable(initial.document) !== stable(retry.document) || stable(initial.document) !== stable(restart.document)) fail('P-12 quota data was not retained across failure, retry, and restart');
  if (initial.document.routerMode !== restart.document.routerMode) fail('P-12 failover mode did not persist after rollback and restart');
  const eventRecord = artifact(repoRoot, binding.environmentId, document.interactionEvents, 'P-12 interaction events', { mediaType: 'json', minimumBytes: 200 });
  const identity = { manifestSha256: binding.manifestSha256 };
  const interactions = validateEvents(eventRecord, identity, envelope.startedAt, envelope.endedAt);
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
  const evidence = [...envelope.attestation, document.catalogs.initial, document.catalogs.retry, document.catalogs.restart,
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
