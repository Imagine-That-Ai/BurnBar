import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
  verifyInstalledManifestTree
} from './linux-installed-manifest.mjs';

export const ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST = Object.freeze([
  '.BUILDINFO',
  '.MTREE',
  '.PKGINFO'
]);

// The package payload is rooted under /usr except for this single, declarative
// XDG autostart entry. Keep the exception exact so an archive cannot smuggle
// arbitrary /etc configuration into the extraction or attestation path.
export const NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST = Object.freeze([
  'etc/xdg/autostart/openburnbar.desktop'
]);

export const ARCH_PACKAGE_PRIVATE_DIRECTORIES = Object.freeze([
  '/usr/lib/openburnbar',
  '/usr/share/openburnbar'
]);

// Pacman cannot resolve virtual dependencies non-interactively with only
// --noconfirm.  The GTK/WebKit runtime pulls in the virtual `ttf-font`
// dependency, so pin the provider used by the release smoke/lifecycle jobs.
// This is deliberately an install-time prerequisite, not a product package
// dependency: the package's declared dependency set remains release-owned.
export const ARCH_NONINTERACTIVE_PROVIDER_PACKAGES = Object.freeze([
  'ttf-dejavu'
]);

function runBinary(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: 'buffer',
    input: options.input,
    maxBuffer: 512 * 1024 * 1024,
    env: options.env ?? process.env
  });
  if (result.error || (result.status ?? 1) !== 0) {
    throw new Error([
      `${command} ${args.join(' ')} failed`,
      result.error?.message,
      result.stdout?.toString('utf8'),
      result.stderr?.toString('utf8')
    ].filter(Boolean).join('\n'));
  }
  return result.stdout;
}

function normalizedArchitecture(value) {
  switch (value.trim()) {
    case 'amd64':
      return 'x86_64';
    case 'arm64':
      return 'aarch64';
    case 'x86_64':
    case 'aarch64':
      return value.trim();
    default:
      throw new Error(`unsupported native package metadata architecture: ${value.trim()}`);
  }
}

export function assertSafeArchiveMemberNames(listing, {
  allowedRootMetadata = [],
  allowedPaths = []
} = {}) {
  if (typeof listing !== 'string' || listing.length === 0 || listing.includes('\0')) {
    throw new Error('native package archive member listing is empty or malformed');
  }
  const seen = new Set();
  for (const raw of listing.split('\n').filter(Boolean)) {
    if (/[\u0000-\u001f\u007f\\]/u.test(raw)) {
      throw new Error(`native package archive member contains unsafe characters: ${JSON.stringify(raw)}`);
    }
    const stripped = raw.replace(/^\.\//u, '').replace(/\/$/u, '');
    if (stripped === '' || stripped === '.') continue;
    if (path.posix.isAbsolute(stripped)) {
      throw new Error(`native package archive member is absolute: ${raw}`);
    }
    const segments = stripped.split('/');
    if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) {
      throw new Error(`native package archive member traverses its extraction root: ${raw}`);
    }
    if (segments.length === 1 && allowedRootMetadata.includes(segments[0])) {
      const normalized = segments[0];
      if (seen.has(normalized)) throw new Error(`native package archive contains duplicate member: ${raw}`);
      seen.add(normalized);
      continue;
    }
    // Archive listings include parent directory entries before the allowed
    // leaf. Accept only those parents (or descendants of the exact leaf),
    // never a sibling under the same top-level directory.
    const isAllowedPath = allowedPaths.some((allowedPath) => (
      allowedPath === stripped
      || allowedPath.startsWith(`${stripped}/`)
      || stripped.startsWith(`${allowedPath}/`)
    ));
    if (segments[0] !== 'usr' && !isAllowedPath) {
      throw new Error(`native package archive member is outside /usr: ${raw}`);
    }
    const normalized = segments.join('/');
    if (seen.has(normalized)) throw new Error(`native package archive contains duplicate member: ${raw}`);
    seen.add(normalized);
  }
  if (seen.size === 0) throw new Error('native package archive has no installable members');
  return seen;
}

export function extractPreflightedArchiveBytes(archive, destination, {
  env = process.env,
  allowedRootMetadata = [],
  allowedPaths = [],
  extractUsrOnly = false
} = {}) {
  if (!Buffer.isBuffer(archive) || archive.length === 0) throw new Error('native package archive is empty');
  const listing = runBinary('bsdtar', ['-tf', '-'], { input: archive, env }).toString('utf8');
  const members = assertSafeArchiveMemberNames(listing, { allowedRootMetadata, allowedPaths });
  const verbose = runBinary('bsdtar', ['-tvf', '-'], { input: archive, env }).toString('utf8');
  const types = verbose.split('\n').filter(Boolean).map((line) => line[0]);
  if (types.length < members.size || types.some((type) => !['-', 'd', 'l'].includes(type))) {
    throw new Error('native package archive contains unsupported or ambiguous member types');
  }
  fs.rmSync(destination, { recursive: true, force: true });
  fs.mkdirSync(destination, { recursive: true });
  const extractArgs = ['-xmf', '-', '-C', destination];
  if (extractUsrOnly) extractArgs.push('usr', ...allowedPaths);
  runBinary('bsdtar', extractArgs, { input: archive, env });
  return destination;
}

export function inspectNativePackageMetadata(format, artifact, { env = process.env } = {}) {
  const rows = format === 'deb'
    ? ['Package', 'Version', 'Architecture'].map((field) =>
        runBinary('dpkg-deb', ['-f', artifact, field], { env }).toString('utf8').trim())
    : format === 'rpm'
      ? runBinary('rpm', ['-qp', '--queryformat', '%{NAME}\n%{VERSION}\n%{ARCH}\n', artifact], { env })
        .toString('utf8').trim().split('\n').map((entry) => entry.trim())
      : format === 'arch'
        ? inspectArchMetadata(artifact, env)
      : (() => { throw new Error(`unsupported native package format: ${format}`); })();
  if (rows.length !== 3 || rows.some((entry) => entry.length === 0)) {
    throw new Error(`${format} package metadata did not return name, version, and architecture`);
  }
  return { packageName: rows[0], packageVersion: rows[1], packageArchitecture: normalizedArchitecture(rows[2]) };
}

function inspectArchMetadata(artifact, env) {
  const metadata = runBinary('bsdtar', ['-xOf', artifact, '.PKGINFO'], { env }).toString('utf8');
  const fields = new Map();
  for (const line of metadata.split('\n')) {
    const match = /^([a-z][a-z0-9_]*) = (.+)$/u.exec(line);
    if (match && !fields.has(match[1])) fields.set(match[1], match[2].trim());
  }
  const rawVersion = fields.get('pkgver') ?? '';
  const packageVersion = rawVersion.replace(/-[1-9][0-9]*$/u, '');
  return [fields.get('pkgname') ?? '', packageVersion, fields.get('arch') ?? ''];
}

export function inspectArchPackageDependencies(artifact, { env = process.env } = {}) {
  const metadata = runBinary('bsdtar', ['-xOf', artifact, '.PKGINFO'], { env }).toString('utf8');
  const dependencies = metadata.split('\n')
    .map((line) => /^depend = (.+)$/u.exec(line)?.[1]?.trim())
    .filter(Boolean);
  if (dependencies.length === 0) throw new Error('Arch package metadata has no runtime dependencies');
  for (const dependency of dependencies) {
    if (!/^[a-z0-9@._+:-]+(?:[<>=]+[a-zA-Z0-9@._+:-]+)?$/u.test(dependency)) {
      throw new Error(`Arch package metadata has an unsafe dependency: ${dependency}`);
    }
  }
  return dependencies;
}

export function archDependencyPackagesForInstall(dependencies) {
  if (!Array.isArray(dependencies) || dependencies.length === 0) {
    throw new Error('Arch package dependency list is empty');
  }
  const packageNames = dependencies.map((dependency) => {
    if (typeof dependency !== 'string') {
      throw new Error(`Arch dependency cannot be installed safely: ${dependency}`);
    }
    const match = /^([a-z0-9@._+:-]+)/u.exec(dependency);
    if (!match) throw new Error(`Arch dependency cannot be installed safely: ${dependency}`);
    return match[1];
  });
  return [...new Set([...packageNames, ...ARCH_NONINTERACTIVE_PROVIDER_PACKAGES])];
}

export function extractNativePackage(format, artifact, destination, { env = process.env } = {}) {
  if (typeof process.getuid === 'function' && process.getuid() !== 0) {
    throw new Error('native package inventory extraction requires the isolated root toolchain container');
  }
  const archive = format === 'deb'
    ? runBinary('dpkg-deb', ['--fsys-tarfile', artifact], { env })
    : format === 'rpm'
      ? runBinary('rpm2cpio', [artifact], { env })
      : format === 'arch'
        ? fs.readFileSync(artifact)
      : (() => { throw new Error(`unsupported native package format: ${format}`); })();
  extractPreflightedArchiveBytes(archive, destination, {
    env,
    allowedRootMetadata: format === 'arch' ? ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST : [],
    allowedPaths: format === 'arch' ? NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST : [],
    extractUsrOnly: format === 'arch'
  });
}

export function archPackageRemovalCandidates(listing, metadataProvider = fs.lstatSync) {
  const candidates = [];
  for (const file of [...new Set(listing.split('\n').filter(Boolean))]) {
    let metadata;
    try {
      metadata = metadataProvider(file);
    } catch (error) {
      if (error?.code === 'ENOENT') continue;
      throw error;
    }
    const isPrivateDirectory = metadata.isDirectory()
      && ARCH_PACKAGE_PRIVATE_DIRECTORIES.some((root) => file === root || file.startsWith(`${root}/`));
    if (!metadata.isDirectory() || isPrivateDirectory) candidates.push(file);
  }
  return candidates;
}

export function remainingFilesystemEntriesNoFollow(files, metadataProvider = fs.lstatSync) {
  return files.filter((file) => {
    try {
      metadataProvider(file);
      return true;
    } catch (error) {
      if (error?.code === 'ENOENT') return false;
      throw error;
    }
  });
}

export function verifySignedNativePackage({
  format,
  artifact,
  manifestBytes,
  signatureBytes,
  publicKeyPem,
  metadataProvider = null,
  env = process.env,
  extractor = extractNativePackage,
  metadataInspector = inspectNativePackageMetadata
}) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), `openburnbar-${format}-verify-`));
  try {
    extractor(format, artifact, temporary, { env });
    const installedManifestBytes = fs.readFileSync(
      path.join(temporary, INSTALLED_MANIFEST_PATH.slice(1))
    );
    const installedSignatureBytes = fs.readFileSync(
      path.join(temporary, INSTALLED_MANIFEST_SIGNATURE_PATH.slice(1))
    );
    if (!installedManifestBytes.equals(manifestBytes) || !installedSignatureBytes.equals(signatureBytes)) {
      throw new Error(`${format} does not embed its recorded installed attestation bytes`);
    }
    const manifest = verifyInstalledManifestTree({
      installedRoot: temporary,
      manifestBytes,
      signatureBytes,
      publicKeyPem,
      metadataProvider
    });
    const metadata = metadataInspector(format, artifact, { env });
    if (metadata.packageName !== manifest.packageName
        || metadata.packageVersion !== manifest.packageVersion
        || metadata.packageArchitecture !== manifest.packageArchitecture) {
      throw new Error(`${format} manager metadata does not match the signed installed manifest identity`);
    }
    return manifest;
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}
