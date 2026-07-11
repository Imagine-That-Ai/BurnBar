import crypto from 'node:crypto';
import fs from 'node:fs';

const CHANNELS = new Set(['stable', 'prerelease', 'nightly']);
const SHA256 = /^[a-f0-9]{64}$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const POINTER_ETAG = /^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u;
const ACTOR = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,96}|[A-Za-z0-9_-]{0,91}\[bot\])$/u;
const RUN_URL = /^https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/actions\/runs\/[1-9][0-9]*(?:\/attempts\/[1-9][0-9]*)?$/u;

export function repositorySnapshotIdentity(closurePath) {
  const bytes = fs.readFileSync(closurePath);
  const closure = JSON.parse(bytes.toString('utf8'));
  if (![1, 2].includes(closure.schemaVersion)) throw new Error('repository closure schemaVersion must be 1 or 2');
  if (!CHANNELS.has(closure.channel)) throw new Error('repository closure channel is invalid');
  if (!VERSION.test(closure.version ?? '')) throw new Error('repository closure version is invalid');
  if (!/^[a-f0-9]{40}$/u.test(closure.gitCommit ?? '')) throw new Error('repository closure git commit is invalid');
  return {
    channel: closure.channel,
    version: closure.version,
    sourceCommit: closure.gitCommit,
    snapshotId: crypto.createHash('sha256').update(bytes).digest('hex')
  };
}

export function validateActivationStatus(value, expectedChannel, responseEtag = undefined) {
  if (!value || value.schemaVersion !== 1 || value.channel !== expectedChannel
      || !['active', 'inactive'].includes(value.status)) {
    throw new Error('repository activation status is malformed or channel-mismatched');
  }
  if (value.status === 'inactive') {
    if ((value.active !== undefined && value.active !== null)
        || (value.activation !== undefined && value.activation !== null)) {
      throw new Error('repository activation status contains contradictory inactive state');
    }
    const hasPointer = value.deactivation !== undefined || value.pointerEtag !== undefined;
    if (!hasPointer) {
      if (responseEtag !== undefined && responseEtag !== null) {
        throw new Error('repository activation absent pointer unexpectedly has an HTTP ETag');
      }
      return { ...value, active: null, currentGeneration: null, currentPointerEtag: null };
    }
    if (!value.deactivation || !Number.isSafeInteger(value.deactivation.generation)
        || value.deactivation.generation <= 0 || !POINTER_ETAG.test(value.pointerEtag ?? '')
        || (responseEtag !== undefined && responseEtag !== value.pointerEtag)) {
      throw new Error('repository activation status contains an invalid inactive pointer');
    }
    return {
      ...value,
      active: null,
      currentGeneration: value.deactivation.generation,
      currentPointerEtag: value.pointerEtag
    };
  }
  const active = value.active ?? value.activation;
  if (value.deactivation !== undefined) {
    throw new Error('repository activation status contains contradictory active state');
  }
  if (!active || !SHA256.test(active.snapshotId ?? '') || !VERSION.test(active.version ?? '')) {
    throw new Error('repository activation status contains an invalid active snapshot');
  }
  if (!Number.isSafeInteger(active.generation) || active.generation <= 0
      || !POINTER_ETAG.test(value.pointerEtag ?? '')
      || (responseEtag !== undefined && responseEtag !== value.pointerEtag)) {
    throw new Error('repository activation status contains an invalid active pointer');
  }
  return {
    ...value,
    active,
    currentGeneration: active.generation,
    currentPointerEtag: value.pointerEtag
  };
}

export function activationRequest({ identity, status, actor, runUrl, reason, mode = 'promote' }) {
  if (!identity || !SHA256.test(identity.snapshotId ?? '') || !CHANNELS.has(identity.channel)) {
    throw new Error('target repository snapshot identity is invalid');
  }
  const current = validateActivationStatus(status, identity.channel);
  if (typeof actor !== 'string' || !ACTOR.test(actor)) throw new Error('activation actor is invalid');
  if (!['promote', 'rollback', 'refresh'].includes(mode)) throw new Error('activation mode is invalid');
  if (typeof reason !== 'string' || reason.length < 8 || reason.length > 500
      || reason.trim() !== reason || /[\u0000-\u001f\u007f]/u.test(reason)) {
    throw new Error('activation reason must contain 8 to 500 printable characters');
  }
  if (runUrl !== null && runUrl !== undefined && !RUN_URL.test(runUrl)) {
    throw new Error('activation run URL must be an OpenBurnBar GitHub Actions run URL');
  }
  return {
    schemaVersion: 1,
    mode,
    channel: identity.channel,
    targetSnapshotId: identity.snapshotId,
    expectedCurrentSnapshotId: current.active?.snapshotId ?? null,
    expectedCurrentGeneration: current.currentGeneration,
    expectedCurrentPointerEtag: current.currentPointerEtag,
    version: identity.version,
    sourceCommit: identity.sourceCommit,
    actor,
    runUrl: runUrl ?? null,
    reason
  };
}

export function validateActivationResponse(value, request, responseEtag) {
  const record = value?.activation;
  const responseKeys = value && typeof value === 'object' ? Object.keys(value).sort() : [];
  const recordKeys = record && typeof record === 'object' ? Object.keys(record).sort() : [];
  const expectedGeneration = (request.expectedCurrentGeneration ?? 0) + 1;
  if (JSON.stringify(responseKeys) !== JSON.stringify(['activation', 'pointerEtag', 'schemaVersion', 'status'])
      || JSON.stringify(recordKeys) !== JSON.stringify([
        'activatedAt', 'actor', 'channel', 'closureSha256', 'generation', 'mode', 'previousSnapshotId',
        'reason', 'runUrl', 'schemaVersion', 'snapshotId', 'sourceCommit', 'version'
      ])
      || value?.schemaVersion !== 1 || value.status !== 'activated'
      || !record || record.channel !== request.channel
      || record.snapshotId !== request.targetSnapshotId || !SHA256.test(record.snapshotId ?? '')
      || record.version !== request.version || record.sourceCommit !== request.sourceCommit
      || record.schemaVersion !== 1 || record.mode !== request.mode
      || record.closureSha256 !== request.targetSnapshotId
      || record.previousSnapshotId !== request.expectedCurrentSnapshotId
      || record.generation !== expectedGeneration
      || record.actor !== request.actor || record.runUrl !== request.runUrl || record.reason !== request.reason
      || typeof record.activatedAt !== 'string' || !Number.isFinite(Date.parse(record.activatedAt))
      || !POINTER_ETAG.test(value.pointerEtag ?? '') || responseEtag !== value.pointerEtag) {
    throw new Error('repository activation response does not confirm the requested snapshot');
  }
  return value;
}
