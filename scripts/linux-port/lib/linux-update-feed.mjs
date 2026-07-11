/** Pure classification and schema validation for the public Linux update feed. */

const SHA256 = /^[a-f0-9]{64}$/;
const COMMIT = /^[a-f0-9]{40}$/;
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const TYPES = new Set(['appimage', 'deb', 'rpm', 'daemon']);
const ARCHITECTURES = new Set(['aarch64', 'x86_64']);
const CHANNELS = new Set(['stable', 'prerelease', 'nightly']);
const ALLOWED_HOSTS = new Set([
  'burnbar.ai',
  'www.burnbar.ai',
  'downloads.burnbar.ai',
  'github.com',
  'objects.githubusercontent.com',
  'github-releases.githubusercontent.com'
]);

export function looksLikeHtml(text, contentType) {
  const ct = (contentType ?? '').toLowerCase();
  if (ct.includes('text/html') || ct.includes('application/xhtml')) return true;
  const head = String(text ?? '').trim().slice(0, 256).toLowerCase();
  return head.startsWith('<!doctype html') || head.startsWith('<html') || head.includes('<head') || head.includes('<body');
}

function validHttpsUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password && ALLOWED_HOSTS.has(url.hostname);
  } catch {
    return false;
  }
}

function validReleaseUrl(value, version) {
  if (!validHttpsUrl(value)) return false;
  const url = new URL(value);
  if (url.search || url.hash) return false;
  const filename = url.pathname.split('/').at(-1);
  if (!filename || !/^[A-Za-z0-9._-]+$/u.test(filename)) return false;
  if (url.hostname === 'downloads.burnbar.ai') {
    return url.pathname === `/linux/releases/linux-v${version}/${filename}`;
  }
  if (url.hostname === 'github.com') {
    return url.pathname === `/Imagine-That-Ai/BurnBar/releases/download/linux-v${version}/${filename}`;
  }
  return ['burnbar.ai', 'www.burnbar.ai'].includes(url.hostname)
    && url.pathname === `/downloads/${filename}`;
}

export function validateFeedDocument(document, options = {}) {
  const failures = [];
  if (document?.schemaVersion !== 1) failures.push('feed schemaVersion must be 1.');
  if (document?.product !== 'OpenBurnBar' || document?.platform !== 'linux') failures.push('feed product/platform is invalid.');
  if (!SEMVER.test(document?.version ?? '')) failures.push('feed version must be strict X.Y.Z semver.');
  if (!COMMIT.test(document?.gitCommit ?? '')) failures.push('feed gitCommit must be a 40-character lowercase SHA.');
  if (!CHANNELS.has(document?.channel)) failures.push('feed channel is invalid.');
  if (!document?.publishedAt || Number.isNaN(Date.parse(document.publishedAt))) failures.push('feed publishedAt must be an ISO date.');
  if ('notes' in (document ?? {})
      && (typeof document.notes !== 'string' || document.notes.length === 0 || document.notes.length > 8192)) {
    failures.push('feed notes must be a non-empty string of at most 8192 characters when present.');
  }
  if (options.previousVersion && compareSemver(document?.version, options.previousVersion) <= 0) {
    failures.push('feed version is not monotonic relative to the previous release.');
  }
  if (!Array.isArray(document?.artifacts) || document.artifacts.length === 0) {
    failures.push('feed artifacts must be a non-empty array.');
  } else {
    const keys = new Set();
    for (const artifact of document.artifacts) {
      const key = `${artifact?.type}:${artifact?.architecture}`;
      if (keys.has(key)) failures.push(`duplicate feed artifact: ${key}.`);
      keys.add(key);
      if (!TYPES.has(artifact?.type)) failures.push(`feed artifact type is invalid: ${artifact?.type ?? '<missing>'}.`);
      if (!ARCHITECTURES.has(artifact?.architecture)) failures.push(`feed artifact architecture is invalid: ${artifact?.architecture ?? '<missing>'}.`);
      if (!validReleaseUrl(artifact?.url, document?.version)) failures.push(`feed artifact URL is not an allowed release path: ${artifact?.url ?? '<missing>'}.`);
      if (!validReleaseUrl(artifact?.signatureUrl, document?.version)) failures.push(`feed signature URL is not an allowed release path: ${artifact?.signatureUrl ?? '<missing>'}.`);
      if (!SHA256.test(artifact?.sha256 ?? '')) failures.push(`feed artifact SHA-256 is invalid: ${key}.`);
      if (!Number.isSafeInteger(artifact?.size) || artifact.size <= 0) failures.push(`feed artifact size is invalid: ${key}.`);
    }
    for (const architecture of ARCHITECTURES) {
      if (!keys.has(`appimage:${architecture}`)) failures.push(`feed is missing AppImage architecture: ${architecture}.`);
    }
  }
  if (document?.signature?.algorithm !== 'Ed25519') failures.push('feed signature algorithm must be Ed25519.');
  if (!SHA256.test(document?.signature?.publicKeySpkiSha256 ?? '')) failures.push('feed public-key fingerprint is invalid.');
  if (!validReleaseUrl(document?.signature?.url, document?.version)) failures.push('feed detached signature URL is not an allowed release path.');
  return failures;
}

export function classifyFeedResponse({ status, contentType, text, allowMissing = false, previousVersion = null }) {
  const failures = [];
  const warnings = [];
  let bodyKind = 'unknown';
  let keys;
  let document;
  const mime = (contentType ?? '').toLowerCase();

  if (status === 404) {
    bodyKind = 'missing';
    if (allowMissing) warnings.push('latest-linux.json is missing (404); allow-missing soft pass.');
    else failures.push('latest-linux.json returned HTTP 404.');
  } else if (status < 200 || status >= 300) {
    bodyKind = 'http-error';
    failures.push(`latest-linux.json HTTP ${status}`);
  } else if (looksLikeHtml(text, contentType)) {
    bodyKind = 'html';
    failures.push('latest-linux.json returned HTML (marketing shell) instead of JSON update metadata.');
  } else if (!mime.includes('application/json')) {
    bodyKind = 'wrong-mime';
    failures.push(`latest-linux.json has non-JSON content type: ${contentType ?? '<missing>'}.`);
  } else {
    try {
      document = JSON.parse(text);
      if (document === null || typeof document !== 'object' || Array.isArray(document)) {
        bodyKind = 'json-non-object';
        failures.push('latest-linux.json parsed but is not a JSON object.');
      } else {
        bodyKind = 'json';
        keys = Object.keys(document).slice(0, 20);
        failures.push(...validateFeedDocument(document, { previousVersion }));
      }
    } catch {
      bodyKind = 'non-json';
      failures.push('latest-linux.json body is not valid JSON.');
    }
  }
  return { bodyKind, failures, warnings, passed: failures.length === 0, keys, document };
}

export function finalizeFeedReport(report) {
  return { ...report, passed: (report.failures ?? []).length === 0 };
}

function compareSemver(left, right) {
  if (!SEMVER.test(left ?? '') || !SEMVER.test(right ?? '')) return -1;
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}
