import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { captureP06GatewayBoundaryProof } from './capture-p06-gateway-boundary-proof.mjs';
import {
  P06_PROOF_FILENAME,
  P06_PROOF_ROLE,
  P06_SESSION_FILENAME,
  P06_SOURCE_CONTRACTS,
  p06SourceContractMarkers,
  validateP06GatewayBoundaryProof,
  validateP06GatewayBoundarySession
} from './lib/p06-gateway-credential-boundary-proof.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-06.mjs';
import { inspectRendererProcesses } from './run-p06-gateway-boundary-session.mjs';

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
    id: 'openburnbar-linux-p06-gateway-boundary-session-v1',
    requirementId: 'P-06',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    capture: {
      architecture: 'x86_64', desktop: 'GNOME', mode: 'installed-live-renderer-boundary',
      os: { id: 'ubuntu', versionId: '24.04' }, platform: 'linux', session: 'wayland'
    },
    package: {
      architecture: 'x86_64', format: 'deb', installed: true,
      manifestSha256: 'c'.repeat(64), source: 'signed-installed-candidate', version: VERSION
    },
    nativeProxy: {
      authenticationInjectedNatively: true, boundedRequest: true, boundedResponse: true,
      cancellationOwnedNatively: true, commandsRegistered: true, installedBinaryMatchedManifest: true,
      loopbackOnly: true, productionBinaryInspected: true
    },
    rendererIsolation: {
      cspBlocksDirectNetwork: true, desktopProcessLive: true, directFetchAbsent: true,
      installedAssetsMatchedManifest: true, rendererArgumentsScanned: true, rendererAssetsScanned: true,
      rendererEnvironmentScanned: true, rendererProcessCount: 2, rendererProcessesLive: true,
      tauriCredentialCommandAbsent: true
    },
    redaction: {
      diagnosticsRedacted: true, secretBytesCaptured: false, secretOccurrences: 0,
      stderrRedacted: true, stdoutRedacted: true
    }
  };
}

function stageSources(root) {
  for (const sourcePath of P06_SOURCE_CONTRACTS) {
    write(path.join(root, sourcePath), fs.readFileSync(path.join(process.cwd(), sourcePath)));
  }
}

function stageOwnershipSourceFixtures() {
  if (process.env.OPENBURNBAR_PARITY_PREFLIGHT_OWNERSHIP_TEST !== '1') return () => {};
  const markers = p06SourceContractMarkers();
  for (const sourcePath of P06_SOURCE_CONTRACTS) write(sourcePath, `${markers[sourcePath].join('\n')}\n`);
  return () => { for (const sourcePath of P06_SOURCE_CONTRACTS) fs.rmSync(sourcePath, { force: true }); };
}

function capture() {
  const root = fs.mkdtempSync(path.join(process.cwd(), '.linux-p06-proof-test-'));
  const restoreSources = stageOwnershipSourceFixtures();
  stageSources(root);
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-06', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true });
  const sessionReport = writeJson(path.join(inputRoot, P06_SESSION_FILENAME), session());
  try {
    const result = captureP06GatewayBoundaryProof({
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
  const proofFile = path.join(value.inputRoot, 'feature-artifacts', P06_PROOF_FILENAME);
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
  return {
    schemaVersion: 1, requirementId: 'P-06', checkId: 'p-06.gateway-credential-boundary',
    environmentId: ENVIRONMENT, targetHead: HEAD, repoRoot: value.root,
    releaseClosure: { document: {
      schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed',
      requirementId: 'P-06', environmentId: ENVIRONMENT, blockers: [],
      architectures: [...RELEASE_ARCHITECTURES], supportEnvironments: [...SUPPORT_ENVIRONMENTS],
      selectedPackage: { architecture: 'x86_64', format: 'deb' }, version: VERSION,
      candidate: { runId: RUN_ID, artifactDigest: DIGEST }, packageManifestSignature: signature,
      proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P06_PROOF_ROLE, ...proof }]
    } },
    subjects: {
      release: aggregate, packageManifest: manifest, packages: [manifest], runtimes: [runtime],
      installation: [aggregate], environment
    }
  };
}

test('P-06 capture emits a candidate-bound installed renderer-boundary proof', () => {
  const value = capture();
  try {
    assert.equal(value.result.document.requirementId, 'P-06');
    const registration = JSON.parse(fs.readFileSync(value.result.registration, 'utf8'));
    assert.deepEqual(registration.artifacts, [{ role: P06_PROOF_ROLE, path: `feature-artifacts/${P06_PROOF_FILENAME}` }]);
    const sessionBytes = fs.readFileSync(value.sessionReport);
    validateP06GatewayBoundaryProof({
      repoRoot: value.root, snapshot: { bytes: fs.readFileSync(value.result.output) },
      sourceSnapshot: { bytes: sessionBytes, sha256: sha256(sessionBytes) }, environmentId: ENVIRONMENT,
      targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
    });
  } finally {
    value.restoreSources();
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('P-06 rejects credential exposure, renderer escape, native regression, and source drift', async () => {
  const value = capture();
  try {
    assert.equal((await validateProductRequirement(requirementContext(value))).status, 'passed');
    for (const [label, mutate, pattern] of [
      ['native auth removal', (document) => { document.observed.nativeProxy.authenticationInjectedNatively = false; }, /authenticationInjectedNatively/u],
      ['direct renderer network', (document) => { document.observed.rendererIsolation.directFetchAbsent = false; }, /directFetchAbsent/u],
      ['process token leak', (document) => { document.observed.redaction.secretOccurrences = 1; }, /credential material/u],
      ['missing renderer process', (document) => { document.observed.rendererIsolation.rendererProcessCount = 0; }, /live renderer process/u],
      ['source drift', (document) => { document.sourceEvidence[0].sha256 = 'f'.repeat(64); }, /source evidence hash changed/u]
    ]) {
      const mutated = structuredClone(value.result.document);
      mutate(mutated);
      assert.throws(() => validateP06GatewayBoundaryProof({
        repoRoot: value.root, snapshot: { bytes: Buffer.from(`${JSON.stringify(mutated, null, 2)}\n`) },
        environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
      }), pattern, label);
    }
  } finally {
    value.restoreSources();
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('P-06 session fails closed for fixture capture, unsigned package posture, and weak CSP', () => {
  for (const [mutate, pattern] of [
    [(document) => { document.capture.mode = 'fixture'; }, /installed support environment/u],
    [(document) => { document.package.source = 'local-build'; }, /signed installed candidate/u],
    [(document) => { document.rendererIsolation.cspBlocksDirectNetwork = false; }, /cspBlocksDirectNetwork/u]
  ]) {
    const document = session();
    mutate(document);
    assert.throws(() => validateP06GatewayBoundarySession(document, {
      environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
    }), pattern);
  }
});

test('P-06 renderer process inspection detects exact bearer propagation without recording it', () => {
  const token = Buffer.from('gateway-test-value-1234');
  const rows = [
    { pid: 10, ppid: 1, exe: '/usr/bin/openburnbar-linux-desktop', cmdline: Buffer.from('openburnbar'), environ: Buffer.from('HOME=/home/test') },
    { pid: 11, ppid: 10, exe: '/usr/lib/webkit/WebKitWebProcess', cmdline: Buffer.from('WebKitWebProcess'), environ: Buffer.from('HOME=/home/test') }
  ];
  assert.deepEqual(inspectRendererProcesses(token, rows), { rendererProcessCount: 1, secretOccurrences: 0 });
  rows[1].environ = Buffer.from(`HOME=/home/test\0VALUE=${token.toString('utf8')}`);
  assert.throws(() => inspectRendererProcesses(token, rows), /bearer reached a renderer process/u);
});
