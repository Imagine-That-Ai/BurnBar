#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  copyArtifact,
  discoverBundleArtifacts,
  expectedLinuxReleaseIdentity,
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
  verifyEd25519Signature,
  writeJson
} from './lib/linux-release-common.mjs';

const args = new Set(process.argv.slice(2));
const versionArgIndex = process.argv.indexOf('--version');
const outDir = path.resolve(
  process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? releaseEvidenceDir
);
const appDir = path.join(repoRoot, 'apps/linux-desktop');
const manifest = readJson(manifestPath);
const requestedVersion = versionArgIndex >= 0 ? process.argv[versionArgIndex + 1] : null;
const version = requestedVersion?.trim() || packageVersion();
if (version !== packageVersion()) {
  console.error(`Linux release version ${version} does not match apps/linux-desktop/package.json ${packageVersion()}.`);
  process.exit(1);
}
const rawGit = gitInfo();
const generatedEvidencePrefix = `${relative(outDir)}/`;
const dirtyInputEntries = rawGit.dirtyEntries.filter((entry) => !entry.slice(3).startsWith(generatedEvidencePrefix));
const git = {
  ...rawGit,
  dirty: dirtyInputEntries.length > 0,
  dirtyEntries: dirtyInputEntries
};
if (git.dirty) {
  console.error(JSON.stringify({
    error: 'release checkout is dirty before artifact generation',
    dirtyEntries: git.dirtyEntries.slice(0, 40)
  }, null, 2));
  process.exit(1);
}
const logsDir = path.join(outDir, 'logs');
const artifactsDir = path.join(outDir, 'artifacts');
const sidecarDir = path.join(outDir, 'sidecars');
for (const generatedDir of [logsDir, artifactsDir, sidecarDir, path.join(outDir, 'smoke')]) {
  fs.rmSync(generatedDir, { recursive: true, force: true });
}
fs.mkdirSync(logsDir, { recursive: true });
fs.mkdirSync(artifactsDir, { recursive: true });
fs.mkdirSync(sidecarDir, { recursive: true });

const releaseEnvironment = {
  tag: process.env.OPENBURNBAR_RELEASE_TAG?.trim() || '',
  ref: process.env.OPENBURNBAR_RELEASE_REF?.trim() || '',
  commit: process.env.OPENBURNBAR_RELEASE_COMMIT?.trim() || '',
  expectedCosignIdentity: process.env.OPENBURNBAR_EXPECTED_COSIGN_IDENTITY?.trim() || ''
};
const hasReleaseEnvironment = Object.values(releaseEnvironment).some(Boolean);
if (hasReleaseEnvironment && Object.values(releaseEnvironment).some((value) => !value)) {
  console.error('Linux release binding is incomplete; tag, ref, commit, and expected Cosign identity are all required.');
  process.exit(1);
}
if (hasReleaseEnvironment) {
  const expectedTag = `linux-v${version}`;
  const expectedRef = `refs/tags/${expectedTag}`;
  const resolvedTag = runStep('git', ['rev-list', '-n', '1', `${releaseEnvironment.ref}^{commit}`]);
  const expectedIdentity = expectedLinuxReleaseIdentity(releaseEnvironment.ref);
  const bindingFailures = [
    releaseEnvironment.tag === expectedTag ? null : `tag=${releaseEnvironment.tag}, expected=${expectedTag}`,
    releaseEnvironment.ref === expectedRef ? null : `ref=${releaseEnvironment.ref}, expected=${expectedRef}`,
    releaseEnvironment.commit === git.commit ? null : `commit=${releaseEnvironment.commit}, HEAD=${git.commit}`,
    resolvedTag.exitCode === 0 && resolvedTag.stdout.trim() === releaseEnvironment.commit
      ? null
      : `${releaseEnvironment.ref} does not resolve to ${releaseEnvironment.commit}`,
    releaseEnvironment.expectedCosignIdentity === expectedIdentity
      ? null
      : `Cosign identity=${releaseEnvironment.expectedCosignIdentity}, expected=${expectedIdentity}`
  ].filter(Boolean);
  if (bindingFailures.length > 0) {
    console.error(`Linux release binding failed:\n- ${bindingFailures.join('\n- ')}`);
    process.exit(1);
  }
}

const release = {
  tag: releaseEnvironment.tag || `linux-v${version}`,
  ref: releaseEnvironment.ref || `refs/tags/linux-v${version}`,
  commit: releaseEnvironment.commit || git.commit,
  expectedCosignIdentity: releaseEnvironment.expectedCosignIdentity
    || expectedLinuxReleaseIdentity(`refs/tags/linux-v${version}`)
};

const cargoBuildJobs = process.env.OPENBURNBAR_LINUX_CARGO_BUILD_JOBS?.trim() || '4';
const swiftBuildJobs = process.env.OPENBURNBAR_LINUX_SWIFT_BUILD_JOBS?.trim() || '4';
const packageBuildEnv = {
  ...process.env,
  CARGO_BUILD_JOBS: cargoBuildJobs,
  // linuxdeploy (Tauri's AppImage bundler) is itself an AppImage and needs FUSE
  // to self-mount; container builds (local toolchain + CI docker) have no FUSE,
  // so tell it to self-extract instead. Harmless outside containers.
  APPIMAGE_EXTRACT_AND_RUN: '1'
};

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
  buildSteps.push(runStep('npm', ['run', 'tauri:build', '--', '--bundles', 'deb,rpm,appimage'], {
    cwd: appDir,
    env: packageBuildEnv
  }));
}
writeLog('package-build.log', buildSteps);

const blockers = [];
if (!hasReleaseEnvironment) {
  blockers.push({
    kind: 'release-binding',
    message: 'Tag-bound release environment is absent; local output is evidence-only and cannot be promoted.'
  });
}
for (const step of buildSteps) {
  if (step.exitCode !== 0) {
    blockers.push({
      kind: 'package-build',
      message: `Command failed: ${step.command}`,
      log: 'logs/package-build.log'
    });
  }
}

const daemonSteps = [];
if (!args.has('--skip-daemon')) {
  daemonSteps.push(runStep('swift', [
    'build',
    '--disable-automatic-resolution',
    '--jobs',
    swiftBuildJobs,
    '--package-path',
    'OpenBurnBarDaemon',
    '-c',
    'release',
    '--product',
    'OpenBurnBarDaemon'
  ]));
}
writeLog('daemon-build.log', daemonSteps);
for (const step of daemonSteps) {
  if (step.exitCode !== 0) {
    blockers.push({
      kind: 'daemon-build',
      message: `Command failed: ${step.command}`,
      log: 'logs/daemon-build.log'
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
const daemonBinary = path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
if (!args.has('--skip-daemon')) {
  if (fs.existsSync(daemonBinary)) {
    const daemonArtifact = path.join(artifactsDir, `openburnbar-daemon-${version}-linux-${linuxArch()}`);
    fs.copyFileSync(daemonBinary, daemonArtifact);
    fs.chmodSync(daemonArtifact, 0o755);
    copied.push({
      type: 'daemon',
      file: relative(daemonArtifact),
      sourceFile: relative(daemonBinary),
      size: fileSize(daemonArtifact),
      sha256: sha256(daemonArtifact)
    });
  } else {
    blockers.push({
      kind: 'missing-daemon-artifact',
      message: 'Required Linux daemon executable was not produced by swift build.',
      log: 'logs/daemon-build.log'
    });
  }
}

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

const sourceSuffix = release.commit === 'unknown' ? 'unknown' : release.commit.slice(0, 12);
const sourceTar = path.join(sidecarDir, `OpenBurnBar-${version}-source-${sourceSuffix}.tar.gz`);
const sourceChecksumFile = `${sourceTar}.sha256`;
const sourceArchive = runStep('bash', [
  'scripts/ci/build-corresponding-source-archive.sh',
  '--version',
  version,
  '--output',
  sourceTar
]);
const sourceSteps = [sourceArchive];
if (sourceArchive.exitCode !== 0 || !fs.existsSync(sourceTar) || !fs.existsSync(sourceChecksumFile)) {
  blockers.push({
    kind: 'source-archive',
    message: 'Canonical corresponding-source archive or checksum generation failed.',
    log: 'logs/source-archive.log'
  });
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
  const publicKeyPem = fs.readFileSync(
    path.join(repoRoot, manifest.externalCredentials.ed25519PublicKey)
  );
  for (const artifact of copied) {
    const artifactPath = path.join(repoRoot, artifact.file);
    const signature = crypto.sign(null, fs.readFileSync(artifactPath), privateKey);
    const sigPath = path.join(sidecarDir, `${path.basename(artifact.file)}.ed25519.sig`);
    fs.writeFileSync(sigPath, signature);
    signatureRows.push({ artifact: artifact.file, signature: relative(sigPath), algorithm: 'Ed25519' });
    if (!verifyEd25519Signature(fs.readFileSync(artifactPath), signature, publicKeyPem)) {
      blockers.push({
        kind: 'signing-key-mismatch',
        message: `Detached signature for ${artifact.file} does not verify with the checked-in release public key.`
      });
    }
  }
} else {
  blockers.push({
    kind: 'signing-credentials',
    message: 'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM is not configured; detached package signatures were not produced.'
  });
}

if (!process.env.SIGSTORE_ID_TOKEN && !process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
  blockers.push({
    kind: 'cosign-oidc',
    message: 'GitHub OIDC request token is unavailable locally; CI must produce and verify cosign bundle with GitHub OIDC.'
  });
}

const provenance = {
  predicateType: 'https://openburnbar.dev/attestations/linux-release-artifact/v1',
  generatedAt: new Date().toISOString(),
  expectedCosignIdentity: release.expectedCosignIdentity,
  release,
  git,
  version,
  artifacts: copied,
  metadata: metadataFiles,
  checksums: relative(checksumFile),
  sbom: fs.existsSync(sbomFile) ? relative(sbomFile) : null,
  vex: fs.existsSync(vexFile) ? relative(vexFile) : null,
  sourceArchive: fs.existsSync(sourceTar)
    ? {
        file: relative(sourceTar),
        sha256: sha256(sourceTar),
        checksumFile: fs.existsSync(sourceChecksumFile) ? relative(sourceChecksumFile) : null,
        represents: release.commit
      }
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
  release,
  generatedAt: new Date().toISOString(),
  promotionState: blockers.length === 0 ? 'candidate' : 'blocked',
  primaryArtifact: primary ?? null,
  artifacts: copied,
  sidecars: {
    checksums: relative(checksumFile),
    sbom: fs.existsSync(sbomFile) ? relative(sbomFile) : null,
    vex: fs.existsSync(vexFile) ? relative(vexFile) : null,
    provenancePredicate: relative(provenanceFile),
    sourceArchive: fs.existsSync(sourceTar)
      ? {
          file: relative(sourceTar),
          sha256: sha256(sourceTar),
          checksumFile: fs.existsSync(sourceChecksumFile) ? relative(sourceChecksumFile) : null,
          represents: release.commit
        }
      : null
  },
  blockers
};
writeJson(path.join(outDir, manifest.updateMetadata.draftName), latestDraft);

writeJson(path.join(outDir, 'package-closure.json'), {
  generatedAt: new Date().toISOString(),
  manifest: relative(manifestPath),
  git,
  release,
  version,
  artifacts: copied,
  metadata: metadataFiles,
  sidecars: {
    checksums: relative(checksumFile),
    sbom: fs.existsSync(sbomFile) ? relative(sbomFile) : null,
    vex: fs.existsSync(vexFile) ? relative(vexFile) : null,
    provenancePredicate: relative(provenanceFile),
    sourceArchive: fs.existsSync(sourceTar)
      ? {
          file: relative(sourceTar),
          sha256: sha256(sourceTar),
          checksumFile: fs.existsSync(sourceChecksumFile) ? relative(sourceChecksumFile) : null,
          represents: release.commit
        }
      : null
  },
  blockers
});

console.log(JSON.stringify({ outDir: relative(outDir), artifacts: copied, blockers }, null, 2));
process.exit(blockers.some((blocker) => blocker.kind === 'package-build') ? 1 : 0);

function linuxArch() {
  switch (process.arch) {
    case 'arm64':
      return 'aarch64';
    case 'x64':
      return 'x86_64';
    default:
      return process.arch;
  }
}
