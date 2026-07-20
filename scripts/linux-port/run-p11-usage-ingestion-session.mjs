#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const CLI = '/usr/bin/openburnbar-cli';
const MAX_RPC_BYTES = 4 * 1024 * 1024;
const APPLE_REFERENCE_SECONDS = 978_307_200;

function assert(condition, message) { if (!condition) throw new Error(message); }

function lstatNoSymlink(file, label, { allowMissingLeaf = false } = {}) {
  const absolute = path.resolve(file);
  let current = path.parse(absolute).root;
  const components = absolute.slice(current.length).split(path.sep).filter(Boolean);
  for (const [index, component] of components.entries()) {
    current = path.join(current, component);
    try {
      const stat = fs.lstatSync(current);
      assert(!stat.isSymbolicLink(), `${label} traverses a symlink`);
    } catch (error) {
      if (allowMissingLeaf && error.code === 'ENOENT' && index === components.length - 1) return null;
      throw error;
    }
  }
  return fs.lstatSync(absolute);
}

function ownerOnlyDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const absolute = fs.realpathSync(directory);
  const stat = lstatNoSymlink(absolute, 'P-11 raw output');
  assert(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    'P-11 raw output must be an owner-only directory');
  assert(fs.readdirSync(absolute).length === 0, 'P-11 raw output must be empty');
  return absolute;
}

function safeLedger(file) {
  const absolute = path.resolve(file);
  const stat = lstatNoSymlink(absolute, 'P-11 ledger', { allowMissingLeaf: true });
  if (stat === null) return Buffer.alloc(0);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    'P-11 ledger must be a current-user owner-only regular file');
  const bytes = fs.readFileSync(absolute);
  const rows = bytes.toString('utf8').split('\n').filter(Boolean);
  assert(rows.length === 0 || rows.every((line) => JSON.parse(line)?.idempotencyKey?.startsWith('p11-')),
    'P-11 refuses to capture a non-isolated user usage ledger');
  return bytes;
}

function writeExclusive(file, bytes) {
  const descriptor = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
}

function writeJson(file, value) { writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`, 'utf8')); }

function socketExchange({ socketPath }, payload) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection({ path: socketPath });
    let response = Buffer.alloc(0);
    const timer = setTimeout(() => client.destroy(new Error(`P-11 RPC timeout: ${method}`)), 15_000);
    client.on('connect', () => client.end(payload.endsWith('\n') ? payload : `${payload}\n`));
    client.on('data', (chunk) => {
      response = Buffer.concat([response, chunk]);
      if (response.length > MAX_RPC_BYTES) client.destroy(new Error('P-11 RPC response exceeded byte budget'));
    });
    client.on('error', (error) => { clearTimeout(timer); reject(error); });
    client.on('close', () => {
      clearTimeout(timer);
      if (response.length === 0) return reject(new Error('P-11 RPC returned no response'));
      try { resolve(JSON.parse(response.toString('utf8').trim())); } catch (error) { reject(new Error(`P-11 RPC returned invalid JSON: ${error.message}`)); }
    });
  });
}

function socketRPC(options, method, params) {
  return socketExchange(options, JSON.stringify({ id: crypto.randomUUID(), method, authToken: options.authToken, params }));
}

function socketRawRPC(options, rawRequest) { return socketExchange(options, rawRequest); }

function cliEnvironment(options) {
  return {
    ...process.env,
    OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile
  };
}

function runCLI(options, arguments_) {
  const child = spawnSync(CLI, arguments_, { encoding: 'utf8', timeout: 20_000, maxBuffer: 1024 * 1024, env: cliEnvironment(options) });
  assert(!child.error && child.status === 0, `installed CLI failed (${arguments_.join(' ')}): ${(child.stderr || child.error?.message || '').trim()}`);
  return child.stdout;
}

function parseCLI(output) {
  return Object.fromEntries(output.trim().split('\n').map((line) => line.split('=', 2)).filter(([key, value]) => key && value !== undefined));
}

function subscriptionResult(output) {
  const value = parseCLI(output);
  const seq = Number(value.seq);
  assert(value.subscription_id && value.topic === 'health' && Number.isSafeInteger(seq), 'installed CLI returned invalid subscription output');
  return {
    subscriptionID: value.subscription_id,
    topic: value.topic,
    seq,
    ...(value.disconnect_detected !== undefined ? { disconnectDetected: value.disconnect_detected === 'true' } : {}),
    ...(value.recovered_after_restart !== undefined ? { recoveredAfterRestart: value.recovered_after_restart === 'true' } : {})
  };
}

function defaultRestart(options) {
  const child = spawnSync('systemctl', ['--user', 'restart', 'openburnbar-daemon.service'], { encoding: 'utf8', timeout: 30_000, env: cliEnvironment(options) });
  assert(!child.error && child.status === 0, `installed daemon restart failed: ${(child.stderr || child.error?.message || '').trim()}`);
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const health = spawnSync(CLI, ['health'], { encoding: 'utf8', timeout: 5_000, env: cliEnvironment(options) });
    if (!health.error && health.status === 0) return;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
  }
  throw new Error('installed daemon did not become healthy after restart');
}

function malformedEvent(event, kind) {
  const value = { ...event };
  if (kind === 'blank-provider') value.providerID = '';
  if (kind === 'control-model') value.modelID = 'bad\nmodel';
  if (kind === 'oversized-session') value.sessionID = 'x'.repeat(257);
  if (kind === 'negative-token') value.inputTokens = -1;
  if (kind === 'negative-cost') value.cost = -0.01;
  if (kind === 'out-of-range-timestamp') value.recordedAt = -APPLE_REFERENCE_SECONDS;
  return value;
}

function rawMalformedRequest(options, key, event, kind) {
  const base = JSON.stringify({ id: crypto.randomUUID(), method: 'daemon.usage.record', authToken: options.authToken, params: { idempotencyKey: key, event } });
  if (kind === 'nonfinite-cost') return base.replace('"cost":0.01234', '"cost":1e309');
  if (kind === 'token-sum-overflow') return base.replace('"inputTokens":420', '"inputTokens":9223372036854775807').replace('"outputTokens":170', '"outputTokens":1');
  throw new Error(`P-11 unknown raw malformed kind: ${kind}`);
}

function sanitizeRequest(method, params) { return { method, params }; }

function assertRecordResponse(response, key, inserted, label) {
  assert(!response?.error && response?.result?.idempotencyKey === key && response.result.inserted === inserted,
    `${label} returned an invalid daemon result`);
}

function assertRecentResponse(response, event, label) {
  assert(!response?.error && Array.isArray(response?.result?.usage), `${label} returned an invalid daemon result`);
  const expected = JSON.stringify(event, Object.keys(event).sort());
  const matches = response.result.usage.filter((row) => JSON.stringify(row, Object.keys(row).sort()) === expected);
  assert(matches.length === 1, `${label} did not return exactly one canonical usage event`);
}

export async function runP11UsageIngestionSession(options, dependencies = {}) {
  const verifyInstalled = dependencies.installedVerifier ?? verifyInstalledCandidate;
  const rpc = dependencies.rpcClient ?? ((method, params) => socketRPC(options, method, params));
  const rawRpc = dependencies.rawRpcClient ?? ((payload) => socketRawRPC(options, payload));
  const ledger = dependencies.readLedger ?? (() => safeLedger(options.ledgerPath));
  const cli = dependencies.cliRunner ?? ((args) => runCLI(options, args));
  const restart = dependencies.restartDaemon ?? (() => defaultRestart(options));
  verifyInstalled(options);
  const output = ownerOnlyDirectory(options.rawOutputDir);
  const tokenStat = lstatNoSymlink(options.tokenFile, 'P-11 daemon token file');
  assert(tokenStat.isFile() && !tokenStat.isSymbolicLink() && tokenStat.uid === process.getuid?.() && (tokenStat.mode & 0o077) === 0,
    'P-11 daemon token file must be owner-only');
  const token = fs.readFileSync(options.tokenFile, 'utf8').trim();
  assert(token.length >= 32, 'P-11 daemon token is invalid');
  if (!dependencies.rpcClient) {
    const socketStat = lstatNoSymlink(options.socketPath, 'P-11 daemon socket');
    assert(socketStat.isSocket() && socketStat.uid === process.getuid?.(), 'P-11 daemon socket must be a current-user Unix socket');
    options.authToken = token;
  }
  const before = ledger();
  assert(before.length === 0, 'P-11 requires a fresh isolated ledger');
  writeExclusive(path.join(output, 'ledger-before.jsonl'), before);

  const idempotencyKey = `p11-${crypto.randomBytes(16).toString('hex')}`;
  const event = {
    providerID: 'hermes', modelID: 'minimax-m2.7-highspeed', inputTokens: 420, outputTokens: 170,
    cacheCreationTokens: 12, cacheReadTokens: 34, reasoningTokens: 56, cost: 0.01234,
    recordedAt: Date.now() / 1_000 - APPLE_REFERENCE_SECONDS,
    sessionID: `p11-session-${crypto.randomUUID()}`, projectName: 'P11 installed usage proof', confidence: 'exact'
  };
  const rpcRows = [];
  const call = async (phase, method, params) => {
    const response = await rpc(method, params);
    rpcRows.push({ at: new Date().toISOString(), phase, request: sanitizeRequest(method, params), response });
    return response;
  };
  const params = { idempotencyKey, event };
  const first = await call('record-first', 'daemon.usage.record', params);
  assertRecordResponse(first, idempotencyKey, true, 'P-11 first usage record');
  writeExclusive(path.join(output, 'ledger-after-insert.jsonl'), ledger());
  const duplicate = await call('record-duplicate', 'daemon.usage.record', params);
  assertRecordResponse(duplicate, idempotencyKey, false, 'P-11 duplicate usage record');
  writeExclusive(path.join(output, 'ledger-after-duplicate.jsonl'), ledger());
  assertRecentResponse(await call('recent-before-restart', 'daemon.usage.recent', { limit: 500 }), event, 'P-11 pre-restart refresh');

  const subscriptionRows = [];
  const started = subscriptionResult(cli(['subscribe', 'health']));
  subscriptionRows.push({ at: new Date().toISOString(), phase: 'start', result: started });
  const resumed = subscriptionResult(cli(['subscription-resume', started.subscriptionID, '--topic', 'health', '--after-seq', String(started.seq)]));
  subscriptionRows.push({ at: new Date().toISOString(), phase: 'resume-before-restart', result: resumed });

  const malformedRows = [];
  for (const kind of ['blank-provider', 'control-model', 'oversized-session', 'token-sum-overflow', 'nonfinite-cost', 'negative-token', 'negative-cost', 'out-of-range-timestamp']) {
    const rejectedKey = `${idempotencyKey}-${kind}`;
    const malformedParams = { idempotencyKey: rejectedKey, event: malformedEvent(event, kind) };
    const ledgerBefore = ledger();
    const isRaw = ['token-sum-overflow', 'nonfinite-cost'].includes(kind);
    const rawRequest = isRaw ? rawMalformedRequest(options, rejectedKey, event, kind) : null;
    const evidenceRawRequest = isRaw ? rawMalformedRequest({ ...options, authToken: undefined }, rejectedKey, event, kind) : null;
    const response = isRaw ? await rawRpc(rawRequest) : await rpc('daemon.usage.record', malformedParams);
    const ledgerAfterRejection = ledger();
    assert(response?.error?.code === -32602 && response.result === undefined, `P-11 ${kind} was not rejected with invalid params`);
    assert(ledgerBefore.equals(ledgerAfterRejection), `P-11 ${kind} rejection mutated the ledger`);
    const recoveryParams = { idempotencyKey: rejectedKey, event: { ...event, sessionID: `p11-session-recovery-${kind}` } };
    const recoveryResponse = await rpc('daemon.usage.record', recoveryParams);
    assertRecordResponse(recoveryResponse, rejectedKey, true, `P-11 ${kind} rejected-key recovery`);
    const recovery = { at: new Date().toISOString(), request: sanitizeRequest('daemon.usage.record', recoveryParams), response: recoveryResponse };
    malformedRows.push({
      at: new Date().toISOString(), case: kind,
      request: isRaw ? { encoding: 'utf8', rawBase64: Buffer.from(evidenceRawRequest, 'utf8').toString('base64') } : sanitizeRequest('daemon.usage.record', malformedParams),
      response, recovery,
      ledger: {
        beforeBase64: ledgerBefore.toString('base64'), afterRejectionBase64: ledgerAfterRejection.toString('base64'),
        afterRecoveryBase64: ledger().toString('base64')
      }
    });
  }

  restart();
  assertRecentResponse(await call('recent-after-restart', 'daemon.usage.recent', { limit: 500 }), event, 'P-11 post-restart refresh');
  writeExclusive(path.join(output, 'ledger-after-restart.jsonl'), ledger());
  const after = subscriptionResult(cli(['subscription-resume', started.subscriptionID, '--topic', 'health', '--after-seq', String(resumed.seq)]));
  assert(after.seq > resumed.seq && after.disconnectDetected === true && after.recoveredAfterRestart === true,
    'P-11 installed CLI subscription did not recover after restart');
  subscriptionRows.push({ at: new Date().toISOString(), phase: 'resume-after-restart', result: after });
  writeJson(path.join(output, 'usage-rpc-transcript.json'), { producer: 'openburnbar-p11-installed-rpc-runner-v1', transport: 'AF_UNIX newline-framed BurnBarRPC', rows: rpcRows });
  writeJson(path.join(output, 'usage-malformed-transcript.json'), { producer: 'openburnbar-p11-installed-rpc-runner-v1', transport: 'AF_UNIX newline-framed BurnBarRPC', rows: malformedRows });
  writeJson(path.join(output, 'usage-subscription-transcript.json'), { producer: 'openburnbar-p11-installed-cli-runner-v1', transport: 'AF_UNIX newline-framed BurnBarRPC', rows: subscriptionRows });
  return { output, idempotencyKey, event };
}

function args(argv) {
  const flags = ['--raw-output-dir', '--ledger-path', '--socket-path', '--token-file', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    rawOutputDir: values.get('--raw-output-dir'), ledgerPath: values.get('--ledger-path'), socketPath: values.get('--socket-path'), tokenFile: values.get('--token-file'),
    environmentId: values.get('--environment'), targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'), packageVersion: values.get('--package-version'),
    manifestSha256: values.get('--manifest-sha256'), manifestSignatureSha256: values.get('--manifest-signature-sha256')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(await runP11UsageIngestionSession(args(process.argv.slice(2))), null, 2)}\n`); }
  catch (error) { process.stderr.write(`P-11 live usage runner failed: ${error.message}\n`); process.exitCode = 1; }
}
