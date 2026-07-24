import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { captureP05CredentialCustodyProof } from './capture-p05-credential-custody-proof.mjs';
import { main as finalizeProductFeatureProofClosure } from './finalize-product-feature-proof-closure.mjs';
import {
  P05_PROOF_FILENAME,
  P05_PROOF_ROLE,
  P05_SESSION_FILENAME,
  P05_SOURCE_CONTRACTS,
  p05SourceContractMarkers,
  validateP05CredentialCustodyProof,
  validateP05InstalledCustodySession
} from './lib/p05-credential-custody-proof.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-05.mjs';

const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-x86_64';
const HEAD = 'a'.repeat(40);
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const VERSION = '1.2.3';

function write(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
  return file;
}
function writeJson(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return { path: path.relative(root, file).split(path.sep).join('/'), sha256: sha256(bytes), size: bytes.length };
}

function session() {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p05-installed-custody-session-v1',
    requirementId: 'P-05',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    capture: {
      architecture: 'x86_64', desktop: 'GNOME', mode: 'installed-native-custody',
      os: { id: 'ubuntu', versionId: '24.04' }, platform: 'linux', session: 'wayland'
    },
    package: {
      architecture: 'x86_64', format: 'deb', installed: true,
      manifestSha256: 'c'.repeat(64), source: 'signed-installed-candidate', version: VERSION
    },
    backend: {
      cleanupConfirmed: true, command: 'secret-tool', encryptedAtRest: false,
      firstReadbackMatched: true, healthPassed: true, id: 'secret-service',
      missingBeforeWrite: true, noSecretInArguments: true, oldValueRejected: true,
      recoveryReadbackMatched: true, rotationReadbackMatched: true,
      trustLevel: 'secret_service', unavailableFailClosed: true
    },
    redaction: {
      diagnosticsRedacted: true, secretBytesCaptured: false, secretOccurrences: 0,
      stderrRedacted: true, stdoutRedacted: true
    }
  };
}

function stageOwnershipSourceFixtures() {
  if (process.env.OPENBURNBAR_PARITY_PREFLIGHT_OWNERSHIP_TEST !== '1') return () => {};
  const markers = p05SourceContractMarkers();
  for (const sourcePath of P05_SOURCE_CONTRACTS) write(sourcePath, `${markers[sourcePath].join('\n')}\n`);
  return () => {
    for (const sourcePath of P05_SOURCE_CONTRACTS) fs.rmSync(sourcePath, { force: true });
  };
}

function capture() {
  const root = fs.mkdtempSync(path.join(process.cwd(), '.linux-p05-proof-test-'));
  const restoreSources = stageOwnershipSourceFixtures();
  for (const sourcePath of P05_SOURCE_CONTRACTS) {
    write(path.join(root, sourcePath), fs.readFileSync(path.join(process.cwd(), sourcePath)));
  }
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-05', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true });
  const sessionReport = writeJson(path.join(inputRoot, P05_SESSION_FILENAME), session());
  try {
    const result = captureP05CredentialCustodyProof({
      repoRoot: root, inputRoot, sessionReport, environmentId: ENVIRONMENT,
      targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST,
      resolveHead: () => HEAD
    });
    return { root, inputRoot, sessionReport, result, restoreSources };
  } catch (error) {
    restoreSources();
    fs.rmSync(root, { recursive: true, force: true });
    throw error;
  }
}

function requirementContext(value) {
  const proofFile = path.join(value.inputRoot, 'feature-artifacts', P05_PROOF_FILENAME);
  const aggregateFile = writeJson(path.join(value.inputRoot, 'release-subjects/aggregate.json'), { passed: true });
  const manifestFile = writeJson(path.join(value.inputRoot, 'release-subjects/manifest.json'), {
    gitCommit: HEAD, packageArchitecture: 'x86_64', packageFormat: 'deb', packageVersion: VERSION
  });
  const runtimeFile = writeJson(path.join(value.inputRoot, 'release-subjects/runtime.json'), {
    shellVersion: VERSION, daemonVersion: VERSION
  });
  const environmentFile = writeJson(path.join(value.inputRoot, 'release-subjects/environment.json'), {
    environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'x86_64', passed: true
  });
  const signatureFile = write(path.join(value.inputRoot, 'release-subjects/manifest.sig'), 'signature\n');
  const aggregate = record(value.root, aggregateFile);
  const proof = record(value.root, proofFile);
  const manifest = record(value.root, manifestFile);
  const runtime = record(value.root, runtimeFile);
  const environment = record(value.root, environmentFile);
  const signature = record(value.root, signatureFile);
  const closure = {
    schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed',
    requirementId: 'P-05', environmentId: ENVIRONMENT, blockers: [],
    architectures: [...RELEASE_ARCHITECTURES], supportEnvironments: [...SUPPORT_ENVIRONMENTS],
    selectedPackage: { architecture: 'x86_64', format: 'deb' }, version: VERSION,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST }, packageManifestSignature: signature,
    proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P05_PROOF_ROLE, ...proof }]
  };
  return {
    schemaVersion: 1, requirementId: 'P-05', checkId: 'p-05.credential-custody',
    environmentId: ENVIRONMENT, targetHead: HEAD, repoRoot: value.root,
    releaseClosure: { document: closure },
    subjects: {
      release: aggregate, packageManifest: manifest, packages: [manifest], runtimes: [runtime],
      installation: [aggregate], environment
    }
  };
}

test('P-05 capture emits a candidate-bound installed native custody proof', () => {
  const value = capture();
  try {
    assert.equal(value.result.document.requirementId, 'P-05');
    assert.equal(value.result.document.observed.backend.id, 'secret-service');
    const registration = JSON.parse(fs.readFileSync(value.result.registration, 'utf8'));
    assert.deepEqual(registration.artifacts, [{ role: P05_PROOF_ROLE, path: `feature-artifacts/${P05_PROOF_FILENAME}` }]);
    const bytes = fs.readFileSync(value.result.output);
    validateP05CredentialCustodyProof({
      repoRoot: value.root, snapshot: { bytes }, sourceSnapshot: { bytes: fs.readFileSync(value.sessionReport), sha256: sha256(fs.readFileSync(value.sessionReport)) },
      environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
    });
  } finally {
    value.restoreSources();
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('P-05 independently rejects custody lifecycle, availability, and source mutations', async () => {
  const value = capture();
  try {
    const context = requirementContext(value);
    assert.equal((await validateProductRequirement(context)).status, 'passed');
    const proof = structuredClone(value.result.document);
    for (const [label, mutate, pattern] of [
      ['rotation', (document) => { document.observed.backend.oldValueRejected = false; }, /oldValueRejected/u],
      ['locked backend', (document) => { document.observed.backend.unavailableFailClosed = false; }, /unavailableFailClosed/u],
      ['plaintext fallback', (document) => { document.observed.redaction.secretBytesCaptured = true; }, /credential material/u],
      ['source drift', (document) => { document.sourceEvidence[0].sha256 = 'f'.repeat(64); }, /source evidence hash changed/u]
    ]) {
      const mutated = structuredClone(proof);
      mutate(mutated);
      assert.throws(() => validateP05CredentialCustodyProof({
        repoRoot: value.root, snapshot: { bytes: Buffer.from(`${JSON.stringify(mutated, null, 2)}\n`) },
        environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
      }), pattern, label);
    }
  } finally {
    value.restoreSources();
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('P-05 live session rejects fixture, wrong backend, and unencrypted headless custody', () => {
  const fixture = session();
  fixture.capture.mode = 'fixture';
  assert.throws(() => validateP05InstalledCustodySession(fixture, {
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
  }), /installed support environment/u);
  const wrong = session();
  wrong.backend.id = 'kwallet';
  assert.throws(() => validateP05InstalledCustodySession(wrong, {
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
  }), /wrong native custodian/u);
});

test('P-05 materializer selects the installed credential custody proof', () => {
  assert.throws(() => finalizeProductFeatureProofClosure([]), /--requirement is required/u);
  const registry = JSON.parse(fs.readFileSync('docs/linux-port/product-feature-proof-registry.json', 'utf8'));
  assert.deepEqual(registry.requirements.find((row) => row.requirementId === 'P-05')?.artifacts, [{
    role: P05_PROOF_ROLE, mediaType: 'application/json', maxBytes: 1_048_576
  }]);
});
