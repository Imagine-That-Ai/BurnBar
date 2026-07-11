#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const productionRepositoryOrigin = 'https://downloads.burnbar.ai';
const CHANNELS = new Set(['stable', 'prerelease', 'nightly']);
const SHA256 = /^[a-f0-9]{64}$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const COMMIT = /^[a-f0-9]{40}$/u;
const ETAG = /^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u;
const ACTOR = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,96}|[A-Za-z0-9_-]{0,91}\[bot\])$/u;
const RUN_URL = /^https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/actions\/runs\/[1-9][0-9]*(?:\/attempts\/[1-9][0-9]*)?$/u;

function repositoryBaseUrl(value, allowLocalTestOrigin) {
  if (value === productionRepositoryOrigin || value === `${productionRepositoryOrigin}/`) return productionRepositoryOrigin;
  const url = new URL(value);
  const bare = !url.username && !url.password && url.pathname === '/' && !url.search && !url.hash;
  if (!bare) throw new Error('repository router URL must be a bare origin without credentials, path, query, or fragment');
  if (allowLocalTestOrigin === true && ['127.0.0.1', 'localhost'].includes(url.hostname)) return url.origin;
  throw new Error(`repository router URL must use ${productionRepositoryOrigin}`);
}

function identity(value, label) {
  const normalized = value?.targetSnapshotId
    ? { channel: value.channel, snapshotId: value.targetSnapshotId, version: value.version, sourceCommit: value.sourceCommit }
    : value;
  if (!normalized || !CHANNELS.has(normalized.channel) || !SHA256.test(normalized.snapshotId ?? '')
      || !VERSION.test(normalized.version ?? '') || !COMMIT.test(normalized.sourceCommit ?? '')) {
    throw new Error(`${label} repository activation identity is invalid`);
  }
  return {
    channel: normalized.channel,
    snapshotId: normalized.snapshotId,
    version: normalized.version,
    sourceCommit: normalized.sourceCommit
  };
}

function validateOptions(options) {
  if (typeof options.token !== 'string' || !/^[A-Za-z0-9._~+/=-]{32,4096}$/u.test(options.token)) {
    throw new Error('repository activation token must use the approved 32 to 4096 character alphabet');
  }
  if (typeof options.actor !== 'string' || !ACTOR.test(options.actor)) throw new Error('repository compensation actor is invalid');
  if (options.runUrl !== null && options.runUrl !== undefined && !RUN_URL.test(options.runUrl)) {
    throw new Error('repository compensation run URL is invalid');
  }
  if (options.reason !== null && options.reason !== undefined
      && (typeof options.reason !== 'string' || !/^[\x20-\x7e]{8,500}$/u.test(options.reason))) {
    throw new Error('repository compensation reason must contain 8 to 500 printable ASCII characters');
  }
}

function readSourceReceipt(receiptPath) {
  if (!receiptPath || !fs.existsSync(receiptPath)) return { attempted: false, reason: 'missing-receipt', receipt: null };
  const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
  if ((receipt.phase === 'planned' && receipt.mutationAttempted === true)
      || (receipt.phase === 'attempted' && receipt.mutationAttempted === false)
      || (receipt.dryRun === true && receipt.mutationAttempted === true)) {
    throw new Error('activation receipt contains contradictory mutation-attempt state');
  }
  if (receipt.mutationAttempted === false || receipt.phase === 'planned' || receipt.dryRun === true) {
    return { attempted: false, reason: 'proven-not-attempted', receipt };
  }
  return { attempted: true, reason: 'attempted-or-ambiguous', receipt };
}

function publicRoots(channel) {
  return [
    `/linux/apt/dists/${channel}/InRelease`,
    ...['aarch64', 'x86_64'].flatMap((architecture) => [
      `/linux/rpm/${channel}/${architecture}/repodata/repomd.xml`,
      `/linux/rpm/${channel}/${architecture}/repodata/repomd.xml.asc`
    ])
  ];
}

function feedRoots(channel) {
  const feedPath = channel === 'stable'
    ? '/latest-linux.json'
    : `/linux/update/${channel}/latest-linux.json`;
  return [feedPath, `${feedPath}.ed25519.sig`];
}

function activePointer(value, response, channel) {
  const raw = value?.activation ?? value?.active;
  const active = identity(raw, 'live');
  const pointerEtag = value?.pointerEtag;
  if (value?.schemaVersion !== 1 || value.status !== 'active' || value.channel !== channel
      || !Number.isSafeInteger(raw?.generation) || raw.generation <= 0
      || !(raw.previousSnapshotId === null || SHA256.test(raw.previousSnapshotId ?? ''))
      || !ETAG.test(pointerEtag ?? '') || response.headers.get('etag') !== pointerEtag) {
    throw new Error('repository compensation active status is malformed');
  }
  return {
    ...value,
    active: { ...active, generation: raw.generation, previousSnapshotId: raw.previousSnapshotId },
    pointerEtag
  };
}

function inactivePointer(value, response, channel) {
  if (value?.schemaVersion !== 1 || value.status !== 'inactive' || value.channel !== channel) {
    throw new Error('repository compensation inactive status is malformed');
  }
  if (!value.deactivation) {
    if (value.pointerEtag !== undefined || response.headers.get('etag')) {
      throw new Error('repository compensation absent pointer status unexpectedly has an ETag');
    }
    return { ...value, active: null, deactivation: null, pointerEtag: null };
  }
  const record = value.deactivation;
  if (!Number.isSafeInteger(record.generation) || record.generation <= 1
      || !['legacy-direct-r2', 'disabled'].includes(record.fallbackMode)
      || !SHA256.test(record.previousSnapshotId ?? '') || !VERSION.test(record.previousVersion ?? '')
      || !COMMIT.test(record.previousSourceCommit ?? '') || !ETAG.test(value.pointerEtag ?? '')
      || response.headers.get('etag') !== value.pointerEtag) {
    throw new Error('repository compensation deactivation status is malformed');
  }
  return { ...value, active: null, pointerEtag: value.pointerEtag };
}

function matchesIdentity(left, right) {
  return Boolean(left && right && left.channel === right.channel && left.snapshotId === right.snapshotId
    && left.version === right.version && left.sourceCommit === right.sourceCommit);
}

function feedIdentity(record) {
  return record ? {
    channel: record.channel,
    version: record.version,
    sourceCommit: record.sourceCommit,
    feed: record.feed,
    publishedAt: record.publishedAt
  } : null;
}

function feedMatchesRepository(record, repository) {
  return Boolean(record && repository?.active
    && record.channel === repository.active.channel
    && record.version === repository.active.version
    && record.sourceCommit === repository.active.sourceCommit
    && record.repository?.generation === repository.active.generation
    && record.repository?.snapshotId === repository.active.snapshotId
    && record.repository?.pointerEtag === repository.pointerEtag);
}

export async function compensateLinuxRepositoryActivation(options, fetchImpl = fetch) {
  const outcome = {
    schemaVersion: 1,
    operation: 'compensate-linux-repository-activation',
    sourceMutationAttempted: null,
    channel: null,
    candidate: null,
    previous: null,
    strategy: null,
    desiredSnapshotId: null,
    candidateWasCurrent: false,
    mutationAttempted: false,
    attempts: [],
    finalObservedStatus: null,
    feedRestoration: null,
    expectedFallbackMode: null,
    contained: false,
    passed: false,
    failures: []
  };
  const fail = (error) => outcome.failures.push(error instanceof Error ? error.message : String(error));

  try {
    const source = readSourceReceipt(options.activationReceiptPath);
    outcome.sourceMutationAttempted = source.attempted;
    if (!source.attempted) {
      outcome.strategy = source.reason;
      outcome.contained = true;
      outcome.passed = true;
      return outcome;
    }

    const receipt = source.receipt;
    outcome.candidate = identity(receipt.result?.activation ?? receipt.candidate ?? receipt.request, 'candidate');
    outcome.channel = outcome.candidate.channel;
    if (receipt.status?.active) {
      outcome.previous = identity(receipt.status.active, 'previous');
      if (outcome.previous.channel !== outcome.channel) throw new Error('previous activation channel does not match candidate');
    }
    outcome.desiredSnapshotId = outcome.previous?.snapshotId ?? null;

    const baseUrl = repositoryBaseUrl(options.baseUrl, options.allowLocalTestOrigin);
    validateOptions(options);
    const headers = { Authorization: `Bearer ${options.token}`, Accept: 'application/json' };
    const jsonPost = async (publicPath, request, operation) => {
      const attempt = { operation, request, ok: false };
      outcome.attempts.push(attempt);
      outcome.mutationAttempted = true;
      try {
        const response = await fetchImpl(`${baseUrl}${publicPath}`, {
          method: 'POST',
          headers: { ...headers, 'Content-Type': 'application/json' },
          body: JSON.stringify(request),
          redirect: 'error'
        });
        attempt.httpStatus = response.status;
        attempt.responseEtag = response.headers.get('etag');
        attempt.body = response.ok ? await response.json() : null;
        if (!response.ok) attempt.error = (await response.text()).slice(0, 500);
        else attempt.ok = true;
        return { response, body: attempt.body };
      } catch (error) {
        attempt.error = error instanceof Error ? error.message : String(error);
        return { response: null, body: null };
      }
    };
    const observeStatus = async (phase) => {
      const attempt = { operation: 'status', phase, ok: false };
      outcome.attempts.push(attempt);
      const response = await fetchImpl(`${baseUrl}/linux/repository-admin/status?channel=${outcome.channel}`, {
        headers,
        redirect: 'error'
      });
      attempt.httpStatus = response.status;
      if (![200, 404].includes(response.status)) throw new Error(`repository compensation status failed: HTTP ${response.status}`);
      const value = await response.json();
      const status = response.status === 200
        ? activePointer(value, response, outcome.channel)
        : inactivePointer(value, response, outcome.channel);
      attempt.ok = true;
      attempt.snapshotId = status.active?.snapshotId ?? null;
      attempt.generation = status.active?.generation ?? status.deactivation?.generation ?? null;
      attempt.pointerEtag = status.pointerEtag;
      return status;
    };
    const verifyRoots = async (mode, snapshotId = null) => {
      for (const publicPath of publicRoots(outcome.channel)) {
        const attempt = { operation: 'verify-public-root', expectedState: mode, path: publicPath, ok: false };
        outcome.attempts.push(attempt);
        const response = await fetchImpl(`${baseUrl}${publicPath}`, { method: 'HEAD', redirect: 'error' });
        attempt.httpStatus = response.status;
        attempt.snapshotId = response.headers.get('x-openburnbar-repository-snapshot');
        const valid = mode === 'active'
          ? response.status === 200 && attempt.snapshotId === snapshotId
          : mode === 'legacy-direct-r2'
            ? [200, 404].includes(response.status) && attempt.snapshotId === null
            : response.status === 503 && attempt.snapshotId === null;
        if (!valid) throw new Error(`public repository root did not prove ${mode} containment: ${publicPath}`);
        attempt.ok = true;
      }
    };
    const verifyFeedRoots = async (mode, snapshotId = null, feedGeneration = null) => {
      for (const publicPath of feedRoots(outcome.channel)) {
        const attempt = { operation: 'verify-public-feed', expectedState: mode, path: publicPath, ok: false };
        outcome.attempts.push(attempt);
        const response = await fetchImpl(`${baseUrl}${publicPath}`, { method: 'HEAD', redirect: 'error' });
        attempt.httpStatus = response.status;
        attempt.snapshotId = response.headers.get('x-openburnbar-repository-snapshot');
        attempt.feedGeneration = response.headers.get('x-openburnbar-feed-generation');
        const valid = mode === 'active'
          ? response.status === 200 && attempt.snapshotId === snapshotId
            && attempt.feedGeneration === String(feedGeneration)
          : mode === 'legacy-direct-r2'
            ? (outcome.channel === 'stable' ? [200, 404].includes(response.status) : response.status === 404)
              && attempt.snapshotId === null && attempt.feedGeneration === null
            : response.status === 503 && attempt.snapshotId === null && attempt.feedGeneration === null;
        if (!valid) {
          throw new Error(`public Linux feed did not prove ${mode} containment: ${publicPath}`);
        }
        attempt.ok = true;
      }
    };
    const observeFeed = async (phase) => {
      const attempt = { operation: 'feed-status', phase, ok: false };
      outcome.attempts.push(attempt);
      const response = await fetchImpl(
        `${baseUrl}/linux/repository-admin/feed-status?channel=${outcome.channel}`,
        { headers, redirect: 'error' }
      );
      attempt.httpStatus = response.status;
      if (response.status === 404) {
        const value = await response.json();
        if (value?.schemaVersion !== 1 || value.status !== 'inactive') throw new Error('inactive feed status is malformed');
        attempt.ok = true;
        return null;
      }
      if (response.status !== 200) throw new Error(`feed status failed: HTTP ${response.status}`);
      const value = await response.json();
      if (value?.schemaVersion !== 1 || value.status !== 'published' || !value.feed
          || !Number.isSafeInteger(value.feed.generation) || value.feed.generation <= 0
          || !ETAG.test(value.pointerEtag ?? '') || response.headers.get('etag') !== value.pointerEtag) {
        throw new Error('published feed status is malformed');
      }
      attempt.ok = true;
      attempt.generation = value.feed.generation;
      attempt.pointerEtag = value.pointerEtag;
      return { record: value.feed, pointerEtag: value.pointerEtag };
    };
    const restoreFeed = async (repository) => {
      const current = await observeFeed('before-rebind');
      if (!current) {
        outcome.feedRestoration = 'no-feed-pointer';
        return true;
      }
      if (feedMatchesRepository(current.record, repository)) {
        outcome.feedRestoration = 'already-bound';
        return true;
      }
      const restoredIdentity = repository.active;
      const currentIdentity = feedIdentity(current.record);
      const previousIdentity = current.record.previousFeed;
      const target = currentIdentity?.channel === restoredIdentity.channel
          && currentIdentity.version === restoredIdentity.version
          && currentIdentity.sourceCommit === restoredIdentity.sourceCommit
        ? 'current'
        : previousIdentity?.channel === restoredIdentity.channel
          && previousIdentity.version === restoredIdentity.version
          && previousIdentity.sourceCommit === restoredIdentity.sourceCommit ? 'previous' : null;
      if (!target) throw new Error('feed pointer retains no descriptor matching the restored repository');
      const request = {
        schemaVersion: 1,
        channel: outcome.channel,
        target,
        expectedCurrent: { generation: current.record.generation, etag: current.pointerEtag },
        expectedRepository: {
          generation: repository.active.generation,
          snapshotId: repository.active.snapshotId,
          pointerEtag: repository.pointerEtag
        },
        actor: options.actor,
        runUrl: options.runUrl ?? null,
        reason: options.reason ?? `Restore Linux update feed after repository compensation ${outcome.candidate.snapshotId}`
      };
      await jsonPost('/linux/repository-admin/rebind-feed', request, 'rebind-feed');
      const reconciled = await observeFeed('after-rebind');
      if (!reconciled || !feedMatchesRepository(reconciled.record, repository)) {
        throw new Error('feed rebind did not reach the restored repository identity');
      }
      outcome.feedRestoration = target;
      return true;
    };

    let live = await observeStatus('initial');
    outcome.finalObservedStatus = live;
    outcome.candidateWasCurrent = matchesIdentity(live.active, outcome.candidate);

    if (outcome.previous && matchesIdentity(live.active, outcome.previous)) {
      outcome.strategy = 'already-rolled-back';
    } else if (outcome.previous && live.active === null
        && live.deactivation?.previousSnapshotId === outcome.candidate.snapshotId
        && live.deactivation.fallbackMode === 'disabled') {
      outcome.strategy = 'rollback-fallback-deactivate';
      outcome.expectedFallbackMode = 'disabled';
    } else if (!outcome.previous && live.active === null) {
      outcome.strategy = live.deactivation ? 'already-deactivated' : 'activation-not-committed';
      outcome.expectedFallbackMode = live.deactivation?.fallbackMode ?? null;
    } else if (!outcome.candidateWasCurrent) {
      outcome.strategy = 'unrelated-current';
      throw new Error('candidate repository snapshot is not current and the desired compensation state is not active');
    } else if (outcome.previous) {
      outcome.strategy = 'rollback';
      const request = {
        schemaVersion: 1,
        mode: 'rollback',
        channel: outcome.channel,
        targetSnapshotId: outcome.previous.snapshotId,
        expectedCurrentSnapshotId: live.active.snapshotId,
        expectedCurrentGeneration: live.active.generation,
        expectedCurrentPointerEtag: live.pointerEtag,
        version: outcome.previous.version,
        sourceCommit: outcome.previous.sourceCommit,
        actor: options.actor,
        runUrl: options.runUrl ?? null,
        reason: options.reason ?? `Compensate failed release activation ${outcome.candidate.snapshotId}`
      };
      await jsonPost('/linux/repository-admin/activate', request, 'rollback');
      live = await observeStatus('after-rollback');
      outcome.finalObservedStatus = live;
      if (matchesIdentity(live.active, outcome.candidate)) {
        outcome.strategy = 'rollback-fallback-deactivate';
        outcome.expectedFallbackMode = 'disabled';
        const deactivateRequest = {
          schemaVersion: 1,
          channel: outcome.channel,
          expectedCurrentSnapshotId: live.active.snapshotId,
          expectedCurrentGeneration: live.active.generation,
          expectedCurrentPointerEtag: live.pointerEtag,
          actor: options.actor,
          runUrl: options.runUrl ?? null,
          reason: options.reason ?? `Fail closed after repository rollback failed ${outcome.candidate.snapshotId}`
        };
        await jsonPost('/linux/repository-admin/deactivate', deactivateRequest, 'fallback-deactivate');
        live = await observeStatus('after-fallback-deactivate');
        outcome.finalObservedStatus = live;
      }
    } else {
      outcome.strategy = 'deactivate';
      outcome.expectedFallbackMode = live.active.previousSnapshotId === null ? 'legacy-direct-r2' : 'disabled';
      const request = {
        schemaVersion: 1,
        channel: outcome.channel,
        expectedCurrentSnapshotId: live.active.snapshotId,
        expectedCurrentGeneration: live.active.generation,
        expectedCurrentPointerEtag: live.pointerEtag,
        actor: options.actor,
        runUrl: options.runUrl ?? null,
        reason: options.reason ?? `Compensate failed first release activation ${outcome.candidate.snapshotId}`
      };
      await jsonPost('/linux/repository-admin/deactivate', request, 'deactivate');
      live = await observeStatus('after-deactivate');
      outcome.finalObservedStatus = live;
    }

    if (outcome.strategy === 'activation-not-committed') {
      outcome.contained = true;
      outcome.passed = true;
      return outcome;
    }

    if (outcome.previous && matchesIdentity(live.active, outcome.previous)) {
      await restoreFeed(live);
    } else if (live.active !== null) {
      throw new Error('repository compensation did not reach a contained activation state');
    }

    const before = await observeStatus('stability-before');
    if (before.active) {
      if (!outcome.previous || !matchesIdentity(before.active, outcome.previous)) {
        throw new Error('repository activation changed before compensation stability verification');
      }
      const feedBefore = await observeFeed('stability-before');
      if (outcome.feedRestoration === 'no-feed-pointer') {
        if (feedBefore !== null) throw new Error('Linux feed pointer appeared after no-feed containment was proven');
      } else if (!feedBefore || !feedMatchesRepository(feedBefore.record, before)) {
        throw new Error('Linux feed binding changed before public compensation verification');
      }
      await verifyRoots('active', before.active.snapshotId);
      if (feedBefore) {
        await verifyFeedRoots('active', before.active.snapshotId, feedBefore.record.generation);
      }
      const after = await observeStatus('stability-after');
      if (!matchesIdentity(after.active, before.active) || after.pointerEtag !== before.pointerEtag
          || after.active.generation !== before.active.generation) {
        throw new Error('repository activation changed during public compensation verification');
      }
      const feedAfter = await observeFeed('stability-after');
      if ((feedBefore === null) !== (feedAfter === null)
          || (feedBefore && (feedAfter.pointerEtag !== feedBefore.pointerEtag
            || !feedMatchesRepository(feedAfter.record, after)))) {
        throw new Error('Linux feed binding changed during public compensation verification');
      }
      const final = await observeStatus('final');
      if (!matchesIdentity(final.active, after.active) || final.pointerEtag !== after.pointerEtag
          || final.active.generation !== after.active.generation) {
        throw new Error('repository activation changed after feed compensation verification');
      }
      outcome.finalObservedStatus = final;
    } else {
      if (!before.deactivation || before.deactivation.previousSnapshotId !== outcome.candidate.snapshotId
          || before.deactivation.fallbackMode !== outcome.expectedFallbackMode) {
        throw new Error(`repository deactivation did not preserve expected ${outcome.expectedFallbackMode} containment`);
      }
      await verifyRoots(outcome.expectedFallbackMode);
      await verifyFeedRoots(outcome.expectedFallbackMode);
      const after = await observeStatus('stability-after');
      if (after.active !== null || after.pointerEtag !== before.pointerEtag
          || after.deactivation?.generation !== before.deactivation.generation
          || after.deactivation?.fallbackMode !== before.deactivation.fallbackMode
          || after.deactivation?.previousSnapshotId !== before.deactivation.previousSnapshotId) {
        throw new Error('repository deactivation changed during public compensation verification');
      }
      const final = await observeStatus('final');
      if (final.active !== null || final.pointerEtag !== after.pointerEtag
          || final.deactivation?.generation !== after.deactivation.generation
          || final.deactivation?.fallbackMode !== after.deactivation.fallbackMode
          || final.deactivation?.previousSnapshotId !== after.deactivation.previousSnapshotId) {
        throw new Error('repository deactivation changed after public compensation verification');
      }
      outcome.finalObservedStatus = final;
    }
    outcome.contained = true;
  } catch (error) {
    fail(error);
  }

  outcome.passed = outcome.contained && outcome.failures.length === 0;
  return outcome;
}

export function writeAtomicJson(outputPath, value) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const temporary = `${outputPath}.tmp-${process.pid}-${Date.now()}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
    fs.renameSync(temporary, outputPath);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

async function main() {
  const releaseOut = process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release');
  const runUrl = process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
    ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : null;
  const result = await compensateLinuxRepositoryActivation({
    activationReceiptPath: process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_RECEIPT
      ?? path.join(releaseOut, 'repository-activation.json'),
    baseUrl: process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? productionRepositoryOrigin,
    token: process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN,
    actor: process.env.GITHUB_ACTOR ?? process.env.USER ?? 'unknown',
    runUrl
  });
  const receipt = { ...result, completedAt: new Date().toISOString() };
  const outputPath = process.env.OPENBURNBAR_LINUX_REPOSITORY_COMPENSATION_RECEIPT;
  if (outputPath) writeAtomicJson(outputPath, receipt);
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  if (!result.passed) process.exitCode = 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
