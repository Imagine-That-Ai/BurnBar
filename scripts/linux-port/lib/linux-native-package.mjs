import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
  verifyInstalledManifestTree
} from './linux-installed-manifest.mjs';

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

export function assertSafeArchiveMemberNames(listing, { allowedRootMetadata = [] } = {}) {
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
    if (segments[0] !== 'usr') {
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
  extractUsrOnly = false
} = {}) {
  if (!Buffer.isBuffer(archive) || archive.length === 0) throw new Error('native package archive is empty');
  const listing = runBinary('bsdtar', ['-tf', '-'], { input: archive, env }).toString('utf8');
  const members = assertSafeArchiveMemberNames(listing, { allowedRootMetadata });
  const verbose = runBinary('bsdtar', ['-tvf', '-'], { input: archive, env }).toString('utf8');
  const types = verbose.split('\n').filter(Boolean).map((line) => line[0]);
  if (types.length < members.size || types.some((type) => !['-', 'd', 'l'].includes(type))) {
    throw new Error('native package archive contains unsupported or ambiguous member types');
  }
  fs.rmSync(destination, { recursive: true, force: true });
  fs.mkdirSync(destination, { recursive: true });
  const extractArgs = ['-xmf', '-', '-C', destination];
  if (extractUsrOnly) extractArgs.push('usr');
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
    allowedRootMetadata: format === 'arch' ? ['.BUILDINFO', '.INSTALL', '.MTREE', '.PKGINFO'] : [],
    extractUsrOnly: format === 'arch'
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
