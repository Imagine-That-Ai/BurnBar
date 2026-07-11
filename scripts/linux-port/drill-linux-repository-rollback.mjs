#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  repositorySnapshotIdentity,
  validateActivationResponse,
  validateActivationStatus
} from './lib/linux-repository-activation.mjs';
import { writeAtomicJson } from './compensate-linux-repository-activation.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const productionRepositoryOrigin = 'https://downloads.burnbar.ai';

function repositoryBaseUrl(value, allowLocalTestOrigin) {
  if (value === productionRepositoryOrigin || value === `${productionRepositoryOrigin}/`) return productionRepositoryOrigin;
  const url = new URL(value);
  const bare = url.username === '' && url.password === '' && url.pathname === '/'
    && url.search === '' && url.hash === '';
  if (!bare) throw new Error('repository router URL must be a bare origin without credentials, path, query, or fragment');
  if (allowLocalTestOrigin === true && ['127.0.0.1', 'localhost'].includes(url.hostname)) return url.origin;
  throw new Error(`repository router URL must use ${productionRepositoryOrigin}`);
}

function validPrevious(value, channel) {
  return value && value.channel === channel
    && /^[a-f0-9]{64}$/u.test(value.snapshotId ?? '')
    && /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u.test(value.version ?? '')
    && /^[a-f0-9]{40}$/u.test(value.sourceCommit ?? '');
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

export async function drillLinuxRepositoryRollback(options, fetchImpl = fetch) {
  const outcome = {
    schemaVersion: 1,
    operation: 'drill-linux-repository-rollback',
    skipped: false,
    candidate: null,
    previous: null,
    attempts: [],
    finalObservedStatus: null,
    candidateRestored: false,
    passed: false,
    failures: []
  };
  let baseUrl;
  let headers;
  let reactivationSucceeded = false;
  let candidateWasCurrent = false;
  const fail = (error) => outcome.failures.push(error instanceof Error ? error.message : String(error));
  const observeStatus = async (phase) => {
    const attempt = { operation: 'status', phase, ok: false };
    outcome.attempts.push(attempt);
    const response = await fetchImpl(`${baseUrl}/linux/repository-admin/status?channel=${outcome.candidate.channel}`, {
      headers,
      redirect: 'error'
    });
    attempt.httpStatus = response.status;
    if (!response.ok) throw new Error(`repository rollback drill status failed: HTTP ${response.status}`);
    const status = validateActivationStatus(
      await response.json(),
      outcome.candidate.channel,
      response.headers.get('etag')
    );
    attempt.ok = true;
    attempt.snapshotId = status.active?.snapshotId ?? null;
    return status;
  };
  const post = async (identity, expectedCurrentSnapshotId, mode, reason, phase) => {
    const current = await observeStatus(`${phase}-precondition`);
    if (current.active?.snapshotId !== expectedCurrentSnapshotId) {
      throw new Error(`repository rollback drill ${phase} precondition changed before mutation`);
    }
    const request = {
      schemaVersion: 1,
      mode,
      channel: outcome.candidate.channel,
      targetSnapshotId: identity.snapshotId,
      expectedCurrentSnapshotId,
      expectedCurrentGeneration: current.currentGeneration,
      expectedCurrentPointerEtag: current.currentPointerEtag,
      version: identity.version,
      sourceCommit: identity.sourceCommit,
      actor: options.actor,
      runUrl: options.runUrl ?? null,
      reason
    };
    const attempt = { operation: 'activate', phase, request, ok: false };
    outcome.attempts.push(attempt);
    const response = await fetchImpl(`${baseUrl}/linux/repository-admin/activate`, {
      method: 'POST',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
      redirect: 'error'
    });
    attempt.httpStatus = response.status;
    if (!response.ok) throw new Error(`repository rollback drill activation failed: HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    const result = validateActivationResponse(await response.json(), request, response.headers.get('etag'));
    attempt.ok = true;
    attempt.snapshotId = identity.snapshotId;
    return result;
  };
  const assertPublicSnapshot = async (snapshotId, phase) => {
    for (const publicPath of publicRoots(outcome.candidate.channel)) {
      const attempt = { operation: 'verify-public-root', phase, path: publicPath, ok: false };
      outcome.attempts.push(attempt);
      const response = await fetchImpl(`${baseUrl}${publicPath}`, { method: 'HEAD', redirect: 'error' });
      attempt.httpStatus = response.status;
      attempt.snapshotId = response.headers.get('x-openburnbar-repository-snapshot');
      if (!response.ok || attempt.snapshotId !== snapshotId) {
        throw new Error(`public repository did not resolve expected snapshot ${snapshotId}: ${publicPath}`);
      }
      attempt.ok = true;
    }
  };

  try {
    baseUrl = repositoryBaseUrl(options.baseUrl, options.allowLocalTestOrigin);
    if (typeof options.token !== 'string' || !/^[A-Za-z0-9._~+/=-]{32,4096}$/u.test(options.token)) {
      throw new Error('repository activation token must use the approved 32 to 4096 character alphabet');
    }
    headers = { Authorization: `Bearer ${options.token}`, Accept: 'application/json' };
    outcome.candidate = repositorySnapshotIdentity(options.closurePath);
    const receipt = JSON.parse(fs.readFileSync(options.activationReceiptPath, 'utf8'));
    if (receipt.result?.activation?.snapshotId !== outcome.candidate.snapshotId) {
      throw new Error('activation receipt does not bind the candidate repository snapshot');
    }
    outcome.previous = receipt.status?.active ?? null;
    if (outcome.previous && !validPrevious(outcome.previous, outcome.candidate.channel)) {
      throw new Error('activation receipt contains an invalid previous generation');
    }
    const initial = await observeStatus('initial');
    if (initial.active?.snapshotId !== outcome.candidate.snapshotId) {
      throw new Error('candidate repository snapshot is not active at rollback drill start');
    }
    candidateWasCurrent = true;
    if (!outcome.previous) {
      outcome.skipped = true;
    } else {
      await post(outcome.previous, outcome.candidate.snapshotId, 'rollback',
        `Rollback drill from ${outcome.candidate.snapshotId} to retained generation ${outcome.previous.snapshotId}`, 'rollback');
      try {
        await assertPublicSnapshot(outcome.previous.snapshotId, 'rollback');
      } catch (error) {
        fail(error);
      }
      await post(outcome.candidate, outcome.previous.snapshotId, 'promote',
        `Reactivate verified candidate ${outcome.candidate.snapshotId} after rollback drill`, 'reactivate');
      reactivationSucceeded = true;
      await assertPublicSnapshot(outcome.candidate.snapshotId, 'reactivate');
    }
  } catch (error) {
    fail(error);
  }

  if (candidateWasCurrent && !reactivationSucceeded && baseUrl && outcome.candidate && outcome.previous) {
    try {
      const recoveryStatus = await observeStatus('recovery-check');
      if (recoveryStatus.active?.snapshotId === outcome.previous.snapshotId) {
        await post(outcome.candidate, outcome.previous.snapshotId, 'promote',
          `Restore candidate ${outcome.candidate.snapshotId} after interrupted rollback drill`, 'restore-after-failure');
        reactivationSucceeded = true;
        await assertPublicSnapshot(outcome.candidate.snapshotId, 'restore-after-failure');
      }
    } catch (error) {
      fail(error);
    }
  }
  if (baseUrl && outcome.candidate) {
    try {
      outcome.finalObservedStatus = await observeStatus('final');
    } catch (error) {
      fail(error);
    }
  }
  outcome.candidateRestored = Boolean(outcome.candidate
    && outcome.finalObservedStatus?.active?.snapshotId === outcome.candidate.snapshotId);
  outcome.passed = outcome.candidateRestored && outcome.failures.length === 0;
  if (outcome.skipped && outcome.passed) outcome.reason = 'first channel activation has no rollback generation';
  return outcome;
}

async function main() {
  const releaseOut = process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release');
  const runUrl = process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
    ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : null;
  const result = await drillLinuxRepositoryRollback({
    closurePath: path.join(releaseOut, 'repositories/repository-closure.json'),
    activationReceiptPath: path.join(releaseOut, 'repository-activation.json'),
    baseUrl: process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? productionRepositoryOrigin,
    token: process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN,
    actor: process.env.GITHUB_ACTOR ?? process.env.USER ?? 'unknown',
    runUrl
  });
  const receipt = { ...result, verifiedAt: new Date().toISOString() };
  const outputPath = process.env.OPENBURNBAR_LINUX_REPOSITORY_ROLLBACK_RECEIPT;
  if (outputPath) writeAtomicJson(outputPath, receipt);
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  if (!result.passed) process.exitCode = 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
