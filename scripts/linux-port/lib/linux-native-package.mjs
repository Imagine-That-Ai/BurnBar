import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
  INSTALLED_MANIFEST_NON_USR_PATH_ALLOWLIST,
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
export const NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST = Object.freeze(
  INSTALLED_MANIFEST_NON_USR_PATH_ALLOWLIST.map((entry) => entry.slice(1))
);

export function isAllowedNativeNonUsrPath(
  packagePath,
  allowlist = NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST
) {
  return typeof packagePath === 'string' && allowlist.some((allowedPath) => (
    allowedPath === packagePath
    || allowedPath.startsWith(`${packagePath}/`)
    || packagePath.startsWith(`${allowedPath}/`)
  ));
}

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

// Package payloads (dpkg-deb --fsys-tarfile, rpm2cpio) are multi-gigabyte
// uncompressed streams. They are never held in process memory: producers are
// streamed to a mode-0600 temporary payload file through a redirected file
// descriptor, and bsdtar reads that file directly. Captured stdout is only
// ever archive listings and package metadata, which this bound covers with
// large headroom while keeping a runaway or hostile producer from exhausting
// memory.
const METADATA_MAX_BUFFER = 64 * 1024 * 1024;

// Error messages must stay well under V8's maximum string length even when a
// failing binary produced hundreds of megabytes of output, so only the tail
// of each stream is stringified for diagnostics.
const ERROR_OUTPUT_TAIL_BYTES = 16 * 1024;

// Package tooling must terminate: a wedged producer (fifo, network mount,
// hostile decompression bomb feeding a pipe that is never drained) is killed
// rather than hanging the release pipeline forever. Overridable for slow CI
// hardware; never disabled.
const DEFAULT_TOOL_TIMEOUT_MS = (() => {
  const raw = Number.parseInt(process.env.OPENBURNBAR_LINUX_PACKAGE_TOOL_TIMEOUT_MS ?? '', 10);
  return Number.isSafeInteger(raw) && raw > 0 ? raw : 30 * 60 * 1000;
})();

export function boundedOutputTail(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) return '';
  const tail = buffer.subarray(-ERROR_OUTPUT_TAIL_BYTES);
  const prefix = buffer.length > tail.length
    ? `[truncated ${buffer.length - tail.length} bytes]\n`
    : '';
  return `${prefix}${tail.toString('utf8')}`;
}

function describeToolFailure(command, args, result) {
  const timedOut = result.error?.code === 'ETIMEDOUT'
    || (result.signal === 'SIGTERM' && result.error?.code === undefined && result.status === null);
  return [
    `${command} ${args.join(' ')} failed`,
    timedOut ? `killed after exceeding the ${DEFAULT_TOOL_TIMEOUT_MS}ms package tool timeout` : null,
    result.signal ? `terminated by signal ${result.signal}` : null,
    result.error?.message,
    boundedOutputTail(result.stdout),
    boundedOutputTail(result.stderr)
  ].filter(Boolean).join('\n');
}

function runBinary(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: 'buffer',
    input: options.input,
    maxBuffer: options.maxBuffer ?? METADATA_MAX_BUFFER,
    timeout: options.timeoutMs ?? DEFAULT_TOOL_TIMEOUT_MS,
    env: options.env ?? process.env
  });
  if (result.error || result.signal || (result.status ?? 1) !== 0) {
    throw new Error(describeToolFailure(command, args, result));
  }
  return result.stdout;
}

/**
 * Run a payload-scale producer with stdout redirected straight to a private
 * temporary file. The payload never enters process memory; only a bounded
 * stderr tail is captured for diagnostics. A timeout kills the producer and
 * the partial output file is removed, so callers observe either a complete
 * payload file or a thrown error — never a truncated payload.
 */
export function streamBinaryToFile(command, args, outputPath, options = {}) {
  const fd = fs.openSync(outputPath, 'w', 0o600);
  let result;
  try {
    result = spawnSync(command, args, {
      cwd: options.cwd,
      stdio: ['ignore', fd, 'pipe'],
      encoding: 'buffer',
      maxBuffer: options.maxBuffer ?? METADATA_MAX_BUFFER,
      timeout: options.timeoutMs ?? DEFAULT_TOOL_TIMEOUT_MS,
      env: options.env ?? process.env
    });
  } finally {
    fs.closeSync(fd);
  }
  if (result.error || result.signal || (result.status ?? 1) !== 0) {
    fs.rmSync(outputPath, { force: true });
    throw new Error(describeToolFailure(command, args, result));
  }
  return outputPath;
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
    const isAllowedPath = isAllowedNativeNonUsrPath(stripped, allowedPaths);
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

/**
 * Preflight and extract an on-disk archive without ever loading the payload
 * into memory. All three bsdtar passes (member listing, member types, actual
 * extraction) read the archive file directly.
 */
export function extractPreflightedArchiveFile(archivePath, destination, {
  env = process.env,
  allowedRootMetadata = [],
  allowedPaths = [],
  extractUsrOnly = false,
  timeoutMs = DEFAULT_TOOL_TIMEOUT_MS,
  listingMaxBuffer = METADATA_MAX_BUFFER
} = {}) {
  if (typeof archivePath !== 'string' || archivePath.length === 0) {
    throw new Error('native package archive path is empty');
  }
  const stat = fs.statSync(archivePath);
  if (!stat.isFile() || stat.size === 0) throw new Error('native package archive is empty');
  const listing = runBinary('bsdtar', ['-tf', archivePath], {
    env, timeoutMs, maxBuffer: listingMaxBuffer
  }).toString('utf8');
  const members = assertSafeArchiveMemberNames(listing, { allowedRootMetadata, allowedPaths });
  const verbose = runBinary('bsdtar', ['-tvf', archivePath], {
    env, timeoutMs, maxBuffer: listingMaxBuffer
  }).toString('utf8');
  const types = verbose.split('\n').filter(Boolean).map((line) => line[0]);
  if (types.length < members.size || types.some((type) => !['-', 'd', 'l'].includes(type))) {
    throw new Error('native package archive contains unsupported or ambiguous member types');
  }
  fs.rmSync(destination, { recursive: true, force: true });
  fs.mkdirSync(destination, { recursive: true });
  const extractArgs = ['-xmf', archivePath, '-C', destination];
  if (extractUsrOnly) extractArgs.push('usr', ...allowedPaths);
  runBinary('bsdtar', extractArgs, { env, timeoutMs });
  return destination;
}

/**
 * Byte-buffer compatibility wrapper. Callers that already hold small archive
 * bytes (tests, fixture builders) stage them into a private temporary file so
 * the streaming preflight/extraction path stays the single implementation.
 * Payload-scale callers must use extractPreflightedArchiveFile directly.
 */
export function extractPreflightedArchiveBytes(archive, destination, options = {}) {
  if (!Buffer.isBuffer(archive) || archive.length === 0) throw new Error('native package archive is empty');
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-archive-bytes-'));
  try {
    const archivePath = path.join(staging, 'archive');
    fs.writeFileSync(archivePath, archive, { mode: 0o600 });
    return extractPreflightedArchiveFile(archivePath, destination, options);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

/**
 * Stream a package's uncompressed payload to a file inside stagingDirectory
 * (deb, rpm) or hand back the artifact itself (arch, whose payload bsdtar
 * reads directly). Never buffers the payload in memory.
 */
export function materializeNativePackagePayload(format, artifact, stagingDirectory, {
  env = process.env,
  timeoutMs = DEFAULT_TOOL_TIMEOUT_MS
} = {}) {
  if (format === 'arch') return artifact;
  const payloadPath = path.join(stagingDirectory, `payload-${format}`);
  if (format === 'deb') {
    return streamBinaryToFile('dpkg-deb', ['--fsys-tarfile', artifact], payloadPath, { env, timeoutMs });
  }
  if (format === 'rpm') {
    return streamBinaryToFile('rpm2cpio', [artifact], payloadPath, { env, timeoutMs });
  }
  throw new Error(`unsupported native package format: ${format}`);
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
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-payload-staging-'));
  try {
    const payloadPath = materializeNativePackagePayload(format, artifact, staging, { env });
    extractPreflightedArchiveFile(payloadPath, destination, {
      env,
      allowedRootMetadata: format === 'arch' ? ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST : [],
      allowedPaths: NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST,
      extractUsrOnly: format === 'arch'
    });
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
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
