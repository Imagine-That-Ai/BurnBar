#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const CLI = '/usr/bin/openburnbar-cli';
const DESKTOP = '/usr/bin/openburnbar-linux-desktop';
const DAEMON_LAUNCHER = '/usr/libexec/openburnbar-daemon-launch';
const SEED = path.join(ROOT, 'scripts/linux-port/seed-p17-activity-database.py');
const CONTROL = path.join(ROOT, 'scripts/linux-port/p17-atspi-control.py');

function assert(value, message) { if (!value) throw new Error(message); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function writeExclusive(file, bytes) {
  const descriptor = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
}
function writeJson(file, value) { writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`)); }
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }

function ownerOnlyDirectory(directory, label, { empty = false } = {}) {
  const supplied = path.resolve(directory);
  fs.mkdirSync(supplied, { recursive: true, mode: 0o700 });
  const link = fs.lstatSync(supplied);
  assert(link.isDirectory() && !link.isSymbolicLink() && link.uid === process.getuid?.() && (link.mode & 0o077) === 0,
    `${label} must be an owner-only real directory`);
  const resolved = fs.realpathSync(supplied);
  if (empty) assert(fs.readdirSync(resolved).length === 0, `${label} must be empty`);
  return resolved;
}

function ownerOnlyToken(file) {
  const stat = fs.lstatSync(file);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    'P-17 daemon token must be an owner-only regular file');
  const value = fs.readFileSync(file, 'utf8').trim();
  assert(value.length >= 32 && !/[\r\n]/u.test(value), 'P-17 daemon token is invalid');
  return value;
}

function configureXdgDownloads(homeDir, downloadDir) {
  assert(!/[\0\r\n]/u.test(downloadDir), 'P-17 download directory cannot be encoded in XDG user-dirs');
  const escaped = downloadDir
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll('$', '\\$')
    .replaceAll('`', '\\`');
  const configDirectory = path.join(homeDir, '.config');
  fs.mkdirSync(configDirectory, { mode: 0o700 });
  const configFile = path.join(configDirectory, 'user-dirs.dirs');
  writeExclusive(configFile, Buffer.from(`XDG_DOWNLOAD_DIR="${escaped}"\n`));
  return configFile;
}

function commandRunner() {
  return {
    run(command, args = [], options = {}) {
      const result = spawnSync(command, args, { encoding: 'utf8', timeout: 30_000, maxBuffer: 8 * 1024 * 1024, ...options });
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

function required(runner, command, args, label, options = {}) {
  const result = runner.run(command, args, options);
  assert(result.status === 0, `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}

async function waitFor(label, operation, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try { return await operation(); } catch (error) { lastError = error; await sleep(250); }
  }
  throw new Error(`${label} timed out: ${lastError?.message ?? 'unavailable'}`);
}

async function waitForExit(runner, pid) {
  await waitFor(`PID ${pid} exit`, () => {
    const result = runner.run('kill', ['-0', String(pid)]);
    assert(result.status !== 0, `PID ${pid} is still running`);
    return true;
  }, 15_000);
}

function installedDesktopPids(runner) {
  const result = runner.run('pgrep', ['-f', '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)']);
  if (result.status === 1) return [];
  assert(result.status === 0, `P-17 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim().split(/\s+/u).filter(Boolean).map(Number).filter(Number.isSafeInteger);
}

function p17Environment(options) {
  return {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, '.config'),
    XDG_DATA_HOME: path.join(options.homeDir, '.local/share'),
    OPENBURNBAR_DAEMON_SUPPORT_DIR: options.supportDir,
    OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile,
    OPENBURNBAR_INDEX_DATABASE_PATH: options.indexDatabase
  };
}

function defaultCLI(runner, options) {
  return (args, { allowFailure = false } = {}) => {
    const result = runner.run(CLI, args, { env: p17Environment(options) });
    if (!allowFailure) assert(result.status === 0, `installed Activity CLI failed: ${(result.stderr || result.stdout).trim()}`);
    let document = null;
    try { document = JSON.parse(result.stdout); } catch { /* error output is captured below */ }
    return { args, status: result.status, stdout: result.stdout, stderr: result.stderr, document };
  };
}

function defaultSeed(runner, options, sessionID, marker) {
  const stdout = required(runner, 'python3', [SEED,
    '--database', options.indexDatabase,
    '--usage-ledger', path.join(options.supportDir, 'usage-events.jsonl'),
    '--home', options.homeDir,
    '--session-id', sessionID,
    '--marker', marker
  ], 'P-17 database seed');
  return JSON.parse(stdout);
}

function defaultDaemon(runner, options) {
  let process = null;
  let wasActive = false;
  const env = p17Environment(options);
  const launch = async (label) => {
    fs.rmSync(options.socketPath, { force: true });
    const log = fs.openSync(path.join(options.rawOutputDir, `daemon-${label}.log`), 'wx', 0o600);
    process = spawn(DAEMON_LAUNCHER, ['--version', `p17-installed-${label}`], {
      env, stdio: ['ignore', log, log]
    });
    process.unref();
    fs.closeSync(log);
    await waitFor(`P-17 daemon ${label}`, () => {
      assert(fs.existsSync(options.socketPath) && fs.lstatSync(options.socketPath).isSocket(), 'daemon socket is absent');
      const health = runner.run(CLI, ['health'], { env });
      assert(health.status === 0 && /ok=true/u.test(health.stdout), 'installed CLI health is unavailable');
      return true;
    });
  };
  const stopChild = async () => {
    if (!process) return;
    process.kill('SIGTERM');
    await waitForExit(runner, process.pid);
    process = null;
  };
  return {
    async prepare() {
      const status = runner.run('systemctl', ['--user', 'is-active', '--quiet', 'openburnbar-daemon.service']);
      wasActive = status.status === 0;
      assert([0, 3].includes(status.status), 'P-17 could not determine the user daemon state');
      if (wasActive) required(runner, 'systemctl', ['--user', 'stop', 'openburnbar-daemon.service'], 'stop user daemon');
      await launch('initial');
    },
    async stop() { await stopChild(); },
    async start(label = 'restart') { await launch(label); },
    async restart() { await stopChild(); await launch('restart'); },
    async restore() {
      await stopChild();
      if (wasActive) required(runner, 'systemctl', ['--user', 'start', 'openburnbar-daemon.service'], 'restore user daemon');
    }
  };
}

function atspi(runner, output, suffix, mode, name = null, extra = []) {
  const file = path.join(output, `.p17-atspi-${suffix}.json`);
  const args = [CONTROL, '--application', 'OpenBurnBar', '--mode', mode, '--output', file];
  if (name) args.push('--name', name);
  args.push(...extra);
  required(runner, 'python3', args, `P-17 AT-SPI ${suffix}`);
  const value = readJson(file);
  fs.rmSync(file, { force: true });
  return value;
}

function treeNames(tree) { return (tree.nodes ?? []).map((node) => String(node.name ?? '')).filter(Boolean); }
function treeContains(tree, value) { return treeNames(tree).some((name) => name.includes(value)); }

function newestDownload(directory, extension, afterMs) {
  const matches = fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(extension))
    .map((entry) => ({ file: path.join(directory, entry.name), stat: fs.lstatSync(path.join(directory, entry.name)) }))
    .filter((row) => !row.stat.isSymbolicLink() && row.stat.mtimeMs >= afterMs)
    .sort((left, right) => right.stat.mtimeMs - left.stat.mtimeMs);
  assert(matches.length === 1, `P-17 expected exactly one fresh ${extension} download`);
  return matches[0].file;
}

function captureDownload(directory, extension, afterMs, destination) {
  const source = newestDownload(directory, extension, afterMs);
  const bytes = fs.readFileSync(source);
  assert(bytes.length >= 100, `P-17 ${extension} export is empty`);
  writeExclusive(destination, bytes);
  fs.rmSync(source);
  return { byteCount: bytes.length, sha256: sha256(bytes) };
}

function defaultUI(runner, options) {
  const output = options.rawOutputDir;
  let app = null;
  const activate = (suffix, name, role = null) => atspi(runner, output, suffix, 'activate', name, role ? ['--role', role] : []);
  const snapshot = (suffix) => atspi(runner, output, suffix, 'snapshot');
  const setText = (suffix, name, text) => atspi(runner, output, suffix, 'set-text', name, ['--text', text]);
  const select = (suffix, name, option) => atspi(runner, output, suffix, 'select', name, ['--option', option]);
  const launch = async () => {
    app = runner.start(DESKTOP, [], { env: { ...p17Environment(options), OPENBURNBAR_EVIDENCE_OUT: output } });
    assert(Number.isSafeInteger(app.pid) && app.pid > 1, 'P-17 installed app returned no PID');
    const windowID = await waitFor('P-17 installed app window', () => {
      const found = runner.run('xdotool', ['search', '--onlyvisible', '--pid', String(app.pid), '--name', '^OpenBurnBar']);
      const ids = found.status === 0 ? found.stdout.trim().split(/\s+/u).filter(Boolean) : [];
      assert(ids.length === 1, 'expected one installed OpenBurnBar window');
      return ids[0];
    });
    return { pid: app.pid, windowID };
  };
  const stop = async () => {
    if (!app) return;
    app.kill();
    await waitForExit(runner, app.pid);
    app = null;
  };
  const route = async () => {
    activate('palette', 'Open command palette');
    activate('route', 'Activity & logs', 'dialog');
    await sleep(500);
  };
  const assertMarker = async (label, marker) => waitFor(label, () => {
    const tree = snapshot(label.replace(/[^a-z0-9]+/giu, '-'));
    assert(treeContains(tree, marker), `${label} marker is absent`);
    return tree;
  });
  const expandAndLoad = async (suffix, marker) => {
    activate(`${suffix}-details`, 'Show details');
    activate(`${suffix}-body`, 'Load session body');
    return assertMarker(`${suffix}-body-loaded`, marker);
  };
  const exportLoaded = async (format, suffix) => {
    if (format === 'markdown') select(`${suffix}-format`, 'Activity export format', 'Markdown');
    const started = Date.now();
    activate(`${suffix}-export`, `Export activity as ${format === 'json' ? 'JSON' : 'Markdown'}`);
    await sleep(500);
    return captureDownload(options.downloadDir, format === 'json' ? '.json' : '.md', started,
      path.join(output, `activity-loaded.${format === 'json' ? 'json' : 'md'}`));
  };
  const exportHistory = async () => {
    select('history-format', 'Activity export format', 'JSON');
    const started = Date.now();
    activate('history-export', 'Export full history');
    await sleep(800);
    return captureDownload(options.downloadDir, '.json', started, path.join(output, 'activity-history.json'));
  };
  return {
    launch, stop, route, snapshot, assertMarker, expandAndLoad, exportLoaded, exportHistory,
    async search(marker) {
      setText('search', 'Search sessions', marker);
      await sleep(500);
      return assertMarker('search-results', marker);
    },
    async reloadBody() { activate('reload-body', 'Reload session body'); },
    async retryBody() { activate('retry-body', 'Retry session body'); },
    screenshot(state, identity) {
      const file = path.join(output, `activity-${state}.png`);
      required(runner, 'scrot', ['--overwrite', '--focused', file], `P-17 ${state} screenshot`);
      assert(fs.statSync(file).size > 1024, `P-17 ${state} screenshot is empty`);
      return { file, manifestSha256: identity.manifestSha256 };
    }
  };
}

function timestamp(clock) {
  const milliseconds = Math.max(Date.now(), clock.value + 1);
  clock.value = milliseconds;
  return new Date(milliseconds).toISOString();
}

export async function runP17NativeActivityProbes(options, dependencies = {}) {
  assert((dependencies.platform ?? process.platform) === 'linux', 'P-17 native probe must execute on Linux');
  assert(dependencies.desktopSession ?? (process.env.DBUS_SESSION_BUS_ADDRESS && process.env.DISPLAY),
    'P-17 requires a live Linux X11 desktop and D-Bus session');
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = ownerOnlyDirectory(options.rawOutputDir, 'P-17 raw output', { empty: true });
  options.supportDir = ownerOnlyDirectory(options.supportDir, 'P-17 support directory', { empty: false });
  options.homeDir = ownerOnlyDirectory(options.homeDir, 'P-17 isolated home', { empty: true });
  options.downloadDir = ownerOnlyDirectory(options.downloadDir, 'P-17 download directory', { empty: true });
  configureXdgDownloads(options.homeDir, options.downloadDir);
  ownerOnlyToken(options.tokenFile);
  assert(path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir, 'P-17 daemon token must be inside the isolated support directory');
  assert(JSON.stringify(fs.readdirSync(options.supportDir).sort()) === JSON.stringify([path.basename(options.tokenFile)]),
    'P-17 isolated support directory may contain only the supplied daemon token before seeding');
  assert(path.dirname(path.resolve(options.indexDatabase)) === options.supportDir && !fs.existsSync(options.indexDatabase),
    'P-17 index database must be a missing support-directory child');
  const runner = dependencies.runner ?? commandRunner();
  const processIDs = (dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner)))();
  assert(Array.isArray(processIDs) && processIDs.length === 0, 'P-17 requires no pre-existing installed desktop process');
  if (!dependencies.ui) for (const command of ['python3', 'xdotool', 'scrot']) {
    required(runner, 'sh', ['-c', 'command -v "$1" >/dev/null', 'p17-tool', command], `required tool ${command}`);
  }

  const sessionID = dependencies.sessionID ?? crypto.randomUUID();
  const marker = dependencies.marker ?? `P17-${crypto.randomBytes(8).toString('hex')}`;
  const seed = (dependencies.seed ?? ((id, value) => defaultSeed(runner, options, id, value)))(sessionID, marker);
  assert(seed.sourceID === `Codex:${sessionID}` && seed.marker === marker && seed.body.includes(marker), 'P-17 seed readback is invalid');
  writeJson(path.join(options.rawOutputDir, 'activity-seed.json'), {
    schemaVersion: seed.schemaVersion,
    producer: seed.producer,
    sourceID: seed.sourceID,
    providerSessionID: seed.providerSessionID,
    ambiguousSessionID: seed.ambiguousSessionID,
    marker: seed.marker,
    title: seed.title,
    body: seed.body,
    createdAt: seed.createdAt,
    databaseSha256: sha256(fs.readFileSync(options.indexDatabase)),
    usageLedgerSha256: sha256(fs.readFileSync(path.join(options.supportDir, 'usage-events.jsonl'))),
    sessionFileSha256: sha256(fs.readFileSync(seed.sessionFile))
  });
  const daemon = dependencies.daemon ?? defaultDaemon(runner, options);
  const cli = dependencies.cli ?? defaultCLI(runner, options);
  const ui = dependencies.ui ?? defaultUI(runner, options);
  const cliRows = [];
  const events = [];
  const clock = { value: 0 };
  let app = null;
  let initialAppPid = null;
  let daemonPrepared = false;
  const callCLI = (phase, args, settings) => {
    const result = cli(args, settings);
    cliRows.push({ phase, at: timestamp(clock), args, status: result.status, stdout: result.stdout, stderr: result.stderr,
      document: result.document });
    return result;
  };
  try {
    await daemon.prepare();
    daemonPrepared = true;
    const history = callCLI('history-initial', ['activity', 'history', '--limit', '500']);
    assert(history.document?.historyComplete === true && history.document.totalCount >= 1,
      'P-17 complete history was not returned by the installed CLI');
    const exact = history.document.sessions.filter((row) => row.sourceID === seed.sourceID);
    assert(exact.length === 1 && exact[0].providerSessionID === sessionID && exact[0].bodyMD.includes(marker),
      'P-17 history is not bound to the seeded persisted body');
    const search = callCLI('search-initial', ['activity', 'search', marker, '--limit', '10']);
    assert(search.document?.hits?.filter((hit) => hit.sourceID === seed.sourceID).length === 1,
      'P-17 installed CLI search did not resolve the exact source');
    const replay = callCLI('replay-initial', ['activity', 'replay', seed.sourceID]);
    assert(replay.document?.kind === 'native' && replay.document?.briefingMD?.includes(marker)
      && replay.document?.argv?.[0] === 'codex' && replay.document?.argv?.[1] === 'resume'
      && replay.document?.argv?.includes(sessionID), 'P-17 native resume readback is invalid');
    const missing = callCLI('replay-missing', ['activity', 'replay', `Codex:missing-${marker}`], { allowFailure: true });
    assert(missing.document?.kind === 'error' && missing.document.errorCode === 'session_not_found',
      'P-17 missing source did not fail closed');
    const ambiguous = callCLI('replay-ambiguous', ['activity', 'replay', seed.ambiguousSessionID], { allowFailure: true });
    assert(ambiguous.document?.kind === 'error' && ambiguous.document.errorCode === 'ambiguous_session',
      'P-17 ambiguous source did not fail closed');

    app = await ui.launch();
    initialAppPid = app.pid;
    await ui.route();
    await ui.assertMarker('initial-usage-row', marker);
    const bodyTree = await ui.expandAndLoad('initial', marker);
    const initialScreenshot = ui.screenshot('initial', options);
    const loadedJSON = await ui.exportLoaded('json', 'loaded-json');
    const loadedMarkdown = await ui.exportLoaded('markdown', 'loaded-markdown');
    const historyJSON = await ui.exportHistory();
    events.push({ kind: 'populated-replay-export', at: timestamp(clock), appPid: app.pid, marker,
      sourceID: seed.sourceID, bodyObserved: treeContains(bodyTree, marker), loadedJSON, loadedMarkdown, historyJSON,
      manifestSha256: options.manifestSha256 });

    await daemon.stop();
    await ui.reloadBody();
    const staleTree = await waitFor('P-17 retained body failure state', () => {
      const tree = ui.snapshot('stale-body');
      assert(treeContains(tree, marker) && treeContains(tree, 'showing the last successful body'),
        'P-17 did not retain the body with explicit failure provenance');
      return tree;
    });
    const staleScreenshot = ui.screenshot('stale', options);
    events.push({ kind: 'failure-retained', at: timestamp(clock), appPid: app.pid, marker,
      bodyRetained: treeContains(staleTree, marker), failureExposed: treeContains(staleTree, 'showing the last successful body'),
      manifestSha256: options.manifestSha256 });

    await daemon.start('recovery');
    await ui.retryBody();
    await ui.assertMarker('recovered-body', marker);
    await ui.stop();
    app = null;
    await daemon.restart();
    const restartHistory = callCLI('history-after-restart', ['activity', 'history', '--limit', '500']);
    const restartSearch = callCLI('search-after-restart', ['activity', 'search', marker, '--limit', '10']);
    const restartReplay = callCLI('replay-after-restart', ['activity', 'replay', seed.sourceID]);
    assert(restartHistory.document?.sessions?.some((row) => row.sourceID === seed.sourceID && row.bodyMD.includes(marker))
      && restartSearch.document?.hits?.some((hit) => hit.sourceID === seed.sourceID)
      && restartReplay.document?.briefingMD?.includes(marker), 'P-17 daemon restart lost indexed Activity state');
    app = await ui.launch();
    assert(app.pid !== initialAppPid, 'P-17 app restart reused the initial process instead of launching a fresh installed UI');
    await ui.route();
    await ui.search(marker);
    const restartTree = await ui.expandAndLoad('restart', marker);
    const restartScreenshot = ui.screenshot('restart', options);
    events.push({ kind: 'restart-durable', at: timestamp(clock), appPid: app.pid, marker,
      sourceID: seed.sourceID, searchObserved: treeContains(restartTree, marker), bodyObserved: treeContains(restartTree, marker),
      manifestSha256: options.manifestSha256 });

    writeJson(path.join(options.rawOutputDir, 'activity-cli-transcript.json'), {
      producer: 'openburnbar-p17-installed-cli-probe-v1', transport: 'installed OpenBurnBar CLI over AF_UNIX', rows: cliRows
    });
    writeJson(path.join(options.rawOutputDir, 'activity-interactions.json'), {
      producer: 'openburnbar-p17-installed-ui-probe-v1', events
    });
    for (const [name, tree] of [['activity-initial-atspi.json', bodyTree], ['activity-stale-atspi.json', staleTree], ['activity-restart-atspi.json', restartTree]]) {
      writeJson(path.join(options.rawOutputDir, name), { ...tree, appPid: name.includes('restart') ? app.pid : events[0].appPid,
        manifestSha256: options.manifestSha256, marker });
    }
    return { output: options.rawOutputDir, marker, sourceID: seed.sourceID, sessionID,
      screenshots: [initialScreenshot.file, staleScreenshot.file, restartScreenshot.file] };
  } finally {
    try { if (app) await ui.stop(); } catch { /* preserve primary failure */ }
    if (daemonPrepared) await daemon.restore();
  }
}

export function parseP17Arguments(argv) {
  const flags = ['--raw-output-dir', '--support-dir', '--home-dir', '--download-dir', '--socket-path', '--token-file', '--index-database',
    '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256',
    '--manifest-signature-sha256', '--compositor'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    rawOutputDir: values.get('--raw-output-dir'), supportDir: values.get('--support-dir'), homeDir: values.get('--home-dir'),
    downloadDir: values.get('--download-dir'), socketPath: values.get('--socket-path'), tokenFile: values.get('--token-file'),
    indexDatabase: values.get('--index-database'), environmentId: values.get('--environment'), targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(await runP17NativeActivityProbes(parseP17Arguments(process.argv.slice(2))), null, 2)}\n`); }
  catch (error) { process.stderr.write(`P-17 native Activity probe failed: ${error.message}\n`); process.exitCode = 1; }
}
