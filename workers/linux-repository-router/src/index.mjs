const CHANNELS = new Set(['stable', 'prerelease', 'nightly']);
const APT_ARCHITECTURES = new Set(['amd64', 'arm64']);
const RPM_ARCHITECTURES = new Set(['aarch64', 'x86_64']);
const SNAPSHOT_ID_PATTERN = /^[a-f0-9]{64}$/u;
const VERSION_PATTERN = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const COMMIT_PATTERN = /^[a-f0-9]{40}$/u;
const ACTOR_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,96}|[A-Za-z0-9_-]{0,91}\[bot\])$/u;
const RUN_URL_PATTERN = /^https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/actions\/runs\/[1-9][0-9]*(?:\/attempts\/[1-9][0-9]*)?$/u;
const POINTER_PREFIX = 'linux/repository-activations';
const SNAPSHOT_PREFIX = 'linux/repository-snapshots';
const FEED_POINTER_PREFIX = 'linux/update-feed-activations';
const WORKER_ROLES = new Set(['serving', 'control', 'upload', 'feed']);
const MAX_ADMIN_BODY_BYTES = 16 * 1024;
const MAX_CLOSURE_BYTES = 1024 * 1024;
const MAX_CLOSURE_FILES = 512;
const MAX_ACTIVATION_HASH_BYTES = 8 * 1024 * 1024;
const MINIMUM_APT_VALIDITY_MS = 24 * 60 * 60 * 1000;
const IMMUTABLE_CACHE = 'public, max-age=31536000, immutable';
const POINTER_CACHE = 'no-cache, must-revalidate';
const BOOTSTRAP_CACHE = 'public, max-age=300, must-revalidate';
const OFFICIAL_FEED_PUBLIC_KEY_SPKI_BASE64 = 'MCowBQYDK2VwAyEAWPJHS2mAIVuX4A9POmB58154l2+c20up/WasNc9Tlng=';
const OFFICIAL_FEED_PUBLIC_KEY_SPKI_SHA256 = '0e0fd1f52af308d96c71571ef7e94f3e183218abf531760dfcc8ef8e499e5c37';

export default {
  fetch(request, env) {
    return handleRequest(request, env);
  }
};

export async function handleRequest(request, env, options = {}) {
  const now = options.now ?? (() => new Date());
  const feedVerification = options.feedVerification ?? {
    spki: base64Bytes(OFFICIAL_FEED_PUBLIC_KEY_SPKI_BASE64),
    fingerprint: OFFICIAL_FEED_PUBLIC_KEY_SPKI_SHA256
  };
  try {
    if (!env?.REPOSITORY_BUCKET) return problem(500, 'repository bucket binding is unavailable');
    if (!WORKER_ROLES.has(env.WORKER_ROLE)) return problem(500, 'repository worker role is invalid');
    const url = new URL(request.url);
    if (env.WORKER_ROLE === 'upload' && url.pathname.startsWith('/linux/repository-upload/')) {
      return handleImmutableUpload(request, url, env);
    }
    if (env.WORKER_ROLE === 'upload' && url.pathname.startsWith('/linux/repository-preview/')) {
      return handlePreview(request, url, env);
    }
    if (env.WORKER_ROLE === 'control' && url.pathname.startsWith('/linux/repository-admin/')) {
      return handleAdmin(request, url, env, now, feedVerification);
    }
    if (env.WORKER_ROLE === 'serving') return handlePublic(request, url, env);
    if (env.WORKER_ROLE === 'feed') return handleFeedPublic(request, url, env);
    return problem(404, 'repository route is unavailable for this worker role');
  } catch (error) {
    console.error('linux repository router failed', error);
    return problem(500, 'repository router failed closed');
  }
}

async function handleImmutableUpload(request, url, env) {
  if (!(await isAuthorized(request, env.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN))) {
    return jsonResponse(401, { error: 'unauthorized' }, { 'WWW-Authenticate': 'Bearer' });
  }
  if (url.pathname !== '/linux/repository-upload/immutable') {
    return jsonResponse(404, { error: 'unknown immutable repository upload route' });
  }
  if (request.method !== 'PUT') return methodNotAllowed('PUT');
  if (url.search) return jsonResponse(400, { error: 'immutable upload does not accept query parameters' });
  return putImmutableObject(request, env.REPOSITORY_BUCKET);
}

async function handleAdmin(request, url, env, now, feedVerification) {
  if (!(await isAuthorized(request, env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN))) {
    return jsonResponse(401, { error: 'unauthorized' }, { 'WWW-Authenticate': 'Bearer' });
  }
  if (url.pathname === '/linux/repository-admin/status') {
    if (request.method !== 'GET') return methodNotAllowed('GET');
    const channel = onlyChannelQuery(url);
    if (!channel) return jsonResponse(400, { error: 'query must contain exactly one supported channel' });
    const pointer = await readPointer(env.REPOSITORY_BUCKET, channel);
    if (!pointer) return jsonResponse(404, { schemaVersion: 1, status: 'inactive', channel });
    if (!pointer.valid) return jsonResponse(503, { error: 'activation pointer is invalid' });
    if (!pointer.active) {
      return jsonResponse(404, {
        schemaVersion: 1,
        status: 'inactive',
        channel,
        deactivation: pointer.record,
        pointerEtag: pointer.object.httpEtag
      }, { ETag: pointer.object.httpEtag });
    }
    return jsonResponse(200, {
      schemaVersion: 1,
      status: 'active',
      channel,
      activation: pointer.record,
      pointerEtag: pointer.object.httpEtag
    }, { ETag: pointer.object.httpEtag });
  }
  if (url.pathname === '/linux/repository-admin/activate') {
    if (request.method !== 'POST') return methodNotAllowed('POST');
    if (url.search) return jsonResponse(400, { error: 'activate does not accept query parameters' });
    return activate(request, env.REPOSITORY_BUCKET, now);
  }
  if (url.pathname === '/linux/repository-admin/deactivate') {
    if (request.method !== 'POST') return methodNotAllowed('POST');
    if (url.search) return jsonResponse(400, { error: 'deactivate does not accept query parameters' });
    return deactivate(request, env.REPOSITORY_BUCKET, now);
  }
  if (url.pathname === '/linux/repository-admin/feed-status') {
    if (request.method !== 'GET') return methodNotAllowed('GET');
    const channel = onlyChannelQuery(url);
    if (!channel) return jsonResponse(400, { error: 'query must contain exactly one supported channel' });
    const pointer = await readFeedPointer(env.REPOSITORY_BUCKET, channel);
    if (!pointer) return jsonResponse(404, { schemaVersion: 1, status: 'inactive', channel });
    if (!pointer.valid) return jsonResponse(503, { error: 'feed pointer is invalid' });
    return jsonResponse(200, {
      schemaVersion: 1,
      status: 'published',
      feed: pointer.record,
      pointerEtag: pointer.object.httpEtag
    }, { ETag: pointer.object.httpEtag });
  }
  if (url.pathname === '/linux/repository-admin/publish-feed') {
    if (request.method !== 'POST') return methodNotAllowed('POST');
    if (url.search) return jsonResponse(400, { error: 'publish-feed does not accept query parameters' });
    return publishFeed(request, env.REPOSITORY_BUCKET, now, feedVerification);
  }
  if (url.pathname === '/linux/repository-admin/rebind-feed') {
    if (request.method !== 'POST') return methodNotAllowed('POST');
    if (url.search) return jsonResponse(400, { error: 'rebind-feed does not accept query parameters' });
    return rebindFeed(request, env.REPOSITORY_BUCKET, now, feedVerification);
  }
  return jsonResponse(404, { error: 'unknown repository administration route' });
}

async function putImmutableObject(request, bucket) {
  const key = request.headers.get('x-openburnbar-object-key') ?? '';
  const sha256 = request.headers.get('x-openburnbar-object-sha256') ?? '';
  const contentType = request.headers.get('content-type') ?? 'application/octet-stream';
  const size = Number(request.headers.get('content-length') ?? -1);
  if (!validImmutableKey(key) || !SNAPSHOT_ID_PATTERN.test(sha256)
      || !Number.isSafeInteger(size) || size < 0 || size > 5 * 1024 * 1024 * 1024
      || !/^[\x20-\x7e]{1,200}$/u.test(contentType)) {
    return jsonResponse(400, { error: 'immutable object key, digest, size, or content type is invalid' });
  }
  const existing = await bucket.head(key);
  if (existing) return immutableExistingResponse(bucket, existing, key, sha256, size);
  const stored = await bucket.put(key, request.body, {
    onlyIf: new Headers({ 'If-None-Match': '*' }),
    sha256,
    httpMetadata: { contentType, cacheControl: IMMUTABLE_CACHE },
    customMetadata: { sha256 }
  });
  if (!stored) {
    const raced = await bucket.head(key);
    if (raced) return immutableExistingResponse(bucket, raced, key, sha256, size);
    return jsonResponse(409, { error: 'immutable object create lost a race without a readable winner' });
  }
  return jsonResponse(201, { schemaVersion: 1, status: 'created', key, sha256, size, etag: stored.httpEtag });
}

async function immutableExistingResponse(bucket, object, key, sha256, size) {
  if (object.size === size && object.customMetadata?.sha256 === sha256) {
    return jsonResponse(200, { schemaVersion: 1, status: 'unchanged', key, sha256, size, etag: object.httpEtag });
  }
  if (object.size === size && !object.customMetadata?.sha256 && size <= MAX_ACTIVATION_HASH_BYTES) {
    const existing = await bucket.get(key);
    if (existing && 'body' in existing
        && await sha256Hex(new Uint8Array(await existing.arrayBuffer())) === sha256) {
      return jsonResponse(200, {
        schemaVersion: 1,
        status: 'verified-legacy',
        key,
        sha256,
        size,
        etag: object.httpEtag
      });
    }
  }
  return jsonResponse(409, { error: 'immutable object already exists with different bytes', key });
}

function validImmutableKey(key) {
  if (typeof key !== 'string' || key.length < 1 || key.length > 900 || key.includes('//')
      || key.split('/').some((segment) => segment === '.' || segment === '..')
      || !/^[A-Za-z0-9._+~\/-]+$/u.test(key)) return false;
  if (/^linux\/releases\/linux-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\/[A-Za-z0-9][A-Za-z0-9._+~-]*$/u.test(key)) return true;
  if (/^linux\/repository-snapshots\/(stable|prerelease|nightly)\/[a-f0-9]{64}\/(?:repository-(?:closure\.json(?:\.asc)?|lifecycle\.json)|(?:apt|rpm)\/[A-Za-z0-9._+~\/-]+)$/u.test(key)) return true;
  const route = classifyPublicPath(`/${key}`);
  return Boolean(route && !route.snapshotRouted);
}

async function publishFeed(request, bucket, now, feedVerification) {
  const parsed = await readJsonRequest(request, MAX_ADMIN_BODY_BYTES, 'feed publication');
  if (!parsed.valid) return jsonResponse(parsed.status, { error: parsed.error });
  const input = parsed.value;
  const inputError = validateFeedPublicationInput(input);
  if (inputError) return jsonResponse(400, { error: inputError });

  const repository = await readPointer(bucket, input.channel);
  if (!repository?.valid || !repository.active) {
    return jsonResponse(409, { error: 'bound repository activation is unavailable' });
  }
  if (repository.record.generation !== input.generation
      || repository.record.snapshotId !== input.snapshotId
      || repository.record.version !== input.version
      || repository.record.sourceCommit !== input.sourceCommit
      || repository.object.httpEtag !== input.repositoryPointerEtag) {
    return jsonResponse(409, { error: 'repository activation no longer matches feed publication request' });
  }

  const current = await readFeedPointer(bucket, input.channel);
  if (current && !current.valid) return jsonResponse(503, { error: 'current feed pointer is invalid' });
  const expected = input.expectedCurrent;
  if ((!current && (expected.generation !== null || expected.etag !== null))
      || (current && (expected.generation !== current.record.generation || expected.etag !== current.object.httpEtag))) {
    return jsonResponse(409, {
      error: 'feed compare-and-swap precondition failed',
      currentGeneration: current?.record.generation ?? null,
      currentEtag: current?.object.httpEtag ?? null
    });
  }

  const bundle = await validateFeedBundle(bucket, input, feedVerification);
  if (!bundle.valid) return jsonResponse(409, { error: bundle.error });
  if (current?.record.generation >= Number.MAX_SAFE_INTEGER) {
    return jsonResponse(409, { error: 'feed generation is exhausted' });
  }
  const publishedAt = now();
  if (!(publishedAt instanceof Date) || !Number.isFinite(publishedAt.getTime())) {
    return jsonResponse(500, { error: 'feed publication clock is invalid' });
  }
  const record = {
    schemaVersion: 1,
    generation: (current?.record.generation ?? 0) + 1,
    channel: input.channel,
    repository: {
      generation: input.generation,
      snapshotId: input.snapshotId,
      pointerEtag: input.repositoryPointerEtag
    },
    version: input.version,
    sourceCommit: input.sourceCommit,
    feed: input.feed,
    publishedAt: publishedAt.toISOString(),
    previousFeed: current ? feedIdentity(current.record) : null
  };
  const onlyIf = current
    ? { etagMatches: current.object.etag }
    : new Headers({ 'If-None-Match': '*' });
  const stored = await bucket.put(feedPointerKey(input.channel), `${JSON.stringify(record, null, 2)}\n`, {
    onlyIf,
    httpMetadata: { contentType: 'application/json; charset=utf-8', cacheControl: 'no-store' }
  });
  if (!stored) return jsonResponse(409, { error: 'feed publication lost a concurrent compare-and-swap race' });
  const after = await readPointer(bucket, input.channel);
  if (!repositoryPointerMatchesFeed(after, record)) {
    return jsonResponse(409, { error: 'repository changed during feed publication; channel feed is fail-closed' });
  }
  return jsonResponse(200, {
    schemaVersion: 1,
    status: 'published',
    feed: record,
    pointerEtag: stored.httpEtag
  }, { ETag: stored.httpEtag });
}

async function rebindFeed(request, bucket, now, feedVerification) {
  const parsed = await readJsonRequest(request, MAX_ADMIN_BODY_BYTES, 'feed rebind');
  if (!parsed.valid) return jsonResponse(parsed.status, { error: parsed.error });
  const input = parsed.value;
  const inputError = validateFeedRebindInput(input);
  if (inputError) return jsonResponse(400, { error: inputError });

  const current = await readFeedPointer(bucket, input.channel);
  if (!current?.valid) {
    return jsonResponse(current ? 503 : 409, {
      error: current ? 'current feed pointer is invalid' : 'feed pointer is unavailable'
    });
  }
  if (current.record.generation !== input.expectedCurrent.generation
      || current.object.httpEtag !== input.expectedCurrent.etag) {
    return jsonResponse(409, {
      error: 'feed rebind compare-and-swap precondition failed',
      currentGeneration: current.record.generation,
      currentEtag: current.object.httpEtag
    });
  }

  const repository = await readPointer(bucket, input.channel);
  if (!repository?.valid || !repository.active) {
    return jsonResponse(409, { error: 'active repository pointer is unavailable for feed rebind' });
  }
  if (!repositoryIdentityMatches(input.expectedRepository, repository)) {
    return jsonResponse(409, {
      error: 'repository rebind compare-and-swap precondition failed',
      currentGeneration: repository.record.generation,
      currentSnapshotId: repository.record.snapshotId,
      currentEtag: repository.object.httpEtag
    });
  }

  const candidate = input.target === 'current'
    ? feedIdentity(current.record)
    : current.record.previousFeed;
  if (!candidate) return jsonResponse(409, { error: 'feed pointer has no retained previous feed' });
  if (candidate.channel !== input.channel
      || candidate.version !== repository.record.version
      || candidate.sourceCommit !== repository.record.sourceCommit) {
    return jsonResponse(409, { error: 'selected feed identity does not match the active repository' });
  }
  const bundle = await validateFeedBundle(bucket, candidate, feedVerification);
  if (!bundle.valid) return jsonResponse(409, { error: bundle.error });
  if (current.record.generation >= Number.MAX_SAFE_INTEGER) {
    return jsonResponse(409, { error: 'feed generation is exhausted' });
  }
  const reboundAt = now();
  if (!(reboundAt instanceof Date) || !Number.isFinite(reboundAt.getTime())) {
    return jsonResponse(500, { error: 'feed rebind clock is invalid' });
  }
  const record = {
    schemaVersion: 1,
    generation: current.record.generation + 1,
    channel: candidate.channel,
    repository: {
      generation: repository.record.generation,
      snapshotId: repository.record.snapshotId,
      pointerEtag: repository.object.httpEtag
    },
    version: candidate.version,
    sourceCommit: candidate.sourceCommit,
    feed: candidate.feed,
    publishedAt: candidate.publishedAt,
    previousFeed: input.target === 'previous' ? feedIdentity(current.record) : current.record.previousFeed
  };
  const stored = await bucket.put(feedPointerKey(input.channel), `${JSON.stringify(record, null, 2)}\n`, {
    onlyIf: { etagMatches: current.object.etag },
    httpMetadata: { contentType: 'application/json; charset=utf-8', cacheControl: 'no-store' }
  });
  if (!stored) return jsonResponse(409, { error: 'feed rebind lost a concurrent compare-and-swap race' });
  const repositoryAfterWrite = await readPointer(bucket, input.channel);
  if (!repositoryPointerMatchesFeed(repositoryAfterWrite, record)) {
    return jsonResponse(409, { error: 'repository changed during feed rebind; channel feed is fail-closed' });
  }
  return jsonResponse(200, {
    schemaVersion: 1,
    status: 'rebound',
    target: input.target,
    feed: record,
    pointerEtag: stored.httpEtag,
    reboundAt: reboundAt.toISOString()
  }, { ETag: stored.httpEtag });
}

async function validateFeedBundle(bucket, input, feedVerification) {
  if (!(feedVerification.spki instanceof Uint8Array)
      || await sha256Hex(feedVerification.spki) !== feedVerification.fingerprint) {
    return { valid: false, error: 'bundled feed verification key fingerprint is invalid' };
  }
  const feedObject = await bucket.get(input.feed.key);
  if (!feedObject || !('body' in feedObject) || feedObject.size !== input.feed.size
      || feedObject.size > MAX_CLOSURE_BYTES) {
    return { valid: false, error: 'immutable feed object is missing or size-mismatched' };
  }
  const feedBytes = new Uint8Array(await feedObject.arrayBuffer());
  if (feedBytes.byteLength !== input.feed.size || await sha256Hex(feedBytes) !== input.feed.sha256) {
    return { valid: false, error: 'immutable feed object digest does not match publication request' };
  }
  let document;
  try {
    document = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(feedBytes));
  } catch {
    return { valid: false, error: 'immutable feed object is not valid UTF-8 JSON' };
  }
  const documentError = validateFeedDocument(document, input, feedVerification.fingerprint);
  if (documentError) return { valid: false, error: documentError };

  const signature = await bucket.get(input.feed.signatureKey);
  if (!signature || !('body' in signature) || signature.size !== input.feed.signatureSize
      || signature.size <= 0 || signature.size > MAX_CLOSURE_BYTES) {
    return { valid: false, error: 'immutable feed signature is missing or size-mismatched' };
  }
  const signatureBytes = new Uint8Array(await signature.arrayBuffer());
  if (signatureBytes.byteLength !== input.feed.signatureSize
      || await sha256Hex(signatureBytes) !== input.feed.signatureSha256) {
    return { valid: false, error: 'immutable feed signature digest does not match publication request' };
  }
  if (signatureBytes.byteLength !== 64
      || !await verifyEd25519(feedVerification.spki, signatureBytes, feedBytes)) {
    return { valid: false, error: 'immutable feed detached Ed25519 signature verification failed' };
  }
  for (const artifact of document.artifacts) {
    const key = new URL(artifact.url).pathname.slice(1);
    const object = await bucket.head(key);
    if (!object || object.size !== artifact.size || object.customMetadata?.sha256 !== artifact.sha256) {
      return { valid: false, error: `signed feed artifact is missing or integrity metadata drifted: ${key}` };
    }
  }
  return { valid: true };
}

function validateFeedDocument(document, input, expectedFingerprint) {
  const topLevel = ['schemaVersion', 'product', 'platform', 'version', 'gitCommit', 'publishedAt', 'channel', 'artifacts', 'signature'];
  const fieldSet = Object.keys(document ?? {}).sort();
  const baseFieldSet = [...topLevel].sort();
  const notesFieldSet = [...topLevel, 'notes'].sort();
  if (!isPlainObject(document)
      || (JSON.stringify(fieldSet) !== JSON.stringify(baseFieldSet)
        && JSON.stringify(fieldSet) !== JSON.stringify(notesFieldSet))
      || document.schemaVersion !== 1 || document.product !== 'OpenBurnBar' || document.platform !== 'linux'
      || document.version !== input.version || document.gitCommit !== input.sourceCommit
      || document.channel !== input.channel || typeof document.publishedAt !== 'string'
      || !Number.isFinite(Date.parse(document.publishedAt))
      || ('notes' in document && (typeof document.notes !== 'string'
        || document.notes.length === 0 || document.notes.length > 8192))) {
    return 'feed document identity does not match publication request';
  }
  if (!Array.isArray(document.artifacts) || document.artifacts.length < 2 || document.artifacts.length > 32) {
    return 'feed document artifact set is invalid';
  }
  const releasePrefix = `https://downloads.burnbar.ai/linux/releases/linux-v${input.version}/`;
  const seen = new Set();
  for (const artifact of document.artifacts) {
    if (!isPlainObject(artifact)
        || !hasExactKeys(artifact, ['type', 'architecture', 'url', 'sha256', 'size', 'signatureUrl'])
        || !['appimage', 'deb', 'rpm', 'daemon'].includes(artifact.type)
        || !['aarch64', 'x86_64'].includes(artifact.architecture)
        || !validReleaseUrl(artifact.url, releasePrefix)
        || !validReleaseUrl(artifact.signatureUrl, releasePrefix)
        || !SNAPSHOT_ID_PATTERN.test(artifact.sha256 ?? '')
        || !Number.isSafeInteger(artifact.size) || artifact.size <= 0) {
      return 'feed document contains an invalid artifact';
    }
    const identity = `${artifact.type}:${artifact.architecture}`;
    if (seen.has(identity)) return 'feed document contains a duplicate artifact identity';
    seen.add(identity);
  }
  if (!seen.has('appimage:aarch64') || !seen.has('appimage:x86_64')) {
    return 'feed document omits a required AppImage architecture';
  }
  const expectedSignatureUrl = `${releasePrefix}latest-linux.json.ed25519.sig`;
  if (!isPlainObject(document.signature)
      || !hasExactKeys(document.signature, ['algorithm', 'publicKeySpkiSha256', 'url'])
      || document.signature.algorithm !== 'Ed25519'
      || document.signature.publicKeySpkiSha256 !== expectedFingerprint
      || document.signature.url !== expectedSignatureUrl) {
    return 'feed document signature identity or URL is invalid';
  }
  return null;
}

function validReleaseUrl(value, prefix) {
  if (typeof value !== 'string' || !value.startsWith(prefix)) return false;
  const filename = value.slice(prefix.length);
  return filename.length > 0 && filename.length <= 255 && /^[A-Za-z0-9][A-Za-z0-9._+~-]*$/u.test(filename);
}

function validateFeedPublicationInput(input) {
  const keys = ['schemaVersion', 'channel', 'generation', 'snapshotId', 'version', 'sourceCommit',
    'repositoryPointerEtag', 'feed', 'expectedCurrent'];
  if (!isPlainObject(input) || !hasExactKeys(input, keys)) return 'feed publication request has an invalid field set';
  if (input.schemaVersion !== 1 || !CHANNELS.has(input.channel)
      || !Number.isSafeInteger(input.generation) || input.generation <= 0
      || !SNAPSHOT_ID_PATTERN.test(input.snapshotId ?? '') || !VERSION_PATTERN.test(input.version ?? '')
      || !COMMIT_PATTERN.test(input.sourceCommit ?? '') || !validHttpEtag(input.repositoryPointerEtag)) {
    return 'feed publication repository identity is invalid';
  }
  const expectedFeedKey = `linux/releases/linux-v${input.version}/latest-linux.json`;
  if (!isPlainObject(input.feed)
      || !hasExactKeys(input.feed, ['key', 'signatureKey', 'sha256', 'size', 'signatureSha256', 'signatureSize'])
      || input.feed.key !== expectedFeedKey
      || input.feed.signatureKey !== `${expectedFeedKey}.ed25519.sig`
      || !SNAPSHOT_ID_PATTERN.test(input.feed.sha256 ?? '')
      || !SNAPSHOT_ID_PATTERN.test(input.feed.signatureSha256 ?? '')
      || !Number.isSafeInteger(input.feed.size) || input.feed.size <= 0 || input.feed.size > MAX_CLOSURE_BYTES
      || !Number.isSafeInteger(input.feed.signatureSize) || input.feed.signatureSize <= 0
      || input.feed.signatureSize > MAX_CLOSURE_BYTES) {
    return 'feed publication bundle identity is invalid';
  }
  if (!isPlainObject(input.expectedCurrent) || !hasExactKeys(input.expectedCurrent, ['generation', 'etag'])
      || !((input.expectedCurrent.generation === null && input.expectedCurrent.etag === null)
        || (Number.isSafeInteger(input.expectedCurrent.generation) && input.expectedCurrent.generation > 0
          && validHttpEtag(input.expectedCurrent.etag)))) {
    return 'feed publication expectedCurrent CAS identity is invalid';
  }
  return null;
}

function validateFeedRebindInput(input) {
  const keys = ['schemaVersion', 'channel', 'target', 'expectedCurrent', 'expectedRepository',
    'actor', 'runUrl', 'reason'];
  if (!isPlainObject(input) || !hasExactKeys(input, keys)) return 'feed rebind request has an invalid field set';
  if (input.schemaVersion !== 1 || !CHANNELS.has(input.channel) || !['current', 'previous'].includes(input.target)) {
    return 'feed rebind channel or target is invalid';
  }
  if (!validExpectedPointer(input.expectedCurrent, false)) {
    return 'feed rebind expectedCurrent identity is invalid';
  }
  if (!isPlainObject(input.expectedRepository)
      || !hasExactKeys(input.expectedRepository, ['generation', 'snapshotId', 'pointerEtag'])
      || !Number.isSafeInteger(input.expectedRepository.generation) || input.expectedRepository.generation <= 0
      || !SNAPSHOT_ID_PATTERN.test(input.expectedRepository.snapshotId ?? '')
      || !validHttpEtag(input.expectedRepository.pointerEtag)) {
    return 'feed rebind expectedRepository identity is invalid';
  }
  if (!ACTOR_PATTERN.test(input.actor ?? '')) return 'actor is invalid';
  if (input.runUrl !== null && !RUN_URL_PATTERN.test(input.runUrl ?? '')) {
    return 'runUrl must be null or an OpenBurnBar GitHub Actions run URL';
  }
  if (!validReason(input.reason)) return 'reason must contain 8-500 printable characters';
  return null;
}

function validExpectedPointer(value, allowAbsent) {
  if (!isPlainObject(value) || !hasExactKeys(value, ['generation', 'etag'])) return false;
  if (value.generation === null || value.etag === null) {
    return allowAbsent && value.generation === null && value.etag === null;
  }
  return Number.isSafeInteger(value.generation) && value.generation > 0 && validHttpEtag(value.etag);
}

function validHttpEtag(value) {
  return typeof value === 'string' && /^"[a-f0-9]{32,64}(?:-[1-9][0-9]*)?"$/u.test(value);
}

async function handlePreview(request, url, env) {
  if (!['GET', 'HEAD'].includes(request.method)) return methodNotAllowed('GET, HEAD');
  if (url.search || url.hash || /%|\/\//u.test(url.pathname)) return problem(404, 'repository preview object not found');
  const segments = url.pathname.split('/').slice(1);
  if (segments.length < 6 || segments[0] !== 'linux' || segments[1] !== 'repository-preview'
      || !CHANNELS.has(segments[2]) || !SNAPSHOT_ID_PATTERN.test(segments[3])
      || !['apt', 'rpm'].includes(segments[4])) {
    return problem(404, 'repository preview object not found');
  }
  const channel = segments[2];
  const snapshotId = segments[3];
  const relative = segments.slice(4).join('/');
  const route = classifyPublicPath(`/linux/${relative}`);
  if (!route || (route.channel && route.channel !== channel) || !previewBootstrapMatchesChannel(relative, channel)) {
    return problem(404, 'repository preview object not found');
  }
  const key = `${snapshotPrefixFor(channel, snapshotId)}/${relative}`;
  const response = await serveObject(request, env.REPOSITORY_BUCKET, key, IMMUTABLE_CACHE);
  response.headers.set('X-OpenBurnBar-Repository-Snapshot', snapshotId);
  return response;
}

function previewBootstrapMatchesChannel(relative, channel) {
  const aptSource = relative.match(/^apt\/openburnbar-(stable|prerelease|nightly)\.sources$/u);
  if (aptSource) return aptSource[1] === channel;
  const rpmRepo = relative.match(/^rpm\/openburnbar-(stable|prerelease|nightly)\.repo$/u);
  return !rpmRepo || rpmRepo[1] === channel;
}

async function activate(request, bucket, now) {
  const contentType = request.headers.get('content-type') ?? '';
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(contentType)) {
    return jsonResponse(415, { error: 'Content-Type must be application/json' });
  }
  const declaredLength = Number(request.headers.get('content-length') ?? 0);
  if (declaredLength > MAX_ADMIN_BODY_BYTES) return jsonResponse(413, { error: 'activation request is too large' });
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_ADMIN_BODY_BYTES) {
    return jsonResponse(bytes.byteLength === 0 ? 400 : 413, { error: 'activation request body size is invalid' });
  }
  let input;
  try {
    input = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch {
    return jsonResponse(400, { error: 'activation request must be valid UTF-8 JSON' });
  }
  const inputError = validateActivationInput(input);
  if (inputError) return jsonResponse(400, { error: inputError });

  const current = await readPointer(bucket, input.channel);
  if (current && !current.valid) return jsonResponse(503, { error: 'current activation pointer is invalid' });
  const currentSnapshotId = current?.active ? current.record.snapshotId : null;
  const currentGeneration = current?.record.generation ?? null;
  const currentPointerEtag = current?.object.httpEtag ?? null;
  if (input.expectedCurrentSnapshotId !== currentSnapshotId
      || input.expectedCurrentGeneration !== currentGeneration
      || input.expectedCurrentPointerEtag !== currentPointerEtag) {
    return jsonResponse(409, {
      error: 'activation compare-and-swap precondition failed',
      currentSnapshotId,
      currentGeneration,
      currentPointerEtag
    });
  }
  if (input.targetSnapshotId === currentSnapshotId) {
    return jsonResponse(409, { error: 'target snapshot is already active', currentSnapshotId });
  }
  if (current?.active && input.mode === 'promote' && compareVersions(input.version, current.record.version) <= 0) {
    return jsonResponse(409, { error: 'promotion version must be strictly newer than the active version' });
  }
  if (current && !current.active && input.mode === 'promote') {
    const retryingExactDeactivatedSnapshot = input.targetSnapshotId === current.record.previousSnapshotId
      && input.version === current.record.previousVersion
      && input.sourceCommit === current.record.previousSourceCommit;
    if (!retryingExactDeactivatedSnapshot
        && compareVersions(input.version, current.record.previousVersion) <= 0) {
      return jsonResponse(409, {
        error: 'promotion after deactivation must retry the exact prior snapshot or use a strictly newer version'
      });
    }
  }
  if (current?.active && input.mode === 'rollback' && input.targetSnapshotId !== current.record.previousSnapshotId) {
    return jsonResponse(409, { error: 'rollback target must be the active generation previousSnapshotId' });
  }
  if ((!current || !current.active) && input.mode === 'rollback') {
    return jsonResponse(409, { error: 'cannot rollback an inactive channel' });
  }
  if (current?.record.generation >= Number.MAX_SAFE_INTEGER) {
    return jsonResponse(409, { error: 'activation generation is exhausted' });
  }

  const activatedAt = now();
  if (!(activatedAt instanceof Date) || !Number.isFinite(activatedAt.getTime())) {
    return jsonResponse(500, { error: 'activation clock is invalid' });
  }
  const target = await validateTargetSnapshot(bucket, input, activatedAt);
  if (!target.valid) return jsonResponse(target.status, { error: target.error });
  const activation = {
    schemaVersion: 1,
    mode: input.mode,
    channel: input.channel,
    generation: (current?.record.generation ?? 0) + 1,
    snapshotId: input.targetSnapshotId,
    closureSha256: input.targetSnapshotId,
    version: input.version,
    sourceCommit: input.sourceCommit,
    activatedAt: activatedAt.toISOString(),
    previousSnapshotId: currentSnapshotId,
    actor: input.actor,
    runUrl: input.runUrl,
    reason: input.reason
  };
  const pointerKey = pointerKeyFor(input.channel);
  const onlyIf = current
    ? { etagMatches: current.object.etag }
    : new Headers({ 'If-None-Match': '*' });
  const stored = await bucket.put(pointerKey, `${JSON.stringify(activation, null, 2)}\n`, {
    onlyIf,
    httpMetadata: {
      contentType: 'application/json; charset=utf-8',
      cacheControl: 'no-store'
    }
  });
  if (!stored) {
    return jsonResponse(409, { error: 'activation lost a concurrent compare-and-swap race' });
  }
  return jsonResponse(200, {
    schemaVersion: 1,
    status: 'activated',
    activation,
    pointerEtag: stored.httpEtag
  }, { ETag: stored.httpEtag });
}

async function deactivate(request, bucket, now) {
  const parsed = await readJsonRequest(request, MAX_ADMIN_BODY_BYTES, 'deactivation');
  if (!parsed.valid) return jsonResponse(parsed.status, { error: parsed.error });
  const input = parsed.value;
  const inputError = validateDeactivationInput(input);
  if (inputError) return jsonResponse(400, { error: inputError });

  const current = await readPointer(bucket, input.channel);
  if (current && !current.valid) return jsonResponse(503, { error: 'current activation pointer is invalid' });
  if (!current || !current.active) {
    return jsonResponse(409, { error: 'repository channel is already inactive', currentSnapshotId: null });
  }
  if (input.expectedCurrentSnapshotId !== current.record.snapshotId) {
    return jsonResponse(409, {
      error: 'deactivation compare-and-swap precondition failed',
      currentSnapshotId: current.record.snapshotId
    });
  }
  if (input.expectedCurrentGeneration !== current.record.generation
      || input.expectedCurrentPointerEtag !== current.object.httpEtag) {
    return jsonResponse(409, {
      error: 'deactivation compare-and-swap precondition failed',
      currentSnapshotId: current.record.snapshotId,
      currentGeneration: current.record.generation,
      currentPointerEtag: current.object.httpEtag
    });
  }
  if (current.record.generation >= Number.MAX_SAFE_INTEGER) {
    return jsonResponse(409, { error: 'activation generation is exhausted' });
  }

  const deactivatedAt = now();
  if (!(deactivatedAt instanceof Date) || !Number.isFinite(deactivatedAt.getTime())) {
    return jsonResponse(500, { error: 'deactivation clock is invalid' });
  }
  const deactivation = {
    schemaVersion: 1,
    status: 'inactive',
    channel: input.channel,
    generation: current.record.generation + 1,
    previousSnapshotId: current.record.snapshotId,
    previousVersion: current.record.version,
    previousSourceCommit: current.record.sourceCommit,
    fallbackMode: current.record.previousSnapshotId === null ? 'legacy-direct-r2' : 'disabled',
    deactivatedAt: deactivatedAt.toISOString(),
    actor: input.actor,
    runUrl: input.runUrl,
    reason: input.reason
  };
  const stored = await bucket.put(pointerKeyFor(input.channel), `${JSON.stringify(deactivation, null, 2)}\n`, {
    onlyIf: { etagMatches: current.object.etag },
    httpMetadata: {
      contentType: 'application/json; charset=utf-8',
      cacheControl: 'no-store'
    }
  });
  if (!stored) return jsonResponse(409, { error: 'deactivation lost a concurrent compare-and-swap race' });
  return jsonResponse(200, {
    schemaVersion: 1,
    status: 'inactive',
    channel: input.channel,
    previousSnapshotId: current.record.snapshotId,
    fallbackMode: deactivation.fallbackMode,
    generation: deactivation.generation,
    pointerEtag: stored.httpEtag
  }, { ETag: stored.httpEtag });
}

async function readJsonRequest(request, limit, label) {
  const contentType = request.headers.get('content-type') ?? '';
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(contentType)) {
    return { valid: false, status: 415, error: 'Content-Type must be application/json' };
  }
  const declaredLength = Number(request.headers.get('content-length') ?? 0);
  if (declaredLength > limit) return { valid: false, status: 413, error: `${label} request is too large` };
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength === 0 || bytes.byteLength > limit) {
    return { valid: false, status: bytes.byteLength === 0 ? 400 : 413, error: `${label} request body size is invalid` };
  }
  try {
    return { valid: true, value: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) };
  } catch {
    return { valid: false, status: 400, error: `${label} request must be valid UTF-8 JSON` };
  }
}

async function validateTargetSnapshot(bucket, input, activatedAt) {
  const prefix = snapshotPrefixFor(input.channel, input.targetSnapshotId);
  const closure = await bucket.get(`${prefix}/repository-closure.json`);
  if (!closure || !('body' in closure)) {
    return { valid: false, status: 409, error: 'target snapshot closure is missing' };
  }
  if (closure.size > MAX_CLOSURE_BYTES) {
    return { valid: false, status: 409, error: 'target snapshot closure exceeds the size limit' };
  }
  const closureBytes = new Uint8Array(await closure.arrayBuffer());
  if (closureBytes.byteLength > MAX_CLOSURE_BYTES) {
    return { valid: false, status: 409, error: 'target snapshot closure exceeds the size limit' };
  }
  if (await sha256Hex(closureBytes) !== input.targetSnapshotId) {
    return { valid: false, status: 409, error: 'target snapshot ID does not match closure bytes' };
  }
  let document;
  try {
    document = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(closureBytes));
  } catch {
    return { valid: false, status: 409, error: 'target snapshot closure is invalid JSON' };
  }
  if (!isPlainObject(document)
      || ![1, 2].includes(document.schemaVersion)
      || document.channel !== input.channel
      || document.version !== input.version
      || document.gitCommit !== input.sourceCommit) {
    return { valid: false, status: 409, error: 'target snapshot closure identity does not match activation request' };
  }
  const closureFiles = validateClosureFiles(document.files, input.channel);
  if (!closureFiles.valid) return { valid: false, status: 409, error: closureFiles.error };
  const validUntil = Date.parse(document.repositories?.apt?.validUntil ?? '');
  if (!Number.isFinite(validUntil) || validUntil < activatedAt.getTime() + MINIMUM_APT_VALIDITY_MS) {
    return { valid: false, status: 409, error: 'target snapshot apt metadata has less than 24 hours of validity remaining' };
  }
  for (const row of closureFiles.files) {
    const key = `${prefix}/${row.file}`;
    const object = await bucket.head(key);
    if (!object || object.size !== row.size) {
      return { valid: false, status: 409, error: `target snapshot object is missing or size-mismatched: ${row.file}` };
    }
    if (row.size <= MAX_ACTIVATION_HASH_BYTES) {
      const body = await bucket.get(key);
      if (!body || !('body' in body) || await sha256Hex(new Uint8Array(await body.arrayBuffer())) !== row.sha256) {
        return { valid: false, status: 409, error: `target snapshot object hash does not match closure: ${row.file}` };
      }
    } else if (object.customMetadata?.sha256 !== row.sha256) {
      return { valid: false, status: 409,
        error: `target snapshot large-object integrity metadata does not match closure: ${row.file}` };
    }
  }
  const signature = await bucket.head(`${prefix}/repository-closure.json.asc`);
  if (!signature || signature.size <= 0) {
    return { valid: false, status: 409, error: 'target snapshot closure signature is missing' };
  }
  return { valid: true };
}

function validateClosureFiles(files, channel) {
  if (!Array.isArray(files) || files.length === 0 || files.length > MAX_CLOSURE_FILES) {
    return { valid: false, error: `target snapshot closure must contain 1-${MAX_CLOSURE_FILES} files` };
  }
  const seen = new Set();
  for (const row of files) {
    if (!isPlainObject(row) || !hasExactKeys(row, ['file', 'sha256', 'size'])
        || typeof row.file !== 'string' || row.file.length > 500
        || !/^(apt|rpm)\/[A-Za-z0-9._+~\/-]+$/u.test(row.file)
        || row.file.includes('//') || row.file.split('/').some((segment) => segment === '.' || segment === '..')
        || !SNAPSHOT_ID_PATTERN.test(row.sha256 ?? '')
        || !Number.isSafeInteger(row.size) || row.size < 0 || seen.has(row.file)) {
      return { valid: false, error: 'target snapshot closure contains an invalid file record' };
    }
    seen.add(row.file);
  }
  const required = [
    'apt/openburnbar-archive-keyring.gpg',
    `apt/openburnbar-${channel}.sources`,
    `apt/dists/${channel}/InRelease`,
    `apt/dists/${channel}/Release`,
    `apt/dists/${channel}/Release.gpg`,
    'rpm/RPM-GPG-KEY-openburnbar',
    `rpm/openburnbar-${channel}.repo`,
    `rpm/${channel}/aarch64/repodata/repomd.xml`,
    `rpm/${channel}/aarch64/repodata/repomd.xml.asc`,
    `rpm/${channel}/x86_64/repodata/repomd.xml`,
    `rpm/${channel}/x86_64/repodata/repomd.xml.asc`
  ];
  if (required.some((file) => !seen.has(file))) {
    return { valid: false, error: 'target snapshot closure omits required apt/RPM activation roots' };
  }
  return { valid: true, files };
}

async function handlePublic(request, url, env) {
  if (!['GET', 'HEAD'].includes(request.method)) return methodNotAllowed('GET, HEAD');
  if (url.search || url.hash || /%|\/\//u.test(url.pathname)) return problem(404, 'repository object not found');
  const route = classifyPublicPath(url.pathname);
  if (!route) return problem(404, 'repository object not found');

  let key = route.key;
  let snapshotId = null;
  if (route.snapshotRouted) {
    const pointer = await readPointer(env.REPOSITORY_BUCKET, route.channel);
    if (!pointer?.valid) return problem(503, 'repository channel has no valid active snapshot');
    if (pointer.active) {
      snapshotId = pointer.record.snapshotId;
      key = `${snapshotPrefixFor(route.channel, snapshotId)}/${route.snapshotRelative}`;
    } else if (pointer.record.fallbackMode !== 'legacy-direct-r2') {
      return problem(503, 'repository channel is inactive with legacy fallback disabled');
    }
  }
  const response = await serveObject(request, env.REPOSITORY_BUCKET, key, route.cacheControl);
  if (snapshotId && response.status === 404) {
    return problem(503, 'active repository snapshot is incomplete');
  }
  if (snapshotId) response.headers.set('X-OpenBurnBar-Repository-Snapshot', snapshotId);
  return response;
}

async function handleFeedPublic(request, url, env) {
  if (!['GET', 'HEAD'].includes(request.method)) return methodNotAllowed('GET, HEAD');
  const route = classifyFeedPublicPath(url.pathname);
  if (url.search || url.hash || !route) {
    return problem(404, 'Linux update feed not found');
  }
  const feedPointer = await readFeedPointer(env.REPOSITORY_BUCKET, route.channel);
  if (feedPointer && !feedPointer.valid) {
    return problem(503, 'Linux update feed has no valid active publication');
  }
  const repository = await readPointer(env.REPOSITORY_BUCKET, route.channel);
  if (repository?.valid && !repository.active) {
    if (repository.record.fallbackMode !== 'legacy-direct-r2') {
      return problem(503, 'Linux update feed is inactive with legacy fallback disabled');
    }
    if (route.channel !== 'stable') return problem(404, 'Linux update feed not found');
    const response = await serveObject(
      request,
      env.REPOSITORY_BUCKET,
      route.rawRootKey,
      POINTER_CACHE
    );
    const repositoryAfterFallbackRead = await readPointer(env.REPOSITORY_BUCKET, route.channel);
    if (!repositoryAfterFallbackRead?.valid
        || repositoryAfterFallbackRead.active
        || repositoryAfterFallbackRead.record.fallbackMode !== 'legacy-direct-r2'
        || repositoryAfterFallbackRead.object.httpEtag !== repository.object.httpEtag) {
      return problem(503, 'Linux update feed fallback changed during request');
    }
    return response;
  }
  if (!feedPointer) return problem(503, 'Linux update feed has no valid active publication');
  if (!repositoryPointerMatchesFeed(repository, feedPointer.record)) {
    return problem(503, 'Linux update feed does not match the active repository generation');
  }
  const key = route.signature
    ? feedPointer.record.feed.signatureKey
    : feedPointer.record.feed.key;
  const response = await serveObject(request, env.REPOSITORY_BUCKET, key, POINTER_CACHE);
  if (response.status === 404) return problem(503, 'active Linux update feed bundle is incomplete');
  const feedPointerAfterRead = await readFeedPointer(env.REPOSITORY_BUCKET, route.channel);
  if (!feedPointerAfterRead?.valid
      || feedPointerAfterRead.object.httpEtag !== feedPointer.object.httpEtag) {
    return problem(503, 'Linux update feed publication changed during request');
  }
  const repositoryAfterRead = await readPointer(env.REPOSITORY_BUCKET, route.channel);
  if (!repositoryPointerMatchesFeed(repositoryAfterRead, feedPointer.record)) {
    return problem(503, 'Linux update feed repository binding changed during request');
  }
  response.headers.set('X-OpenBurnBar-Repository-Snapshot', feedPointer.record.repository.snapshotId);
  response.headers.set('X-OpenBurnBar-Feed-Generation', String(feedPointer.record.generation));
  return response;
}

function classifyFeedPublicPath(pathname) {
  if (pathname === '/latest-linux.json') {
    return { channel: 'stable', signature: false, rawRootKey: 'latest-linux.json' };
  }
  if (pathname === '/latest-linux.json.ed25519.sig') {
    return { channel: 'stable', signature: true, rawRootKey: 'latest-linux.json.ed25519.sig' };
  }
  const match = pathname.match(
    /^\/linux\/update\/(stable|prerelease|nightly)\/(latest-linux\.json(?:\.ed25519\.sig)?)$/u
  );
  if (!match) return null;
  return {
    channel: match[1],
    signature: match[2].endsWith('.sig'),
    rawRootKey: match[2]
  };
}

function repositoryPointerMatchesFeed(pointer, feedRecord) {
  return Boolean(pointer?.valid
    && pointer.active
    && pointer.record.channel === feedRecord.channel
    && pointer.record.generation === feedRecord.repository.generation
    && pointer.record.snapshotId === feedRecord.repository.snapshotId
    && pointer.record.version === feedRecord.version
    && pointer.record.sourceCommit === feedRecord.sourceCommit
    && pointer.object.httpEtag === feedRecord.repository.pointerEtag);
}

function repositoryIdentityMatches(expected, pointer) {
  return pointer.record.generation === expected.generation
    && pointer.record.snapshotId === expected.snapshotId
    && pointer.object.httpEtag === expected.pointerEtag;
}

function classifyPublicPath(pathname) {
  const segments = pathname.split('/').slice(1);
  if (segments[0] !== 'linux') return null;
  if (segments[1] === 'apt') return classifyAptPath(segments);
  if (segments[1] === 'rpm') return classifyRpmPath(segments);
  return null;
}

function classifyAptPath(segments) {
  if (segments.length === 3 && segments[2] === 'openburnbar-archive-keyring.gpg') {
    return snapshotRoute(segments, 'stable', segments.slice(1).join('/'), BOOTSTRAP_CACHE);
  }
  const keyring = segments.length === 3
    ? segments[2].match(/^openburnbar-(stable|prerelease|nightly)-archive-keyring\.gpg$/u)
    : null;
  if (keyring) {
    return snapshotRoute(segments, keyring[1], 'apt/openburnbar-archive-keyring.gpg', BOOTSTRAP_CACHE);
  }
  const sources = segments.length === 3
    ? segments[2].match(/^openburnbar-(stable|prerelease|nightly)\.sources$/u)
    : null;
  if (sources) {
    return snapshotRoute(segments, sources[1], segments.slice(1).join('/'), BOOTSTRAP_CACHE);
  }
  if (segments.length === 7
      && segments.slice(2, 6).join('/') === 'pool/main/o/openburnbar'
      && safePackageFilename(segments[6], '.deb')) {
    return sharedRoute(segments, IMMUTABLE_CACHE);
  }
  if (segments.length < 5 || segments[2] !== 'dists' || !CHANNELS.has(segments[3])) return null;
  const channel = segments[3];
  const relative = segments.slice(1).join('/');
  if (segments.length === 5 && ['InRelease', 'Release', 'Release.gpg'].includes(segments[4])) {
    return snapshotRoute(segments, channel, relative);
  }
  if (segments.length === 8
      && segments[4] === 'main'
      && /^binary-(amd64|arm64)$/u.test(segments[5])
      && segments[6] === 'by-hash'
      && segments[7] === 'SHA256') return null;
  if (segments.length === 9
      && segments[4] === 'main'
      && /^binary-(amd64|arm64)$/u.test(segments[5])
      && segments[6] === 'by-hash'
      && segments[7] === 'SHA256'
      && SNAPSHOT_ID_PATTERN.test(segments[8])) {
    return sharedRoute(segments, IMMUTABLE_CACHE);
  }
  if (segments.length === 7
      && segments[4] === 'main'
      && /^binary-(amd64|arm64)$/u.test(segments[5])
      && ['Packages', 'Packages.gz'].includes(segments[6])) {
    return snapshotRoute(segments, channel, relative);
  }
  return null;
}

function classifyRpmPath(segments) {
  if (segments.length === 3 && segments[2] === 'RPM-GPG-KEY-openburnbar') {
    return snapshotRoute(segments, 'stable', segments.slice(1).join('/'), BOOTSTRAP_CACHE);
  }
  const key = segments.length === 3
    ? segments[2].match(/^RPM-GPG-KEY-openburnbar-(stable|prerelease|nightly)$/u)
    : null;
  if (key) {
    return snapshotRoute(segments, key[1], 'rpm/RPM-GPG-KEY-openburnbar', BOOTSTRAP_CACHE);
  }
  const repo = segments.length === 3
    ? segments[2].match(/^openburnbar-(stable|prerelease|nightly)\.repo$/u)
    : null;
  if (repo) {
    return snapshotRoute(segments, repo[1], segments.slice(1).join('/'), BOOTSTRAP_CACHE);
  }
  if (segments.length < 5 || !CHANNELS.has(segments[2]) || !RPM_ARCHITECTURES.has(segments[3])) return null;
  const channel = segments[2];
  const relative = segments.slice(1).join('/');
  if (segments.length === 5 && safePackageFilename(segments[4], '.rpm')) {
    return sharedRoute(segments, IMMUTABLE_CACHE);
  }
  if (segments.length === 6 && segments[4] === 'repodata') {
    if (['repomd.xml', 'repomd.xml.asc'].includes(segments[5])) {
      return snapshotRoute(segments, channel, relative);
    }
    if (/^[a-f0-9]{64}-[A-Za-z0-9][A-Za-z0-9._+-]*$/u.test(segments[5])) {
      return sharedRoute(segments, IMMUTABLE_CACHE);
    }
  }
  return null;
}

function sharedRoute(segments, cacheControl) {
  return { key: segments.join('/'), cacheControl, snapshotRouted: false };
}

function snapshotRoute(segments, channel, snapshotRelative, cacheControl = POINTER_CACHE) {
  return {
    key: segments.join('/'),
    cacheControl,
    snapshotRouted: true,
    channel,
    snapshotRelative
  };
}

async function serveObject(request, bucket, key, cacheControl) {
  const metadata = await bucket.head(key);
  if (!metadata) return problem(404, 'repository object not found');
  const etagResult = evaluateEtagPreconditions(request.headers, metadata.httpEtag);
  if (etagResult) return objectResponse(etagResult, null, metadata, cacheControl);
  if (request.method === 'HEAD') return objectResponse(200, null, metadata, cacheControl);

  const ifRange = request.headers.get('if-range');
  const rangeHeader = ifRange && ifRange !== metadata.httpEtag ? null : request.headers.get('range');
  const range = parseRange(rangeHeader, metadata.size);
  if (range?.invalid) {
    return new Response(null, {
      status: 416,
      headers: baseObjectHeaders(metadata, cacheControl, {
        'Content-Range': `bytes */${metadata.size}`,
        'Content-Length': '0'
      })
    });
  }
  const object = await bucket.get(key, range ? { range } : undefined);
  if (!object || !('body' in object)) return problem(404, 'repository object not found');
  return objectResponse(range ? 206 : 200, object.body, object, cacheControl, range);
}

function objectResponse(status, body, object, cacheControl, range = null) {
  const extras = {};
  if (status === 304 || status === 412) extras['Content-Length'] = '0';
  else if (range) {
    extras['Content-Length'] = String(range.length);
    extras['Content-Range'] = `bytes ${range.offset}-${range.offset + range.length - 1}/${object.size}`;
  } else extras['Content-Length'] = String(object.size);
  return new Response(body, { status, headers: baseObjectHeaders(object, cacheControl, extras) });
}

function baseObjectHeaders(object, cacheControl, extras = {}) {
  const headers = new Headers();
  object.writeHttpMetadata?.(headers);
  headers.set('ETag', object.httpEtag);
  headers.set('Cache-Control', cacheControl);
  headers.set('Accept-Ranges', 'bytes');
  headers.set('X-Content-Type-Options', 'nosniff');
  for (const [name, value] of Object.entries(extras)) headers.set(name, value);
  return headers;
}

function parseRange(value, size) {
  if (!value) return null;
  const match = value.match(/^bytes=([0-9]*)-([0-9]*)$/u);
  if (!match || (!match[1] && !match[2]) || size <= 0) return { invalid: true };
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return { invalid: true };
    const length = Math.min(suffix, size);
    return { offset: size - length, length };
  }
  const start = Number(match[1]);
  const requestedEnd = match[2] ? Number(match[2]) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(requestedEnd) || start >= size || requestedEnd < start) {
    return { invalid: true };
  }
  const end = Math.min(requestedEnd, size - 1);
  return { offset: start, length: end - start + 1 };
}

function evaluateEtagPreconditions(headers, httpEtag) {
  const ifMatch = headers.get('if-match');
  if (ifMatch && ifMatch !== '*' && !strongEtagListContains(ifMatch, httpEtag)) return 412;
  const ifNoneMatch = headers.get('if-none-match');
  if (ifNoneMatch && (ifNoneMatch.trim() === '*' || weakEtagListContains(ifNoneMatch, httpEtag))) return 304;
  return null;
}

function strongEtagListContains(value, httpEtag) {
  return value.split(',').map((part) => part.trim()).includes(httpEtag);
}

function weakEtagListContains(value, httpEtag) {
  return value.split(',').map((part) => part.trim().replace(/^W\//u, '')).includes(httpEtag);
}

async function readPointer(bucket, channel) {
  const object = await bucket.get(pointerKeyFor(channel));
  if (!object || !('body' in object)) return null;
  if (object.size > MAX_ADMIN_BODY_BYTES) return { valid: false, object };
  let record;
  try {
    record = JSON.parse(await object.text());
  } catch {
    return { valid: false, object };
  }
  const active = validateActivationRecord(record) && record.channel === channel;
  const inactive = validateDeactivationRecord(record) && record.channel === channel;
  return { valid: active || inactive, active, record, object };
}

function feedPointerKey(channel) {
  return `${FEED_POINTER_PREFIX}/${channel}.json`;
}

async function readFeedPointer(bucket, channel) {
  const object = await bucket.get(feedPointerKey(channel));
  if (!object || !('body' in object)) return null;
  if (object.size > MAX_ADMIN_BODY_BYTES) return { valid: false, object };
  let record;
  try {
    record = JSON.parse(await object.text());
  } catch {
    return { valid: false, object };
  }
  return { valid: validateFeedRecord(record, channel), record, object };
}

function validateFeedRecord(record, channel) {
  if (!isPlainObject(record)
      || !hasExactKeys(record, ['schemaVersion', 'generation', 'channel', 'repository', 'version',
        'sourceCommit', 'feed', 'publishedAt', 'previousFeed'])
      || record.schemaVersion !== 1 || !Number.isSafeInteger(record.generation) || record.generation <= 0
      || !CHANNELS.has(record.channel) || !VERSION_PATTERN.test(record.version ?? '')
      || !COMMIT_PATTERN.test(record.sourceCommit ?? '') || typeof record.publishedAt !== 'string'
      || !Number.isFinite(Date.parse(record.publishedAt))
      || !isPlainObject(record.repository)
      || !hasExactKeys(record.repository, ['generation', 'snapshotId', 'pointerEtag'])
      || !Number.isSafeInteger(record.repository.generation) || record.repository.generation <= 0
      || !SNAPSHOT_ID_PATTERN.test(record.repository.snapshotId ?? '')
      || !validHttpEtag(record.repository.pointerEtag)
      || record.channel !== channel
      || !(record.previousFeed === null
        || (validateFeedIdentity(record.previousFeed) && record.previousFeed.channel === channel))) return false;
  return validateFeedIdentity(feedIdentity(record));
}

function feedIdentity(record) {
  return {
    channel: record.channel,
    version: record.version,
    sourceCommit: record.sourceCommit,
    feed: record.feed,
    publishedAt: record.publishedAt
  };
}

function validateFeedIdentity(identity) {
  if (!isPlainObject(identity)
      || !hasExactKeys(identity, ['channel', 'version', 'sourceCommit', 'feed', 'publishedAt'])
      || typeof identity.publishedAt !== 'string'
      || !Number.isFinite(Date.parse(identity.publishedAt))) return false;
  return validateFeedPublicationInput({
    schemaVersion: 1,
    channel: identity.channel,
    generation: 1,
    snapshotId: '0'.repeat(64),
    version: identity.version,
    sourceCommit: identity.sourceCommit,
    repositoryPointerEtag: `"${'0'.repeat(64)}"`,
    feed: identity.feed,
    expectedCurrent: { generation: null, etag: null }
  }) === null;
}

function validateActivationRecord(record) {
  if (!isPlainObject(record)) return false;
  const keys = [
    'schemaVersion', 'mode', 'channel', 'generation', 'snapshotId', 'closureSha256', 'version',
    'sourceCommit', 'activatedAt', 'previousSnapshotId', 'actor', 'runUrl', 'reason'
  ];
  if (!hasExactKeys(record, keys)) return false;
  return record.schemaVersion === 1
    && ['promote', 'rollback'].includes(record.mode)
    && CHANNELS.has(record.channel)
    && Number.isSafeInteger(record.generation) && record.generation > 0
    && SNAPSHOT_ID_PATTERN.test(record.snapshotId)
    && record.closureSha256 === record.snapshotId
    && VERSION_PATTERN.test(record.version)
    && COMMIT_PATTERN.test(record.sourceCommit)
    && typeof record.activatedAt === 'string' && Number.isFinite(Date.parse(record.activatedAt))
    && (record.previousSnapshotId === null || SNAPSHOT_ID_PATTERN.test(record.previousSnapshotId))
    && ACTOR_PATTERN.test(record.actor)
    && (record.runUrl === null || RUN_URL_PATTERN.test(record.runUrl))
    && validReason(record.reason);
}

function validateDeactivationRecord(record) {
  if (!isPlainObject(record)) return false;
  const keys = [
    'schemaVersion', 'status', 'channel', 'generation', 'previousSnapshotId', 'previousVersion',
    'previousSourceCommit', 'fallbackMode', 'deactivatedAt', 'actor', 'runUrl', 'reason'
  ];
  if (!hasExactKeys(record, keys)) return false;
  return record.schemaVersion === 1
    && record.status === 'inactive'
    && CHANNELS.has(record.channel)
    && Number.isSafeInteger(record.generation) && record.generation > 1
    && SNAPSHOT_ID_PATTERN.test(record.previousSnapshotId)
    && VERSION_PATTERN.test(record.previousVersion)
    && COMMIT_PATTERN.test(record.previousSourceCommit)
    && ['legacy-direct-r2', 'disabled'].includes(record.fallbackMode)
    && typeof record.deactivatedAt === 'string' && Number.isFinite(Date.parse(record.deactivatedAt))
    && ACTOR_PATTERN.test(record.actor)
    && (record.runUrl === null || RUN_URL_PATTERN.test(record.runUrl))
    && validReason(record.reason);
}

function validateActivationInput(input) {
  const keys = [
    'schemaVersion', 'mode', 'channel', 'targetSnapshotId', 'expectedCurrentSnapshotId',
    'expectedCurrentGeneration', 'expectedCurrentPointerEtag', 'version', 'sourceCommit',
    'actor', 'runUrl', 'reason'
  ];
  if (!isPlainObject(input) || !hasExactKeys(input, keys)) return 'activation request has an invalid field set';
  if (input.schemaVersion !== 1) return 'schemaVersion must be 1';
  if (!['promote', 'rollback'].includes(input.mode)) return 'mode must be promote or rollback';
  if (!CHANNELS.has(input.channel)) return 'channel is unsupported';
  if (!SNAPSHOT_ID_PATTERN.test(input.targetSnapshotId ?? '')) return 'targetSnapshotId must be a lowercase SHA-256 digest';
  if (input.expectedCurrentSnapshotId !== null
      && !SNAPSHOT_ID_PATTERN.test(input.expectedCurrentSnapshotId ?? '')) {
    return 'expectedCurrentSnapshotId must be null or a lowercase SHA-256 digest';
  }
  if (!validExpectedPointer({
    generation: input.expectedCurrentGeneration,
    etag: input.expectedCurrentPointerEtag
  }, true)) return 'expected current generation and pointer ETag identity is invalid';
  if (input.expectedCurrentSnapshotId !== null && input.expectedCurrentGeneration === null) {
    return 'an expected snapshot requires a generation and pointer ETag';
  }
  if (!VERSION_PATTERN.test(input.version ?? '')) return 'version must be strict semantic x.y.z';
  if (!COMMIT_PATTERN.test(input.sourceCommit ?? '')) return 'sourceCommit must be a lowercase 40-character commit';
  if (!ACTOR_PATTERN.test(input.actor ?? '')) return 'actor is invalid';
  if (input.runUrl !== null && !RUN_URL_PATTERN.test(input.runUrl ?? '')) {
    return 'runUrl must be null or an OpenBurnBar GitHub Actions run URL';
  }
  if (!validReason(input.reason)) return 'reason must contain 8-500 printable characters';
  return null;
}

function validateDeactivationInput(input) {
  const keys = [
    'schemaVersion', 'channel', 'expectedCurrentSnapshotId', 'expectedCurrentGeneration',
    'expectedCurrentPointerEtag', 'actor', 'runUrl', 'reason'
  ];
  if (!isPlainObject(input) || !hasExactKeys(input, keys)) return 'deactivation request has an invalid field set';
  if (input.schemaVersion !== 1) return 'schemaVersion must be 1';
  if (!CHANNELS.has(input.channel)) return 'channel is unsupported';
  if (!SNAPSHOT_ID_PATTERN.test(input.expectedCurrentSnapshotId ?? '')) {
    return 'expectedCurrentSnapshotId must be a lowercase SHA-256 digest';
  }
  if (!validExpectedPointer({
    generation: input.expectedCurrentGeneration,
    etag: input.expectedCurrentPointerEtag
  }, false)) return 'expected current generation and pointer ETag identity is invalid';
  if (!ACTOR_PATTERN.test(input.actor ?? '')) return 'actor is invalid';
  if (input.runUrl !== null && !RUN_URL_PATTERN.test(input.runUrl ?? '')) {
    return 'runUrl must be null or an OpenBurnBar GitHub Actions run URL';
  }
  if (!validReason(input.reason)) return 'reason must contain 8-500 printable characters';
  return null;
}

function validReason(value) {
  return typeof value === 'string'
    && value.length >= 8
    && value.length <= 500
    && value.trim() === value
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function compareVersions(left, right) {
  const leftParts = left.split('.').map(BigInt);
  const rightParts = right.split('.').map(BigInt);
  for (let index = 0; index < 3; index += 1) {
    if (leftParts[index] !== rightParts[index]) return leftParts[index] > rightParts[index] ? 1 : -1;
  }
  return 0;
}

function onlyChannelQuery(url) {
  const entries = [...url.searchParams.entries()];
  if (entries.length !== 1 || entries[0][0] !== 'channel' || !CHANNELS.has(entries[0][1])) return null;
  return entries[0][1];
}

async function isAuthorized(request, expectedToken) {
  const header = request.headers.get('authorization') ?? '';
  const match = header.match(/^Bearer ([A-Za-z0-9._~+/=-]{32,4096})$/u);
  if (!match || typeof expectedToken !== 'string'
      || !/^[A-Za-z0-9._~+/=-]{32,4096}$/u.test(expectedToken)) return false;
  const [provided, expected] = await Promise.all([
    crypto.subtle.digest('SHA-256', new TextEncoder().encode(match[1])),
    crypto.subtle.digest('SHA-256', new TextEncoder().encode(expectedToken))
  ]);
  const left = new Uint8Array(provided);
  const right = new Uint8Array(expected);
  let difference = left.length ^ right.length;
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

async function sha256Hex(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function verifyEd25519(spki, signature, message) {
  try {
    const key = await crypto.subtle.importKey('spki', spki, { name: 'Ed25519' }, false, ['verify']);
    return crypto.subtle.verify('Ed25519', key, signature, message);
  } catch {
    return false;
  }
}

function base64Bytes(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function pointerKeyFor(channel) {
  return `${POINTER_PREFIX}/${channel}.json`;
}

function snapshotPrefixFor(channel, snapshotId) {
  return `${SNAPSHOT_PREFIX}/${channel}/${snapshotId}`;
}

function safePackageFilename(value, suffix) {
  return typeof value === 'string'
    && value.endsWith(suffix)
    && value.length <= 255
    && /^[A-Za-z0-9][A-Za-z0-9._+~-]*$/u.test(value)
    && !value.includes('..');
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype;
}

function hasExactKeys(value, expected) {
  const actual = Object.keys(value).sort();
  return actual.length === expected.length
    && expected.slice().sort().every((key, index) => actual[index] === key);
}

function methodNotAllowed(allow) {
  return problem(405, 'method not allowed', { Allow: allow });
}

function problem(status, error, extraHeaders = {}) {
  return jsonResponse(status, { error }, extraHeaders);
}

function jsonResponse(status, value, extraHeaders = {}) {
  const headers = new Headers({
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...extraHeaders
  });
  return new Response(`${JSON.stringify(value)}\n`, { status, headers });
}
