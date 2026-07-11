#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  activationRequest,
  repositorySnapshotIdentity,
  validateActivationResponse,
  validateActivationStatus
} from './lib/linux-repository-activation.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const productionRepositoryOrigin = 'https://downloads.burnbar.ai';

function repositoryBaseUrl(value, allowLocalTestOrigin) {
  if (value === productionRepositoryOrigin || value === `${productionRepositoryOrigin}/`) {
    return new URL(productionRepositoryOrigin);
  }
  const url = new URL(value);
  const isBareOrigin = url.username === '' && url.password === '' && url.pathname === '/'
    && url.search === '' && url.hash === '';
  if (!isBareOrigin) throw new Error('repository router URL must be a bare origin without credentials, path, query, or fragment');
  const isLocalTestOrigin = allowLocalTestOrigin === true
    && (url.hostname === '127.0.0.1' || url.hostname === 'localhost');
  if (!isLocalTestOrigin) throw new Error(`repository router URL must use ${productionRepositoryOrigin}`);
  return url;
}

export async function activateLinuxRepository(options, fetchImpl = fetch) {
  if (typeof options.token !== 'string' || !/^[A-Za-z0-9._~+/=-]{32,4096}$/u.test(options.token)) {
    throw new Error('repository activation token must use the approved 32 to 4096 character alphabet');
  }
  const identity = repositorySnapshotIdentity(options.closurePath);
  if (options.channel && options.channel !== identity.channel) throw new Error('requested channel does not match repository closure');
  const baseUrl = repositoryBaseUrl(options.baseUrl, options.allowLocalTestOrigin);
  const statusUrl = new URL('/linux/repository-admin/status', baseUrl);
  statusUrl.searchParams.set('channel', identity.channel);
  const headers = { Authorization: `Bearer ${options.token}`, Accept: 'application/json' };
  const statusResponse = await fetchImpl(statusUrl, { headers, redirect: 'error' });
  if (!statusResponse.ok && statusResponse.status !== 404) {
    throw new Error(`repository activation status failed: HTTP ${statusResponse.status}`);
  }
  const status = validateActivationStatus(
    await statusResponse.json(),
    identity.channel,
    statusResponse.headers.get('etag')
  );
  if (options.expectedCurrent !== undefined) {
    const expected = options.expectedCurrent === 'none' ? null : options.expectedCurrent;
    if ((status.active?.snapshotId ?? null) !== expected) throw new Error('active repository snapshot does not match --expected-current');
  }
  const request = activationRequest({
    identity,
    status,
    actor: options.actor,
    runUrl: options.runUrl,
    reason: options.reason
  });
  if (!options.confirm) return { dryRun: true, request, status };
  await options.onAttempt?.({ identity, request, status });
  const activationUrl = new URL('/linux/repository-admin/activate', baseUrl);
  const response = await fetchImpl(activationUrl, {
    method: 'POST',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify(request),
    redirect: 'error'
  });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`repository activation failed: HTTP ${response.status}: ${body.slice(0, 500)}`);
  }
  return {
    dryRun: false,
    request,
    status,
    result: validateActivationResponse(await response.json(), request, response.headers.get('etag'))
  };
}

function writeAtomicJson(outputPath, value) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const temporary = `${outputPath}.tmp-${process.pid}-${Date.now()}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
    fs.renameSync(temporary, outputPath);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--yes') { values.confirm = true; continue; }
    if (!argument.startsWith('--')) throw new Error(`unexpected argument: ${argument}`);
    const next = argv[++index];
    if (!next || next.startsWith('--')) throw new Error(`missing value for ${argument}`);
    values[argument.slice(2).replaceAll('-', '_')] = next;
  }
  return values;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const releaseOut = process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release');
  const token = process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN;
  if (!token || !/^[A-Za-z0-9._~+/=-]{32,4096}$/u.test(token)) {
    throw new Error('OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN must use the approved 32 to 4096 character alphabet');
  }
  const closurePath = args.closure ?? path.join(releaseOut, 'repositories/repository-closure.json');
  const identity = repositorySnapshotIdentity(closurePath);
  const outputPath = args.output ? path.resolve(args.output) : null;
  const receiptBase = { schemaVersion: 1, generatedAt: new Date().toISOString() };
  if (args.confirm === true && outputPath) {
    writeAtomicJson(outputPath, {
      ...receiptBase,
      dryRun: false,
      mutationAttempted: false,
      candidate: identity,
      phase: 'planned'
    });
  }
  const result = await activateLinuxRepository({
    closurePath,
    baseUrl: args.base_url ?? process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? 'https://downloads.burnbar.ai',
    channel: args.channel,
    expectedCurrent: args.expected_current,
    actor: args.actor ?? process.env.GITHUB_ACTOR ?? process.env.USER ?? 'unknown',
    runUrl: args.run_url ?? (process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
      ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : null),
    reason: args.reason ?? `Activate verified Linux repository snapshot from ${process.env.GITHUB_SHA ?? 'local operator'}`,
    confirm: args.confirm === true,
    token,
    onAttempt: outputPath ? ({ request, status }) => writeAtomicJson(outputPath, {
      ...receiptBase,
      dryRun: false,
      mutationAttempted: true,
      candidate: identity,
      phase: 'attempted',
      request,
      status
    }) : undefined
  });
  const receipt = { ...receiptBase, mutationAttempted: result.dryRun === false, candidate: identity, ...result };
  const output = `${JSON.stringify(receipt, null, 2)}\n`;
  if (outputPath) writeAtomicJson(outputPath, receipt);
  process.stdout.write(output);
  if (result.dryRun) process.stderr.write('dry run only; pass --yes to activate the repository snapshot\n');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
