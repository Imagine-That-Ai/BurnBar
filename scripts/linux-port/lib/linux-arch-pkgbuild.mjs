import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const archPkgbuildCommonSources = Object.freeze([
  ['DESKTOP', 'packaging/linux/aur/openburnbar.desktop'],
  ['SAFE_MODE_DESKTOP', 'packaging/linux/aur/openburnbar-safe-mode.desktop'],
  ['SERVICE', 'packaging/linux/aur/openburnbar-daemon.service'],
  ['LAUNCH', 'packaging/linux/aur/openburnbar-daemon-launch'],
  ['COMPUTER_USE_POLKIT_POLICY', 'packaging/linux/com.openburnbar.computer-use.policy'],
  ['PLAYWRIGHT_BRIDGE', 'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js'],
  ['BROWSER_RUNTIME_PROBE', 'packaging/linux/openburnbar-browser-runtime-probe'],
  ['BROWSER_RUNTIME_REQUIREMENTS', 'packaging/linux/browser-runtime-requirements.json'],
  ['RELEASE_PUBLIC_KEY', 'packaging/linux/openburnbar-linux-ed25519.pub.pem']
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

  for (const [slot, relativeFile] of archPkgbuildCommonSources) {
    const file = path.join(repoRoot, relativeFile);
    const record = fileRecord(file, relativeFile);
    checksums[slot] = record.sha256;
    sources.push({ slot, ...record });
  }

  for (const architecture of ['x86_64', 'aarch64']) {
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
  return { pkgbuildFile, metadataFile, metadata };
}

function requiredArtifact(byType, type, architecture) {
  const artifact = byType.get(type);
  if (!artifact) throw new Error(`Arch release metadata is missing ${type}:${architecture}`);
  return requiredRecord(artifact, `${type}:${architecture}`);
}

function requiredRecord(record, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)
      || typeof record.file !== 'string' || !/^[a-f0-9]{64}$/u.test(record.sha256 ?? '')
      || !Number.isSafeInteger(record.size) || record.size <= 0) {
    throw new Error(`Arch release metadata ${label} record is invalid`);
  }
  return record;
}

function copyRecordedFile(repoRoot, record, destination) {
  const source = path.resolve(repoRoot, record.file);
  const relative = path.relative(repoRoot, source);
  if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Arch release source escapes repository');
  const actual = fileRecord(source, record.file);
  if (actual.sha256 !== record.sha256 || actual.size !== record.size) throw new Error('Arch release source record drifted');
  fs.copyFileSync(source, destination);
  return fileRecord(destination, path.relative(repoRoot, destination).split(path.sep).join('/'));
}

function fileRecord(file, relativeFile) {
  const bytes = fs.readFileSync(file);
  return {
    file: relativeFile,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  };
}
