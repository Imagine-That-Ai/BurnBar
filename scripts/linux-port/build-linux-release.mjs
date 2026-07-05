#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  copyArtifact,
  discoverBundleArtifacts,
  fileSize,
  gitInfo,
  manifestPath,
  packageVersion,
  readJson,
  relative,
  releaseEvidenceDir,
  repoRoot,
  runStep,
  sha256,
  writeJson
} from './lib/linux-release-common.mjs';

const args = new Set(process.argv.slice(2));
const outDir = path.resolve(
  process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? releaseEvidenceDir
);
const appDir = path.join(repoRoot, 'apps/linux-desktop');
const manifest = readJson(manifestPath);
const version = packageVersion();
const git = gitInfo();
const logsDir = path.join(outDir, 'logs');
const artifactsDir = path.join(outDir, 'artifacts');
const sidecarDir = path.join(outDir, 'sidecars');
fs.mkdirSync(logsDir, { recursive: true });
fs.mkdirSync(artifactsDir, { recursive: true });
fs.mkdirSync(sidecarDir, { recursive: true });

function writeLog(name, steps) {
  const body = steps
    .map((step) => [
      `## ${step.command}`,
      `cwd=${step.cwd}`,
      `exit_code=${step.exitCode}`,
      '### stdout',
      step.stdout,
      '### stderr',
      step.stderr
    ].join('\n'))
    .join('\n\n');
  fs.writeFileSync(path.join(logsDir, name), `${body}\n`, 'utf8');
}

const buildSteps = [];
if (!args.has('--skip-tauri')) {
  buildSteps.push(runStep('npm', ['ci', '--no-audit', '--no-fund'], { cwd: appDir }));
  buildSteps.push(runStep('npm', ['run', 'build'], { cwd: appDir }));
  buildSteps.push(runStep('npm', ['run', 'tauri:build', '--', '--bundles', 'deb,rpm,appimage'], { cwd: appDir }));
}
writeLog('package-build.log', buildSteps);

const blockers = [];
for (const step of buildSteps) {
  if (step.exitCode !== 0) {
    blockers.push({
      kind: 'package-build',
      message: `Command failed: ${step.command}`,
      log: 'logs/package-build.log'
    });
  }
}

const copied = discoverBundleArtifacts().map((artifact) => {
  const dest = copyArtifact(artifact.file, artifactsDir);
  return {
    type: artifact.type,
    file: relative(dest),
    sourceFile: relative(artifact.file),
    size: fileSize(dest),
    sha256: sha256(dest)
  };
});

for (const required of manifest.requiredArtifacts) {
  if (!copied.some((artifact) => artifact.type === required)) {
    blockers.push({
      kind: 'missing-artifact',
      message: `Required Linux ${required} artifact was not produced by Tauri bundle output.`
    });
  }
}

const metadataFiles = Object.entries(manifest.tailMetadata).map(([kind, file]) => {
  const full = path.join(repoRoot, file);
  return {
    kind,
    file,
    exists: fs.existsSync(full),
    sha256: fs.existsSync(full) ? sha256(full) : null
  };
});
for (const meta of metadataFiles) {
  if (!meta.exists) {
    blockers.push({
      kind: 'missing-metadata',
      message: `Linux metadata file is missing: ${meta.file}`
    });
  }
}

const checksums = copied
  .map((artifact) => `${artifact.sha256}  ${artifact.file}`)
  .join('\n');
const checksumFile = path.join(sidecarDir, `OpenBurnBar-${version}-linux-checksums.txt`);
fs.writeFileSync(checksumFile, `${checksums}\n`, 'utf8');

const sourceSuffix = git.commit === 'unknown' ? 'unknown' : git.commit.slice(0, 12);
const sourceTar = path.join(sidecarDir, `OpenBurnBar-${version}-source-${sourceSuffix}.tar`);
const sourceArchive = runStep('git', [
  'archive',
  '--format=tar',
  `--prefix=OpenBurnBar-${version}/`,
  `--output=${sourceTar}`,
  'HEAD'
]);
const sourceSteps = [sourceArchive];
if (sourceArchive.exitCode !== 0) {
  const fallback = runStep('tar', [
    '-cf',
    sourceTar,
    'AGENTS.md',
    'CLAUDE.md',
    'CHANGELOG.md',
    'LICENSE',
    'NOTICE',
    'README.md',
    'SECURITY.md',
    'THIRD_PARTY.md',
    'THIRD_PARTY_NOTICES.md',
    'apps/linux-desktop/index.html',
    'apps/linux-desktop/package-lock.json',
    'apps/linux-desktop/package.json',
    'apps/linux-desktop/src',
    'apps/linux-desktop/src-tauri/Cargo.toml',
    'apps/linux-desktop/src-tauri/build.rs',
    'apps/linux-desktop/src-tauri/src',
    'apps/linux-desktop/src-tauri/tauri.conf.json',
    'docs/linux-port',
    'docs/RELEASE_MACOS.md',
    'docs/SCHEMA_SQLITE.sql',
    'docs/security/SUPPLY_CHAIN_PROVENANCE.md',
    'packaging/linux',
    'scripts/linux-port'
  ]);
  sourceSteps.push(fallback);
  if (fallback.exitCode !== 0) {
    blockers.push({ kind: 'source-archive', message: 'git archive and fallback tar failed.', log: 'logs/source-archive.log' });
  } else {
    blockers.push({
      kind: 'source-archive-fallback',
      message: 'Source archive was generated from the working tree because git archive was unavailable; promote only from CI or a checkout with commit-bound git archive.'
    });
  }
}
writeLog('source-archive.log', sourceSteps);
if (!git.gitAvailable) {
  blockers.push({
    kind: 'git-metadata',
    message: 'Git metadata was unavailable in this runner; release commit binding must be regenerated in CI or with OPENBURNBAR_GIT_* env values.'
  });
}
if (git.dirty) {
  blockers.push({
    kind: 'dirty-worktree',
    message: 'Release metadata cannot be promoted from a dirty worktree; source archive only represents HEAD.'
  });
}

const sbomFile = path.join(sidecarDir, `OpenBurnBar-${version}-linux.spdx.json`);
const sbom = runStep('python3', [
  'scripts/generate-sbom.py',
  '--version',
  version,
  '--repo-root',
  repoRoot,
  '--output',
  sbomFile
]);
const vexFile = path.join(sidecarDir, `OpenBurnBar-${version}-linux.openvex.json`);
const vex = runStep('python3', [
  'scripts/supply-chain/generate-vex.py',
  '--sbom',
  sbomFile,
  '--output',
  vexFile,
  '--product-version',
  version
]);
writeLog('supply-chain-sidecars.log', [sbom, vex]);
if (sbom.exitCode !== 0 || !fs.existsSync(sbomFile)) {
  blockers.push({ kind: 'sbom', message: 'SPDX SBOM generation failed.', log: 'logs/supply-chain-sidecars.log' });
}
if (vex.exitCode !== 0 || !fs.existsSync(vexFile)) {
  blockers.push({ kind: 'vex', message: 'OpenVEX sidecar generation failed.', log: 'logs/supply-chain-sidecars.log' });
}

const privateKeyPem = process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM;
const signatureRows = [];
if (privateKeyPem) {
  const privateKey = crypto.createPrivateKey(privateKeyPem);
  for (const artifact of copied) {
    const artifactPath = path.join(repoRoot, artifact.file);
    const signature = crypto.sign(null, fs.readFileSync(artifactPath), privateKey);
    const sigPath = path.join(sidecarDir, `${path.basename(artifact.file)}.ed25519.sig`);
    fs.writeFileSync(sigPath, signature);
    signatureRows.push({ artifact: artifact.file, signature: relative(sigPath), algorithm: 'Ed25519' });
  }
} else {
  blockers.push({
    kind: 'signing-credentials',
    message: 'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM is not configured; detached package signatures were not produced.'
  });
}

if (!process.env.SIGSTORE_ID_TOKEN) {
  blockers.push({
    kind: 'cosign-oidc',
    message: 'SIGSTORE_ID_TOKEN is unavailable locally; CI must produce and verify cosign bundle with GitHub OIDC.'
  });
}

const expectedCosignIdentity = `https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml@refs/tags/v${version}`;
const provenance = {
  predicateType: 'https://openburnbar.dev/attestations/linux-release-artifact/v1',
  generatedAt: new Date().toISOString(),
  expectedCosignIdentity,
  git,
  version,
  artifacts: copied,
  metadata: metadataFiles,
  checksums: relative(checksumFile),
  sbom: fs.existsSync(sbomFile) ? relative(sbomFile) : null,
  vex: fs.existsSync(vexFile) ? relative(vexFile) : null,
  sourceArchive: fs.existsSync(sourceTar)
    ? { file: relative(sourceTar), sha256: sha256(sourceTar), represents: 'HEAD only' }
    : null,
  signatures: signatureRows,
  promotionBlocked: blockers.length > 0,
  blockers
};
const provenanceFile = path.join(sidecarDir, `OpenBurnBar-${version}-linux.provenance-predicate.json`);
writeJson(provenanceFile, provenance);

const primary = copied.find((artifact) => artifact.type === manifest.primaryArtifact);
const latestDraft = {
  schemaVersion: 1,
  product: manifest.product,
  platform: 'linux',
  version,
  commit: git.commit,
  generatedAt: new Date().toISOString(),
  promotionState: blockers.length === 0 ? 'candidate' : 'blocked',
  primaryArtifact: primary ?? null,
  artifacts: copied,
  sidecars: {
    checksums: relative(checksumFile),
    sbom: fs.existsSync(sbomFile) ? relative(sbomFile) : null,
    vex: fs.existsSync(vexFile) ? relative(vexFile) : null,
    provenancePredicate: relative(provenanceFile)
  },
  blockers
};
writeJson(path.join(outDir, manifest.updateMetadata.draftName), latestDraft);

writeJson(path.join(outDir, 'package-closure.json'), {
  generatedAt: new Date().toISOString(),
  manifest: relative(manifestPath),
  git,
  version,
  artifacts: copied,
  metadata: metadataFiles,
  sidecars: {
    checksums: relative(checksumFile),
    sbom: fs.existsSync(sbomFile) ? relative(sbomFile) : null,
    vex: fs.existsSync(vexFile) ? relative(vexFile) : null,
    provenancePredicate: relative(provenanceFile)
  },
  blockers
});

console.log(JSON.stringify({ outDir: relative(outDir), artifacts: copied, blockers }, null, 2));
process.exit(blockers.some((blocker) => blocker.kind === 'package-build') ? 1 : 0);
