#!/usr/bin/env node
/**
 * Publish exactly one Afar (Mission Control) Mac artifact to the existing
 * downloads R2 bucket, after the clean-GUI acceptance recorded in the reviewed
 * contract (config/afar-mac-release.json).
 *
 * Order, every step fail-closed:
 *   1. The contract validates and records an accepted clean-GUI install of the
 *      exact artifact SHA-256. A false or mismatched acceptance stops here.
 *   2. The artifact is read from a DRAFT GitHub release (private staging in this
 *      public repository) and must match the contract's size and SHA-256.
 *   3. Consistency probe: the bucket's copy of latest-macos.json must equal the
 *      public host's copy. This is a consistency check, not authoritative proof
 *      of the bucket/domain binding; the custodian's binding verification stays
 *      an operational gate. Zero writes happen before it passes.
 *   4. One conditional PutObject (If-None-Match: *) of the one contract key, with
 *      an x-amz-checksum-sha256 for server-side verification. An existing key
 *      (412) is never overwritten: identical public bytes mean "already
 *      published", anything else is a conflict.
 *   5. Anonymous public re-fetch must match size, SHA-256 and media type, and the
 *      OpenBurnBar feeds (latest-macos.json, appcast.xml) must be byte-identical
 *      to the snapshot taken before the write.
 *
 * Every HTTP read goes through boundedGet(): HTTPS only, no userinfo or port,
 * per-hop origin allow-lists, the GitHub token only on api.github.com, a byte
 * cap enforced while streaming, and both overall and idle deadlines.
 *
 * It never writes any key other than the contract's, never touches OpenBurnBar
 * feeds, metadata or GitHub releases, and never reads release.json.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const EXPECTED_BUCKET = "openburnbar-downloads";
export const EXPECTED_PUBLIC_BASE_URL = "https://downloads.burnbar.ai";
export const CONSISTENCY_PROBE_KEY = "latest-macos.json";
export const FEED_KEYS = Object.freeze(["latest-macos.json", "appcast.xml"]);
export const DMG_MEDIA_TYPE = "application/x-apple-diskimage";
const GITHUB_API_ORIGIN = "https://api.github.com";
// GitHub release-asset downloads redirect to one of these storage hosts.
const GITHUB_ASSET_STORAGE_ORIGINS = Object.freeze([
  "https://objects.githubusercontent.com",
  "https://release-assets.githubusercontent.com"
]);
const MAX_SINGLE_PUT_BYTES = 5 * 1024 ** 3;
const HEX64 = /^[a-f0-9]{64}$/u;
const VERSION = /^\d+\.\d+\.\d+$/u;
const ACCOUNT_ID = /^[a-f0-9]{32}$/u;
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;

/**
 * Byte caps, deadlines and the shared run budget. Tests shrink the deadlines;
 * production uses these.
 *
 * totalBudgetMs is measured from the job's first step (AFAR_JOB_STARTED_AT_MS),
 * not from this process, so slow checkout, Node setup or AWS CLI install spend
 * the same budget. The write starts only while postWriteReserveMs of it
 * remains, which covers the PUT and every check after it: put 5 min + 4 public
 * artifact reads of 2 min + 2 feeds x 3 reads of 30 s, with retry backoff, is
 * about 16.4 min. The job timeout sits at least JOB_UNBOUNDED_ALLOWANCE_MS
 * above the budget, which covers the runner's own "Set up job" before the
 * first step and the post-job cleanup, so the runner never kills the process
 * between the write and its verification.
 */
export const DEFAULT_LIMITS = Object.freeze({
  apiMaxBytes: 8 * 1024 * 1024,
  feedMaxBytes: 1024 * 1024,
  apiDeadlineMs: 30_000,
  feedDeadlineMs: 30_000,
  artifactDeadlineMs: 300_000,
  publicArtifactDeadlineMs: 120_000,
  publicArtifactAttempts: 4,
  idleMs: 30_000,
  awsProbeTimeoutMs: 60_000,
  awsPutTimeoutMs: 300_000,
  totalBudgetMs: 34 * 60_000,
  postWriteReserveMs: 18 * 60_000
});
export const JOB_UNBOUNDED_ALLOWANCE_MS = 10 * 60_000;
const JOB_START_MAX_AGE_MS = 24 * 60 * 60_000;
const ISO_UTC = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?Z$/u;

export class PublishError extends Error {}

function fail(message) {
  throw new PublishError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** RFC 3339 UTC (YYYY-MM-DDTHH:MM:SS[.mmm]Z) naming a real instant: no rollover such as 2026-02-31. */
export function isIsoUtcTimestamp(value) {
  const match = typeof value === "string" ? ISO_UTC.exec(value) : null;
  if (!match) return false;
  const time = Date.parse(value);
  if (!Number.isFinite(time)) return false;
  const date = new Date(time);
  return (
    date.getUTCFullYear() === Number(match[1]) &&
    date.getUTCMonth() + 1 === Number(match[2]) &&
    date.getUTCDate() === Number(match[3]) &&
    date.getUTCHours() === Number(match[4]) &&
    date.getUTCMinutes() === Number(match[5]) &&
    date.getUTCSeconds() === Number(match[6])
  );
}

/**
 * The job-start anchor written by the workflow's first step: epoch milliseconds,
 * not in the future and not stale. Missing or malformed fails closed.
 */
export function parseJobStartedAt(raw, nowMs) {
  if (typeof raw !== "string" || !/^\d{13}$/u.test(raw)) {
    fail("AFAR_JOB_STARTED_AT_MS must be the job's first-step time in epoch milliseconds");
  }
  const value = Number(raw);
  if (value > nowMs) fail("AFAR_JOB_STARTED_AT_MS is in the future; refusing to extend the run budget");
  if (nowMs - value > JOB_START_MAX_AGE_MS) fail("AFAR_JOB_STARTED_AT_MS is stale; refusing to publish");
  return value;
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

/** Validate the reviewed contract. Every field is pinned; nothing is defaulted. */
export function validateContract(raw, { requireAccepted = false } = {}) {
  if (!isPlainObject(raw)) fail("contract must be a JSON object");
  if (raw.schemaVersion !== 1) fail("contract schemaVersion must be 1");
  if (raw.product !== "Afar") fail("contract product must be Afar");
  const { version, artifact } = raw;
  if (typeof version !== "string" || !VERSION.test(version)) fail("version must be MAJOR.MINOR.PATCH");
  if (!isPlainObject(artifact)) fail("artifact must be an object");
  const fileName = `MissionControl-blank-${version}-universal-release.dmg`;
  if (artifact.fileName !== fileName) fail(`artifact.fileName must be ${fileName}`);
  if (typeof artifact.sha256 !== "string" || !HEX64.test(artifact.sha256)) {
    fail("artifact.sha256 must be 64 lowercase hex characters");
  }
  if (!Number.isInteger(artifact.size) || artifact.size < 1 || artifact.size > MAX_SINGLE_PUT_BYTES) {
    fail("artifact.size must be a positive integer within a single PUT");
  }
  if (raw.draftReleaseTag !== `afar-mac-${version}`) fail(`draftReleaseTag must be afar-mac-${version}`);
  if (raw.bucket !== EXPECTED_BUCKET) fail(`bucket must be ${EXPECTED_BUCKET}`);
  if (raw.publicBaseUrl !== EXPECTED_PUBLIC_BASE_URL) fail(`publicBaseUrl must be ${EXPECTED_PUBLIC_BASE_URL}`);
  if (raw.objectKey !== `mission-control/${version}/${fileName}`) {
    fail(`objectKey must be mission-control/${version}/${fileName}`);
  }
  if (raw.consistencyProbeKey !== CONSISTENCY_PROBE_KEY) fail(`consistencyProbeKey must be ${CONSISTENCY_PROBE_KEY}`);
  const acceptance = raw.cleanGuiAcceptance;
  if (!isPlainObject(acceptance)) fail("cleanGuiAcceptance must be an object");
  if (requireAccepted) {
    if (acceptance.accepted !== true) fail("clean GUI acceptance is not recorded; refusing to publish");
    if (acceptance.installedArtifactSha256 !== artifact.sha256) {
      fail("clean GUI acceptance was not recorded for this exact artifact SHA-256");
    }
    if (typeof acceptance.evidenceSha256 !== "string" || !HEX64.test(acceptance.evidenceSha256)) {
      fail("cleanGuiAcceptance.evidenceSha256 must reference the acceptance evidence");
    }
    if (!isIsoUtcTimestamp(acceptance.acceptedAt)) {
      fail("cleanGuiAcceptance.acceptedAt must be an RFC 3339 UTC timestamp such as 2026-10-19T00:00:00Z");
    }
  }
  return Object.freeze({
    version,
    fileName,
    sha256: artifact.sha256,
    size: artifact.size,
    draftReleaseTag: raw.draftReleaseTag,
    bucket: raw.bucket,
    publicBaseUrl: raw.publicBaseUrl,
    objectKey: raw.objectKey,
    publicUrl: `${raw.publicBaseUrl}/${raw.objectKey}`
  });
}

/** HTTPS, default port, no userinfo, and an origin from the allow-list for this hop. */
function checkedUrl(raw, allowedOrigins) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    fail(`refusing malformed URL ${String(raw).slice(0, 120)}`);
  }
  if (url.protocol !== "https:" || url.username || url.password || url.port) {
    fail(`refusing non-HTTPS or credentialed URL for origin ${url.origin}`);
  }
  if (!allowedOrigins.includes(url.origin)) fail(`refusing request to unapproved origin ${url.origin}`);
  return url;
}

function mediaType(response) {
  return (response.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
}

async function readChunk(reader, idleMs, deadlineAt) {
  const wait = Math.min(idleMs, deadlineAt - Date.now());
  if (wait <= 0) fail("response exceeded its deadline");
  let timer;
  try {
    return await Promise.race([
      reader.read(),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new PublishError("response stalled or exceeded its deadline")), wait);
      })
    ]);
  } finally {
    clearTimeout(timer);
  }
}

/** Stream a body, stopping as soon as it passes maxBytes or a deadline. */
async function readBounded(response, { maxBytes, idleMs, deadlineAt }) {
  const declared = response.headers.get("content-length");
  if (declared !== null && (!/^\d+$/u.test(declared) || Number(declared) > maxBytes)) {
    fail(`declared response size ${declared} exceeds the ${maxBytes}-byte cap`);
  }
  if (!response.body) fail("response has no body stream");
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await readChunk(reader, idleMs, deadlineAt);
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) fail(`response exceeded the ${maxBytes}-byte cap`);
      chunks.push(Buffer.from(value.buffer, value.byteOffset, value.byteLength));
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  }
  return Buffer.concat(chunks, total);
}

/**
 * One bounded GET. Redirects are followed manually, each hop re-checked against
 * redirectOrigins; Authorization is attached only when the hop's origin is the
 * GitHub API. Returns { status: 404 } for a missing object, else the bytes.
 */
export async function boundedGet(rawUrl, {
  fetchImpl,
  origins,
  redirectOrigins = [],
  maxRedirects = 0,
  token = null,
  accept,
  maxBytes,
  exactBytes = null,
  mediaTypes = null,
  deadlineMs,
  idleMs,
  noCache = false
}) {
  const controller = new AbortController();
  const deadlineAt = Date.now() + deadlineMs;
  const timer = setTimeout(() => controller.abort(), deadlineMs);
  try {
    let url = checkedUrl(rawUrl, origins);
    for (let hop = 0; ; hop++) {
      const headers = { Accept: accept };
      if (url.origin === GITHUB_API_ORIGIN) {
        headers["X-GitHub-Api-Version"] = "2022-11-28";
        if (token) headers.Authorization = `Bearer ${token}`;
      }
      if (noCache) headers["Cache-Control"] = "no-cache";
      const response = await fetchImpl(url.href, { headers, redirect: "manual", signal: controller.signal });
      if (response.status >= 300 && response.status < 400) {
        await response.body?.cancel?.().catch(() => {});
        if (hop >= maxRedirects) fail(`refusing redirect from ${url.origin}`);
        const location = response.headers.get("location");
        if (!location) fail("redirect has no location");
        url = checkedUrl(new URL(location, url).href, redirectOrigins);
        continue;
      }
      if (response.status === 404) {
        await response.body?.cancel?.().catch(() => {});
        return { status: 404, bytes: null };
      }
      if (!response.ok) {
        await response.body?.cancel?.().catch(() => {});
        fail(`GET ${url.origin}${url.pathname} failed with HTTP ${response.status}`);
      }
      if (mediaTypes && !mediaTypes.includes(mediaType(response))) {
        await response.body?.cancel?.().catch(() => {});
        fail(`unexpected media type ${mediaType(response) || "(none)"} from ${url.origin}`);
      }
      const bytes = await readBounded(response, { maxBytes, idleMs, deadlineAt });
      if (exactBytes !== null && bytes.length !== exactBytes) {
        fail(`expected exactly ${exactBytes} bytes, received ${bytes.length}`);
      }
      return { status: response.status, bytes, mediaType: mediaType(response) };
    }
  } catch (error) {
    if (error instanceof PublishError) throw error;
    if (controller.signal.aborted) fail("request exceeded its deadline");
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

/** Read the artifact from the single DRAFT release carrying the contract tag. */
export async function downloadDraftAsset({ contract, repository, token, fetchImpl, limits = DEFAULT_LIMITS }) {
  if (!REPOSITORY.test(repository ?? "")) fail("GITHUB_REPOSITORY is malformed");
  if (!token) fail("GH_TOKEN is required to read the draft release");
  const api = {
    fetchImpl,
    origins: [GITHUB_API_ORIGIN],
    token,
    accept: "application/vnd.github+json",
    maxBytes: limits.apiMaxBytes,
    mediaTypes: ["application/json"],
    deadlineMs: limits.apiDeadlineMs,
    idleMs: limits.idleMs
  };
  const matches = [];
  for (let page = 1; page <= 10; page++) {
    const { bytes } = await boundedGet(`${GITHUB_API_ORIGIN}/repos/${repository}/releases?per_page=100&page=${page}`, api);
    if (bytes === null) fail("releases listing returned 404");
    const releases = JSON.parse(bytes.toString("utf8"));
    if (!Array.isArray(releases)) fail("releases listing is not an array");
    matches.push(...releases.filter((release) => release?.tag_name === contract.draftReleaseTag));
    if (releases.length < 100) break;
  }
  if (matches.length !== 1) fail(`expected exactly one release tagged ${contract.draftReleaseTag}, found ${matches.length}`);
  const [release] = matches;
  if (release.draft !== true) fail("the staging release is not a draft; its bytes may already be public");
  const assets = (release.assets ?? []).filter((asset) => asset?.name === contract.fileName);
  if (assets.length !== 1) fail(`expected exactly one ${contract.fileName} asset on the draft`);
  const [asset] = assets;
  if (asset.size !== contract.size) fail("draft asset size does not match the contract");
  const { bytes } = await boundedGet(asset.url, {
    fetchImpl,
    origins: [GITHUB_API_ORIGIN],
    redirectOrigins: GITHUB_ASSET_STORAGE_ORIGINS,
    maxRedirects: 1,
    token,
    accept: "application/octet-stream",
    maxBytes: contract.size,
    exactBytes: contract.size,
    mediaTypes: ["application/octet-stream", DMG_MEDIA_TYPE],
    deadlineMs: limits.artifactDeadlineMs,
    idleMs: limits.idleMs
  });
  if (bytes === null) fail("draft asset returned 404");
  if (sha256Hex(bytes) !== contract.sha256) fail("downloaded draft asset SHA-256 does not match the contract");
  return bytes;
}

/** Anonymous, uncached GET from the public host only, never redirected. */
async function publicGet(contract, key, { fetchImpl, limits, sleep, attempts, artifact = false }) {
  const options = {
    fetchImpl,
    origins: [contract.publicBaseUrl],
    accept: artifact ? DMG_MEDIA_TYPE : "*/*",
    maxBytes: artifact ? contract.size : limits.feedMaxBytes,
    exactBytes: artifact ? contract.size : null,
    mediaTypes: artifact ? [DMG_MEDIA_TYPE] : null,
    deadlineMs: artifact ? limits.publicArtifactDeadlineMs : limits.feedDeadlineMs,
    idleMs: limits.idleMs,
    noCache: true
  };
  let last = null;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const result = await boundedGet(`${contract.publicBaseUrl}/${key}?afar-verify=${Date.now()}-${attempt}`, options);
      if (result.status !== 404 || attempt === attempts) return result.bytes;
    } catch (error) {
      last = error;
      if (attempt === attempts) throw error;
    }
    await sleep(attempt * 2000);
  }
  if (last) throw last;
  return null;
}

/** The exact AWS CLI argument vector. aws-cli 1.x: no v2-only flags such as --no-cli-pager. */
export function awsArgv(args) {
  return [...args, "--output", "json"];
}

function isPreconditionFailed(result) {
  return /PreconditionFailed|\(412\)|status code: 412/u.test(`${result.stderr}\n${result.stdout}`);
}

/** Both AWS commands the publisher runs, for review and offline parsing checks. */
export function awsCommands({ contract, endpoint, artifactPath, probePath }) {
  return {
    probe: [
      "s3api", "get-object", "--endpoint-url", endpoint,
      "--bucket", contract.bucket, "--key", CONSISTENCY_PROBE_KEY, probePath
    ],
    put: [
      "s3api", "put-object", "--endpoint-url", endpoint,
      "--bucket", contract.bucket, "--key", contract.objectKey, "--body", artifactPath,
      "--if-none-match", "*",
      "--checksum-sha256", Buffer.from(contract.sha256, "hex").toString("base64"),
      "--content-type", DMG_MEDIA_TYPE,
      "--cache-control", "public, max-age=31536000, immutable"
    ]
  };
}

/** The full guarded publication. Every external effect goes through injected functions. */
export async function publish({ contractRaw, repository, token, accountId, fetchImpl, runAws, workDir, sleep, limits = DEFAULT_LIMITS, now = Date.now, startedAt = now() }) {
  const contract = validateContract(contractRaw, { requireAccepted: true });
  if (!Number.isSafeInteger(startedAt) || startedAt > now()) fail("the run budget anchor must be a past epoch-millisecond time");
  // The write window closes once the post-write reserve is no longer left in the budget.
  const writeWindowOpen = () => now() - startedAt <= limits.totalBudgetMs - limits.postWriteReserveMs;
  if (!writeWindowOpen()) fail("job setup used the write window; refusing before any network or bucket access");
  if (!ACCOUNT_ID.test(accountId ?? "")) fail("CLOUDFLARE_ACCOUNT_ID must be 32 lowercase hex characters");
  const endpoint = `https://${accountId}.r2.cloudflarestorage.com`;
  const io = { fetchImpl, limits, sleep };

  const bytes = await downloadDraftAsset({ contract, repository, token, fetchImpl, limits });
  const artifactPath = join(workDir, contract.fileName);
  writeFileSync(artifactPath, bytes);
  const commands = awsCommands({ contract, endpoint, artifactPath, probePath: join(workDir, "consistency-probe") });

  const feedsBefore = {};
  for (const key of FEED_KEYS) {
    const body = await publicGet(contract, key, { ...io, attempts: 3 });
    feedsBefore[key] = body === null ? null : sha256Hex(body);
  }

  const probePublic = await publicGet(contract, CONSISTENCY_PROBE_KEY, { ...io, attempts: 3 });
  if (probePublic === null) fail("consistency probe key is not served by the public host; refusing to write");
  const probe = runAws(commands.probe, limits.awsProbeTimeoutMs);
  if (probe.status !== 0) fail("consistency probe could not read the bucket; refusing to write");
  const probeSha = sha256Hex(readFileSync(commands.probe.at(-1)));
  if (probeSha !== sha256Hex(probePublic)) {
    fail("bucket and public host disagree on the consistency probe; refusing to write");
  }

  // Never start a write that could not be verified before the run budget ends.
  if (!writeWindowOpen()) fail("not enough of the run budget remains to verify a write; refusing to write");
  const put = runAws(commands.put, limits.awsPutTimeoutMs);
  let result = "published";
  if (put.status !== 0) {
    if (!isPreconditionFailed(put)) fail("conditional PutObject failed; nothing was overwritten");
    result = "already-published";
  }

  let published;
  try {
    published = await publicGet(contract, contract.objectKey, { ...io, attempts: limits.publicArtifactAttempts, artifact: true });
  } catch (error) {
    if (result === "already-published") fail("the key already exists with different bytes; conflict, not overwritten");
    throw error;
  }
  if (published === null) fail("published object is not reachable on the public host");
  if (sha256Hex(published) !== contract.sha256) {
    fail(result === "already-published"
      ? "the key already exists with different bytes; conflict, not overwritten"
      : "public bytes do not match the contract");
  }

  for (const key of FEED_KEYS) {
    const body = await publicGet(contract, key, { ...io, attempts: 3 });
    const after = body === null ? null : sha256Hex(body);
    if (after !== feedsBefore[key]) fail(`OpenBurnBar feed ${key} changed during publication`);
  }

  return {
    result,
    product: "Afar",
    version: contract.version,
    url: contract.publicUrl,
    objectKey: contract.objectKey,
    sha256: contract.sha256,
    size: contract.size,
    consistencyProbeSha256: probeSha,
    feedsUnchanged: feedsBefore
  };
}

function argValue(args, name) {
  const index = args.indexOf(name);
  return index === -1 ? null : args[index + 1] ?? null;
}

async function main(argv) {
  const [command, ...args] = argv;
  const contractPath = argValue(args, "--contract");
  if (!contractPath) fail("--contract is required");
  const contractRaw = JSON.parse(readFileSync(contractPath, "utf8"));
  if (command === "check") {
    const contract = validateContract(contractRaw, { requireAccepted: args.includes("--require-accepted") });
    process.stdout.write(`${JSON.stringify({ ok: true, objectKey: contract.objectKey, url: contract.publicUrl })}\n`);
    return;
  }
  if (command !== "publish") fail("usage: afar-mac-artifact-publish.mjs check|publish --contract <path>");
  const startedAt = parseJobStartedAt(process.env.AFAR_JOB_STARTED_AT_MS, Date.now());
  const awsBin = process.env.AWS_BIN;
  if (!awsBin) fail("AWS_BIN is required");
  if (!process.env.R2_ACCESS_KEY_ID || !process.env.R2_SECRET_ACCESS_KEY) fail("R2 credentials are required");
  // The AWS CLI sees only R2 credentials; the GitHub token never reaches it.
  const awsEnv = {
    PATH: process.env.PATH ?? "",
    HOME: process.env.HOME ?? "",
    AWS_ACCESS_KEY_ID: process.env.R2_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY: process.env.R2_SECRET_ACCESS_KEY,
    AWS_DEFAULT_REGION: "auto",
    AWS_EC2_METADATA_DISABLED: "true",
    AWS_PAGER: ""
  };
  const runAws = (awsArgs, timeoutMs) => {
    const result = spawnSync(awsBin, awsArgv(awsArgs), { env: awsEnv, encoding: "utf8", timeout: timeoutMs });
    return { status: result.status ?? 1, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
  };
  const workDir = mkdtempSync(join(process.env.RUNNER_TEMP ?? tmpdir(), "afar-mac-publish-"));
  const receipt = await publish({
    contractRaw,
    repository: process.env.GITHUB_REPOSITORY,
    token: process.env.GH_TOKEN,
    accountId: process.env.CLOUDFLARE_ACCOUNT_ID,
    fetchImpl: fetch,
    runAws,
    workDir,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    startedAt
  });
  writeFileSync(join(workDir, "receipt.json"), `${JSON.stringify(receipt, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(receipt)}\n`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${error instanceof PublishError ? error.message : error?.stack ?? error}\n`);
    process.exit(1);
  });
}
