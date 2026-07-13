#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import {
  PRODUCT_PROOF_CLOSURE_SCHEMA_VERSION,
  NATIVE_PACKAGE_TYPES,
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  atomicWriteJson,
  deriveReleaseAttestationSubjects,
  readRegularSnapshot,
  validateRecord
} from './lib/product-proof-closure.mjs';
import { snapshotFeatureProofRegistry } from './lib/product-feature-proof.mjs';
import { validateArchReleaseMetadata } from './lib/linux-arch-pkgbuild.mjs';

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function outputRecord(outputDir, snapshot) {
  const relative = path.relative(outputDir, snapshot.absolute).split(path.sep).join('/');
  if (relative === '..' || relative.startsWith('../') || path.posix.isAbsolute(relative)) {
    throw new Error(`proof subject is outside the Linux release output: ${snapshot.absolute}`);
  }
  return { path: relative, sha256: snapshot.sha256, size: snapshot.size };
}

function subject(repoRoot, outputDir, record, label) {
  return outputRecord(outputDir, validateRecord(repoRoot, record, label));
}

function localSubject(outputDir, relativePath, label) {
  return outputRecord(outputDir, readRegularSnapshot(outputDir, relativePath, label));
}

function requireManifestBinding(snapshot, { commit, version, architecture, format }, validateSchema) {
  const manifest = parseJson(snapshot, 'installed package manifest');
  if (!validateSchema(manifest)) {
    const detail = validateSchema.errors?.map((error) => `${error.instancePath || '/'} ${error.message}`).join('; ');
    throw new Error(`installed package manifest does not satisfy its canonical schema: ${detail ?? 'unknown error'}`);
  }
  if (manifest.gitCommit !== commit || manifest.packageVersion !== version
      || manifest.packageArchitecture !== architecture || manifest.packageFormat !== format
      || !manifest.files.some((entry) => entry?.path === '/usr/bin/openburnbar-daemon' && entry.type === 'file')
      || !manifest.files.some((entry) => entry?.path === '/usr/bin/openburnbar-linux-desktop' && entry.type === 'file')) {
    throw new Error(`installed package manifest is not bound to ${format}:${architecture}:${version}:${commit}`);
  }
  return manifest;
}

function verifyManifestSignature(manifest, signature, publicKey) {
  verifyDetachedSignature(manifest, signature, publicKey, 'installed package manifest');
}

function verifyDetachedSignature(subjectSnapshot, signature, publicKey, label) {
  if (signature.bytes.length !== 64) throw new Error(`${label} signature must be 64 bytes`);
  let key;
  try {
    key = crypto.createPublicKey(publicKey.bytes);
  } catch (error) {
    throw new Error(`release public key is invalid: ${error.message}`);
  }
  if (key.asymmetricKeyType !== 'ed25519'
      || !crypto.verify(null, subjectSnapshot.bytes, key, signature.bytes)) {
    throw new Error(`${label} signature does not verify with the release public key`);
  }
}

export function finalizeProductProofClosure({
  repoRoot = DEFAULT_ROOT,
  outputDir = path.join(repoRoot, '.linux-release'),
  targetHead = null
} = {}) {
  const realRoot = fs.realpathSync(repoRoot);
  const realOutput = fs.realpathSync(outputDir);
  const output = path.join(realOutput, 'product-proof-closure.json');
  fs.rmSync(output, { force: true });
  const packageClosureSnapshot = readRegularSnapshot(realRoot, path.relative(realRoot, path.join(realOutput, 'package-closure.json')).split(path.sep).join('/'), 'package closure');
  const packageClosure = parseJson(packageClosureSnapshot, 'package closure');
  const commit = targetHead ?? packageClosure?.git?.commit;
  if (packageClosure?.schemaVersion !== 3 || packageClosure?.stage !== 'candidate'
      || packageClosure?.git?.commit !== commit
      || packageClosure?.git?.dirty !== false || !Array.isArray(packageClosure?.blockers)
      || packageClosure.blockers.length !== 0) {
    throw new Error('package closure must be clean, passed, and bound to the target HEAD');
  }
  const version = packageClosure.version;
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/u.test(version ?? '')) {
    throw new Error('package closure has an invalid release version');
  }
  const publicKey = readRegularSnapshot(realRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem', 'release public key');
  const releaseManifest = parseJson(
    readRegularSnapshot(realRoot, 'packaging/linux/release-manifest.json', 'Linux release manifest'),
    'Linux release manifest'
  );
  if (!Array.isArray(releaseManifest.requiredArtifacts) || !Array.isArray(releaseManifest.supportedArchitectures)) {
    throw new Error('Linux release manifest does not declare required artifacts and architectures');
  }
  const manifestSchema = parseJson(
    readRegularSnapshot(
      realRoot,
      'packaging/linux/attestation/openburnbar-installed-manifest.schema.json',
      'installed package manifest schema'
    ),
    'installed package manifest schema'
  );
  const validateManifestSchema = new Ajv2020({ allErrors: true, strict: true }).compile(manifestSchema);
  const packageRows = [];
  const releaseArtifactRows = [];
  const packageKeys = new Set();
  const releaseArtifactKeys = new Set();
  for (const artifact of packageClosure.artifacts ?? []) {
    const format = String(artifact?.type ?? '').toLowerCase();
    const architecture = artifact.architecture;
    const key = `${format}:${architecture}`;
    if (!releaseManifest.requiredArtifacts.includes(format)
        || !RELEASE_ARCHITECTURES.includes(architecture) || releaseArtifactKeys.has(key)) {
      throw new Error(`invalid or duplicate release artifact row: ${key}`);
    }
    releaseArtifactKeys.add(key);
    const packageSnapshot = validateRecord(realRoot, artifact, `package ${key}`);
    const detachedSignatureSnapshot = readRegularSnapshot(
      realOutput,
      `sidecars/${path.basename(artifact.file)}.ed25519.sig`,
      `package Ed25519 signature ${key}`
    );
    const sigstoreSnapshot = readRegularSnapshot(
      realOutput,
      `${path.relative(realOutput, packageSnapshot.absolute).split(path.sep).join('/')}.sigstore.json`,
      `package Sigstore bundle ${key}`
    );
    verifyDetachedSignature(packageSnapshot, detachedSignatureSnapshot, publicKey, `release artifact ${key}`);
    releaseArtifactRows.push({
      type: format,
      architecture,
      artifact: outputRecord(realOutput, packageSnapshot),
      detachedSignature: outputRecord(realOutput, detachedSignatureSnapshot),
      sigstore: outputRecord(realOutput, sigstoreSnapshot)
    });
    if (!NATIVE_PACKAGE_TYPES.includes(format)) continue;
    packageKeys.add(key);
    const manifestSnapshot = validateRecord(realRoot, artifact.installedManifest, `installed manifest ${key}`);
    const signatureSnapshot = validateRecord(realRoot, artifact.installedManifestSignature, `installed manifest signature ${key}`);
    requireManifestBinding(
      manifestSnapshot,
      { commit, version, architecture, format },
      validateManifestSchema
    );
    verifyManifestSignature(manifestSnapshot, signatureSnapshot, publicKey);
    packageRows.push({
      format,
      architecture,
      artifact: outputRecord(realOutput, packageSnapshot),
      installedManifest: outputRecord(realOutput, manifestSnapshot),
      installedManifestSignature: outputRecord(realOutput, signatureSnapshot),
      detachedSignature: outputRecord(realOutput, detachedSignatureSnapshot),
      sigstore: outputRecord(realOutput, sigstoreSnapshot)
    });
  }
  const requiredPackageKeys = new Set(RELEASE_ARCHITECTURES.flatMap((architecture) =>
    NATIVE_PACKAGE_TYPES.map((format) => `${format}:${architecture}`)
  ));
  if (packageKeys.size !== requiredPackageKeys.size || [...requiredPackageKeys].some((key) => !packageKeys.has(key))) {
    throw new Error('release output must contain deb, rpm, and Arch installed-manifest closures for both architectures');
  }
  const requiredReleaseArtifactKeys = new Set(releaseManifest.requiredArtifacts.flatMap((type) =>
    RELEASE_ARCHITECTURES.map((architecture) => `${type}:${architecture}`)
  ));
  if (releaseArtifactKeys.size !== requiredReleaseArtifactKeys.size
      || [...requiredReleaseArtifactKeys].some((key) => !releaseArtifactKeys.has(key))) {
    throw new Error('release output does not contain the exact required artifact and architecture matrix');
  }

  const pkgbuildSnapshot = validateRecord(realRoot, packageClosure.sidecars?.archPkgbuild, 'Arch PKGBUILD');
  const archMetadataSnapshot = validateRecord(
    realRoot,
    packageClosure.sidecars?.archReleaseMetadata,
    'Arch release metadata'
  );
  validateArchReleaseMetadata({
    repoRoot: realRoot,
    pkgbuildSnapshot,
    metadataSnapshot: archMetadataSnapshot,
    version,
    gitCommit: commit,
    artifacts: packageClosure.artifacts
  });

  const attestationSubjects = deriveReleaseAttestationSubjects(
    packageClosure,
    releaseManifest.requiredArtifacts
  ).map((subjectRow) => {
    const subjectSnapshot = validateRecord(realRoot, subjectRow.record, `${subjectRow.role} attestation subject`);
    const subjectRelative = path.relative(realOutput, subjectSnapshot.absolute).split(path.sep).join('/');
    const bundleSnapshot = readRegularSnapshot(
      realOutput,
      `${subjectRelative}.sigstore.json`,
      `${subjectRow.role} Sigstore bundle`
    );
    return {
      role: subjectRow.role,
      ...(subjectRow.architecture ? { architecture: subjectRow.architecture } : {}),
      ...(subjectRow.type ? { format: subjectRow.type } : {}),
      subject: outputRecord(realOutput, subjectSnapshot),
      bundle: outputRecord(realOutput, bundleSnapshot)
    };
  });

  const proofs = [];
  const addSidecar = (role, key) => {
    const record = packageClosure.sidecars?.[key];
    if (!record) throw new Error(`package closure is missing required ${key} sidecar`);
    proofs.push({ role, ...subject(realRoot, realOutput, record, `${role} proof`) });
  };
  addSidecar('checksums', 'checksums');
  addSidecar('sbom', 'sbom');
  addSidecar('vex', 'vex');
  addSidecar('provenance', 'provenancePredicate');
  addSidecar('source-archive', 'sourceArchive');
  addSidecar('arch-pkgbuild', 'archPkgbuild');
  addSidecar('arch-release-metadata', 'archReleaseMetadata');
  addSidecar('architecture-sessions', 'architectureSessions');
  addSidecar('package-smoke', 'packageSmoke');
  addSidecar('update-feed', 'updateFeed');
  addSidecar('update-feed-signature', 'updateFeedSignature');
  verifyDetachedSignature(
    validateRecord(realRoot, packageClosure.sidecars.updateFeed, 'update feed'),
    validateRecord(realRoot, packageClosure.sidecars.updateFeedSignature, 'update feed signature'),
    publicKey,
    'update feed'
  );
  proofs.push({
    role: 'architecture-smoke',
    ...localSubject(realOutput, 'smoke/architecture-smoke-summary.json', 'architecture smoke proof')
  });
  const feed = subject(realRoot, realOutput, packageClosure.sidecars.updateFeed, 'update feed');
  proofs.push({
    role: 'update-feed-sigstore',
    ...localSubject(realOutput, `${feed.path}.sigstore.json`, 'update feed Sigstore proof')
  });
  for (const row of releaseArtifactRows) {
    proofs.push({ role: 'package-signature', architecture: row.architecture, format: row.type, ...row.detachedSignature });
    proofs.push({ role: 'package-sigstore', architecture: row.architecture, format: row.type, ...row.sigstore });
  }
  const seenProofs = new Set();
  for (const proof of proofs) {
    const key = `${proof.role}:${proof.architecture ?? '*'}:${proof.format ?? '*'}:${proof.path}`;
    if (seenProofs.has(key)) throw new Error(`duplicate product proof subject: ${key}`);
    seenProofs.add(key);
  }
  const featureProofRegistry = outputRecord(
    realOutput,
    snapshotFeatureProofRegistry(realRoot, realOutput)
  );
  const document = {
    schemaVersion: PRODUCT_PROOF_CLOSURE_SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    targetHead: commit,
    sourceCommit: commit,
    status: 'passed',
    stage: 'candidate',
    git: { commit, dirty: false },
    version,
    architectures: [...RELEASE_ARCHITECTURES],
    supportEnvironments: [...SUPPORT_ENVIRONMENTS],
    releaseArtifacts: releaseArtifactRows.sort((left, right) =>
      `${left.type}:${left.architecture}`.localeCompare(`${right.type}:${right.architecture}`)
    ),
    packages: packageRows.sort((left, right) => `${left.format}:${left.architecture}`.localeCompare(`${right.format}:${right.architecture}`)),
    featureProofRegistry,
    attestationSubjects,
    proofs: proofs.sort((left, right) => `${left.role}:${left.path}`.localeCompare(`${right.role}:${right.path}`)),
    blockers: []
  };
  atomicWriteJson(output, document);
  return { document, output };
}

function parseArguments(argv) {
  if (argv.length === 0) return {};
  if (argv.length !== 2 || argv[0] !== '--target-head' || !/^[a-f0-9]{40,64}$/u.test(argv[1])) {
    throw new Error('usage: finalize-product-proof-closure.mjs [--target-head <commit>]');
  }
  return { targetHead: argv[1] };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = finalizeProductProofClosure(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, status: result.document.status }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`product proof closure finalization failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
