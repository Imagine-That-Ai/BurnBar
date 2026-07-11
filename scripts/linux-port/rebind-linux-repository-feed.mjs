#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PRODUCTION_ORIGIN = 'https://downloads.burnbar.ai';
const CHANNELS = new Set(['stable', 'prerelease', 'nightly']);
const SHA256 = /^[a-f0-9]{64}$/u;
const ETAG = /^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u;
const ACTOR = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,96}|[A-Za-z0-9_-]{0,91}\[bot\])$/u;
const RUN_URL = /^https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/actions\/runs\/[1-9][0-9]*(?:\/attempts\/[1-9][0-9]*)?$/u;

function baseOrigin(value, allowLocalTestOrigin) {
  const url = new URL(value);
  if (url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('repository origin must be a bare origin');
  }
  if (url.origin === PRODUCTION_ORIGIN) return url.origin;
  if (allowLocalTestOrigin && ['127.0.0.1', 'localhost'].includes(url.hostname)) return url.origin;
  throw new Error(`repository origin must use ${PRODUCTION_ORIGIN}`);
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, file);
  } finally { fs.rmSync(temporary, { force: true }); }
}

function repositoryStatus(value, response, channel) {
  const record = value?.activation;
  if (value?.schemaVersion !== 1 || value.status !== 'active' || value.channel !== channel
      || !record || record.channel !== channel || !SHA256.test(record.snapshotId ?? '')
      || !Number.isSafeInteger(record.generation) || record.generation <= 0
      || !ETAG.test(value.pointerEtag ?? '') || response.headers.get('etag') !== value.pointerEtag) {
    throw new Error('active repository status is malformed');
  }
  return { record, etag: value.pointerEtag };
}

function feedStatus(value, response, channel) {
  const record = value?.feed;
  if (value?.schemaVersion !== 1 || value.status !== 'published' || !record || record.channel !== channel
      || !Number.isSafeInteger(record.generation) || record.generation <= 0
      || !ETAG.test(value.pointerEtag ?? '') || response.headers.get('etag') !== value.pointerEtag
      || typeof record.feed?.key !== 'string' || !SHA256.test(record.feed?.sha256 ?? '')) {
    throw new Error('published feed status is malformed');
  }
  return { record, etag: value.pointerEtag };
}

function bound(feed, repository) {
  return feed.record.repository?.generation === repository.record.generation
    && feed.record.repository?.snapshotId === repository.record.snapshotId
    && feed.record.repository?.pointerEtag === repository.etag;
}

function sameRepository(left, right) {
  return left.etag === right.etag
    && left.record.generation === right.record.generation
    && left.record.snapshotId === right.record.snapshotId
    && left.record.version === right.record.version
    && left.record.sourceCommit === right.record.sourceCommit;
}

function sameFeedIdentity(left, right) {
  return left.channel === right.channel && left.version === right.version
    && left.sourceCommit === right.sourceCommit && left.publishedAt === right.publishedAt
    && JSON.stringify(left.feed) === JSON.stringify(right.feed);
}

export async function rebindLinuxRepositoryFeed(options, fetchImpl = fetch) {
  if (!CHANNELS.has(options.channel)) throw new Error('feed rebind channel is invalid');
  if (typeof options.token !== 'string' || !/^[A-Za-z0-9._~+/=-]{32,4096}$/u.test(options.token)) {
    throw new Error('repository activation token is invalid');
  }
  if (!ACTOR.test(options.actor ?? '')) throw new Error('feed rebind actor is invalid');
  if (options.runUrl !== null && options.runUrl !== undefined && !RUN_URL.test(options.runUrl)) {
    throw new Error('feed rebind run URL is invalid');
  }
  if (typeof options.reason !== 'string' || !/^[\x20-\x7e]{8,500}$/u.test(options.reason)) {
    throw new Error('feed rebind reason must contain 8 to 500 printable ASCII characters');
  }
  if (options.target !== 'current') throw new Error('scheduled refresh may only rebind the current feed descriptor');
  const origin = baseOrigin(options.baseUrl ?? PRODUCTION_ORIGIN, options.allowLocalTestOrigin === true);
  const headers = { Authorization: `Bearer ${options.token}`, Accept: 'application/json' };
  const get = async (pathName) => {
    const response = await fetchImpl(`${origin}${pathName}`, { headers, redirect: 'error' });
    if (!response.ok) throw new Error(`feed rebind status failed: HTTP ${response.status}`);
    return { response, value: await response.json() };
  };
  const observe = async () => {
    const repositoryResponse = await get(`/linux/repository-admin/status?channel=${options.channel}`);
    const feedResponse = await get(`/linux/repository-admin/feed-status?channel=${options.channel}`);
    const repositoryAfterResponse = await get(`/linux/repository-admin/status?channel=${options.channel}`);
    const repository = repositoryStatus(repositoryResponse.value, repositoryResponse.response, options.channel);
    const repositoryAfter = repositoryStatus(
      repositoryAfterResponse.value,
      repositoryAfterResponse.response,
      options.channel
    );
    if (!sameRepository(repository, repositoryAfter)) {
      throw new Error('active repository changed during feed status observation');
    }
    return { repository: repositoryAfter, feed: feedStatus(feedResponse.value, feedResponse.response, options.channel) };
  };
  const before = await observe();
  if (before.feed.record.version !== before.repository.record.version
      || before.feed.record.sourceCommit !== before.repository.record.sourceCommit) {
    throw new Error('retained feed identity does not match the active repository release');
  }
  if (bound(before.feed, before.repository)) {
    return { schemaVersion: 1, passed: true, mutationAttempted: false, alreadyBound: true, before };
  }
  const request = {
    schemaVersion: 1,
    channel: options.channel,
    target: 'current',
    expectedCurrent: { generation: before.feed.record.generation, etag: before.feed.etag },
    expectedRepository: {
      generation: before.repository.record.generation,
      snapshotId: before.repository.record.snapshotId,
      pointerEtag: before.repository.etag
    },
    actor: options.actor,
    runUrl: options.runUrl ?? null,
    reason: options.reason
  };
  options.onAttempt?.({ request, before });
  let mutationError = null;
  try {
    const response = await fetchImpl(`${origin}/linux/repository-admin/rebind-feed`, {
      method: 'POST',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
      redirect: 'error'
    });
    if (!response.ok) mutationError = new Error(`feed rebind failed: HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
  } catch (error) {
    mutationError = error;
  }
  const after = await observe();
  if (!bound(after.feed, after.repository)
      || after.repository.record.snapshotId !== before.repository.record.snapshotId
      || after.feed.record.generation !== before.feed.record.generation + 1
      || !sameFeedIdentity(after.feed.record, before.feed.record)) {
    throw mutationError ?? new Error('feed rebind reconciliation did not prove the exact retained feed on the active repository');
  }
  return {
    schemaVersion: 1,
    passed: true,
    mutationAttempted: true,
    alreadyBound: false,
    reconciledAfterError: Boolean(mutationError),
    request,
    before,
    after
  };
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`unexpected argument: ${argument}`);
    const next = argv[++index];
    if (!next || next.startsWith('--')) throw new Error(`missing value for ${argument}`);
    values[argument.slice(2).replaceAll('-', '_')] = next;
  }
  return values;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const output = args.output ? path.resolve(args.output) : null;
  const base = { schemaVersion: 1, operation: 'rebind-linux-repository-feed', generatedAt: new Date().toISOString() };
  const result = await rebindLinuxRepositoryFeed({
    channel: args.channel,
    target: args.target ?? 'current',
    token: process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN,
    baseUrl: process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? PRODUCTION_ORIGIN,
    actor: args.actor ?? process.env.GITHUB_ACTOR ?? process.env.USER ?? 'unknown',
    runUrl: args.run_url ?? (process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
      ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : null),
    reason: args.reason ?? `Rebind retained signed feed after Linux repository metadata refresh`,
    onAttempt: output ? ({ request, before }) => atomicJson(output, {
      ...base, passed: false, phase: 'attempted', mutationAttempted: true, request, before
    }) : undefined
  });
  const receipt = { ...base, phase: 'complete', ...result };
  if (output) atomicJson(output, receipt);
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
