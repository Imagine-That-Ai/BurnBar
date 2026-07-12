#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  fileSize,
  gitInfo,
  manifestPath,
  readJson,
  reanchorEvidenceDir,
  relative,
  repoRoot,
  runStep,
  sha256,
  writeJson
} from './lib/linux-release-common.mjs';
import { validateFeedDocument } from './lib/linux-update-feed.mjs';
import { validateArchitectureShardSet } from './lib/linux-release-shards.mjs';
import {
  aggregateArchitectureLifecycle,
  validateArchitectureSessionSet
} from './lib/linux-package-session.mjs';
import {
  readShardAttestationSubject,
  validateAggregateInstalledManifest
} from './lib/linux-aggregate-installed-attestation.mjs';

const versionIndex = process.argv.indexOf('--version');
const channelIndex = process.argv.indexOf('--channel');
const candidate = process.argv.includes('--candidate');
const version = versionIndex >= 0 ? process.argv[versionIndex + 1]?.trim() : null;
const channel = channelIndex >= 0 ? process.argv[channelIndex + 1]?.trim() : 'prerelease';
const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release'));
const shardsDir = path.resolve(process.env.OPENBURNBAR_LINUX_SHARDS_DIR ?? path.join(repoRoot, '.linux-shards'));
const manifest = readJson(manifestPath);
const rawGit = gitInfo();
const generatedPrefixes = [relative(outDir), relative(shardsDir), relative(reanchorEvidenceDir)]
  .filter((value) => value && !value.startsWith('..'))
  .map((value) => `${value.replace(/\/$/, '')}/`);
const dirtyEntries = rawGit.dirtyEntries.filter((entry) => {
  const dirtyPath = entry.slice(3);
  return !generatedPrefixes.some((prefix) => dirtyPath.startsWith(prefix));
});
const git = { ...rawGit, dirty: dirtyEntries.length > 0, dirtyEntries };
const blockers = [];

if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version ?? '')) {
  blockers.push({ kind: 'version', message: 'Assembly requires --version with strict X.Y.Z semver.' });
}
if (!['stable', 'prerelease', 'nightly'].includes(channel)) {
  blockers.push({ kind: 'channel', message: 'Assembly channel must be stable, prerelease, or nightly.' });
}
if (git.dirty) {
  blockers.push({
    kind: 'dirty-worktree',
    message: 'Release assembly requires a clean checkout.',
    dirtyEntries: git.dirtyEntries.slice(0, 40)
  });
}

const releaseBaseUrl = validatedReleaseBaseUrl(
  process.env.OPENBURNBAR_LINUX_RELEASE_BASE_URL
    ?? `https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v${version ?? 'invalid'}`
);
if (!releaseBaseUrl) {
  blockers.push({ kind: 'release-base-url', message: 'Release asset base URL is not an allowlisted HTTPS origin.' });
}

const logsDir = path.join(outDir, 'logs');
const artifactsDir = path.join(outDir, 'artifacts');
const installedManifestsDir = path.join(outDir, 'installed-manifests');
const sidecarsDir = path.join(outDir, 'sidecars');
const smokeDir = path.join(outDir, 'smoke');
for (const directory of [logsDir, artifactsDir, installedManifestsDir, sidecarsDir, smokeDir]) {
  fs.mkdirSync(directory, { recursive: true });
}

const shardFiles = findNamedFiles(shardsDir, 'architecture-closure.json');
const shardRows = [];
const shardDocuments = [];
const artifacts = [];
const seenArchitectures = new Set();
const seenArtifactKeys = new Set();
const seenArtifactNames = new Set();

for (const shardFile of shardFiles) {
  let shard;
  try {
    shard = readJson(shardFile);
  } catch (error) {
    blockers.push({ kind: 'shard-json', message: `Architecture shard is invalid JSON: ${shardFile}`, error: String(error) });
    continue;
  }
  const architecture = shard.architecture;
  shardDocuments.push(shard);
  if (shard.schemaVersion !== 1 || !manifest.supportedArchitectures.includes(architecture)) {
    blockers.push({ kind: 'shard-schema', message: `Architecture shard has an invalid schema or architecture: ${shardFile}` });
    continue;
  }
  if (seenArchitectures.has(architecture)) {
    blockers.push({ kind: 'duplicate-shard', message: `Duplicate architecture shard: ${architecture}` });
    continue;
  }
  seenArchitectures.add(architecture);
  if (shard.version !== version || shard.git?.commit !== git.commit || shard.git?.dirty === true) {
    blockers.push({ kind: 'shard-binding', message: `Shard ${architecture} does not bind to version ${version} and commit ${git.commit}.` });
  }
  if ((shard.blockers ?? []).length > 0) {
    blockers.push({ kind: 'shard-blockers', message: `Shard ${architecture} contains build blockers.`, blockers: shard.blockers });
  }
  const shardArtifactsDir = path.join(path.dirname(shardFile), 'artifacts');
  for (const artifact of shard.artifacts ?? []) {
    const key = `${artifact.type}:${artifact.architecture}`;
    if (artifact.architecture !== architecture || seenArtifactKeys.has(key)) {
      blockers.push({ kind: 'artifact-key', message: `Duplicate or mismatched shard artifact: ${key}` });
      continue;
    }
    seenArtifactKeys.add(key);
    const source = path.join(shardArtifactsDir, path.basename(artifact.file ?? ''));
    if (!fs.existsSync(source) || !fs.statSync(source).isFile()) {
      blockers.push({ kind: 'artifact-missing', message: `Shard artifact is missing: ${key}` });
      continue;
    }
    if (sha256(source) !== artifact.sha256 || fileSize(source) !== artifact.size) {
      blockers.push({ kind: 'artifact-drift', message: `Shard artifact hash or size drifted: ${key}` });
      continue;
    }
    const name = path.basename(source);
    if (seenArtifactNames.has(name)) {
      blockers.push({ kind: 'artifact-name', message: `Architecture artifacts collide on filename: ${name}` });
      continue;
    }
    seenArtifactNames.add(name);
    const destination = path.join(artifactsDir, name);
    fs.copyFileSync(source, destination);
    fs.chmodSync(destination, fs.statSync(source).mode & 0o777);
    const assembledArtifact = {
      type: artifact.type,
      architecture,
      file: relative(destination),
      size: fileSize(destination),
      sha256: sha256(destination)
    };
    if (['arch', 'deb', 'rpm'].includes(artifact.type)) {
      const manifestRecord = copyInstalledAttestationSubject({
        shardFile,
        record: artifact.installedManifest,
        destination: path.join(installedManifestsDir, `${name}.installed-manifest.json`),
        label: `${artifact.type}:${architecture} installed manifest`,
        blockers
      });
      const signatureRecord = copyInstalledAttestationSubject({
        shardFile,
        record: artifact.installedManifestSignature,
        destination: path.join(installedManifestsDir, `${name}.installed-manifest.json.sig`),
        label: `${artifact.type}:${architecture} installed manifest signature`,
        blockers
      });
      if (manifestRecord && signatureRecord) {
        try {
          validateAggregateInstalledManifest(fs.readFileSync(path.join(repoRoot, manifestRecord.file)), {
            architecture,
            format: artifact.type,
            version,
            commit: git.commit
          });
          assembledArtifact.installedManifest = manifestRecord;
          assembledArtifact.installedManifestSignature = signatureRecord;
        } catch (error) {
          blockers.push({
            kind: 'installed-manifest',
            message: `${artifact.type}:${architecture} installed manifest binding is invalid: ${error.message}`
          });
        }
      }
    }
    artifacts.push(assembledArtifact);
  }
  const smokeFile = findNamedFiles(path.dirname(shardFile), 'architecture-smoke.json')[0];
  let smoke = null;
  if (smokeFile) {
    try {
      smoke = readJson(smokeFile);
    } catch (error) {
      blockers.push({ kind: 'architecture-smoke-json', message: `Architecture smoke evidence is invalid for ${architecture}: ${error.message}` });
    }
  }
  if (!smoke || smoke.architecture !== architecture || smoke.passed !== true || smoke.failedCount !== 0) {
    blockers.push({ kind: 'architecture-smoke', message: `Native package smoke is not green for ${architecture}.` });
  }
  shardRows.push({ architecture, closure: relative(shardFile), smoke: smokeFile ? relative(smokeFile) : null });
}

for (const message of validateArchitectureShardSet({ manifest, shards: shardDocuments, version, commit: git.commit })) {
  blockers.push({ kind: 'shard-contract', message });
}

const sessionFiles = findNamedFiles(shardsDir, 'architecture-session.json');
const architectureSessions = [];
for (const sessionFile of sessionFiles) {
  try {
    architectureSessions.push(readJson(sessionFile));
  } catch (error) {
    blockers.push({ kind: 'architecture-session-json', message: `Architecture session is invalid JSON: ${sessionFile}`, error: String(error) });
  }
}
const architectureSessionFailures = validateArchitectureSessionSet({
  manifest,
  sessions: architectureSessions,
  version,
  commit: git.commit
});
for (const message of architectureSessionFailures) {
  blockers.push({ kind: 'architecture-session', message });
}
const architectureSessionFile = path.join(smokeDir, 'architecture-sessions.json');
writeJson(architectureSessionFile, {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  sessions: architectureSessions,
  failedCount: architectureSessionFailures.length,
  passed: architectureSessionFailures.length === 0
});
const packageLifecycle = aggregateArchitectureLifecycle({ manifest, sessions: architectureSessions });
const packageSmokeFile = path.join(smokeDir, 'package-smoke-summary.json');
writeJson(packageSmokeFile, {
  schemaVersion: 2,
  generatedAt: new Date().toISOString(),
  architectures: manifest.supportedArchitectures,
  ...packageLifecycle
});

const checksumsFile = path.join(sidecarsDir, `OpenBurnBar-${version}-linux-checksums.txt`);
fs.writeFileSync(
  checksumsFile,
  `${artifacts.map((artifact) => `${artifact.sha256}  ${artifact.file}`).join('\n')}\n`,
  'utf8'
);

const sourceFile = path.join(sidecarsDir, `OpenBurnBar-${version}-source-${git.commit.slice(0, 12)}.tar`);
const source = runStep('git', [
  'archive',
  '--format=tar',
  `--prefix=OpenBurnBar-${version}/`,
  `--output=${sourceFile}`,
  git.commit
]);
if (source.exitCode !== 0) blockers.push({ kind: 'source-archive', message: 'Commit-bound source archive generation failed.' });
writeLog(path.join(logsDir, 'source-archive.log'), [source]);

const sbomFile = path.join(sidecarsDir, `OpenBurnBar-${version}-linux.spdx.json`);
const vexFile = path.join(sidecarsDir, `OpenBurnBar-${version}-linux.openvex.json`);
const sbom = runStep('python3', ['scripts/generate-sbom.py', '--version', version ?? '', '--repo-root', repoRoot, '--output', sbomFile]);
const vex = runStep('python3', ['scripts/supply-chain/generate-vex.py', '--sbom', sbomFile, '--output', vexFile, '--product-version', version ?? '']);
writeLog(path.join(logsDir, 'supply-chain-sidecars.log'), [sbom, vex]);
if (sbom.exitCode !== 0 || !fs.existsSync(sbomFile)) blockers.push({ kind: 'sbom', message: 'SPDX SBOM generation failed.' });
if (vex.exitCode !== 0 || !fs.existsSync(vexFile)) blockers.push({ kind: 'vex', message: 'OpenVEX generation failed.' });

const paritySource = path.join(reanchorEvidenceDir, 'parity-ledger-validation.json');
const parityFile = path.join(sidecarsDir, `OpenBurnBar-${version}-linux.parity-attestation.json`);
if (!candidate && fs.existsSync(paritySource)) {
  fs.copyFileSync(paritySource, parityFile);
  const parity = readJson(parityFile);
  if (parity.targetHead !== git.commit || parity.promotionPassed !== true || parity.productParityClaim !== true) {
    blockers.push({ kind: 'parity-attestation', message: 'Parity attestation is not green for the assembly commit.' });
  }
} else if (!candidate) {
  blockers.push({ kind: 'parity-attestation', message: 'Current release-head parity attestation is missing.' });
}

const privateKeyPem = process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM;
let privateKey = null;
try {
  privateKey = privateKeyPem ? crypto.createPrivateKey(privateKeyPem) : null;
  if (!privateKey || privateKey.asymmetricKeyType !== 'ed25519') throw new Error('Ed25519 key required');
} catch (error) {
  blockers.push({ kind: 'signing-credentials', message: 'A valid Ed25519 release private key is required.', error: String(error) });
}

const signatures = [];
if (privateKey) {
  for (const artifact of artifacts) {
    const signatureFile = path.join(sidecarsDir, `${path.basename(artifact.file)}.ed25519.sig`);
    fs.writeFileSync(signatureFile, crypto.sign(null, fs.readFileSync(path.join(repoRoot, artifact.file)), privateKey));
    signatures.push({ artifact: artifact.file, signature: relative(signatureFile), algorithm: 'Ed25519' });
  }
}

const publishedAt = new Date().toISOString();
const publishedFeedName = manifest.updateMetadata.publishedName;
const feedSignatureName = `${publishedFeedName}.ed25519.sig`;
const feed = {
  schemaVersion: 1,
  product: manifest.product,
  platform: 'linux',
  version,
  gitCommit: git.commit,
  publishedAt,
  channel,
  notes: process.env.OPENBURNBAR_LINUX_RELEASE_NOTES?.trim() || undefined,
  artifacts: artifacts.map((artifact) => ({
    type: artifact.type,
    architecture: artifact.architecture,
    url: releaseBaseUrl ? `${releaseBaseUrl}/${path.basename(artifact.file)}` : '',
    sha256: artifact.sha256,
    size: artifact.size,
    signatureUrl: releaseBaseUrl
      ? `${releaseBaseUrl}/${path.basename(artifact.file)}.ed25519.sig`
      : ''
  })),
  signature: {
    algorithm: 'Ed25519',
    publicKeySpkiSha256: manifest.signing.publicKeySpkiSha256,
    url: releaseBaseUrl ? `${releaseBaseUrl}/${feedSignatureName}` : ''
  }
};
if (feed.notes === undefined) delete feed.notes;
for (const failure of validateFeedDocument(feed)) {
  blockers.push({ kind: 'update-feed', message: failure });
}
const feedFile = path.join(outDir, manifest.updateMetadata.draftName);
writeJson(feedFile, feed);
const feedSignatureFile = path.join(sidecarsDir, feedSignatureName);
if (privateKey) {
  fs.writeFileSync(feedSignatureFile, crypto.sign(null, fs.readFileSync(feedFile), privateKey));
}

const metadata = Object.entries(manifest.tailMetadata).map(([kind, file]) => ({
  kind,
  file,
  exists: fs.existsSync(path.join(repoRoot, file)),
  sha256: fs.existsSync(path.join(repoRoot, file)) ? sha256(path.join(repoRoot, file)) : null
}));
for (const row of metadata) {
  if (!row.exists) blockers.push({ kind: 'tail-metadata', message: `Linux metadata is missing: ${row.file}` });
}

const provenance = {
  predicateType: 'https://openburnbar.dev/attestations/linux-release-artifact/v1',
  generatedAt: new Date().toISOString(),
  expectedCosignIdentity: manifest.signing.cosignIdentityTemplate.replace('{version}', version ?? ''),
  expectedCosignIssuer: manifest.signing.cosignIssuer,
  publicKeySpkiSha256: manifest.signing.publicKeySpkiSha256,
  git,
  version,
  architectures: shardRows,
  artifacts,
  metadata,
  checksums: relative(checksumsFile),
  sbom: fs.existsSync(sbomFile) ? relative(sbomFile) : null,
  vex: fs.existsSync(vexFile) ? relative(vexFile) : null,
  sourceArchive: fs.existsSync(sourceFile) ? { file: relative(sourceFile), sha256: sha256(sourceFile), represents: git.commit } : null,
  updateFeed: fs.existsSync(feedFile) ? { file: relative(feedFile), sha256: sha256(feedFile) } : null,
  updateFeedSignature: fs.existsSync(feedSignatureFile) ? { file: relative(feedSignatureFile), sha256: sha256(feedSignatureFile) } : null,
  signatures,
  architectureSessions: {
    file: relative(architectureSessionFile),
    sha256: sha256(architectureSessionFile),
    size: fileSize(architectureSessionFile)
  },
  packageSmoke: {
    file: relative(packageSmokeFile),
    sha256: sha256(packageSmokeFile),
    size: fileSize(packageSmokeFile)
  },
  promotionBlocked: blockers.length > 0,
  blockers
};
const provenanceFile = path.join(sidecarsDir, `OpenBurnBar-${version}-linux.provenance-predicate.json`);
writeJson(provenanceFile, provenance);

const closureRecord = (file) => fs.existsSync(file)
  ? { file: relative(file), sha256: sha256(file), size: fileSize(file) }
  : null;
writeJson(path.join(outDir, 'package-closure.json'), {
  schemaVersion: 3,
  generatedAt: new Date().toISOString(),
  stage: candidate ? 'candidate' : 'promotion',
  manifest: relative(manifestPath),
  tag: `linux-v${version}`,
  git,
  version,
  architectures: shardRows,
  artifacts,
  metadata,
  sidecars: {
    checksums: closureRecord(checksumsFile),
    sbom: closureRecord(sbomFile),
    vex: closureRecord(vexFile),
    provenancePredicate: closureRecord(provenanceFile),
    sourceArchive: closureRecord(sourceFile),
    parityAttestation: closureRecord(parityFile),
    architectureSessions: closureRecord(architectureSessionFile),
    packageSmoke: closureRecord(packageSmokeFile),
    updateFeed: closureRecord(feedFile),
    updateFeedSignature: closureRecord(feedSignatureFile)
  },
  blockers
});

writeJson(path.join(smokeDir, 'architecture-smoke-summary.json'), {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  architectures: shardRows,
  passed: shardRows.length === manifest.supportedArchitectures.length
    && !blockers.some((blocker) => blocker.kind === 'architecture-smoke')
});
console.log(JSON.stringify({
  outDir: relative(outDir),
  architectures: [...seenArchitectures].sort(),
  artifacts: artifacts.map(({ type, architecture, file }) => ({ type, architecture, file })),
  blockers
}, null, 2));
process.exit(blockers.length === 0 ? 0 : 1);

function findNamedFiles(root, name) {
  if (!fs.existsSync(root)) return [];
  const files = [];
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile() && entry.name === name) files.push(full);
    }
  }
  return files.sort();
}

function validatedReleaseBaseUrl(raw) {
  try {
    const url = new URL(raw);
    if (
      url.protocol !== 'https:'
      || url.username
      || url.password
      || url.search
      || url.hash
      || !['burnbar.ai', 'www.burnbar.ai', 'downloads.burnbar.ai', 'github.com'].includes(url.hostname)
    ) return null;
    return url.toString().replace(/\/$/, '');
  } catch {
    return null;
  }
}

function writeLog(file, steps) {
  const body = steps.map((step) => [
    `## ${step.command}`,
    `cwd=${step.cwd}`,
    `exit_code=${step.exitCode}`,
    '### stdout',
    step.stdout,
    '### stderr',
    step.stderr
  ].join('\n')).join('\n\n');
  fs.writeFileSync(file, `${body}\n`, 'utf8');
}

function copyInstalledAttestationSubject({ shardFile, record, destination, label, blockers }) {
  try {
    const snapshot = readShardAttestationSubject(path.dirname(shardFile), record, label);
    fs.writeFileSync(destination, snapshot.bytes, { mode: 0o600 });
    return { file: relative(destination), sha256: snapshot.sha256, size: snapshot.size };
  } catch (error) {
    blockers.push({ kind: 'installed-manifest', message: `${label}: ${error.message}.` });
    return null;
  }
}
