import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const archPkgbuildCommonSources = Object.freeze([
  ['DESKTOP', 'packaging/linux/aur/openburnbar.desktop'],
  ['SAFE_MODE_DESKTOP', 'packaging/linux/aur/openburnbar-safe-mode.desktop'],
  ['AUTOSTART_DESKTOP', 'packaging/linux/autostart/openburnbar.desktop'],
  ['SERVICE', 'packaging/linux/aur/openburnbar-daemon.service'],
  ['LAUNCH', 'packaging/linux/aur/openburnbar-daemon-launch'],
  ['DESKTOP_LAUNCHER', 'packaging/linux/aur/openburnbar-linux-desktop'],
  ['ICON', 'apps/linux-desktop/src-tauri/icons/icon.png'],
  ['COMPUTER_USE_POLKIT_POLICY', 'packaging/linux/com.openburnbar.computer-use.policy'],
  ['PLAYWRIGHT_BRIDGE', 'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js'],
  ['BROWSER_RUNTIME_PROBE', 'packaging/linux/openburnbar-browser-runtime-probe'],
  ['BROWSER_RUNTIME_REQUIREMENTS', 'packaging/linux/browser-runtime-requirements.json'],
  ['RELEASE_PUBLIC_KEY', 'packaging/linux/openburnbar-linux-ed25519.pub.pem'],
  ['CLI_MIGRATION', 'packaging/linux/openburnbar-cli-migrate.sh'],
  ['CLI_MIGRATION_HOOK', 'packaging/linux/aur/openburnbar-cli-migrate.hook']
]);

export const archPkgbuildArchitectures = Object.freeze(['x86_64', 'aarch64']);

export const archPkgbuildSourceSlots = Object.freeze([
  ...archPkgbuildCommonSources.map(([slot]) => slot),
  ...archPkgbuildArchitectures.flatMap((architecture) => {
    const suffix = architecture.toUpperCase();
    return [
      `APPIMAGE_${suffix}`,
      `DAEMON_${suffix}`,
      `INSTALLED_MANIFEST_${suffix}`,
      `INSTALLED_MANIFEST_SIGNATURE_${suffix}`
    ];
  })
]);

export function renderReleasePkgbuild(template, { version, checksums }) {
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u.test(version)) {
    throw new Error('Arch package version must be strict X.Y.Z');
  }
  const versionSlots = template.match(/^pkgver=.*$/gmu) ?? [];
  if (versionSlots.length !== 1 || versionSlots[0] !== 'pkgver=REPLACE_WITH_RELEASE_VERSION') {
    throw new Error('Arch PKGBUILD template must contain exactly one release version slot');
  }
  let rendered = template.replace('pkgver=REPLACE_WITH_RELEASE_VERSION', `pkgver=${version}`);
  for (const [placeholder, digest] of Object.entries(checksums)) {
    if (!/^[A-Z0-9_]+$/u.test(placeholder) || !/^[a-f0-9]{64}$/u.test(digest)) {
      throw new Error(`invalid Arch source checksum replacement: ${placeholder}`);
    }
    const marker = `REPLACE_WITH_${placeholder}_SHA256`;
    if (!rendered.includes(marker)) throw new Error(`Arch PKGBUILD checksum slot is missing: ${marker}`);
    rendered = rendered.replaceAll(marker, digest);
  }
  const unresolved = rendered.match(/REPLACE_WITH_[A-Z0-9_]+(?:_SHA256)?/gu) ?? [];
  if (unresolved.length > 0) throw new Error(`Arch PKGBUILD has unresolved slots: ${unresolved.join(', ')}`);
  if (/\bSKIP\b/u.test(rendered)) throw new Error('Arch PKGBUILD may not bypass source verification');
  return rendered;
}

export function materializeArchReleaseMetadata({ repoRoot, outDir, version, gitCommit, artifacts }) {
  if (!/^[a-f0-9]{40}$/u.test(gitCommit)) throw new Error('Arch release metadata requires a full commit SHA');
  const templateFile = path.join(repoRoot, 'packaging/linux/aur/PKGBUILD.in');
  const template = fs.readFileSync(templateFile, 'utf8');
  fs.mkdirSync(outDir, { recursive: true });
  const checksums = {};
  const sources = [];
  const installedAttestations = {};

  for (const [slot, relativeFile] of archPkgbuildCommonSources) {
    const file = path.join(repoRoot, relativeFile);
    const record = fileRecord(file, relativeFile);
    checksums[slot] = record.sha256;
    sources.push({ slot, ...record });
  }

  for (const architecture of archPkgbuildArchitectures) {
    const byType = new Map(artifacts
      .filter((artifact) => artifact.architecture === architecture)
      .map((artifact) => [artifact.type, artifact]));
    if (byType.size !== artifacts.filter((artifact) => artifact.architecture === architecture).length) {
      throw new Error(`Arch release metadata has duplicate ${architecture} artifacts`);
    }
    const appImage = requiredArtifact(byType, 'appimage', architecture);
    const daemon = requiredArtifact(byType, 'daemon', architecture);
    const archPackage = requiredArtifact(byType, 'arch', architecture);
    const manifest = requiredRecord(archPackage.installedManifest, `${architecture} installed manifest`);
    const signature = requiredRecord(archPackage.installedManifestSignature, `${architecture} installed manifest signature`);
    const manifestName = `openburnbar-${version}-${architecture}.installed-manifest.json`;
    const signatureName = `openburnbar-${version}-${architecture}.installed-manifest.ed25519`;
    const manifestFile = copyRecordedFile(repoRoot, manifest, path.join(outDir, manifestName));
    const signatureFile = copyRecordedFile(repoRoot, signature, path.join(outDir, signatureName));
    installedAttestations[architecture] = {
      installedManifest: manifestFile,
      installedManifestSignature: signatureFile
    };
    const suffix = architecture.toUpperCase();
    checksums[`APPIMAGE_${suffix}`] = appImage.sha256;
    checksums[`DAEMON_${suffix}`] = daemon.sha256;
    checksums[`INSTALLED_MANIFEST_${suffix}`] = manifestFile.sha256;
    checksums[`INSTALLED_MANIFEST_SIGNATURE_${suffix}`] = signatureFile.sha256;
    sources.push(
      { slot: `APPIMAGE_${suffix}`, architecture, ...requiredRecord(appImage, `${architecture} AppImage`) },
      { slot: `DAEMON_${suffix}`, architecture, ...requiredRecord(daemon, `${architecture} daemon`) },
      { slot: `INSTALLED_MANIFEST_${suffix}`, architecture, ...manifestFile },
      { slot: `INSTALLED_MANIFEST_SIGNATURE_${suffix}`, architecture, ...signatureFile }
    );
  }

  const pkgbuild = renderReleasePkgbuild(template, { version, checksums });
  const releaseTag = `linux-v${version}`;
  if (!pkgbuild.includes('/releases/download/linux-v${pkgver}/')
      || !pkgbuild.includes('/BurnBar/linux-v${pkgver}/')
      || /::(?!https:\/\/)/u.test(pkgbuild)
      || !pkgbuild.includes('OpenBurnBar_${pkgver}_amd64.AppImage')) {
    throw new Error('rendered Arch PKGBUILD is not bound to published release sources');
  }
  const pkgbuildFile = path.join(outDir, 'PKGBUILD');
  fs.writeFileSync(pkgbuildFile, pkgbuild, { mode: 0o644 });
  const metadata = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    version,
    gitCommit,
    releaseTag,
    pkgbuild: fileRecord(pkgbuildFile, path.relative(repoRoot, pkgbuildFile).split(path.sep).join('/')),
    sources,
    aurPublication: {
      published: false,
      status: 'operator-required',
      note: 'Release assets are consumable directly; publishing to the AUR requires a separate operator action.'
    }
  };
  const metadataFile = path.join(outDir, 'arch-release-metadata.json');
  fs.writeFileSync(metadataFile, `${JSON.stringify(metadata, null, 2)}\n`, { mode: 0o644 });
  return { pkgbuildFile, metadataFile, metadata, installedAttestations };
}

export function validateArchReleaseMetadata({
  repoRoot,
  pkgbuildSnapshot,
  metadataSnapshot,
  version,
  gitCommit,
  artifacts
}) {
  let metadata;
  try {
    metadata = JSON.parse(metadataSnapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`Arch release metadata is not valid JSON: ${error.message}`);
  }
  if (metadata?.schemaVersion !== 1 || metadata.product !== 'OpenBurnBar'
      || metadata.version !== version || metadata.gitCommit !== gitCommit
      || metadata.releaseTag !== `linux-v${version}`
      || metadata.aurPublication?.published !== false
      || metadata.aurPublication?.status !== 'operator-required') {
    throw new Error('Arch release metadata is not bound to the release identity and publication state');
  }
  const pkgbuildRecord = requiredRecord(metadata.pkgbuild, 'PKGBUILD');
  if (pkgbuildRecord.file !== pkgbuildSnapshot.path
      || pkgbuildRecord.sha256 !== pkgbuildSnapshot.sha256 || pkgbuildRecord.size !== pkgbuildSnapshot.size) {
    throw new Error('Arch release metadata PKGBUILD record does not match the closure subject');
  }
  if (!Array.isArray(metadata.sources) || metadata.sources.length !== archPkgbuildSourceSlots.length) {
    throw new Error('Arch release metadata does not contain the exact PKGBUILD source set');
  }
  const sources = new Map();
  for (const source of metadata.sources) {
    if (!archPkgbuildSourceSlots.includes(source?.slot) || sources.has(source.slot)) {
      throw new Error(`Arch release metadata has an invalid or duplicate source slot: ${source?.slot}`);
    }
    sources.set(source.slot, requiredRecord(source, `${source.slot} source`));
  }
  if (sources.size !== archPkgbuildSourceSlots.length) {
    throw new Error('Arch release metadata does not contain the exact PKGBUILD source set');
  }

  const expectedRecords = new Map();
  for (const [slot, relativeFile] of archPkgbuildCommonSources) {
    expectedRecords.set(slot, { ...fileRecord(path.join(repoRoot, relativeFile), relativeFile), architecture: undefined });
  }
  for (const architecture of archPkgbuildArchitectures) {
    const byType = new Map(artifacts
      .filter((artifact) => artifact.architecture === architecture)
      .map((artifact) => [artifact.type, artifact]));
    const suffix = architecture.toUpperCase();
    expectedRecords.set(`APPIMAGE_${suffix}`, {
      ...requiredArtifact(byType, 'appimage', architecture), architecture
    });
    expectedRecords.set(`DAEMON_${suffix}`, {
      ...requiredArtifact(byType, 'daemon', architecture), architecture
    });
    const archPackage = requiredArtifact(byType, 'arch', architecture);
    expectedRecords.set(
      `INSTALLED_MANIFEST_${suffix}`,
      {
        ...requiredRecord(archPackage.installedManifest, `${architecture} installed manifest`),
        file: path.posix.join(path.posix.dirname(pkgbuildSnapshot.path), `openburnbar-${version}-${architecture}.installed-manifest.json`),
        architecture
      }
    );
    expectedRecords.set(
      `INSTALLED_MANIFEST_SIGNATURE_${suffix}`,
      {
        ...requiredRecord(archPackage.installedManifestSignature, `${architecture} installed manifest signature`),
        file: path.posix.join(path.posix.dirname(pkgbuildSnapshot.path), `openburnbar-${version}-${architecture}.installed-manifest.ed25519`),
        architecture
      }
    );
  }
  for (const [slot, expected] of expectedRecords) {
    const source = sources.get(slot);
    const metadataSource = metadata.sources.find((row) => row.slot === slot);
    if (source.file !== expected.file || source.sha256 !== expected.sha256 || source.size !== expected.size
        || metadataSource.architecture !== expected.architecture) {
      throw new Error(`Arch release metadata source ${slot} is not bound to release bytes and identity`);
    }
  }
  const template = fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/PKGBUILD.in'), 'utf8');
  const expectedPkgbuild = renderReleasePkgbuild(template, {
    version,
    checksums: Object.fromEntries([...sources].map(([slot, source]) => [slot, source.sha256]))
  });
  if (!pkgbuildSnapshot.bytes.equals(Buffer.from(expectedPkgbuild))) {
    throw new Error('Arch PKGBUILD does not equal the canonical release template rendered from bound sources');
  }
  return metadata;
}

function requiredArtifact(byType, type, architecture) {
  const artifact = byType.get(type);
  if (!artifact) throw new Error(`Arch release metadata is missing ${type}:${architecture}`);
  return requiredRecord(artifact, `${type}:${architecture}`);
}

function requiredRecord(record, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)
      || typeof record.file !== 'string' || record.file.includes('\\') || path.posix.isAbsolute(record.file)
      || path.posix.normalize(record.file) !== record.file || record.file === '..' || record.file.startsWith('../')
      || !/^[a-f0-9]{64}$/u.test(record.sha256 ?? '')
      || !Number.isSafeInteger(record.size) || record.size <= 0) {
    throw new Error(`Arch release metadata ${label} record is invalid`);
  }
  return record;
}

export function copyRecordedFile(repoRoot, record, destination) {
  const root = fs.realpathSync(repoRoot);
  const requestedRoot = path.resolve(repoRoot);
  const requestedTarget = path.resolve(destination);
  const targetRelative = path.relative(requestedRoot, requestedTarget);
  if (targetRelative === '..' || targetRelative.startsWith(`..${path.sep}`) || path.isAbsolute(targetRelative)) {
    throw new Error('Arch release destination escapes repository');
  }
  const target = path.resolve(root, targetRelative);
  let targetAncestor = root;
  const targetComponents = targetRelative.split(path.sep).filter(Boolean);
  for (const component of targetComponents.slice(0, -1)) {
    targetAncestor = path.join(targetAncestor, component);
    if (fs.lstatSync(targetAncestor).isSymbolicLink()) throw new Error('Arch release destination traverses a symlink');
  }
  const existingTarget = fs.lstatSync(target, { throwIfNoEntry: false });
  if (existingTarget?.isSymbolicLink()) throw new Error('Arch release destination is a symlink');
  const snapshot = readRecordedSource(repoRoot, record);
  const temporary = `${target}.tmp-${process.pid}-${crypto.randomUUID()}`;
  const descriptor = fs.openSync(temporary, 'wx', 0o644);
  let renamed = false;
  try {
    try {
      fs.writeFileSync(descriptor, snapshot.bytes);
      fs.fsyncSync(descriptor);
    } finally {
      fs.closeSync(descriptor);
    }
    fs.renameSync(temporary, target);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(temporary, { force: true });
  }
  return fileRecord(target, targetRelative.split(path.sep).join('/'));
}

function readRecordedSource(repoRoot, record) {
  requiredRecord(record, 'recorded source');
  if (path.posix.isAbsolute(record.file) || record.file.includes('\\')
      || path.posix.normalize(record.file) !== record.file
      || record.file === '..' || record.file.startsWith('../')) {
    throw new Error('Arch release source must be a canonical repository-relative path');
  }
  const root = fs.realpathSync(repoRoot);
  const source = path.resolve(root, record.file);
  const relative = path.relative(root, source);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('Arch release source escapes repository');
  }
  let current = root;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (fs.lstatSync(current).isSymbolicLink()) throw new Error('Arch release source traverses a symlink');
  }
  const descriptor = fs.openSync(source, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) throw new Error('Arch release source must be a regular file');
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
      throw new Error('Arch release source changed while it was read');
    }
    const actual = { sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length };
    if (actual.sha256 !== record.sha256 || actual.size !== record.size) {
      throw new Error('Arch release source record drifted');
    }
    return { source, bytes, ...actual };
  } finally {
    fs.closeSync(descriptor);
  }
}

function fileRecord(file, relativeFile) {
  const bytes = fs.readFileSync(file);
  return {
    file: relativeFile,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  };
}
