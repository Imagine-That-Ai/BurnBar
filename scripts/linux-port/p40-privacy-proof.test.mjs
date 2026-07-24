import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { captureP40PrivacyProof } from './capture-p40-privacy-proof.mjs';
import { main as finalizeProductFeatureProofClosure } from './finalize-product-feature-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-40.mjs';
import {
  P40_DEFAULT_RETENTION_RULES,
  P40_PROOF_FILENAME,
  P40_PROOF_ROLE,
  P40_RETENTION_CONTRACT,
  P40_RPC_METHODS,
  P40_SOURCE_CONTRACTS,
  P40_STORES,
  parseP40Json,
  sourceContractMarkers,
  validateP40LiveSession,
  validateP40PrivacyProof
} from './lib/p40-privacy-proof.mjs';

const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-x86_64';
const HEAD = 'a'.repeat(40);
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;

function write(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
  return file;
}

function writeJson(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}

function evidence() {
  return {
    inventory: ['privacy/inventory.json'],
    deletion: ['privacy/deletion.json'],
    export: ['privacy/export.json'],
    retention: ['privacy/retention.json']
  };
}

function session() {
  const paths = evidence();
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p40-live-session-v1',
    requirementId: 'P-40',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    capture: {
      architecture: 'x86_64',
      desktop: 'GNOME',
      mode: 'installed-rpc',
      os: { id: 'ubuntu', versionId: '24.04' },
      platform: 'linux',
      session: 'Wayland'
    },
    package: {
      architecture: 'x86_64',
      format: 'deb',
      installed: true,
      manifestSha256: 'c'.repeat(64),
      source: 'signed-installed-candidate',
      version: '1.2.3'
    },
    desktop: { desktop: 'GNOME', liveSession: true, session: 'Wayland' },
    daemon: { installed: true, rpcMethods: [...P40_RPC_METHODS], running: true, source: 'installed-candidate-daemon' },
    contract: {
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
    },
    observations: {
      inventory: {
        evidencePaths: paths.inventory,
        metadataOnly: true,
        noAbsolutePaths: true,
        noContents: true,
        stores: P40_STORES.map((store) => ({ bytes: 0, state: 'absent', store }))
      },
      deletion: {
        changedPreviewRejected: true,
        confirmationExact: true,
        evidencePaths: paths.deletion,
        expiredPreviewRejected: true,
        idempotent: true,
        noAbsolutePaths: true,
        noContentsReturned: true,
        outsidePathUntouched: true,
        previewScopeBound: true,
        selectedScope: true
      },
      export: {
        encrypted: true,
        evidencePaths: paths.export,
        formatVersion: 1,
        noPlaintextOnDisk: true,
        ownerOnlyPermissions: true,
        passphraseNotPersisted: true,
        selectedScope: true
      },
      retention: {
        agedExpansionPurged: true,
        appliedRules: [
          { store: 'proxy_route_log', maxAgeSeconds: 3_600, maxBytes: 65_536 },
          { store: 'text_expansion_store', maxAgeSeconds: 3_600, maxBytes: 65_536 }
        ],
        defaultRules: structuredClone(P40_DEFAULT_RETENTION_RULES),
        evidencePaths: paths.retention,
        freshRouteRetained: true,
        invalidBoundsRejected: true,
        invalidConfirmationRejected: true,
        malformedStoreFailClosed: true,
        noMutationOnFailure: true,
        oldRoutePurged: true,
        statusObserved: true
      }
    }
  };
}

function subject() {
  const root = fs.mkdtempSync(path.join(process.cwd(), '.linux-p40-proof-test-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-40', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true });
  const report = path.join(inputRoot, 'p40-live-session.json');
  writeJson(report, session());
  for (const evidencePath of Object.values(evidence()).flat()) write(path.join(inputRoot, evidencePath), 'installed evidence\n');
  return { root, inputRoot, report };
}

function stageOwnershipSourceFixtures() {
  // The certification preflight intentionally archives only evidence tooling;
  // stage marker-only source files there so this ownership test can exercise the
  // producer without turning the preflight into a product-evidence shortcut.
  if (process.env.OPENBURNBAR_PARITY_PREFLIGHT_OWNERSHIP_TEST !== '1') return () => {};
  const markers = sourceContractMarkers();
  for (const sourcePath of P40_SOURCE_CONTRACTS) {
    write(sourcePath, `${markers[sourcePath].join('\n')}\n`);
  }
  return () => {
    for (const sourcePath of P40_SOURCE_CONTRACTS) fs.rmSync(sourcePath, { force: true });
  };
}

function capture() {
  const value = subject();
  const restoreSources = stageOwnershipSourceFixtures();
  try {
    const result = captureP40PrivacyProof({
      repoRoot: process.cwd(),
      inputRoot: value.inputRoot,
      sessionReport: value.report,
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      resolveHead: () => HEAD
    });
    return { ...value, result, restoreSources };
  } catch (error) {
    restoreSources();
    fs.rmSync(value.root, { recursive: true, force: true });
    throw error;
  }
}

function proofSnapshot(value) {
  const file = path.join(value.inputRoot, 'feature-artifacts', P40_PROOF_FILENAME);
  const bytes = fs.readFileSync(file);
  return {
    path: file,
    bytes,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  };
}

test('P-40 capture emits a candidate-bound installed privacy proof', () => {
  const value = capture();
  try {
    assert.equal(value.result.document.requirementId, 'P-40');
    assert.equal(value.result.document.role, P40_PROOF_ROLE);
    assert.equal(value.result.document.capture.mode, 'installed-rpc');
    assert.deepEqual(value.result.document.daemon.rpcMethods, [...P40_RPC_METHODS]);
    assert.equal(value.result.document.observations.retention.oldRoutePurged, true);
    assert.equal(value.result.document.observations.export.noPlaintextOnDisk, true);
    const registration = JSON.parse(fs.readFileSync(value.result.registration, 'utf8'));
    assert.deepEqual(registration.artifacts, [{ role: P40_PROOF_ROLE, path: `feature-artifacts/${P40_PROOF_FILENAME}` }]);
    validateP40PrivacyProof({
      repoRoot: process.cwd(),
      snapshot: proofSnapshot(value),
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    });
  } finally {
    value.restoreSources();
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('P-40 capture fails closed for stale heads and missing installed evidence', () => {
  const value = subject();
  try {
    assert.throws(() => captureP40PrivacyProof({
      repoRoot: process.cwd(), inputRoot: value.inputRoot, sessionReport: value.report,
      environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST, resolveHead: () => 'c'.repeat(40)
    }), /does not match checkout HEAD/u);
    fs.rmSync(path.join(value.inputRoot, 'privacy/export.json'));
    assert.throws(() => captureP40PrivacyProof({
      repoRoot: process.cwd(), inputRoot: value.inputRoot, sessionReport: value.report,
      environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST, resolveHead: () => HEAD
    }), /evidence artifact is missing/u);
    assert.equal(fs.existsSync(path.join(value.inputRoot, 'feature-proof-registration.json')), false);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('P-40 independently rejects an installed privacy proof with a substituted retention contract', async () => {
  await assert.rejects(() => validateProductRequirement({}), /requirement release closure/u);
  const value = capture();
  try {
    const snapshot = proofSnapshot(value);
    const document = parseP40Json(snapshot.bytes, 'proof');
    for (const [name, mutate, pattern] of [
      ['retention confirmation', (proof) => { proof.contract.retentionConfirmationPhrase = 'APPLY EVERYTHING'; }, /contract constants/u],
      ['old data retention', (proof) => { proof.observations.retention.oldRoutePurged = false; }, /P-40 retention oldRoutePurged/u],
      ['plaintext export', (proof) => { proof.observations.export.noPlaintextOnDisk = false; }, /P-40 export noPlaintextOnDisk/u],
      ['source evidence drift', (proof) => { proof.sourceEvidence[0].sha256 = 'f'.repeat(64); }, /source evidence hash changed/u],
      ['candidate substitution', (proof) => { proof.candidate.artifactDigest = `sha256:${'f'.repeat(64)}`; }, /candidate artifact digest/u]
    ]) {
      const mutated = structuredClone(document);
      mutate(mutated);
      assert.throws(() => validateP40PrivacyProof({
        repoRoot: process.cwd(),
        snapshot: { ...snapshot, bytes: Buffer.from(`${JSON.stringify(mutated, null, 2)}\n`) },
        targetHead: HEAD,
        environmentId: ENVIRONMENT,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST
      }), pattern, name);
    }
  } finally {
    value.restoreSources();
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('P-40 live session contract rejects fixture mode and unsafe retention bounds', () => {
  const value = session();
  value.capture.mode = 'fixture';
  assert.throws(() => validateP40LiveSession(value, {
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
  }), /installed Linux session/u);
  const invalid = session();
  invalid.observations.retention.appliedRules[0].maxBytes = 1;
  assert.throws(() => validateP40LiveSession(invalid, {
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
  }), /safety bounds/u);
});

test('P-40 materializer selects the candidate-bound installed privacy proof', () => {
  assert.throws(() => finalizeProductFeatureProofClosure([]), /--requirement is required/u);
  const registry = JSON.parse(fs.readFileSync('docs/linux-port/product-feature-proof-registry.json', 'utf8'));
  const contract = registry.requirements.find((entry) => entry.requirementId === 'P-40');
  assert.deepEqual(contract?.artifacts, [{
    role: P40_PROOF_ROLE,
    mediaType: 'application/json',
    maxBytes: 1_048_576
  }]);
});
