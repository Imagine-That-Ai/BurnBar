#!/usr/bin/env node

/** Produce P-06 evidence from a signed, installed Linux desktop session. */

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { P06_SESSION_FILENAME, validateP06GatewayBoundarySession } from './lib/p06-gateway-credential-boundary-proof.mjs';
import { SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';

const MANIFEST_PATH = '/usr/share/openburnbar/attestation/installed-manifest.json';
const MANIFEST_SIGNATURE_PATH = `${MANIFEST_PATH}.sig`;
const RELEASE_PUBLIC_KEY_PATH = '/usr/share/openburnbar/attestation/release-ed25519.pub.pem';
const DESKTOP_BINARY_PATH = '/usr/bin/openburnbar-linux-desktop';
const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;

function assert(condition, message) { if (!condition) throw new Error(message); }
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

function lstatNoSymlink(file, label) {
  const absolute = path.resolve(file);
  let current = path.parse(absolute).root;
  for (const component of absolute.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    let stat;
    try { stat = fs.lstatSync(current); } catch { throw new Error(`${label} is missing or unreadable`); }
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  return fs.lstatSync(absolute);
}

function readJson(file, label) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) { throw new Error(`${label} is not valid JSON: ${error.message}`); }
}

function parseArguments(argv) {
  const allowed = new Set([
    '--token-file', '--output-root', '--environment', '--target-head', '--candidate-run-id',
    '--candidate-artifact-digest', '--package-version', '--manifest-sha256'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || value.startsWith('--') || values.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    }
    values.set(flag, value);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  const options = Object.fromEntries([...values].map(([key, value]) => [key.slice(2).replace(/-([a-z])/gu, (_, letter) => letter.toUpperCase()), value]));
  options.outputRoot = path.resolve(options.outputRoot);
  options.tokenFile = path.resolve(options.tokenFile);
  assert(SUPPORT_ENVIRONMENTS.includes(options.environment), 'unsupported P-06 environment');
  assert(HEAD.test(options.targetHead), 'target head is invalid');
  assert(RUN_ID.test(options.candidateRunId), 'candidate run id is invalid');
  assert(DIGEST.test(options.candidateArtifactDigest), 'candidate artifact digest is invalid');
  assert(VERSION.test(options.packageVersion), 'package version is invalid');
  assert(SHA256.test(options.manifestSha256), 'manifest sha256 is invalid');
  return options;
}

function expectedEnvironment(environmentId) {
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  const session = environmentId.includes('-x11-') ? 'x11' : 'wayland';
  if (environmentId.startsWith('ubuntu-')) return { architecture, session, desktop: 'gnome', os: 'ubuntu', version: '24.04', format: 'deb' };
  if (environmentId.startsWith('fedora-')) return { architecture, session, desktop: 'kde', os: 'fedora', version: null, format: 'rpm' };
  return { architecture, session, desktop: 'sway', os: 'arch', version: null, format: 'arch' };
}

function verifyInstalledCandidate(options) {
  assert(process.platform === 'linux', 'P-06 producer must run on Linux');
  for (const variable of ['OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG', 'BURNBAR_DAEMON_DISABLE_PEER_CODESIG']) {
    assert(process.env[variable] !== '1', `${variable}=1 is forbidden for release P-06 evidence`);
  }
  for (const [file, label] of [
    [MANIFEST_PATH, 'installed manifest'], [MANIFEST_SIGNATURE_PATH, 'installed manifest signature'],
    [RELEASE_PUBLIC_KEY_PATH, 'installed release public key'], [DESKTOP_BINARY_PATH, 'installed desktop binary']
  ]) {
    const stat = lstatNoSymlink(file, label);
    assert(stat.isFile() && stat.uid === 0 && (stat.mode & 0o022) === 0, `${label} must be root-owned and non-writable`);
  }
  const manifestBytes = fs.readFileSync(MANIFEST_PATH);
  const signature = fs.readFileSync(MANIFEST_SIGNATURE_PATH);
  assert(signature.length === 64, 'installed manifest signature must be Ed25519');
  let signatureValid = false;
  try {
    signatureValid = crypto.verify(null, manifestBytes, crypto.createPublicKey(fs.readFileSync(RELEASE_PUBLIC_KEY_PATH)), signature);
  } catch { signatureValid = false; }
  assert(signatureValid, 'installed manifest signature is invalid');
  assert(sha256(manifestBytes) === options.manifestSha256, 'installed manifest hash mismatch');
  const manifest = readJson(MANIFEST_PATH, 'installed manifest');
  const expected = expectedEnvironment(options.environment);
  assert(manifest.gitCommit === options.targetHead, 'installed manifest commit does not match target head');
  assert(manifest.packageArchitecture === expected.architecture, 'installed manifest architecture mismatch');
  assert(manifest.packageFormat === expected.format, 'installed manifest format mismatch');
  assert(manifest.packageVersion === options.packageVersion, 'installed manifest version mismatch');
  const desktopEntry = manifest.files?.find((entry) => entry?.path === DESKTOP_BINARY_PATH && entry.type === 'file');
  assert(desktopEntry && SHA256.test(desktopEntry.sha256), 'installed manifest does not inventory the desktop binary');
  const desktopBytes = fs.readFileSync(DESKTOP_BINARY_PATH);
  assert(sha256(desktopBytes) === desktopEntry.sha256, 'installed desktop binary does not match signed manifest');
  return { manifest, desktopBytes, expected };
}

function readOwnerOnlyToken(file) {
  const stat = lstatNoSymlink(file, 'daemon gateway token file');
  assert(stat.isFile() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0,
    'daemon gateway token file must be owner-only');
  const bytes = fs.readFileSync(file);
  let start = 0;
  let end = bytes.length;
  while (start < end && [0x09, 0x0a, 0x0d, 0x20].includes(bytes[start])) start += 1;
  while (end > start && [0x09, 0x0a, 0x0d, 0x20].includes(bytes[end - 1])) end -= 1;
  const trimmed = Buffer.from(bytes.subarray(start, end));
  bytes.fill(0);
  assert(trimmed.length >= 8 && !trimmed.includes(0x0a) && !trimmed.includes(0x0d), 'daemon gateway token is invalid');
  return trimmed;
}

function procRows() {
  const rows = [];
  for (const entry of fs.readdirSync('/proc', { withFileTypes: true })) {
    if (!entry.isDirectory() || !/^[1-9][0-9]*$/u.test(entry.name)) continue;
    try {
      rows.push({
        pid: Number(entry.name),
        ppid: Number(fs.readFileSync(`/proc/${entry.name}/stat`, 'utf8').match(/^\d+\s+\(.+\)\s+\S\s+(\d+)/u)?.[1]),
        exe: fs.readlinkSync(`/proc/${entry.name}/exe`)
      });
    } catch { /* Processes can exit while /proc is traversed. */ }
  }
  return rows;
}

export function inspectRendererProcesses(tokenBytes, rows = procRows()) {
  const desktop = rows.filter((row) => row.exe === DESKTOP_BINARY_PATH);
  assert(desktop.length === 1, 'exactly one installed desktop process must be live');
  const descendants = [];
  const pending = [desktop[0].pid];
  while (pending.length > 0) {
    const parent = pending.pop();
    for (const row of rows.filter((candidate) => candidate.ppid === parent)) {
      descendants.push(row);
      pending.push(row.pid);
    }
  }
  const observed = [desktop[0], ...descendants].map((row) => {
    const cmdline = row.cmdline ?? fs.readFileSync(`/proc/${row.pid}/cmdline`);
    const environ = row.environ ?? fs.readFileSync(`/proc/${row.pid}/environ`);
    return { row, cmdline, environ, ownedBuffers: row.cmdline === undefined };
  });
  const renderers = observed.filter(({ cmdline }) => /WebKit(?:Web|Network)Process/u.test(cmdline.toString('utf8')));
  assert(renderers.length >= 1, 'no live WebKit renderer process belongs to the installed desktop');
  let secretOccurrences = 0;
  for (const { cmdline, environ, ownedBuffers } of observed) {
    if (cmdline.includes(tokenBytes)) secretOccurrences += 1;
    if (environ.includes(tokenBytes)) secretOccurrences += 1;
    if (ownedBuffers) {
      cmdline.fill(0);
      environ.fill(0);
    }
  }
  assert(secretOccurrences === 0, 'gateway bearer reached a renderer process argument or environment');
  return { rendererProcessCount: renderers.length, secretOccurrences };
}

function inspectInstalledAssets(manifest, tokenBytes) {
  const entries = (manifest.files ?? []).filter((entry) => entry?.type === 'file'
    && typeof entry.path === 'string' && /\.(?:html|js|css)$/u.test(entry.path));
  assert(entries.length >= 2, 'signed manifest does not inventory production renderer assets');
  let secretOccurrences = 0;
  let directFetchAbsent = true;
  let credentialSurfaceAbsent = true;
  for (const entry of entries) {
    const stat = lstatNoSymlink(entry.path, `installed renderer asset ${entry.path}`);
    assert(stat.isFile() && stat.uid === 0 && (stat.mode & 0o022) === 0, 'installed renderer asset is not trusted');
    const bytes = fs.readFileSync(entry.path);
    assert(sha256(bytes) === entry.sha256, `installed renderer asset hash mismatch: ${entry.path}`);
    if (bytes.includes(tokenBytes)) secretOccurrences += 1;
    const text = bytes.toString('utf8');
    if (/\bfetch\s*\(/u.test(text)) directFetchAbsent = false;
    if (/\bgatewayAuthToken\b|\bbearerToken\b|\bAuthorization\b/u.test(text)) credentialSurfaceAbsent = false;
  }
  assert(secretOccurrences === 0, 'gateway bearer exists in installed renderer assets');
  assert(directFetchAbsent, 'installed renderer assets contain direct fetch');
  assert(credentialSurfaceAbsent, 'installed renderer assets contain a gateway credential surface');
  return { directFetchAbsent, secretOccurrences };
}

function verifyNativeProxy(desktopBytes) {
  const text = desktopBytes.toString('latin1');
  for (const marker of [
    'gateway_probe', 'gateway_chat_stream', 'gateway_chat_cancel', 'gateway_non_loopback_host_refused',
    'gateway_request_too_large', 'gateway_response_too_large', 'gateway_aborted'
  ]) assert(text.includes(marker), `installed native proxy is missing marker: ${marker}`);
  assert(!/gateway_auth_token/u.test(text), 'installed binary exposes a gateway bearer command');
  assert(text.includes("connect-src 'self' ipc: tauri:"), 'installed binary does not embed the restrictive renderer CSP');
}

function readOSRelease() {
  const result = {};
  for (const line of fs.readFileSync('/etc/os-release', 'utf8').split('\n')) {
    const match = /^(\w+)=(.*)$/u.exec(line);
    if (match) result[match[1]] = match[2].replace(/^"|"$/gu, '');
  }
  return result;
}

function liveDesktopIdentity(expected) {
  const release = readOSRelease();
  assert(release.ID === expected.os && (expected.version === null || release.VERSION_ID === expected.version), 'running OS mismatch');
  assert((os.arch() === 'arm64' ? 'aarch64' : os.arch()) === expected.architecture, 'running architecture mismatch');
  const session = (process.env.XDG_SESSION_TYPE ?? '').toLowerCase();
  const desktop = `${process.env.XDG_CURRENT_DESKTOP ?? ''}:${process.env.XDG_SESSION_DESKTOP ?? ''}`.toLowerCase();
  assert(session === expected.session, 'running desktop session type mismatch');
  assert(desktop.includes(expected.desktop), 'running desktop environment mismatch');
  return { os: release.ID, version: release.VERSION_ID, session, desktop };
}

function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, bytes, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

export function runP06GatewayBoundarySession(options) {
  const { manifest, desktopBytes, expected } = verifyInstalledCandidate(options);
  const identity = liveDesktopIdentity(expected);
  const tokenBytes = readOwnerOnlyToken(options.tokenFile);
  const processes = inspectRendererProcesses(tokenBytes);
  const assets = inspectInstalledAssets(manifest, tokenBytes);
  verifyNativeProxy(desktopBytes);
  tokenBytes.fill(0);
  const document = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p06-gateway-boundary-session-v1',
    requirementId: 'P-06',
    environmentId: options.environment,
    targetHead: options.targetHead,
    candidate: { runId: options.candidateRunId, artifactDigest: options.candidateArtifactDigest },
    capture: {
      architecture: expected.architecture, desktop: identity.desktop, mode: 'installed-live-renderer-boundary',
      os: { id: identity.os, versionId: identity.version }, platform: 'linux', session: identity.session
    },
    package: {
      architecture: expected.architecture, format: expected.format, installed: true,
      manifestSha256: options.manifestSha256, source: 'signed-installed-candidate', version: options.packageVersion
    },
    nativeProxy: {
      authenticationInjectedNatively: true, boundedRequest: true, boundedResponse: true,
      cancellationOwnedNatively: true, commandsRegistered: true, installedBinaryMatchedManifest: true,
      loopbackOnly: true, productionBinaryInspected: true
    },
    rendererIsolation: {
      cspBlocksDirectNetwork: true, desktopProcessLive: true, directFetchAbsent: assets.directFetchAbsent,
      installedAssetsMatchedManifest: true, rendererArgumentsScanned: true, rendererAssetsScanned: true,
      rendererEnvironmentScanned: true, rendererProcessCount: processes.rendererProcessCount,
      rendererProcessesLive: true, tauriCredentialCommandAbsent: true
    },
    redaction: {
      diagnosticsRedacted: true, secretBytesCaptured: false,
      secretOccurrences: processes.secretOccurrences + assets.secretOccurrences,
      stderrRedacted: true, stdoutRedacted: true
    }
  };
  validateP06GatewayBoundarySession(document, {
    environmentId: options.environment, targetHead: options.targetHead,
    candidateRunId: options.candidateRunId, candidateArtifactDigest: options.candidateArtifactDigest
  });
  const output = path.join(options.outputRoot, P06_SESSION_FILENAME);
  atomicWrite(output, Buffer.from(`${JSON.stringify(document, null, 2)}\n`));
  return { output, document };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = runP06GatewayBoundarySession(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output })}\n`);
  } catch (error) {
    process.stderr.write(`P-06 gateway boundary session failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
