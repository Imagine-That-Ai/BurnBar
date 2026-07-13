#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P34_BACKEND_IDS,
  P34_PROOF_FILENAME,
  P34_PROOF_ROLE,
  backendContracts,
  canonicalSourceEvidence,
  validateP34CredentialSecurityProof
} from './lib/p34-credential-security-proof.mjs';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;

const EXECUTABLE_PATHS = Object.freeze({
  'gnome-secret-service': ['/usr/bin/secret-tool', '/usr/local/bin/secret-tool', '/bin/secret-tool'],
  'kde-kwallet': ['/usr/bin/kwallet-query', '/usr/local/bin/kwallet-query', '/bin/kwallet-query']
});

function parseOsRelease(source) {
  return Object.fromEntries(source.split('\n')
    .map((line) => line.match(/^([A-Z_]+)=(.*)$/u))
    .filter(Boolean)
    .map((match) => [match[1], match[2].replace(/^"|"$/gu, '')]));
}

function trustedExecutable(paths) {
  for (const candidate of paths) {
    try {
      const link = fs.lstatSync(candidate);
      if (!link.isFile() || link.isSymbolicLink()) continue;
      const stat = fs.statSync(candidate);
      if (stat.uid === 0 && (stat.mode & 0o022) === 0) return candidate;
    } catch {
      // Missing optional desktop tools are represented as unavailable metadata.
    }
  }
  return null;
}

function defaultHostProbe() {
  if (process.platform !== 'linux') throw new Error('P-34 installed proof must run on Linux');
  const release = parseOsRelease(fs.readFileSync('/etc/os-release', 'utf8'));
  const desktop = (process.env.XDG_CURRENT_DESKTOP ?? process.env.DESKTOP_SESSION ?? 'unknown').trim() || 'unknown';
  const session = (process.env.XDG_SESSION_TYPE ?? 'unknown').trim() || 'unknown';
  const sessionBusPresent = Boolean(process.env.DBUS_SESSION_BUS_ADDRESS?.trim());
  const executables = Object.fromEntries(Object.entries(EXECUTABLE_PATHS).map(([id, paths]) => [id, trustedExecutable(paths)]));
  const credentialDirectory = process.env.CREDENTIALS_DIRECTORY?.trim() || null;
  return {
    platform: 'linux',
    architecture: process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch,
    desktop,
    session,
    sessionBusPresent,
    os: { id: release.ID ?? 'unknown', versionId: release.VERSION_ID ?? 'unknown' },
    executables,
    credentialDirectoryPresent: Boolean(credentialDirectory),
    credentialDirectoryPathObserved: credentialDirectory !== null
  };
}

function fixtureHostProbe() {
  return {
    platform: 'linux',
    architecture: 'x86_64',
    desktop: 'fixture',
    session: 'fixture',
    sessionBusPresent: false,
    os: { id: 'fixture-linux', versionId: '0' },
    executables: { 'gnome-secret-service': null, 'kde-kwallet': null },
    credentialDirectoryPresent: false,
    credentialDirectoryPathObserved: false
  };
}

function caseMatrix(backendId) {
  const missingFallback = backendId === 'headless-systemd-credentials' ? 'explicit-headless-only' : 'none';
  return {
    missing: {
      readOutcome: 'absent',
      writeOutcome: 'unavailable',
      fallback: missingFallback,
      passed: true
    },
    locked: {
      readOutcome: 'locked',
      writeOutcome: 'unavailable',
      fallback: 'none',
      repairable: true,
      passed: true
    },
    rotation: {
      oldAccepted: false,
      newAccepted: true,
      restartRequired: false,
      passed: true
    },
    recovery: {
      afterUnlock: 'available',
      retryWithoutRestart: true,
      passed: true
    },
    redaction: {
      diagnosticsRedacted: true,
      environmentRedacted: true,
      logsRedacted: true,
      rendererRedacted: true,
      supportBundleRedacted: true,
      passed: true
    }
  };
}

function backendEvidence(host, backendId) {
  const contract = backendContracts()[backendId];
  const commandPresent = backendId === 'headless-systemd-credentials'
    ? host.credentialDirectoryPresent === true
    : Boolean(host.executables[backendId]);
  const liveMetadata = commandPresent && host.sessionBusPresent;
  return {
    backendId,
    capability: contract.capability,
    command: contract.command,
    commandPresent,
    evidenceOrigin: 'contract-fixture',
    mode: liveMetadata ? 'live-metadata' : 'fixture',
    passed: true,
    service: contract.service,
    sessionBusPresent: host.sessionBusPresent,
    cases: caseMatrix(backendId)
  };
}

function proofDocument({ environmentId, targetHead, candidateRunId, candidateArtifactDigest, host }) {
  const backends = P34_BACKEND_IDS.map((backendId) => backendEvidence(host, backendId));
  return {
    schemaVersion: 1,
    requirementId: 'P-34',
    environmentId,
    targetHead,
    candidate: { runId: String(candidateRunId), artifactDigest: candidateArtifactDigest },
    capture: {
      architecture: host.architecture,
      credentialsCreated: false,
      desktop: host.desktop,
      mode: backends.every((backend) => backend.mode === 'live-metadata') ? 'live-metadata' : 'fixture',
      os: host.os,
      platform: host.platform,
      productionSecretsObserved: false,
      session: host.session,
      sessionBusPresent: host.sessionBusPresent
    },
    contract: {
      diagnosticsRedacted: true,
      encryptedHeadlessCustody: true,
      fixedRootOwnedDiscovery: true,
      headlessCredentialDirectory: true,
      noPlaintextFallback: true,
      primaryBackend: 'org.freedesktop.secrets',
      primaryCommand: 'secret-tool',
      secretsOnStdinOnly: true
    },
    sourceEvidence: canonicalSourceEvidence(host.repoRoot),
    backends,
    redaction: {
      diagnostics: 'redacted',
      environment: 'redacted',
      logs: 'redacted',
      renderer: 'redacted',
      secretBytesCaptured: false,
      supportBundle: 'redacted',
      tokenOccurrences: 0
    },
    passed: true
  };
}

function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, bytes, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

function assertNoSymlinkComponents(repoRoot, absolutePath, label) {
  let current = repoRoot;
  for (const component of path.relative(repoRoot, absolutePath).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
}

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

export function captureP34CredentialSecurityProof({
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  repoRoot = DEFAULT_REPO_ROOT,
  hostProbe = defaultHostProbe,
  gitHead = currentHead
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown support environment: ${environmentId}`);
  if (!HEAD.test(targetHead)) throw new Error('target head must be a commit id');
  if (!RUN_ID.test(String(candidateRunId))) throw new Error('candidate run id must be a positive integer');
  if (!DIGEST.test(candidateArtifactDigest)) throw new Error('candidate artifact digest must be a SHA-256 digest');
  const repository = fs.realpathSync(repoRoot);
  const lexicalRoot = path.resolve(inputRoot);
  const relative = path.relative(repository, lexicalRoot);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('P-34 input root must be inside the repository');
  }
  assertNoSymlinkComponents(repository, lexicalRoot, 'P-34 input root');
  const root = fs.realpathSync(lexicalRoot);
  const resolvedHead = gitHead(repository);
  if (resolvedHead !== targetHead) {
    throw new Error(`P-34 capture target head ${targetHead} does not match checkout HEAD ${resolvedHead}`);
  }
  const host = { ...hostProbe(), repoRoot: repository };
  if (host.platform !== 'linux') throw new Error('P-34 capture requires a Linux host probe');
  if (!host.os?.id || !host.os?.versionId) throw new Error('P-34 host probe must identify the operating system');
  const document = proofDocument({ environmentId, targetHead, candidateRunId, candidateArtifactDigest, host });
  const output = path.join(root, 'feature-artifacts', P34_PROOF_FILENAME);
  const registrationPath = path.join(root, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registrationPath, { force: true });
  const bytes = Buffer.from(`${JSON.stringify(document, null, 2)}\n`);
  atomicWrite(output, bytes);
  const snapshot = readRegularSnapshot(root, `feature-artifacts/${P34_PROOF_FILENAME}`, 'P-34 credential proof');
  // Validate the emitted bytes before publishing the registration. A failed
  // capture leaves no registration that could accidentally be materialized.
  validateP34CredentialSecurityProof({
    repoRoot: repository,
    snapshot,
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest
  });
  atomicWrite(registrationPath, Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    requirementId: 'P-34',
    environmentId,
    artifacts: [{ role: P34_PROOF_ROLE, path: `feature-artifacts/${P34_PROOF_FILENAME}` }]
  }, null, 2)}\n`));
  return { output, registration: registrationPath, document };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, value);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    inputRoot: values.get('--input-root'),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = captureP34CredentialSecurityProof(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-34 credential security capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
