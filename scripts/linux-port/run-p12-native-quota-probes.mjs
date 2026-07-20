#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DESKTOP = '/usr/bin/openburnbar-linux-desktop';
const AT_SPI = path.join(ROOT, 'scripts/linux-port/capture-atspi-tree.py');
const FOUNDATION_REFERENCE_EPOCH_MS = Date.UTC(2001, 0, 1);
const MAX_RPC_BYTES = 4 * 1024 * 1024;
const PROVIDER_ID = 'openai';
const MODEL_ID = 'gpt-4o-mini';
const MODES = new Set(['provider_family_failover', 'same_model_failover']);

function assert(value, message) { if (!value) throw new Error(message); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function writeExclusive(file, bytes) {
  const descriptor = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
}
function writeJson(file, value) { writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`)); }
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }

function ownerOnlyEmptyDirectory(directory, label) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const resolved = fs.realpathSync(directory);
  const stat = fs.lstatSync(resolved);
  assert(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    `${label} must be an owner-only directory`);
  assert(fs.readdirSync(resolved).length === 0, `${label} must be empty`);
  return resolved;
}

function ownerOnlyToken(file, label) {
  const stat = fs.lstatSync(file);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    `${label} must be an owner-only regular file`);
  const token = fs.readFileSync(file, 'utf8').trim();
  assert(token.length >= 8 && !/[\r\n]/u.test(token), `${label} is invalid`);
  return token;
}

function socketExchange(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection({ path: socketPath });
    let response = Buffer.alloc(0);
    const timer = setTimeout(() => client.destroy(new Error('P-12 RPC timeout')), 15_000);
    client.on('connect', () => client.end(`${payload}\n`));
    client.on('data', (chunk) => {
      response = Buffer.concat([response, chunk]);
      if (response.length > MAX_RPC_BYTES) client.destroy(new Error('P-12 RPC response exceeded byte budget'));
    });
    client.on('error', (error) => { clearTimeout(timer); reject(error); });
    client.on('close', () => {
      clearTimeout(timer);
      try { resolve(JSON.parse(response.toString('utf8').trim())); }
      catch (error) { reject(new Error(`P-12 RPC returned invalid JSON: ${error.message}`)); }
    });
  });
}

function defaultRpcClient(options) {
  const token = ownerOnlyToken(options.tokenFile, 'P-12 daemon token file');
  const socket = fs.lstatSync(options.socketPath);
  assert(socket.isSocket() && socket.uid === process.getuid?.(), 'P-12 daemon socket must be a current-user Unix socket');
  return (method, params = undefined) => socketExchange(options.socketPath, JSON.stringify({
    id: crypto.randomUUID(), method, authToken: token, ...(params === undefined ? {} : { params })
  }));
}

function commandRunner() {
  return {
    run(command, args = [], options = {}) {
      const result = spawnSync(command, args, { encoding: 'utf8', ...options });
      if (result.error) throw result.error;
      return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
    },
    start(command, args = [], options = {}) {
      const child = spawn(command, args, { stdio: ['ignore', 'ignore', 'ignore'], ...options });
      child.unref();
      return { pid: child.pid, kill: (signal = 'SIGTERM') => child.kill(signal) };
    }
  };
}

function requiredRun(runner, command, args, label, options = {}) {
  const result = runner.run(command, args, options);
  assert(result.status === 0, `${label} failed (${result.status}): ${result.stderr || result.stdout}`.trim());
  return result.stdout.trim();
}

async function waitForWindow(runner, pid) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const found = runner.run('xdotool', ['search', '--onlyvisible', '--pid', String(pid), '--name', '^OpenBurnBar']);
    const ids = found.status === 0 ? found.stdout.trim().split(/\s+/u).filter(Boolean) : [];
    if (ids.length === 1) return ids[0];
    await sleep(250);
  }
  throw new Error(`P-12 installed app window did not appear for PID ${pid}`);
}

async function waitForExit(runner, pid) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (runner.run('kill', ['-0', String(pid)]).status !== 0) return;
    await sleep(200);
  }
  throw new Error(`P-12 installed app PID ${pid} did not exit`);
}

function defaultUi(runner, output, options) {
  const activate = (name, role = null) => {
    const temporary = path.join(output, '.atspi-activation.json');
    const args = [AT_SPI, '--application', 'OpenBurnBar', '--mode', 'activate', '--expected-name', name, '--output', temporary];
    if (role) args.push('--within-role', role);
    requiredRun(runner, 'python3', args, `AT-SPI activate ${name}`);
    fs.rmSync(temporary, { force: true });
  };
  return {
    async launch() {
      const process = runner.start(DESKTOP, [], { env: { ...process.env, OPENBURNBAR_EVIDENCE_OUT: output } });
      assert(Number.isSafeInteger(process.pid) && process.pid > 1, 'P-12 installed app launch returned no PID');
      return { process, pid: process.pid, windowId: await waitForWindow(runner, process.pid) };
    },
    async route() {
      activate('Open command palette');
      activate('Providers & models', 'dialog');
      await sleep(500);
    },
    async refresh(stale) {
      activate(stale ? 'Retry quota catalog' : 'Refresh all');
      await sleep(900);
    },
    capture(state, app, at) {
      const expectedNames = state === 'live'
        ? ['Subscription vault', 'OpenAI', 'Request rate limit', 'Failover policy']
        : ['last available quota snapshot', 'Retry quota catalog'];
      const raw = path.join(output, `.quota-${state}-raw-atspi.json`);
      requiredRun(runner, 'python3', [AT_SPI, '--application', 'OpenBurnBar', '--mode', 'summary', '--route', 'providers',
        '--expected-name', expectedNames[0], '--output', raw], `P-12 ${state} AT-SPI capture`);
      const tree = readJson(raw);
      fs.rmSync(raw, { force: true });
      const names = (tree.namedSamples ?? []).map((row) => String(row.name ?? '')).join('\n');
      assert(tree.pass === true && expectedNames.every((name) => names.includes(name)), `P-12 ${state} quota semantics are missing`);
      const screenshot = path.join(output, state === 'live' ? 'quota-live.png' : 'quota-stale.png');
      requiredRun(runner, 'xdotool', ['windowactivate', '--sync', app.windowId], 'P-12 focus quota window');
      requiredRun(runner, 'scrot', ['--overwrite', '--focused', screenshot], 'P-12 quota screenshot');
      assert(fs.statSync(screenshot).size > 1024, `P-12 ${state} screenshot is empty`);
      return { producer: 'openburnbar-p12-native-quota-probe-v1', capturedAt: at, appPid: app.pid,
        windowId: String(app.windowId), manifestSha256: options.manifestSha256,
        state: state === 'live' ? 'live' : 'stale-retained', expectedNames, namedSamples: tree.namedSamples };
    },
    async stop(app) { app.process.kill(); await waitForExit(runner, app.pid); }
  };
}

function installedDesktopProcessIDs(runner) {
  const result = runner.run('pgrep', ['-f', '^/usr/bin/openburnbar-linux-desktop(?:\\s|$)']);
  if (result.status === 1) return [];
  assert(result.status === 0, `P-12 desktop process preflight failed: ${result.stderr || result.stdout}`.trim());
  return result.stdout.trim().split(/\s+/u).filter(Boolean).map(Number).filter(Number.isSafeInteger);
}

function quotaHeaders(phase, now) {
  const initial = phase === 'initial';
  return {
    'x-ratelimit-limit-requests': '100', 'x-ratelimit-remaining-requests': initial ? '73' : '65',
    'x-ratelimit-reset-requests': new Date(now + 60 * 60 * 1000).toISOString(),
    'x-ratelimit-limit-tokens': '1000', 'x-ratelimit-remaining-tokens': initial ? '580' : '500',
    'x-ratelimit-reset-tokens': new Date(now + 7 * 24 * 60 * 60 * 1000).toISOString()
  };
}

async function createDefaultGatewayHarness(options, rpc, now) {
  let phase = 'initial';
  const requests = [];
  const server = http.createServer((request, response) => {
    const headers = quotaHeaders(phase, now());
    requests.push({ phase, method: request.method, url: request.url, headers });
    request.resume();
    response.writeHead(200, { 'content-type': 'application/json', ...headers });
    response.end(JSON.stringify({ id: `p12-${phase}`, object: 'chat.completion', model: MODEL_ID,
      choices: [{ index: 0, message: { role: 'assistant', content: `P12 ${phase}` }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 2, completion_tokens: 2, total_tokens: 4 } }));
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert(address && typeof address === 'object', 'P-12 mock upstream did not bind');
  const originalResponse = await rpc('daemon.config.get');
  assert(!originalResponse?.error && originalResponse?.result?.snapshot, 'P-12 could not read daemon configuration');
  const original = structuredClone(originalResponse.result.snapshot);
  const configured = structuredClone(original);
  const provider = configured.providers?.find((row) => row.providerID === PROVIDER_ID);
  assert(provider, 'P-12 canonical OpenAI provider configuration is missing');
  for (const row of configured.providers) row.isEnabled = row.providerID === PROVIDER_ID;
  provider.baseURL = `http://127.0.0.1:${address.port}/v1`;
  provider.preferredModelIDs = [MODEL_ID];
  let response = await rpc('daemon.config.update', { snapshot: configured });
  assert(!response?.error, 'P-12 could not route the installed provider to the bounded upstream');
  response = await rpc('daemon.provider.credential_slot.upsert', {
    providerID: PROVIDER_ID, slotID: 'p12-local-upstream', label: 'P12 local upstream', apiKey: 'p12-local-proof-key', isEnabled: true
  });
  assert(!response?.error && response?.result?.slot?.slotID, 'P-12 could not create its isolated provider route');
  const slotId = response.result.slot.slotID;
  const withSlot = structuredClone(response.result.snapshot);
  const withSlotProvider = withSlot.providers.find((row) => row.providerID === PROVIDER_ID);
  withSlotProvider.preferredCredentialSlotID = slotId;
  response = await rpc('daemon.config.update', { snapshot: withSlot });
  assert(!response?.error, 'P-12 could not select its isolated provider route');
  const gatewayToken = ownerOnlyToken(options.gatewayTokenFile, 'P-12 gateway token file');
  return {
    async exercise(nextPhase) {
      phase = nextPhase;
      const health = await rpc('daemon.health');
      const result = health?.result;
      assert(!health?.error && result?.gatewayEnabled === true && result.gatewayHost === '127.0.0.1'
        && Number.isSafeInteger(result.gatewayPort), 'P-12 installed loopback gateway is unavailable');
      const before = requests.length;
      const gatewayResponse = await fetch(`http://127.0.0.1:${result.gatewayPort}/v1/chat/completions`, {
        method: 'POST', headers: { authorization: `Bearer ${gatewayToken}`, 'content-type': 'application/json' },
        body: JSON.stringify({ model: MODEL_ID, stream: false, messages: [{ role: 'user', content: `P12 ${nextPhase}` }] })
      });
      await gatewayResponse.text();
      assert(gatewayResponse.status === 200 && requests.length === before + 1, `P-12 ${nextPhase} gateway request failed`);
      const upstream = requests.at(-1);
      return { responseStatus: gatewayResponse.status, requestCount: 1, quotaHeaders: upstream.headers };
    },
    async close() {
      try { await rpc('daemon.provider.credential_slot.remove', { providerID: PROVIDER_ID, slotID: slotId }); } catch { /* restore below is authoritative */ }
      try { await rpc('daemon.config.update', { snapshot: original }); } finally { await new Promise((resolve) => server.close(resolve)); }
    }
  };
}

function defaultDaemonController(runner, rpc) {
  const service = (verb) => requiredRun(runner, 'systemctl', ['--user', verb, 'openburnbar-daemon.service'], `P-12 daemon ${verb}`);
  const start = async () => {
    service('start');
    for (let attempt = 0; attempt < 30; attempt += 1) {
      try { const response = await rpc('daemon.health'); if (!response?.error && response?.result?.ok === true) return; } catch { /* retry */ }
      await sleep(250);
    }
    throw new Error('P-12 daemon did not recover after service restart');
  };
  return {
    stop: () => service('stop'),
    start,
    async restart() { service('stop'); await start(); }
  };
}

function providerID(raw) {
  if (typeof raw?.providerID === 'string') return raw.providerID;
  if (typeof raw?.providerID?.rawValue === 'string') return raw.providerID.rawValue;
  return raw?.provider;
}

function quotaDate(value, now) {
  assert(typeof value === 'number' && Number.isFinite(value), 'P-12 raw daemon quota date is not Foundation seconds');
  const milliseconds = FOUNDATION_REFERENCE_EPOCH_MS + value * 1000;
  assert(milliseconds >= Date.UTC(2000, 0, 1) && milliseconds <= now + 10 * 366 * 24 * 60 * 60 * 1000,
    'P-12 raw daemon quota date is out of bounds');
  return new Date(milliseconds).toISOString();
}

function normalizeSnapshot(raw, canonical, now) {
  const id = providerID(raw);
  const identity = canonical.get(id);
  assert(identity && /^daemon\.quota\.signals:[^\s:]+$/u.test(raw?.sourceId ?? ''), 'P-12 raw quota identity is invalid');
  assert(raw.confidence !== 'stale', 'P-12 live quota snapshot is stale');
  quotaDate(raw.fetchedAt, now);
  quotaDate(raw.updatedAt, now);
  const buckets = (raw.buckets ?? []).map((bucket) => {
    const usedPct = typeof bucket.usedPercent === 'number' ? bucket.usedPercent
      : typeof bucket.usedValue === 'number' && typeof bucket.limitValue === 'number' && bucket.limitValue > 0
        ? bucket.usedValue / bucket.limitValue * 100 : Number.NaN;
    assert(Number.isFinite(usedPct) && usedPct >= 0 && usedPct <= 100, 'P-12 quota bucket percentage is invalid');
    const idValue = bucket.key ?? bucket.id;
    assert(typeof idValue === 'string' && idValue && typeof bucket.label === 'string' && bucket.label, 'P-12 quota bucket identity is invalid');
    return { id: idValue, label: bucket.label, usedPct, resetsAt: quotaDate(bucket.resetsAt, now), state: usedPct >= 100 ? 'exhausted' : 'ok' };
  });
  assert(buckets.length >= 2, 'P-12 requires request and token quota buckets from the gateway');
  return { providerId: id, sourceId: raw.sourceId, aliases: identity.aliases, sourceKind: raw.sourceKind,
    confidence: raw.confidence, buckets };
}

function selectQuota(response, canonical, now) {
  assert(!response?.error && Array.isArray(response?.result?.signals) && Array.isArray(response?.result?.snapshots),
    'P-12 daemon quota RPC returned no snapshots');
  const raw = response.result.snapshots.find((snapshot) => providerID(snapshot) === PROVIDER_ID);
  assert(raw, 'P-12 daemon quota RPC did not return the routed provider');
  const provider = normalizeSnapshot(raw, canonical, now);
  const signalId = provider.sourceId.slice('daemon.quota.signals:'.length);
  assert(response.result.signals.some((signal) => signal.id === signalId && signal.providerID === PROVIDER_ID),
    'P-12 provider snapshot is not bound to a persisted gateway signal');
  return { provider, signalId };
}

function modeSnapshot(response, label) {
  const snapshot = response?.result?.snapshot;
  assert(!response?.error && snapshot && MODES.has(snapshot.routerMode), `P-12 ${label} returned no valid router mode`);
  return snapshot;
}

function stampFactory(now) {
  let previous = 0;
  return () => {
    const milliseconds = Math.max(now(), previous + 1);
    previous = milliseconds;
    return new Date(milliseconds).toISOString();
  };
}

export async function runP12NativeQuotaProbes(options, dependencies = {}) {
  assert((dependencies.platform ?? process.platform) === 'linux', 'P-12 native quota probe must execute on Linux');
  assert(dependencies.desktopSession ?? (process.env.DBUS_SESSION_BUS_ADDRESS && (process.env.DISPLAY || process.env.WAYLAND_DISPLAY)),
    'P-12 requires a live Linux desktop session and D-Bus');
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const output = ownerOnlyEmptyDirectory(options.outputDir, 'P-12 raw output');
  const support = fs.realpathSync(options.supportDir);
  const supportStat = fs.lstatSync(support);
  assert(supportStat.isDirectory() && !supportStat.isSymbolicLink() && supportStat.uid === process.getuid?.(), 'P-12 support directory is invalid');
  assert(!fs.existsSync(path.join(support, 'quota-signals.jsonl')), 'P-12 requires an isolated support directory with no pre-seeded quota signals');
  const canonicalManifest = readJson(path.join(options.repoRoot ?? ROOT, 'contracts/provider-ingestion-catalog.json'));
  const canonical = new Map(canonicalManifest.providers.map((row) => [row.providerId, row]));
  const runner = dependencies.runner ?? commandRunner();
  const desktopPids = (dependencies.desktopProcessPids ?? (() => installedDesktopProcessIDs(runner)))();
  assert(Array.isArray(desktopPids) && desktopPids.length === 0, 'P-12 requires no pre-existing installed desktop process');
  if (!dependencies.ui) for (const tool of ['python3', 'xdotool', 'scrot']) {
    requiredRun(runner, 'sh', ['-c', 'command -v "$1" >/dev/null', 'p12-tool', tool], `required tool ${tool}`);
  }
  const rpc = dependencies.rpcClient ?? defaultRpcClient(options);
  const now = dependencies.now ?? Date.now;
  const stamp = stampFactory(now);
  const ui = dependencies.ui ?? defaultUi(runner, output, options);
  const daemon = dependencies.daemonController ?? defaultDaemonController(runner, rpc);
  const gateway = dependencies.gatewayHarness ?? await createDefaultGatewayHarness(options, rpc, now);
  const rpcRows = [];
  const gatewayRows = [];
  let app;
  let daemonStopped = false;
  const events = [];
  const callQuota = async (phase) => {
    const response = await rpc('daemon.quota.signals.recent', { limit: 200 });
    const at = stamp();
    rpcRows.push({ at, phase, request: { method: 'daemon.quota.signals.recent', params: { limit: 200 } }, response });
    return { at, response, selected: selectQuota(response, canonical, now()) };
  };
  try {
    const initialGateway = await gateway.exercise('initial');
    const initial = await callQuota('initial');
    gatewayRows.push({ at: initial.at, phase: 'initial', signalId: initial.selected.signalId,
      request: { method: 'POST', path: '/v1/chat/completions', model: MODEL_ID, providerId: PROVIDER_ID }, response: { status: initialGateway.responseStatus },
      upstream: { status: 200, requestCount: initialGateway.requestCount, quotaHeaders: initialGateway.quotaHeaders } });
    app = await ui.launch();
    await ui.route();
    writeJson(path.join(output, 'quota-live-atspi.json'), ui.capture('live', app, stamp()));

    daemon.stop();
    daemonStopped = true;
    await ui.refresh(false);
    const failedAt = stamp();
    const staleAt = stamp();
    writeJson(path.join(output, 'quota-stale-atspi.json'), ui.capture('stale', app, staleAt));
    await daemon.start();
    daemonStopped = false;

    const retryGateway = await gateway.exercise('retry');
    const retry = await callQuota('retry');
    assert(JSON.stringify(initialGateway.quotaHeaders) !== JSON.stringify(retryGateway.quotaHeaders), 'P-12 retry upstream headers did not change');
    gatewayRows.push({ at: retry.at, phase: 'retry', signalId: retry.selected.signalId,
      request: { method: 'POST', path: '/v1/chat/completions', model: MODEL_ID, providerId: PROVIDER_ID }, response: { status: retryGateway.responseStatus },
      upstream: { status: 200, requestCount: retryGateway.requestCount, quotaHeaders: retryGateway.quotaHeaders } });
    await ui.refresh(true);

    const before = modeSnapshot(await rpc('daemon.config.get'), 'mode read-before');
    const beforeAt = stamp();
    const alternate = before.routerMode === 'provider_family_failover' ? 'same_model_failover' : 'provider_family_failover';
    const updated = modeSnapshot(await rpc('daemon.config.update', { snapshot: { ...before, routerMode: alternate } }), 'mode update');
    const updatedAt = stamp();
    assert(updated.routerMode === alternate, 'P-12 mode update did not apply');
    const readback = modeSnapshot(await rpc('daemon.config.get'), 'mode readback');
    const readbackAt = stamp();
    assert(readback.routerMode === alternate, 'P-12 mode readback did not match');
    const rolledBack = modeSnapshot(await rpc('daemon.config.update', { snapshot: before }), 'mode rollback');
    const rolledBackAt = stamp();
    assert(rolledBack.routerMode === before.routerMode, 'P-12 mode rollback did not apply');
    const rollbackReadback = modeSnapshot(await rpc('daemon.config.get'), 'mode rollback readback');
    const rollbackReadbackAt = stamp();
    assert(rollbackReadback.routerMode === before.routerMode, 'P-12 mode rollback readback did not match');

    await daemon.restart();

    const oldApp = app;
    await ui.stop(oldApp);
    app = await ui.launch();
    assert(app.pid !== oldApp.pid, 'P-12 installed app restart reused the old PID');
    await ui.route();
    const restartedAt = stamp();
    const restart = await callQuota('restart');
    assert(JSON.stringify(retry.selected.provider) === JSON.stringify(restart.selected.provider), 'P-12 retry quota did not persist across restart');

    writeJson(path.join(output, 'quota-rpc-transcript.json'), { producer: 'openburnbar-p12-native-quota-probe-v1', transport: 'AF_UNIX newline-framed BurnBarRPC', rows: rpcRows });
    writeJson(path.join(output, 'quota-gateway-transcript.json'), { producer: 'openburnbar-p12-native-quota-probe-v1', transport: 'HTTP/1.1 loopback OpenBurnBar gateway', rows: gatewayRows });
    const rpcSha = sha256(fs.readFileSync(path.join(output, 'quota-rpc-transcript.json')));
    const makeCatalog = (capturedAt, provenance, providers, sourceSha256, routerMode) => ({
      producer: 'openburnbar-p12-daemon-rpc-probe-v1', capturedAt, provenance, providers, routerMode, sourceSha256
    });
    writeJson(path.join(output, 'quota-catalog-initial.json'), makeCatalog(initial.at, 'live-daemon', [initial.selected.provider], rpcSha, before.routerMode));
    const initialSha = sha256(fs.readFileSync(path.join(output, 'quota-catalog-initial.json')));
    writeJson(path.join(output, 'quota-catalog-stale.json'), makeCatalog(staleAt, 'retained-after-refresh-failure', [initial.selected.provider], initialSha, before.routerMode));
    writeJson(path.join(output, 'quota-catalog-retry.json'), makeCatalog(retry.at, 'live-daemon', [retry.selected.provider], rpcSha, before.routerMode));
    writeJson(path.join(output, 'quota-catalog-restart.json'), makeCatalog(restart.at, 'live-daemon', [restart.selected.provider], rpcSha, before.routerMode));
    const hashes = Object.fromEntries(['initial', 'stale', 'retry', 'restart'].map((name) => [name,
      sha256(fs.readFileSync(path.join(output, `quota-catalog-${name}.json`)))]));
    const event = (kind, at, process, mode, catalogSha256) => ({ kind, at, appPid: process.pid, windowId: String(process.windowId),
      manifestSha256: options.manifestSha256, mode, catalogSha256 });
    events.push(
      event('catalog-loaded', initial.at, oldApp, before.routerMode, hashes.initial),
      event('refresh-failed', failedAt, oldApp, before.routerMode, hashes.stale),
      event('stale-catalog-retained', staleAt, oldApp, before.routerMode, hashes.stale),
      event('retry-succeeded', retry.at, oldApp, before.routerMode, hashes.retry),
      event('mode-read-before', beforeAt, oldApp, before.routerMode, hashes.retry),
      event('mode-updated', updatedAt, oldApp, alternate, hashes.retry),
      event('mode-readback', readbackAt, oldApp, alternate, hashes.retry),
      event('mode-rolled-back', rolledBackAt, oldApp, before.routerMode, hashes.retry),
      event('mode-rollback-readback', rollbackReadbackAt, oldApp, before.routerMode, hashes.retry),
      event('app-restarted', restartedAt, app, before.routerMode, hashes.retry),
      event('catalog-persisted-readback', restart.at, app, before.routerMode, hashes.restart)
    );
    writeJson(path.join(output, 'quota-interactions.json'), { producer: 'openburnbar-p12-native-quota-probe-v1', events });
    return { output, initialPid: oldApp.pid, restartedPid: app.pid, providerId: PROVIDER_ID, bucketCount: initial.selected.provider.buckets.length };
  } finally {
    try { if (app) await ui.stop(app); } catch { /* process already stopped */ }
    if (daemonStopped) {
      try { await daemon.start(); } catch { /* preserve the original failure */ }
    }
    await gateway.close();
  }
}

export function parseP12Arguments(argv) {
  const flags = ['--output-dir', '--support-dir', '--socket-path', '--token-file', '--gateway-token-file', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256', '--compositor'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    outputDir: values.get('--output-dir'), supportDir: values.get('--support-dir'), socketPath: values.get('--socket-path'),
    tokenFile: values.get('--token-file'), gatewayTokenFile: values.get('--gateway-token-file'), environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(await runP12NativeQuotaProbes(parseP12Arguments(process.argv.slice(2))), null, 2)}\n`); }
  catch (error) { process.stderr.write(`P-12 native quota probe failed: ${error.message}\n`); process.exitCode = 1; }
}
