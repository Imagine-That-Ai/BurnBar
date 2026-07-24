#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P05_BACKENDS,
  P05_SESSION_FILENAME,
  validateP05InstalledCustodySession
} from './lib/p05-credential-custody-proof.mjs';

const MANIFEST_PATH = '/usr/share/openburnbar/attestation/installed-manifest.json';
const INSTALLED_BINARIES = Object.freeze(['/usr/bin/openburnbar-linux-desktop', '/usr/bin/openburnbar-daemon', '/usr/bin/openburnbar-cli']);
const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;

function fail(message) { throw new Error(message); }
function assert(condition, message) { if (!condition) fail(message); }
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

function environmentContract(environmentId) {
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  if (environmentId.startsWith('ubuntu-')) return { architecture, format: 'deb', backend: P05_BACKENDS.gnome };
  if (environmentId.startsWith('fedora-')) return { architecture, format: 'rpm', backend: P05_BACKENDS.kde };
  if (environmentId === 'arch-sway-wayland-x86_64') return { architecture, format: 'arch', backend: P05_BACKENDS.sway };
  fail(`unsupported P-05 environment: ${environmentId}`);
}

function trustedExecutable(command) {
  for (const directory of ['/usr/bin', '/usr/local/bin', '/bin']) {
    const candidate = path.join(directory, command);
    try {
      const link = fs.lstatSync(candidate);
      const stat = fs.statSync(candidate);
      if (link.isFile() && !link.isSymbolicLink() && stat.uid === 0 && (stat.mode & 0o022) === 0
          && fs.accessSync(candidate, fs.constants.X_OK) === undefined) return candidate;
    } catch {
      // Optional native backend paths are evaluated below.
    }
  }
  fail(`P-05 requires trusted installed ${command}`);
}

function run(executable, args, { input = undefined, env = process.env } = {}) {
  const child = spawnSync(executable, args, {
    input,
    encoding: 'buffer',
    env,
    timeout: 15_000,
    maxBuffer: 64 * 1024
  });
  if (child.error) return { status: null, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) };
  return { status: child.status, stdout: child.stdout ?? Buffer.alloc(0), stderr: child.stderr ?? Buffer.alloc(0) };
}

function equalSecret(output, expected) {
  const normalized = Buffer.from(output.toString('utf8').replace(/\r?\n$/u, ''), 'utf8');
  const wanted = Buffer.from(expected, 'utf8');
  const matched = normalized.length === wanted.length && crypto.timingSafeEqual(normalized, wanted);
  normalized.fill(0);
  wanted.fill(0);
  return matched;
}

function nativeArguments(backend, operation, id) {
  if (backend.id === 'secret-service') {
    if (operation === 'health') return ['search', 'openburnbar-health', 'probe'];
    if (operation === 'read') return ['lookup', 'openburnbar-id', id, 'openburnbar-class', 'provider_credential'];
    if (operation === 'write') return ['store', '--label=OpenBurnBar provider_credential', 'openburnbar-id', id, 'openburnbar-class', 'provider_credential'];
    return ['clear', 'openburnbar-id', id, 'openburnbar-class', 'provider_credential'];
  }
  const wallet = process.env.OPENBURNBAR_KWALLET_NAME?.trim() || 'kdewallet';
  if (operation === 'health') return ['-l', wallet];
  if (operation === 'read') return ['-f', 'OpenBurnBar', '-r', id, wallet];
  if (operation === 'write') return ['-f', 'OpenBurnBar', '-w', id, wallet];
  return ['-f', 'OpenBurnBar', '-d', id, wallet];
}

function nativeMissing(result) {
  if (result.status === 0) return result.stdout.toString('utf8').trim().length === 0;
  const detail = Buffer.concat([result.stdout, result.stderr]).toString('utf8').toLowerCase();
  return /not found|no matching|no such entry|no such secret|no such item/u.test(detail);
}

export function runNativeCustodyProbe({ backend, outputRoot }) {
  const executable = trustedExecutable(backend.command);
  const id = `openburnbar-p05-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  const first = crypto.randomBytes(32).toString('base64url');
  const second = crypto.randomBytes(32).toString('base64url');
  const recovery = crypto.randomBytes(32).toString('base64url');
  const invokedArguments = [];
  const execute = (operation, input) => {
    const args = nativeArguments(backend, operation, id);
    invokedArguments.push(args);
    return run(executable, args, { input: input === undefined ? undefined : Buffer.from(`${input}\n`, 'utf8') });
  };
  try {
    const health = execute('health');
    const healthPassed = health.status === 0
      || (backend.id === 'secret-service' && nativeMissing(health));
    assert(healthPassed, 'native credential backend health check failed');
    const missingBeforeWrite = nativeMissing(execute('read'));
    assert(missingBeforeWrite, 'ephemeral P-05 credential already exists');
    assert(execute('write', first).status === 0, 'first credential write failed');
    const firstReadbackMatched = equalSecret(execute('read').stdout, first);
    assert(firstReadbackMatched, 'first credential readback failed');
    assert(execute('write', second).status === 0, 'credential rotation failed');
    const rotated = execute('read').stdout;
    const rotationReadbackMatched = equalSecret(rotated, second);
    const oldValueRejected = !equalSecret(rotated, first);
    assert(rotationReadbackMatched && oldValueRejected, 'credential rotation readback failed');
    assert(execute('delete').status === 0, 'credential cleanup failed');
    const cleanupConfirmed = nativeMissing(execute('read'));
    assert(cleanupConfirmed, 'credential cleanup was not confirmed');
    assert(execute('write', recovery).status === 0, 'credential recovery write failed');
    const recoveryReadbackMatched = equalSecret(execute('read').stdout, recovery);
    assert(recoveryReadbackMatched, 'credential recovery readback failed');
    assert(execute('delete').status === 0 && nativeMissing(execute('read')), 'credential recovery cleanup failed');
    const unavailable = run(executable, nativeArguments(backend, 'health', id), {
      env: { ...process.env, DBUS_SESSION_BUS_ADDRESS: `unix:path=${path.join(outputRoot, 'missing-session-bus')}` }
    });
    const unavailableFailClosed = unavailable.status !== 0;
    assert(unavailableFailClosed, 'native backend did not fail closed without its session bus');
    const noSecretInArguments = invokedArguments.flat().every((argument) =>
      argument !== first && argument !== second && argument !== recovery
    );
    return {
      cleanupConfirmed, command: backend.command, encryptedAtRest: false,
      firstReadbackMatched, healthPassed, id: backend.id, missingBeforeWrite,
      noSecretInArguments, oldValueRejected, recoveryReadbackMatched,
      rotationReadbackMatched, trustLevel: backend.trustLevel, unavailableFailClosed
    };
  } finally {
    run(executable, nativeArguments(backend, 'delete', id));
  }
}

export function runSystemdCustodyProbe({ backend, outputRoot }) {
  const executable = trustedExecutable(backend.command);
  const credentialName = `openburnbar-p05-${process.pid}`;
  const encrypted = path.join(outputRoot, `${credentialName}.cred`);
  const first = crypto.randomBytes(32).toString('base64url');
  const second = crypto.randomBytes(32).toString('base64url');
  const recovery = crypto.randomBytes(32).toString('base64url');
  const encrypt = (value) => {
    fs.rmSync(encrypted, { force: true });
    const result = run(executable, ['encrypt', `--name=${credentialName}`, '-', encrypted], { input: Buffer.from(`${value}\n`, 'utf8') });
    return result.status === 0;
  };
  const decrypt = () => run(executable, ['decrypt', `--name=${credentialName}`, encrypted, '-']);
  try {
    const healthPassed = run(executable, ['--version']).status === 0;
    const missingBeforeWrite = !fs.existsSync(encrypted);
    assert(healthPassed && missingBeforeWrite, 'systemd credential preflight failed');
    assert(encrypt(first), 'systemd credential encryption failed');
    const encryptedBytes = fs.readFileSync(encrypted);
    const encryptedAtRest = !encryptedBytes.includes(Buffer.from(first, 'utf8'));
    const firstReadbackMatched = equalSecret(decrypt().stdout, first);
    assert(encryptedAtRest && firstReadbackMatched, 'encrypted systemd credential readback failed');
    assert(encrypt(second), 'systemd credential rotation failed');
    const rotated = decrypt().stdout;
    const rotationReadbackMatched = equalSecret(rotated, second);
    const oldValueRejected = !equalSecret(rotated, first);
    fs.rmSync(encrypted, { force: true });
    const cleanupConfirmed = !fs.existsSync(encrypted);
    assert(encrypt(recovery), 'systemd credential recovery encryption failed');
    const recoveryReadbackMatched = equalSecret(decrypt().stdout, recovery);
    fs.rmSync(encrypted, { force: true });
    const unavailableFailClosed = decrypt().status !== 0;
    assert(rotationReadbackMatched && oldValueRejected && cleanupConfirmed
      && recoveryReadbackMatched && unavailableFailClosed, 'systemd credential lifecycle failed');
    return {
      cleanupConfirmed, command: backend.command, encryptedAtRest, firstReadbackMatched,
      healthPassed, id: backend.id, missingBeforeWrite, noSecretInArguments: true,
      oldValueRejected, recoveryReadbackMatched, rotationReadbackMatched,
      trustLevel: backend.trustLevel, unavailableFailClosed
    };
  } finally {
    fs.rmSync(encrypted, { force: true });
  }
}

function parseOsRelease() {
  return Object.fromEntries(fs.readFileSync('/etc/os-release', 'utf8').split('\n')
    .map((line) => line.match(/^([A-Z_]+)=(.*)$/u)).filter(Boolean)
    .map((match) => [match[1], match[2].replace(/^"|"$/gu, '')]));
}

function verifyInstalled(options) {
  assert(process.platform === 'linux', 'P-05 live producer must run on Linux');
  const contract = environmentContract(options.environmentId);
  for (const file of [MANIFEST_PATH, ...INSTALLED_BINARIES]) {
    const link = fs.lstatSync(file);
    const stat = fs.statSync(file);
    assert(link.isFile() && !link.isSymbolicLink() && stat.uid === 0 && (stat.mode & 0o022) === 0, `${file} is not an installed root-owned file`);
  }
  assert(sha256(fs.readFileSync(MANIFEST_PATH)) === options.manifestSha256, 'installed manifest digest does not match candidate');
  const observedArchitecture = process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch;
  assert(observedArchitecture === contract.architecture, 'installed host architecture does not match P-05 environment');
  return contract;
}

export function buildP05Session(options, backend, capture) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p05-installed-custody-session-v1',
    requirementId: 'P-05',
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    capture,
    package: {
      architecture: environmentContract(options.environmentId).architecture,
      format: environmentContract(options.environmentId).format,
      installed: true,
      manifestSha256: options.manifestSha256,
      source: 'signed-installed-candidate',
      version: options.packageVersion
    },
    backend,
    redaction: {
      diagnosticsRedacted: true,
      secretBytesCaptured: false,
      secretOccurrences: 0,
      stderrRedacted: true,
      stdoutRedacted: true
    }
  };
}

function parseArguments(argv) {
  const flags = new Set(['--output-root', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256']);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.has(argv[index]) || argv[index + 1] === undefined || values.has(argv[index])) fail(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) fail(`${flag} is required`);
  const result = {
    outputRoot: path.resolve(values.get('--output-root')),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'),
    manifestSha256: values.get('--manifest-sha256')
  };
  assert(HEAD.test(result.targetHead) && RUN_ID.test(result.candidateRunId) && DIGEST.test(result.candidateArtifactDigest), 'P-05 candidate binding is invalid');
  assert(VERSION.test(result.packageVersion) && SHA256.test(result.manifestSha256), 'P-05 package binding is invalid');
  return result;
}

export function runP05CredentialCustodySession(options) {
  const contract = verifyInstalled(options);
  fs.mkdirSync(options.outputRoot, { recursive: true, mode: 0o700 });
  const outputStat = fs.statSync(options.outputRoot);
  assert(outputStat.isDirectory() && outputStat.uid === process.getuid() && (outputStat.mode & 0o077) === 0, 'P-05 output root must be owner-only');
  const backend = contract.backend.id === 'systemd-credential'
    ? runSystemdCustodyProbe({ backend: contract.backend, outputRoot: options.outputRoot })
    : runNativeCustodyProbe({ backend: contract.backend, outputRoot: options.outputRoot });
  const release = parseOsRelease();
  const capture = {
    architecture: contract.architecture,
    desktop: process.env.XDG_CURRENT_DESKTOP ?? process.env.DESKTOP_SESSION ?? 'unknown',
    mode: 'installed-native-custody',
    os: { id: release.ID ?? 'unknown', versionId: release.VERSION_ID ?? 'unknown' },
    platform: 'linux',
    session: process.env.XDG_SESSION_TYPE ?? 'unknown'
  };
  const document = buildP05Session(options, backend, capture);
  validateP05InstalledCustodySession(document, options);
  const output = path.join(options.outputRoot, P05_SESSION_FILENAME);
  fs.writeFileSync(output, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  return { output, document };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = runP05CredentialCustodySession(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output })}\n`);
  } catch (error) {
    process.stderr.write(`P-05 installed custody session failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
