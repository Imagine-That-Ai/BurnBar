import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { readRegularSnapshot } from './product-proof-closure.mjs';
import { RELEASE_PUBLIC_KEY_PATH, assertInstalledManifest } from './linux-installed-manifest.mjs';

export const INSTALLED_UI_ENVIRONMENTS = Object.freeze({
  'ubuntu-24.04-gnome-x11-x86_64': { architecture: 'x86_64', desktop: 'GNOME', session: 'X11', format: 'deb' },
  'ubuntu-24.04-gnome-x11-aarch64': { architecture: 'aarch64', desktop: 'GNOME', session: 'X11', format: 'deb' },
  'ubuntu-24.04-gnome-wayland-x86_64': { architecture: 'x86_64', desktop: 'GNOME', session: 'Wayland', format: 'deb' },
  'ubuntu-24.04-gnome-wayland-aarch64': { architecture: 'aarch64', desktop: 'GNOME', session: 'Wayland', format: 'deb' },
  'fedora-kde-wayland-x86_64': { architecture: 'x86_64', desktop: 'KDE Plasma', session: 'Wayland', format: 'rpm' },
  'fedora-kde-wayland-aarch64': { architecture: 'aarch64', desktop: 'KDE Plasma', session: 'Wayland', format: 'rpm' },
  'arch-sway-wayland-x86_64': { architecture: 'x86_64', desktop: 'Sway/wlroots', session: 'Wayland', format: 'arch' }
});

export const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;
export const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
export const DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/u;
export const RUN_ID_PATTERN = /^[1-9][0-9]*$/u;
export const VERSION_PATTERN = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;

const FORBIDDEN_LIVE = /(?:xvfb|xfce|fixture|mock|synthetic|source-only|storybook|playwright)/iu;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

export function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} fields must be exactly: ${wanted.join(', ')}`);
  }
}

export function parseJson(bytes, label) {
  try {
    return JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

export function assertString(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
    throw new Error(`${label} must be a non-empty trimmed string`);
  }
  return value;
}

export function assertCandidate(candidate, { targetHead, candidateRunId, candidateArtifactDigest }, label) {
  exactKeys(candidate, ['artifactDigest', 'runId'], `${label} candidate`);
  if (!HEAD_PATTERN.test(targetHead ?? '') || !RUN_ID_PATTERN.test(String(candidate.runId ?? ''))
      || String(candidate.runId) !== String(candidateRunId)
      || !DIGEST_PATTERN.test(candidate.artifactDigest ?? '')
      || candidate.artifactDigest !== candidateArtifactDigest) {
    throw new Error(`${label} is not bound to the selected release candidate`);
  }
}

export function validateInstalledSessionEnvelope(document, binding, requirementId, label) {
  if (document.requirementId !== requirementId || document.environmentId !== binding.environmentId
      || document.targetHead !== binding.targetHead || !HEAD_PATTERN.test(document.targetHead ?? '')) {
    throw new Error(`${label} is not bound to the invoked requirement, environment, and HEAD`);
  }
  assertCandidate(document.candidate, binding, label);
  const expected = INSTALLED_UI_ENVIRONMENTS[binding.environmentId];
  if (!expected) throw new Error(`${label} uses an unknown support environment`);

  exactKeys(document.package, ['architecture', 'format', 'installed', 'manifest', 'signature', 'source', 'version'], `${label} package`);
  if (document.package.architecture !== expected.architecture || document.package.format !== expected.format
      || document.package.installed !== true || document.package.source !== 'verified-live-installed-candidate'
      || !VERSION_PATTERN.test(document.package.version ?? '')) {
    throw new Error(`${label} did not run from the signed installed candidate`);
  }
  const manifest = validateArtifact(binding.repoRoot, document.package.manifest, requirementId, binding.environmentId, `${label} installed manifest`, { mediaType: 'json' });
  const signature = validateArtifact(binding.repoRoot, document.package.signature, requirementId, binding.environmentId, `${label} installed manifest signature`, { minimumBytes: 64 });
  if (manifest.sha256 !== binding.manifestSha256 || signature.sha256 !== binding.manifestSignatureSha256
      || document.package.version !== binding.packageVersion) {
    throw new Error(`${label} package attestation does not match the selected release closure`);
  }
  const pinnedKey = readRegularSnapshot(binding.repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem', `${label} pinned release key`);
  let signatureValid = false;
  try {
    const key = crypto.createPublicKey(pinnedKey.bytes);
    signatureValid = key.asymmetricKeyType === 'ed25519'
      && signature.bytes.length === 64
      && crypto.verify(null, manifest.bytes, key, signature.bytes);
  } catch {
    signatureValid = false;
  }
  if (!signatureValid) throw new Error(`${label} installed manifest signature verification failed`);
  const installedManifest = assertInstalledManifest(parseJson(manifest.bytes, `${label} installed manifest`));
  const keyRecord = installedManifest.files.find((file) => file.path === RELEASE_PUBLIC_KEY_PATH && file.type === 'file');
  if (installedManifest.gitCommit !== binding.targetHead || installedManifest.packageVersion !== binding.packageVersion
      || installedManifest.packageArchitecture !== expected.architecture || installedManifest.packageFormat !== expected.format
      || keyRecord?.sha256 !== pinnedKey.sha256) {
    throw new Error(`${label} signed installed manifest identity does not match the candidate or pinned key`);
  }

  exactKeys(document.desktop, ['compositor', 'desktop', 'displayServer', 'liveSession'], `${label} desktop`);
  if (document.desktop.desktop !== expected.desktop || document.desktop.displayServer !== expected.session
      || document.desktop.liveSession !== true || typeof document.desktop.compositor !== 'string'
      || document.desktop.compositor.length === 0
      || FORBIDDEN_LIVE.test(`${document.desktop.desktop} ${document.desktop.displayServer} ${document.desktop.compositor}`)) {
    throw new Error(`${label} did not run in the requested real Linux desktop session`);
  }

  exactKeys(document.capture, ['endedAt', 'fixtureMode', 'method', 'startedAt'], `${label} capture`);
  const startedAt = Date.parse(document.capture.startedAt);
  const endedAt = Date.parse(document.capture.endedAt);
  if (!Number.isFinite(startedAt) || !Number.isFinite(endedAt) || endedAt < startedAt
      || endedAt - startedAt > 30 * 60 * 1000 || document.capture.fixtureMode !== false
      || document.capture.method !== 'installed-live-product-session') {
    throw new Error(`${label} capture is stale, synthetic, or not a bounded installed session`);
  }
  return { expected, startedAt, endedAt, attestation: [document.package.manifest, document.package.signature] };
}

export function validateCollectedAt(collectedAt, endedAt, now = Date.now()) {
  const collected = Date.parse(collectedAt);
  if (!Number.isFinite(collected) || collected < endedAt || collected - endedAt > 15 * 60 * 1000
      || collected > now + 60_000 || now - collected > 15 * 60 * 1000) {
    throw new Error('installed UI evidence is stale or has an invalid collection time');
  }
  return collected;
}

function requirementPrefix(requirementId, environmentId) {
  return `docs/linux-port/evidence/product-parity-inputs/${requirementId}/${environmentId}/`;
}

export function validateArtifact(repoRoot, record, requirementId, environmentId, label, { mediaType, minimumBytes = 1 } = {}) {
  exactKeys(record, ['path', 'sha256', 'size'], label);
  if (typeof record.path !== 'string' || !record.path.startsWith(requirementPrefix(requirementId, environmentId))
      || !SHA256_PATTERN.test(record.sha256 ?? '') || !Number.isSafeInteger(record.size)
      || record.size < minimumBytes) {
    throw new Error(`${label} must be a non-empty hashed file under the ${requirementId} evidence root`);
  }
  const snapshot = readRegularSnapshot(repoRoot, record.path, label);
  if (snapshot.sha256 !== record.sha256 || snapshot.size !== record.size) {
    throw new Error(`${label} bytes changed after the live capture`);
  }
  if (mediaType === 'json') parseJson(snapshot.bytes, label);
  if (mediaType === 'png') validatePng(snapshot.bytes, label);
  return snapshot;
}

export function artifactRecord(repoRoot, absolutePath, requirementId, environmentId, label) {
  const root = fs.realpathSync(repoRoot);
  const absolute = fs.realpathSync(absolutePath);
  const relative = path.relative(root, absolute).split(path.sep).join('/');
  if (!relative.startsWith(requirementPrefix(requirementId, environmentId))) {
    throw new Error(`${label} is outside the ${requirementId} evidence root`);
  }
  const snapshot = readRegularSnapshot(root, relative, label);
  return { path: snapshot.path, sha256: snapshot.sha256, size: snapshot.size };
}

export function pngCrc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function paeth(left, up, upperLeft) {
  const estimate = left + up - upperLeft;
  const dl = Math.abs(estimate - left);
  const du = Math.abs(estimate - up);
  const dul = Math.abs(estimate - upperLeft);
  return dl <= du && dl <= dul ? left : du <= dul ? up : upperLeft;
}

export function validatePng(bytes, label, { minimumWidth = 320, minimumHeight = 200 } = {}) {
  if (bytes.length < 57 || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error(`${label} is not a PNG screenshot`);
  let offset = 8;
  let ihdr = null;
  let sawIend = false;
  const compressed = [];
  while (offset < bytes.length) {
    if (offset + 12 > bytes.length) throw new Error(`${label} has a truncated PNG chunk`);
    const length = bytes.readUInt32BE(offset);
    if (length > 128 * 1024 * 1024 || offset + 12 + length > bytes.length) throw new Error(`${label} has an invalid PNG chunk length`);
    const type = bytes.subarray(offset + 4, offset + 8);
    const data = bytes.subarray(offset + 8, offset + 8 + length);
    const expectedCrc = bytes.readUInt32BE(offset + 8 + length);
    if (pngCrc32(Buffer.concat([type, data])) !== expectedCrc) throw new Error(`${label} has an invalid PNG CRC`);
    const name = type.toString('ascii');
    if (name === 'IHDR') {
      if (ihdr || length !== 13) throw new Error(`${label} has an invalid PNG header`);
      ihdr = Buffer.from(data);
    } else if (name === 'IDAT') compressed.push(Buffer.from(data));
    else if (name === 'IEND') {
      if (length !== 0) throw new Error(`${label} has an invalid PNG terminator`);
      sawIend = true;
      offset += 12;
      break;
    }
    offset += 12 + length;
  }
  if (!ihdr || compressed.length === 0 || !sawIend || offset !== bytes.length) throw new Error(`${label} has an incomplete PNG structure`);
  const width = ihdr.readUInt32BE(0);
  const height = ihdr.readUInt32BE(4);
  const bitDepth = ihdr[8];
  const colorType = ihdr[9];
  const pixelCount = width * height;
  if (width < minimumWidth || height < minimumHeight || width > 8192 || height > 8192
      || pixelCount > 32_000_000
      || bitDepth !== 8 || ![2, 6].includes(colorType) || ihdr[10] !== 0 || ihdr[11] !== 0 || ihdr[12] !== 0) {
    throw new Error(`${label} PNG format or dimensions are unsupported`);
  }
  const channels = colorType === 6 ? 4 : 3;
  const stride = width * channels;
  if ((stride + 1) * height > 128_000_000) throw new Error(`${label} PNG decoded byte budget is exceeded`);
  let raw;
  try { raw = zlib.inflateSync(Buffer.concat(compressed), { maxOutputLength: (stride + 1) * height }); }
  catch { throw new Error(`${label} PNG pixels cannot be decoded`); }
  if (raw.length !== (stride + 1) * height) throw new Error(`${label} PNG pixel length is invalid`);
  const pixels = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y += 1) {
    const filter = raw[y * (stride + 1)];
    if (filter > 4) throw new Error(`${label} PNG uses an invalid row filter`);
    for (let x = 0; x < stride; x += 1) {
      const source = raw[y * (stride + 1) + 1 + x];
      const out = y * stride + x;
      const left = x >= channels ? pixels[out - channels] : 0;
      const up = y > 0 ? pixels[out - stride] : 0;
      const upperLeft = y > 0 && x >= channels ? pixels[out - stride - channels] : 0;
      const predictor = filter === 0 ? 0 : filter === 1 ? left : filter === 2 ? up
        : filter === 3 ? Math.floor((left + up) / 2) : paeth(left, up, upperLeft);
      pixels[out] = (source + predictor) & 0xff;
    }
  }
  let nonBlank = 0;
  for (let offset = 0; offset < pixels.length; offset += channels) {
    const visible = channels === 3 || pixels[offset + 3] !== 0;
    if (visible && (pixels[offset] !== 0 || pixels[offset + 1] !== 0 || pixels[offset + 2] !== 0)) nonBlank += 1;
  }
  return { width, height, nonBlankPixelRatio: nonBlank / (width * height), pixels };
}

export function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}
