#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  REQUIREMENT_RELEASE_CLOSURE_SCHEMA_VERSION,
  atomicWriteJson,
  environmentPackage,
  readRegularSnapshot,
  validateAggregateDocument,
  validateRecord
} from './lib/product-proof-closure.mjs';

const SUPPORTED_REQUIREMENTS = new Set(['P-01', 'P-03', 'P-04', 'P-37']);
const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PROOF_ROLES = Object.freeze({
  'P-01': new Set([
    'checksums', 'sbom', 'vex', 'provenance', 'source-archive',
    'update-feed', 'update-feed-signature', 'update-feed-sigstore',
    'release-artifact', 'release-public-key', 'package-signature', 'package-sigstore'
  ]),
  'P-03': new Set(['architecture-sessions', 'package-smoke']),
  'P-04': new Set(['architecture-sessions', 'architecture-smoke']),
  'P-37': new Set(['architecture-smoke'])
});

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function safeName(index, role, sourcePath) {
  const roleName = role.replace(/[^a-z0-9-]/gu, '-');
  const basename = path.basename(sourcePath).replace(/[^A-Za-z0-9._-]/gu, '_');
  return `${String(index).padStart(2, '0')}-${roleName}-${basename}`;
}

function copySnapshot(snapshot, destination) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const descriptor = fs.openSync(destination, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, snapshot.bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  return { path: destination, sha256: snapshot.sha256 };
}

export function prepareProductRequirementInput({
  requirementId,
  environmentId,
  inputRoot,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  repoRoot = DEFAULT_REPO_ROOT
}) {
  if (!SUPPORTED_REQUIREMENTS.has(requirementId)) {
    throw new Error(`no release-proof materializer is registered for ${requirementId}`);
  }
  if (!/^[1-9][0-9]*$/u.test(String(candidateRunId ?? ''))
      || !/^sha256:[a-f0-9]{64}$/u.test(candidateArtifactDigest ?? '')) {
    throw new Error('candidate run id and artifact digest are required');
  }
  const expectedPackage = environmentPackage(environmentId);
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  const rootRelative = path.relative(repository, root);
  if (rootRelative === '..' || rootRelative.startsWith(`..${path.sep}`) || path.isAbsolute(rootRelative)) {
    throw new Error('product requirement input root must be inside the repository');
  }
  const subjectsDir = path.join(root, 'release-subjects');
  const output = path.join(root, 'release-closure.json');
  fs.rmSync(subjectsDir, { recursive: true, force: true });
  fs.rmSync(output, { force: true });
  const aggregateRelative = '.linux-release/product-proof-closure.json';
  const aggregateSnapshot = readRegularSnapshot(root, aggregateRelative, 'aggregate product proof closure');
  const aggregate = validateAggregateDocument(parseJson(aggregateSnapshot, 'aggregate product proof closure'));
  if (aggregate.targetHead !== targetHead) throw new Error('aggregate product proof closure target does not match the requested HEAD');
  const packageRow = aggregate.packages.find((row) =>
    row.format === expectedPackage.format && row.architecture === expectedPackage.architecture
  );
  if (!packageRow) throw new Error('aggregate product proof closure has no package for this environment');
  const aggregateRoot = path.dirname(aggregateSnapshot.absolute);
  fs.mkdirSync(subjectsDir, { recursive: true });
  const packageSnapshot = validateRecord(aggregateRoot, packageRow.artifact, 'selected package artifact');
  const manifestSnapshot = validateRecord(aggregateRoot, packageRow.installedManifest, 'selected installed manifest');
  const manifestSignatureSnapshot = validateRecord(
    aggregateRoot,
    packageRow.installedManifestSignature,
    'selected installed manifest signature'
  );
  const packageDestination = path.join(subjectsDir, `installed-package${expectedPackage.format === 'deb' ? '.deb' : '.rpm'}`);
  const manifestDestination = path.join(subjectsDir, 'installed-manifest.json');
  const manifestSignatureDestination = path.join(subjectsDir, 'installed-manifest.json.sig');
  copySnapshot(packageSnapshot, packageDestination);
  copySnapshot(manifestSnapshot, manifestDestination);
  copySnapshot(manifestSignatureSnapshot, manifestSignatureDestination);
  const relative = (file) => path.relative(repository, file).split(path.sep).join('/');
  const proofRecords = [{
    role: 'aggregate-product-proof-closure',
    path: relative(aggregateSnapshot.absolute),
    sha256: aggregateSnapshot.sha256
  }];
  let proofIndex = 0;
  if (requirementId === 'P-01') {
    const publicKey = readRegularSnapshot(
      repository,
      'packaging/linux/openburnbar-linux-ed25519.pub.pem',
      'release public key'
    );
    const destination = path.join(subjectsDir, safeName(proofIndex, 'release-public-key', publicKey.path));
    proofIndex += 1;
    copySnapshot(publicKey, destination);
    proofRecords.push({ role: 'release-public-key', path: relative(destination), sha256: publicKey.sha256 });
    for (const row of aggregate.releaseArtifacts) {
      const snapshot = validateRecord(aggregateRoot, row.artifact, `release artifact ${row.type}:${row.architecture}`);
      const artifactDestination = path.join(subjectsDir, safeName(
        proofIndex,
        'release-artifact',
        row.artifact.path
      ));
      proofIndex += 1;
      copySnapshot(snapshot, artifactDestination);
      proofRecords.push({
        role: 'release-artifact',
        architecture: row.architecture,
        format: row.type,
        path: relative(artifactDestination),
        sha256: snapshot.sha256
      });
    }
  }
  for (const proof of aggregate.proofs) {
    if (!PROOF_ROLES[requirementId].has(proof.role)) continue;
    const snapshot = validateRecord(aggregateRoot, proof, `${proof.role} aggregate proof`);
    const destination = path.join(subjectsDir, safeName(proofIndex, proof.role, proof.path));
    proofIndex += 1;
    copySnapshot(snapshot, destination);
    proofRecords.push({
      role: proof.role,
      ...(proof.architecture ? { architecture: proof.architecture } : {}),
      ...(proof.format ? { format: proof.format } : {}),
      path: relative(destination),
      sha256: snapshot.sha256
    });
  }
  const closure = {
    schemaVersion: REQUIREMENT_RELEASE_CLOSURE_SCHEMA_VERSION,
    targetHead,
    sourceCommit: aggregate.sourceCommit,
    status: 'passed',
    requirementId,
    environmentId,
    version: aggregate.version,
    architectures: aggregate.architectures,
    supportEnvironments: aggregate.supportEnvironments,
    selectedPackage: expectedPackage,
    candidate: {
      runId: String(candidateRunId),
      artifactDigest: candidateArtifactDigest,
      productProofClosureSha256: aggregateSnapshot.sha256
    },
    packageManifest: {
      path: relative(manifestDestination),
      sha256: manifestSnapshot.sha256
    },
    packageManifestSignature: {
      path: relative(manifestSignatureDestination),
      sha256: manifestSignatureSnapshot.sha256
    },
    packages: [{ path: relative(packageDestination), sha256: packageSnapshot.sha256 }],
    proofs: proofRecords,
    blockers: []
  };
  atomicWriteJson(output, closure);
  return { closure, output };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--requirement', '--environment', '--input-root', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, value);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  if (!/^[a-f0-9]{40,64}$/u.test(values.get('--target-head'))) throw new Error('--target-head must be a commit id');
  return {
    requirementId: values.get('--requirement'),
    environmentId: values.get('--environment'),
    inputRoot: values.get('--input-root'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = prepareProductRequirementInput(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, requirementId: result.closure.requirementId }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`product requirement input preparation failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
