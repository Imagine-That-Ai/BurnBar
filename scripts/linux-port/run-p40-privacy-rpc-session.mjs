#!/usr/bin/env node

/**
 * Produce the live P-40 session report from an installed Linux daemon.
 *
 * This intentionally has no test/fixture mode. The caller supplies the
 * candidate identity and an authenticated AF_UNIX socket; every observation
 * below is obtained from that daemon or from files created in a fresh,
 * owner-only P-40 support directory.
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P40_DEFAULT_RETENTION_RULES,
  P40_ENVIRONMENTS,
  P40_RETENTION_CONTRACT,
  P40_RPC_METHODS,
  P40_STORES,
  validateP40LiveSession
} from './lib/p40-privacy-proof.mjs';

const MANIFEST_PATH = '/usr/share/openburnbar/attestation/installed-manifest.json';
const MANIFEST_SIGNATURE_PATH = `${MANIFEST_PATH}.sig`;
const RELEASE_PUBLIC_KEY_PATH = '/usr/share/openburnbar/attestation/release-ed25519.pub.pem';
const DESKTOP_BINARY_PATH = '/usr/bin/openburnbar-linux-desktop';
const CLI_BINARY_PATH = '/usr/bin/openburnbar-cli';
const DAEMON_BINARY_PATH = '/usr/bin/openburnbar-daemon';
const ROUTE_FILENAME = 'proxy-route-events.jsonl';
const EXPANSION_FILENAME = 'text-expansion-v1.obbsealed';
const TOKEN_FILENAME = 'daemon-socket-auth-token';
const REFERENCE_DATE_UNIX_SECONDS = 978307200;
const SHA256 = /^[a-f0-9]{64}$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const SOCKET_TIMEOUT_MS = 15_000;
const EXPIRY_SAFETY_MS = 1_000;
const SYSTEM_COMMANDS = Object.freeze({
  dpkgQuery: '/usr/bin/dpkg-query',
  loginctl: '/usr/bin/loginctl',
  pacman: '/usr/bin/pacman',
  pgrep: '/usr/bin/pgrep',
  rpm: '/usr/bin/rpm'
});
const PACKAGE_FORMATS = Object.freeze({
  deb: Object.freeze({
    manager: 'dpkg',
    packageName: 'open-burn-bar',
    queryCommand: SYSTEM_COMMANDS.dpkgQuery
  }),
  rpm: Object.freeze({
    manager: 'rpm',
    packageName: 'open-burn-bar',
    queryCommand: SYSTEM_COMMANDS.rpm
  }),
  arch: Object.freeze({
    manager: 'pacman',
    packageName: 'openburnbar',
    queryCommand: SYSTEM_COMMANDS.pacman
  })
});
const DESKTOP_RUNTIMES = Object.freeze({
  GNOME: Object.freeze({
    compositor: 'Mutter',
    desktopProcess: 'gnome-shell',
    compositorProcess: 'gnome-shell',
    markers: Object.freeze(['gnome'])
  }),
  'KDE Plasma': Object.freeze({
    compositor: 'KWin',
    desktopProcess: 'plasmashell',
    compositorProcess: 'kwin_wayland',
    markers: Object.freeze(['kde', 'plasma'])
  }),
  'Sway/wlroots': Object.freeze({
    compositor: 'Sway',
    desktopProcess: 'sway',
    compositorProcess: 'sway',
    markers: Object.freeze(['sway'])
  })
});
let activeTokenFile = null;

function dateMilliseconds(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return (value + REFERENCE_DATE_UNIX_SECONDS) * 1_000;
  }
  if (typeof value === 'string') {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return NaN;
}

class RPCError extends Error {
  constructor(code, message) {
    super(message || 'daemon RPC failed');
    this.name = 'RPCError';
    this.code = code;
  }
}

function fail(message) {
  throw new Error(message);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function assertObject(value, label) {
  assert(value !== null && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
}

function assertString(value, label, pattern = null) {
  assert(typeof value === 'string' && value.length > 0, `${label} must be a non-empty string`);
  if (pattern) assert(pattern.test(value), `${label} has an invalid format`);
}

function assertAbsolute(file, label) {
  assert(path.isAbsolute(file), `${label} must be absolute`);
  assert(!file.includes('\\'), `${label} must not contain backslashes`);
  assert(path.normalize(file) === file, `${label} must be normalized`);
}

function lstatNoSymlink(file, label, allowMissing = false) {
  const absolute = path.resolve(file);
  const components = absolute.split(path.sep).filter(Boolean);
  let current = path.parse(absolute).root;
  for (const component of components) {
    current = path.join(current, component);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (allowMissing && current === absolute && error.code === 'ENOENT') return null;
      throw new Error(`${label} is missing or unreadable`);
    }
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  return fs.lstatSync(absolute);
}

function ownerOnlyDirectory(directory, label) {
  const stat = lstatNoSymlink(directory, label);
  assert(stat.isDirectory(), `${label} must be a directory`);
  assert((stat.mode & 0o077) === 0, `${label} must be owner-only`);
  assert(stat.uid === process.getuid?.(), `${label} must be owned by the current user`);
}

function ensureOutputRoot(outputRoot) {
  assertAbsolute(outputRoot, 'output root');
  fs.mkdirSync(outputRoot, { recursive: true, mode: 0o700 });
  ownerOnlyDirectory(outputRoot, 'output root');
  const privacy = path.join(outputRoot, 'privacy');
  fs.mkdirSync(privacy, { recursive: true, mode: 0o700 });
  ownerOnlyDirectory(privacy, 'privacy evidence directory');
  return { privacy };
}

function parseArguments(argv) {
  const flags = new Set([
    '--socket', '--token-file', '--output-root', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest', '--package-version',
    '--manifest-sha256'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flags.has(flag) || value === undefined || value.startsWith('--') || values.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    }
    values.set(flag, value);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);

  const socket = values.get('--socket');
  const tokenFile = path.resolve(values.get('--token-file'));
  const outputRoot = path.resolve(values.get('--output-root'));
  const environmentId = values.get('--environment');
  const targetHead = values.get('--target-head');
  const candidateRunId = values.get('--candidate-run-id');
  const candidateArtifactDigest = values.get('--candidate-artifact-digest');
  const packageVersion = values.get('--package-version');
  const manifestSha256 = values.get('--manifest-sha256');

  assertAbsolute(socket, 'socket');
  assertAbsolute(tokenFile, 'token file');
  assertAbsolute(outputRoot, 'output root');
  assert(P40_ENVIRONMENTS[environmentId], `unsupported P-40 environment: ${environmentId}`);
  assertString(targetHead, 'target head', HEAD);
  assertString(candidateRunId, 'candidate run id', RUN_ID);
  assertString(candidateArtifactDigest, 'candidate artifact digest', DIGEST);
  assertString(packageVersion, 'package version', VERSION);
  assertString(manifestSha256, 'manifest sha256', SHA256);
  return {
    socket,
    tokenFile,
    outputRoot,
    environmentId,
    targetHead,
    candidateRunId,
    candidateArtifactDigest,
    packageVersion,
    manifestSha256
  };
}

function readOwnerOnlyToken(tokenFile) {
  const stat = lstatNoSymlink(tokenFile, 'daemon token file');
  assert(stat.isFile(), 'daemon token file must be regular');
  assert((stat.mode & 0o077) === 0, 'daemon token file must be owner-only');
  assert(stat.uid === process.getuid?.(), 'daemon token file must be owned by the current user');
  const token = fs.readFileSync(tokenFile, 'utf8').trim();
  assert(token.length >= 8 && !/[\r\n]/u.test(token), 'daemon token file is invalid');
  return token;
}

function readJSON(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function normalizeArchitecture(value) {
  switch (String(value ?? '').trim()) {
    case 'x64':
    case 'amd64':
    case 'x86_64':
      return 'x86_64';
    case 'arm64':
    case 'aarch64':
      return 'aarch64';
    default:
      fail(`unsupported Linux architecture: ${String(value ?? '').trim() || '<empty>'}`);
  }
}

function environmentIdentity(environmentId) {
  const expected = P40_ENVIRONMENTS[environmentId];
  assert(expected, `unsupported P-40 environment: ${environmentId}`);
  const packageRuntime = PACKAGE_FORMATS[expected.format];
  const desktopRuntime = DESKTOP_RUNTIMES[expected.desktop];
  assert(packageRuntime, `unsupported P-40 package format: ${expected.format}`);
  assert(desktopRuntime, `unsupported P-40 desktop: ${expected.desktop}`);
  return {
    architecture: expected.architecture,
    compositor: desktopRuntime.compositor,
    compositorProcess: desktopRuntime.compositorProcess,
    desktop: expected.desktop,
    desktopMarkers: [...desktopRuntime.markers],
    desktopProcess: desktopRuntime.desktopProcess,
    displayServer: expected.session,
    manager: packageRuntime.manager,
    os: { ...expected.os },
    packageFormat: expected.format,
    packageName: packageRuntime.packageName,
    packageQueryCommand: packageRuntime.queryCommand
  };
}

function trustedSystemExecutable(file, label) {
  const stat = lstatNoSymlink(file, label);
  assert(stat.isFile() && stat.uid === 0 && (stat.mode & 0o111) !== 0 && (stat.mode & 0o022) === 0,
    `${label} must be a root-owned non-writable executable`);
}

function systemCommandEnvironment() {
  const environment = { ...process.env, LC_ALL: 'C' };
  for (const variable of [
    'DPKG_ADMINDIR',
    'DPKG_ROOT',
    'LD_AUDIT',
    'LD_LIBRARY_PATH',
    'LD_PRELOAD',
    'RPM_CONFIGDIR'
  ]) {
    delete environment[variable];
  }
  return environment;
}

function commandOutput(runner, command, args, label) {
  const result = runner(command, args, {
    encoding: 'utf8',
    env: systemCommandEnvironment(),
    timeout: 15_000,
    maxBuffer: 64 * 1024
  });
  assert(!result?.error && result?.status === 0, `${label} failed`);
  assert(typeof result.stdout === 'string' && result.stdout.trim().length > 0, `${label} returned no identity`);
  return result.stdout;
}

function queryInstalledPackage(identity, expectedVersion, runner = spawnSync) {
  if (runner === spawnSync) trustedSystemExecutable(identity.packageQueryCommand, 'native package query');
  let packageName;
  let packageVersion;
  let packageArchitecture;
  if (identity.packageFormat === 'deb') {
    const output = commandOutput(
      runner,
      identity.packageQueryCommand,
      ['-W', '-f=${Status}\t${Version}\t${Architecture}\t${Package}\n', identity.packageName],
      'installed Debian package query'
    );
    const [status, version, architecture, name, ...extra] = output.trim().split('\t');
    assert(extra.length === 0 && status === 'install ok installed', 'installed Debian package status is invalid');
    packageName = name;
    packageVersion = version;
    packageArchitecture = normalizeArchitecture(architecture);
  } else if (identity.packageFormat === 'rpm') {
    const output = commandOutput(
      runner,
      identity.packageQueryCommand,
      ['-q', '--queryformat', '%{NAME}\t%{VERSION}\t%{ARCH}\n', identity.packageName],
      'installed RPM package query'
    );
    const [name, version, architecture, ...extra] = output.trim().split('\t');
    assert(extra.length === 0, 'installed RPM package identity is malformed');
    packageName = name;
    packageVersion = version;
    packageArchitecture = normalizeArchitecture(architecture);
  } else if (identity.packageFormat === 'arch') {
    const output = commandOutput(
      runner,
      identity.packageQueryCommand,
      ['-Qi', identity.packageName],
      'installed Arch package query'
    );
    const fields = new Map();
    for (const line of output.split('\n')) {
      const match = /^([^:]+?)\s*:\s*(.*)$/u.exec(line);
      if (match && !fields.has(match[1].trim())) fields.set(match[1].trim(), match[2].trim());
    }
    packageName = fields.get('Name');
    packageVersion = String(fields.get('Version') ?? '').replace(/-[1-9][0-9]*$/u, '');
    packageArchitecture = normalizeArchitecture(fields.get('Architecture'));
  } else {
    fail(`unsupported installed package format: ${identity.packageFormat}`);
  }
  assert(packageName === identity.packageName, 'installed package name does not match the support environment');
  assert(packageVersion === expectedVersion, 'installed package version does not match the signed candidate');
  assert(packageArchitecture === identity.architecture,
    'installed package architecture does not match the support environment');
  return {
    architecture: packageArchitecture,
    format: identity.packageFormat,
    manager: identity.manager,
    name: packageName,
    version: packageVersion
  };
}

function verifyInstalledCandidate(options) {
  assert(process.platform === 'linux', 'P-40 producer must run on Linux');
  for (const variable of ['OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG', 'BURNBAR_DAEMON_DISABLE_PEER_CODESIG']) {
    assert(process.env[variable] !== '1', `${variable}=1 is forbidden for release P-40 evidence`);
  }
  const identity = environmentIdentity(options.environmentId);
  const manifestStat = lstatNoSymlink(MANIFEST_PATH, 'installed manifest');
  assert(manifestStat.isFile() && manifestStat.uid === 0 && (manifestStat.mode & 0o0777) === 0o644,
    'installed manifest must be root-owned mode 0644');
  const signatureStat = lstatNoSymlink(MANIFEST_SIGNATURE_PATH, 'installed manifest signature');
  assert(signatureStat.isFile() && signatureStat.uid === 0 && (signatureStat.mode & 0o0777) === 0o644,
    'installed manifest signature must be root-owned mode 0644');
  const publicKeyStat = lstatNoSymlink(RELEASE_PUBLIC_KEY_PATH, 'installed release public key');
  assert(publicKeyStat.isFile() && publicKeyStat.uid === 0 && (publicKeyStat.mode & 0o0777) === 0o644,
    'installed release public key must be root-owned mode 0644');
  const manifestBytes = fs.readFileSync(MANIFEST_PATH);
  const signature = fs.readFileSync(MANIFEST_SIGNATURE_PATH);
  assert(signature.length === 64, 'installed manifest signature must be Ed25519');
  let signatureValid = false;
  try {
    signatureValid = crypto.verify(
      null,
      manifestBytes,
      crypto.createPublicKey(fs.readFileSync(RELEASE_PUBLIC_KEY_PATH)),
      signature
    );
  } catch {
    signatureValid = false;
  }
  assert(signatureValid, 'installed manifest signature is invalid');
  const manifest = readJSON(MANIFEST_PATH, 'installed manifest');
  assert(manifest.gitCommit === options.targetHead, 'installed manifest commit does not match target head');
  assert(manifest.packageArchitecture === identity.architecture, 'installed manifest architecture mismatch');
  assert(manifest.packageFormat === identity.packageFormat, 'installed manifest format mismatch');
  assert(manifest.packageName === identity.packageName, 'installed manifest package name mismatch');
  assert(manifest.packageVersion === options.packageVersion, 'installed manifest version mismatch');
  assert(crypto.createHash('sha256').update(manifestBytes).digest('hex') === options.manifestSha256,
    'installed manifest hash mismatch');
  for (const required of [DAEMON_BINARY_PATH, DESKTOP_BINARY_PATH, CLI_BINARY_PATH, '/usr/libexec/openburnbar-daemon-launch']) {
    const stat = lstatNoSymlink(required, `installed candidate ${required}`);
    assert(stat.isFile() && stat.uid === 0 && (stat.mode & 0o111) !== 0 && (stat.mode & 0o022) === 0,
      `installed candidate binary is not a trusted executable: ${required}`);
    const manifestFile = manifest.files?.find((entry) => entry?.path === required && entry.type === 'file');
    assert(manifestFile?.mode === '0755' && manifestFile.uid === 0 && manifestFile.gid === 0,
      `installed manifest does not inventory the trusted executable: ${required}`);
    assert(crypto.createHash('sha256').update(fs.readFileSync(required)).digest('hex') === manifestFile.sha256,
      `installed executable hash does not match the signed manifest: ${required}`);
  }

  const packageIdentity = queryInstalledPackage(identity, options.packageVersion);
  return { identity, manifest, packageIdentity };
}

function readOSRelease() {
  const values = {};
  for (const line of fs.readFileSync('/etc/os-release', 'utf8').split('\n')) {
    const match = /^(\w+)=(.*)$/u.exec(line);
    if (!match) continue;
    values[match[1]] = match[2].replace(/^"|"$/gu, '');
  }
  return values;
}

function processEnvironment(pid) {
  try {
    const bytes = fs.readFileSync(`/proc/${pid}/environ`);
    return Object.fromEntries(bytes.toString('utf8').split('\0').map((entry) => entry.split('=', 2))
      .filter(([key, value]) => key && value !== undefined));
  } catch {
    return null;
  }
}

function desktopMatches(identity, value) {
  const observed = String(value ?? '').toLowerCase();
  return identity.desktopMarkers.some((marker) => observed.includes(marker));
}

function processIds(uid, processName, runner) {
  const listed = runner(SYSTEM_COMMANDS.pgrep, ['-u', uid, '-x', processName], {
    encoding: 'utf8',
    env: systemCommandEnvironment(),
    timeout: 10_000,
    maxBuffer: 64 * 1024
  });
  assert(!listed?.error, `unable to inspect ${processName}`);
  if (listed.status === 1) return [];
  assert(listed.status === 0, `unable to inspect ${processName}`);
  const ids = listed.stdout.split(/\s+/u).filter(Boolean);
  assert(ids.length > 0 && ids.every((pid) => /^[1-9][0-9]*$/u.test(pid)),
    `${processName} process identity is malformed`);
  return [...new Set(ids)];
}

function matchingProcessEnvironment({
  uid,
  processName,
  identity,
  runner,
  readProcessEnvironment,
  requireDesktop,
  requireDisplay
}) {
  const displayVariable = identity.displayServer === 'Wayland' ? 'WAYLAND_DISPLAY' : 'DISPLAY';
  for (const pid of processIds(uid, processName, runner)) {
    const environment = readProcessEnvironment(pid);
    if (!environment) continue;
    if ((environment.XDG_SESSION_TYPE || '').toLowerCase() !== identity.displayServer.toLowerCase()) continue;
    if (requireDesktop) {
      const desktop = [environment.XDG_CURRENT_DESKTOP, environment.XDG_SESSION_DESKTOP, environment.DESKTOP_SESSION]
        .filter(Boolean).join(':');
      if (!desktopMatches(identity, desktop)) continue;
    }
    if (requireDisplay
        && (typeof environment[displayVariable] !== 'string' || environment[displayVariable].length === 0)) continue;
    return { environment, pid };
  }
  return null;
}

function verifyDesktopSession(identity, dependencies = {}) {
  const runner = dependencies.runner ?? spawnSync;
  const osRelease = dependencies.osRelease ?? readOSRelease();
  const architecture = normalizeArchitecture(dependencies.architecture ?? os.arch());
  const getuid = dependencies.getuid ?? process.getuid;
  const readProcessEnvironment = dependencies.readProcessEnvironment ?? processEnvironment;
  if (!dependencies.runner) {
    trustedSystemExecutable(SYSTEM_COMMANDS.loginctl, 'logind session query');
    trustedSystemExecutable(SYSTEM_COMMANDS.pgrep, 'desktop process query');
  }
  assert(typeof getuid === 'function', 'P-40 desktop verification requires a numeric user id');
  const uid = String(getuid());
  assert(/^[0-9]+$/u.test(uid), 'P-40 desktop verification user id is invalid');
  assert(osRelease.ID === identity.os.id, 'running OS id does not match support environment');
  assert(identity.os.versionId === null || osRelease.VERSION_ID === identity.os.versionId,
    'running OS version does not match support environment');
  const osVersionId = osRelease.VERSION_ID || osRelease.BUILD_ID;
  assert(typeof osVersionId === 'string' && osVersionId.length > 0,
    'running OS does not expose a real version/build identity');
  assert(architecture === identity.architecture, 'running architecture does not match support environment');

  // The producer is commonly launched by a service or over SSH. Bind the
  // claimed row to an active local logind session and to the actual desktop
  // and compositor processes instead of trusting caller-controlled XDG vars.
  const listed = runner(SYSTEM_COMMANDS.loginctl, ['list-sessions', '--no-legend', '--no-pager'], {
    encoding: 'utf8',
    env: systemCommandEnvironment(),
    timeout: 10_000,
    maxBuffer: 128 * 1024
  });
  assert(!listed?.error && listed.status === 0, 'unable to inspect the live logind session');
  const sessions = listed.stdout.split('\n').map((line) => line.trim().split(/\s+/u)).filter((parts) => parts.length >= 2);
  for (const [sessionId, sessionUid] of sessions) {
    if (sessionUid !== uid) continue;
    const detail = runner(SYSTEM_COMMANDS.loginctl, [
      'show-session', sessionId,
      '-p', 'Type', '-p', 'Desktop', '-p', 'Class', '-p', 'Active', '-p', 'Remote', '-p', 'State',
      '--no-pager'
    ], {
      encoding: 'utf8',
      env: systemCommandEnvironment(),
      timeout: 10_000,
      maxBuffer: 64 * 1024
    });
    if (detail?.error || detail.status !== 0) continue;
    const fields = Object.fromEntries(detail.stdout.split('\n').map((line) => line.split('=', 2)).filter(([key, value]) => key && value));
    const sessionIsActive = fields.Type === identity.displayServer.toLowerCase()
      && fields.Class === 'user' && fields.Active === 'yes' && fields.Remote === 'no'
      && ['active', 'online'].includes((fields.State || '').toLowerCase());
    if (!sessionIsActive || (fields.Desktop && !desktopMatches(identity, fields.Desktop))) continue;
    const desktopProcess = matchingProcessEnvironment({
      uid,
      processName: identity.desktopProcess,
      identity,
      runner,
      readProcessEnvironment,
      requireDesktop: true,
      requireDisplay: true
    });
    if (!desktopProcess) continue;
    const compositorProcess = identity.compositorProcess === identity.desktopProcess
      ? desktopProcess
      : matchingProcessEnvironment({
          uid,
          processName: identity.compositorProcess,
          identity,
          runner,
          readProcessEnvironment,
          requireDesktop: false,
          // Wayland compositors create the display socket; unlike their
          // desktop clients, they need not inherit WAYLAND_DISPLAY.
          requireDisplay: false
        });
    if (!compositorProcess) continue;
    return {
      architecture,
      compositor: identity.compositor,
      desktop: identity.desktop,
      displayServer: identity.displayServer,
      os: { id: osRelease.ID, versionId: osVersionId }
    };
  }
  fail('no active local desktop session matches the support environment');
}

function callRPC(socket, token, method, params = undefined) {
  const request = { method };
  const childEnvironment = { ...process.env };
  delete childEnvironment.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
  delete childEnvironment.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
  delete childEnvironment.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE;
  delete childEnvironment.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE;
  childEnvironment.OPENBURNBAR_DAEMON_SOCKET_PATH = socket;
  if (activeTokenFile) childEnvironment.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE = activeTokenFile;
  else childEnvironment.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN = token;
  if (params !== undefined) request.params = params;
  const child = spawnSync(CLI_BINARY_PATH, ['privacy-rpc'], {
    input: `${JSON.stringify(request)}\n`,
    encoding: 'utf8',
    timeout: SOCKET_TIMEOUT_MS,
    maxBuffer: 4 * 1024 * 1024,
    env: childEnvironment
  });
  if (child.error || child.status !== 0) {
    const detail = `${child.stderr ?? ''} ${child.error?.message ?? ''}`.trim();
    const code = /privacy_rpc_error code=(-?[0-9]+)/u.exec(detail)?.[1];
    if (code) throw new RPCError(Number(code), 'daemon rejected privacy operation');
    throw new Error(`authorized privacy CLI failed for ${method}: ${detail || `exit ${child.status}`}`);
  }
  try {
    const result = JSON.parse(child.stdout);
    assertObject(result, `RPC ${method} response`);
    return result;
  } catch (error) {
    throw new Error(`authorized privacy CLI returned invalid JSON for ${method}: ${error.message}`);
  }
}

async function expectRPCError(socket, token, method, params) {
  try {
    await callRPC(socket, token, method, params);
  } catch (error) {
    assert(error instanceof RPCError, `${method} did not return a daemon validation error`);
    return true;
  }
  return false;
}

function writeOwnerOnly(file, bytes) {
  const parent = path.dirname(file);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  ownerOnlyDirectory(parent, `parent directory for ${path.basename(file)}`);
  const stat = lstatNoSymlink(file, file, true);
  assert(stat === null, `refusing to overwrite existing ${path.basename(file)}`);
  const descriptor = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try { fs.writeFileSync(descriptor, bytes); } finally { fs.closeSync(descriptor); }
  fs.chmodSync(file, 0o600);
}

function rewriteOwnerOnly(file, bytes) {
  const stat = lstatNoSymlink(file, file);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    `unsafe producer-owned file: ${path.basename(file)}`);
  const temporary = `${file}.p40-${process.pid}-${crypto.randomUUID()}.tmp`;
  writeOwnerOnly(temporary, bytes);
  fs.renameSync(temporary, file);
  fs.chmodSync(file, 0o600);
}

function routeRecord(id, occurredAt) {
  return {
    id,
    occurredAt: occurredAt - REFERENCE_DATE_UNIX_SECONDS,
    requestPath: '/v1/chat/completions',
    endpoint: 'chat.completions',
    clientModelSlug: 'p40-check',
    rewriteKind: 'none',
    exactModelInvariant: 'passed',
    finalStatus: 'exact',
    streamed: false,
    streamInterrupted: false,
    attempts: []
  };
}

function routeBytes(nowSeconds) {
  const old = routeRecord('p40-old-route', nowSeconds - 7_200);
  const fresh = routeRecord('p40-fresh-route', nowSeconds - 60);
  return Buffer.from(`${JSON.stringify(old)}\n${JSON.stringify(fresh)}\n`, 'utf8');
}

function seedStores(support, nowSeconds) {
  const route = path.join(support, ROUTE_FILENAME);
  const expansion = path.join(support, EXPANSION_FILENAME);
  writeOwnerOnly(route, routeBytes(nowSeconds));
  const expansionMarker = `p40-expansion-${crypto.randomUUID()}`;
  writeOwnerOnly(expansion, Buffer.from(expansionMarker, 'utf8'));
  const oldSeconds = Math.floor(nowSeconds - 7_200);
  fs.utimesSync(expansion, oldSeconds, oldSeconds);
  return { route, expansion, expansionMarker };
}

function removeProducerFile(file) {
  const stat = lstatNoSymlink(file, file, true);
  if (stat === null) return;
  assert(stat.isFile() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    `refusing to remove unsafe producer file: ${path.basename(file)}`);
  fs.unlinkSync(file);
}

function resetStores(files, nowSeconds) {
  removeProducerFile(files.route);
  removeProducerFile(files.expansion);
  return seedStores(path.dirname(files.route), nowSeconds);
}

function fileSnapshot(file) {
  const stat = lstatNoSymlink(file, file);
  return {
    bytes: fs.readFileSync(file),
    mode: stat.mode & 0o777,
    mtimeMs: stat.mtimeMs,
    inode: stat.ino
  };
}

function sameSnapshot(left, right) {
  return left.mode === right.mode && left.mtimeMs === right.mtimeMs && left.inode === right.inode
    && left.bytes.length === right.bytes.length && crypto.timingSafeEqual(left.bytes, right.bytes);
}

function inventoryMetadata(result) {
  assertObject(result, 'inventory response');
  assert(Array.isArray(result.stores), 'inventory response stores missing');
  const stores = result.stores.map((entry) => {
    assertObject(entry, 'inventory store');
    assert(P40_STORES.includes(entry.store), 'inventory returned an unsupported store');
    assert(['absent', 'ready', 'blocked'].includes(entry.state), 'inventory returned an invalid state');
    assert(Number.isSafeInteger(entry.bytes) && entry.bytes >= 0, 'inventory returned invalid byte count');
    assert(typeof entry.reason === 'string' && !entry.reason.includes('/'), 'inventory reason is not metadata-only');
    return { store: entry.store, state: entry.state, bytes: entry.bytes };
  }).sort((left, right) => left.store.localeCompare(right.store));
  assert(stores.length === P40_STORES.length && stores.every((entry, index) => entry.store === [...P40_STORES].sort()[index]),
    'inventory did not cover both supported stores');
  return stores;
}

function assertStores(result, label) {
  assert(Array.isArray(result.stores), `${label} stores missing`);
  assert([...result.stores].sort().join(',') === [...P40_STORES].sort().join(','), `${label} stores mismatch`);
}

function assertRouteIds(file, expectedIds) {
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean);
  const ids = lines.map((line) => {
    const value = JSON.parse(line);
    assert(typeof value.id === 'string' && Number.isFinite(value.occurredAt), 'retained route entry is malformed');
    return value.id;
  });
  assert(ids.length === expectedIds.length && expectedIds.every((id) => ids.includes(id)), 'route retention result mismatch');
}

function validRules() {
  return P40_STORES.map((store) => ({ store, maxAgeSeconds: 3_600, maxBytes: 65_536 }));
}

function assertRules(actual, expected, label) {
  assert(Array.isArray(actual) && actual.length === expected.length, `${label} rule count mismatch`);
  for (const rule of expected) {
    const found = actual.find((candidate) => candidate.store === rule.store);
    assert(found && found.maxAgeSeconds === rule.maxAgeSeconds && found.maxBytes === rule.maxBytes,
      `${label} rule mismatch for ${rule.store}`);
  }
}

function atomicJSON(file, value) {
  assert(lstatNoSymlink(file, `evidence file ${path.basename(file)}`, true) === null,
    `refusing to overwrite existing evidence file: ${path.basename(file)}`);
  const temporary = `${file}.tmp-${process.pid}-${crypto.randomUUID()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
  fs.chmodSync(file, 0o600);
}

function assertNoSensitiveEvidence(root, passphrase) {
  const forbidden = [Buffer.from(passphrase, 'utf8')];
  const files = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(file);
      else if (entry.isFile() && entry.name !== TOKEN_FILENAME) files.push(file);
    }
  };
  visit(root);
  for (const file of files) {
    const bytes = fs.readFileSync(file);
    for (const needle of forbidden) assert(!bytes.includes(needle), 'passphrase persisted in producer output');
  }
}

function buildContract() {
  return {
    confirmationPhrase: P40_RETENTION_CONTRACT.confirmationPhrase,
    defaultRetentionRules: structuredClone(P40_DEFAULT_RETENTION_RULES),
    encryptedExport: true,
    exportFormatVersion: P40_RETENTION_CONTRACT.exportFormatVersion,
    maximumRetentionAgeSeconds: P40_RETENTION_CONTRACT.maximumRetentionAgeSeconds,
    maximumRetentionBytes: P40_RETENTION_CONTRACT.maximumRetentionBytes,
    minimumRetentionAgeSeconds: P40_RETENTION_CONTRACT.minimumRetentionAgeSeconds,
    minimumRetentionBytes: P40_RETENTION_CONTRACT.minimumRetentionBytes,
    retentionConfirmationPhrase: P40_RETENTION_CONTRACT.retentionConfirmationPhrase,
    rpcMethods: [...P40_RPC_METHODS],
    stores: [...P40_STORES]
  };
}

function buildSession(options, identity, packageVersion, manifestSha256, observations, runtime) {
  assertObject(runtime, 'P-40 observed runtime');
  assertObject(runtime.os, 'P-40 observed runtime os');
  assert(runtime.architecture === identity.architecture, 'P-40 observed architecture drifted');
  assert(runtime.desktop === identity.desktop, 'P-40 observed desktop drifted');
  assert(runtime.displayServer === identity.displayServer, 'P-40 observed display server drifted');
  assert(runtime.compositor === identity.compositor, 'P-40 observed compositor drifted');
  assert(runtime.os.id === identity.os.id, 'P-40 observed OS id drifted');
  assert(typeof runtime.os.versionId === 'string' && runtime.os.versionId.length > 0,
    'P-40 observed OS version/build identity is required');
  if (identity.os.versionId !== null) {
    assert(runtime.os.versionId === identity.os.versionId, 'P-40 observed OS version drifted');
  }
  const capture = {
    architecture: runtime.architecture,
    desktop: runtime.desktop,
    mode: 'installed-rpc',
    os: { ...runtime.os },
    platform: 'linux',
    session: runtime.displayServer
  };
  const session = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p40-live-session-v1',
    requirementId: 'P-40',
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: { runId: options.candidateRunId, artifactDigest: options.candidateArtifactDigest },
    capture,
    package: {
      architecture: identity.architecture,
      format: identity.packageFormat,
      installed: true,
      manifestSha256,
      source: 'signed-installed-candidate',
      version: packageVersion
    },
    desktop: { desktop: runtime.desktop, liveSession: true, session: runtime.displayServer },
    daemon: { installed: true, rpcMethods: [...P40_RPC_METHODS], running: true, source: 'installed-candidate-daemon' },
    contract: buildContract(),
    observations
  };
  validateP40LiveSession(session, {
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidateRunId: options.candidateRunId,
    candidateArtifactDigest: options.candidateArtifactDigest
  });
  return session;
}

async function runSession(options) {
  const { privacy } = ensureOutputRoot(options.outputRoot);
  const { identity } = verifyInstalledCandidate(options);
  const runtime = verifyDesktopSession(identity);
  const token = readOwnerOnlyToken(options.tokenFile);
  const support = path.dirname(options.tokenFile);
  assert(path.basename(options.tokenFile) === TOKEN_FILENAME, 'token file is not the daemon support token');
  assert(/(?:^|\/)openburnbar-p40-[0-9]+\/support$/u.test(support), 'support directory is not an isolated P-40 directory');
  ownerOnlyDirectory(support, 'daemon support directory');
  const route = path.join(support, ROUTE_FILENAME);
  const expansion = path.join(support, EXPANSION_FILENAME);
  assert(lstatNoSymlink(route, 'route store', true) === null, 'route store already exists; refusing to mutate existing data');
  assert(lstatNoSymlink(expansion, 'text expansion store', true) === null, 'text expansion store already exists; refusing to mutate existing data');
  const outside = path.join(options.outputRoot, 'p40-outside-sentinel');
  assert(lstatNoSymlink(outside, 'outside sentinel', true) === null, 'outside sentinel already exists');
  writeOwnerOnly(outside, Buffer.from(`outside-${crypto.randomUUID()}`, 'utf8'));
  const outsideSnapshot = fileSnapshot(outside);
  const now = Math.floor(Date.now() / 1000);
  let files = seedStores(support, now);
  let exportFile = path.join(options.outputRoot, 'privacy-export.obbsealed');
  let passphrase = '';
  activeTokenFile = options.tokenFile;
  try {
    const inventory = inventoryMetadata(await callRPC(options.socket, token, 'daemon.privacy.inventory'));
    assert(inventory.every((entry) => entry.state === 'ready' && entry.bytes > 0), 'seeded stores were not ready');
    atomicJSON(path.join(privacy, 'inventory.json'), { metadataOnly: true, stores: inventory });

    const preview = await callRPC(options.socket, token, 'daemon.privacy.deletion.preview', { stores: [...P40_STORES] });
    assertObject(preview, 'deletion preview response');
    assert(typeof preview.token === 'string' && preview.token.length >= 8, 'deletion preview token missing');
    assertStores(preview, 'deletion preview');
    assert(preview.confirmationPhrase === P40_RETENTION_CONTRACT.confirmationPhrase, 'confirmation phrase drifted');
    assert(await expectRPCError(options.socket, token, 'daemon.privacy.deletion.execute', {
      token: preview.token, stores: [...P40_STORES], confirmation: 'DELETE LOCAL DAT'
    }), 'invalid confirmation was accepted');
    assert(await expectRPCError(options.socket, token, 'daemon.privacy.deletion.execute', {
      token: preview.token, stores: ['proxy_route_log'], confirmation: P40_RETENTION_CONTRACT.confirmationPhrase
    }), 'changed deletion scope was accepted');

    fs.appendFileSync(route, Buffer.from('changed-after-preview', 'utf8'));
    assert(await expectRPCError(options.socket, token, 'daemon.privacy.deletion.execute', {
      token: preview.token, stores: [...P40_STORES], confirmation: P40_RETENTION_CONTRACT.confirmationPhrase
    }), 'changed deletion file was accepted');
    files = resetStores(files, Math.floor(Date.now() / 1000));

    const expiryPreview = await callRPC(options.socket, token, 'daemon.privacy.deletion.preview', { stores: [...P40_STORES] });
    const expiryMs = dateMilliseconds(expiryPreview.expiresAt);
    assert(Number.isFinite(expiryMs), 'deletion preview expiry is invalid');
    await new Promise((resolve) => setTimeout(resolve, Math.max(0, expiryMs - Date.now() + EXPIRY_SAFETY_MS)));
    const expiredPreviewRejected = await expectRPCError(options.socket, token, 'daemon.privacy.deletion.execute', {
      token: expiryPreview.token, stores: [...P40_STORES], confirmation: P40_RETENTION_CONTRACT.confirmationPhrase
    });
    assert(expiredPreviewRejected, 'expired deletion preview was accepted');

    const validPreview = await callRPC(options.socket, token, 'daemon.privacy.deletion.preview', { stores: [...P40_STORES] });
    const firstDelete = await callRPC(options.socket, token, 'daemon.privacy.deletion.execute', {
      token: validPreview.token, stores: [...P40_STORES], confirmation: P40_RETENTION_CONTRACT.confirmationPhrase
    });
    assertStores(firstDelete, 'deletion execute');
    const secondDelete = await callRPC(options.socket, token, 'daemon.privacy.deletion.execute', {
      token: validPreview.token, stores: [...P40_STORES], confirmation: P40_RETENTION_CONTRACT.confirmationPhrase
    });
    assert(secondDelete.idempotent === true, 'deletion execute was not idempotent');
    assert(lstatNoSymlink(route, 'deleted route store', true) === null && lstatNoSymlink(expansion, 'deleted expansion store', true) === null,
      'deletion did not remove selected stores');
    assert(sameSnapshot(outsideSnapshot, fileSnapshot(outside)), 'outside sentinel changed');
    const deletion = {
      changedPreviewRejected: true,
      confirmationExact: true,
      evidencePaths: ['privacy/deletion.json'],
      expiredPreviewRejected: true,
      idempotent: true,
      noAbsolutePaths: true,
      noContentsReturned: true,
      outsidePathUntouched: true,
      previewScopeBound: true,
      selectedScope: true
    };
    atomicJSON(path.join(privacy, 'deletion.json'), { checks: deletion });

    files = seedStores(support, Math.floor(Date.now() / 1000));
    passphrase = `p40-${crypto.randomBytes(24).toString('base64url')}`;
    assert(lstatNoSymlink(exportFile, 'export output', true) === null, 'export output already exists');
    const exported = await callRPC(options.socket, token, 'daemon.privacy.export', {
      stores: [...P40_STORES], destinationPath: exportFile, passphrase
    });
    assertStores(exported, 'privacy export');
    assert(exported.formatVersion === P40_RETENTION_CONTRACT.exportFormatVersion, 'export format version drifted');
    const exportStat = lstatNoSymlink(exportFile, 'privacy export');
    const exportBytes = fs.readFileSync(exportFile);
    assert(exportStat.isFile() && exportStat.uid === process.getuid?.() && (exportStat.mode & 0o777) === 0o600,
      'privacy export is not owner-only');
    assert(exportBytes.length > 7 && exportBytes.subarray(0, 7).equals(Buffer.from('OBBPRIV', 'utf8')) && exportBytes[7] === 1,
      'privacy export header is invalid');
    const routeMarker = fs.readFileSync(files.route);
    const expansionMarker = Buffer.from(files.expansionMarker, 'utf8');
    assert(!exportBytes.includes(routeMarker) && !exportBytes.includes(expansionMarker),
      'privacy export contains plaintext store bytes');
    assertNoSensitiveEvidence(options.outputRoot, passphrase);
    assertNoSensitiveEvidence(support, passphrase);
    const exportObservation = {
      encrypted: true,
      evidencePaths: ['privacy/export.json'],
      formatVersion: 1,
      noPlaintextOnDisk: true,
      ownerOnlyPermissions: true,
      passphraseNotPersisted: true,
      selectedScope: true
    };
    atomicJSON(path.join(privacy, 'export.json'), { checks: exportObservation });
    removeProducerFile(exportFile);
    files = resetStores(files, Math.floor(Date.now() / 1000));

    const statusBefore = await callRPC(options.socket, token, 'daemon.privacy.retention.status');
    assertObject(statusBefore, 'retention status response');
    assert(statusBefore.policyState === 'defaults', 'retention policy was not at defaults before apply');
    assertRules(statusBefore.rules, P40_DEFAULT_RETENTION_RULES, 'default retention');
    const beforeInvalid = fileSnapshot(files.route);
    assert(await expectRPCError(options.socket, token, 'daemon.privacy.retention.apply', {
      rules: validRules(), confirmation: 'APPLY RETENTION POLIC'
    }), 'invalid retention confirmation was accepted');
    assert(await expectRPCError(options.socket, token, 'daemon.privacy.retention.apply', {
      rules: validRules().map((rule) => rule.store === 'proxy_route_log' ? { ...rule, maxAgeSeconds: 3_599 } : rule),
      confirmation: P40_RETENTION_CONTRACT.retentionConfirmationPhrase
    }), 'invalid retention bounds were accepted');
    assert(sameSnapshot(beforeInvalid, fileSnapshot(files.route)), 'invalid retention request mutated route store');

    const applied = await callRPC(options.socket, token, 'daemon.privacy.retention.apply', {
      rules: validRules(), confirmation: P40_RETENTION_CONTRACT.retentionConfirmationPhrase
    });
    assertObject(applied.status, 'retention apply status');
    assertRules(applied.status.rules, validRules(), 'applied retention');
    assertRouteIds(files.route, ['p40-fresh-route']);
    assert(lstatNoSymlink(files.expansion, 'aged expansion store', true) === null, 'aged expansion was not purged');

    const policy = path.join(support, 'privacy-retention-policy.json');
    const policyBeforeMalformed = fileSnapshot(policy);
    const malformedBytes = Buffer.from('not-json\n', 'utf8');
    rewriteOwnerOnly(files.route, malformedBytes);
    const malformedBefore = fileSnapshot(files.route);
    assert(await expectRPCError(options.socket, token, 'daemon.privacy.retention.apply', {
      rules: validRules(), confirmation: P40_RETENTION_CONTRACT.retentionConfirmationPhrase
    }), 'malformed route store was accepted');
    assert(sameSnapshot(malformedBefore, fileSnapshot(files.route)), 'malformed route store was mutated');
    assert(sameSnapshot(policyBeforeMalformed, fileSnapshot(policy)), 'malformed route apply changed the policy');
    const statusAfter = await callRPC(options.socket, token, 'daemon.privacy.retention.status');
    assertObject(statusAfter, 'final retention status response');
    const retention = {
      agedExpansionPurged: true,
      appliedRules: validRules(),
      defaultRules: structuredClone(P40_DEFAULT_RETENTION_RULES),
      evidencePaths: ['privacy/retention.json'],
      freshRouteRetained: true,
      invalidBoundsRejected: true,
      invalidConfirmationRejected: true,
      malformedStoreFailClosed: true,
      noMutationOnFailure: true,
      oldRoutePurged: true,
      statusObserved: true
    };
    atomicJSON(path.join(privacy, 'retention.json'), { checks: retention });

    const observations = {
      deletion,
      export: exportObservation,
      inventory: {
        evidencePaths: ['privacy/inventory.json'],
        metadataOnly: true,
        noAbsolutePaths: true,
        noContents: true,
        stores: inventory
      },
      retention
    };
    const session = buildSession(
      options,
      identity,
      options.packageVersion,
      options.manifestSha256,
      observations,
      runtime
    );
    atomicJSON(path.join(options.outputRoot, 'p40-live-session.json'), session);
    return session;
  } finally {
    activeTokenFile = null;
    // Only remove files created in the isolated support/output roots. The
    // preflight above refuses to run against an existing store.
    removeProducerFile(exportFile);
    removeProducerFile(outside);
    removeProducerFile(route);
    removeProducerFile(expansion);
    assertNoSensitiveEvidence(options.outputRoot, passphrase || 'unused-passphrase-not-used');
    assertNoSensitiveEvidence(support, passphrase || 'unused-passphrase-not-used');
  }
}

export {
  RPCError,
  buildSession,
  callRPC,
  environmentIdentity,
  normalizeArchitecture,
  parseArguments,
  queryInstalledPackage,
  runSession,
  verifyDesktopSession
};

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runSession(parseArguments(process.argv.slice(2)))
    .then(() => process.stdout.write('P-40 installed privacy RPC session captured\n'))
    .catch((error) => {
      process.stderr.write(`P-40 installed privacy RPC session failed: ${error.message}\n`);
      process.exitCode = 1;
    });
}
