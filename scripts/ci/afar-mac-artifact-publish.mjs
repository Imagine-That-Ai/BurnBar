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
 *   5. Anonymous re-fetch of the exact canonical customer URL (no query string,
 *      no cache override, never read before the write, so the run cannot seed a
 *      cached 404) must match size, SHA-256 and media type, and the OpenBurnBar
 *      feeds (latest-macos.json, appcast.xml) must be byte-identical to the
 *      snapshot taken before the write.
 *
 * Before any of steps 2-5, the run budget is bound to GitHub's own record of
 * this job (see resolveJobClock): elapsed time is measured from the job's
 * created_at in GitHub's clock, so queueing, environment approval, runner
 * initialization ("Set up job") and setup steps all spend the same budget.
 *
 * Every HTTP read goes through boundedGet(): HTTPS only, no userinfo or port,
 * per-hop origin allow-lists, the GitHub token only on api.github.com, a byte
 * cap enforced while streaming, and both overall and idle deadlines.
 *
 * It never writes any key other than the contract's, never touches OpenBurnBar
 * feeds, metadata or GitHub releases, and never reads release.json.
 *
 * Desktop previews (config/afar-linux-preview.json, config/afar-windows-preview.json,
 * published by .github/workflows/publish-afar-desktop-preview.yml) run the same
 * sequence on their own lane: an unsigned build under its exact qualified file
 * name at mission-control/preview/<os>/<version>/, gated on a recorded preview
 * qualification of those bytes instead of clean-GUI acceptance, and with all
 * four OpenBurnBar feeds proven unchanged. See LANES.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { performance } from "node:perf_hooks";

export const EXPECTED_BUCKET = "openburnbar-downloads";
export const EXPECTED_PUBLIC_BASE_URL = "https://downloads.burnbar.ai";
export const CONSISTENCY_PROBE_KEY = "latest-macos.json";
export const FEED_KEYS = Object.freeze(["latest-macos.json", "appcast.xml"]);
export const DMG_MEDIA_TYPE = "application/x-apple-diskimage";
/** Every OpenBurnBar feed in the shared bucket; desktop previews must leave all of them byte-identical. */
export const ALL_OPENBURNBAR_FEED_KEYS = Object.freeze(["latest-macos.json", "appcast.xml", "latest-linux.json", "latest-windows.json"]);
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
 * totalBudgetMs is measured from the moment GitHub created this job's record
 * (resolveJobClock), which no job timeout can precede. The write starts only
 * while postWriteReserveMs of it remains, which covers the PUT and every check
 * after it: put 5 min + 4 public artifact reads of 2 min + 2 feeds x 3 reads of
 * 30 s, with retry backoff, is about 16.4 min. The workflow's job timeout is
 * strictly above totalBudgetMs, so GitHub cannot cancel the job between the
 * write and its verification, whatever happened before the first step.
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
  totalBudgetMs: 44 * 60_000,
  postWriteReserveMs: 18 * 60_000
});
/** The workflow job's display name; the job lookup must find exactly this job. */
export const PUBLISH_JOB_NAME = "Publish one Afar Mac artifact";
/** The desktop preview workflow's job name (.github/workflows/publish-afar-desktop-preview.yml). */
export const PREVIEW_PUBLISH_JOB_NAME = "Publish one Afar desktop preview artifact";

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

/**
 * Publication lanes. The Mac lane is the accepted contract, unchanged (it has no
 * platform field). Desktop previews are unsigned development builds published
 * under their exact qualified file names: their own key prefix, draft tag, media
 * type and job, a preview qualification in place of clean-GUI acceptance, and
 * every OpenBurnBar feed proven unchanged.
 */
export const LANES = Object.freeze({
  mac: Object.freeze({
    mediaType: DMG_MEDIA_TYPE,
    feedKeys: FEED_KEYS,
    jobName: PUBLISH_JOB_NAME
  }),
  "linux-preview": Object.freeze({
    mediaType: "application/vnd.debian.binary-package",
    feedKeys: ALL_OPENBURNBAR_FEED_KEYS,
    jobName: PREVIEW_PUBLISH_JOB_NAME,
    os: "linux",
    architectures: Object.freeze(["all", "amd64", "arm64"]),
    fileNameRule: "afar-linux_<version>-<label>_<architecture>.deb",
    fileNameMatches: (fileName, { version, architecture }) =>
      new RegExp(`^afar-linux_${escapeRegExp(version)}-[a-z0-9]+(?:-[a-z0-9]+)*_${escapeRegExp(architecture)}\\.deb$`, "u").test(fileName)
  }),
  "windows-preview": Object.freeze({
    mediaType: "application/zip",
    feedKeys: ALL_OPENBURNBAR_FEED_KEYS,
    jobName: PREVIEW_PUBLISH_JOB_NAME,
    os: "windows",
    architectures: Object.freeze(["win-x64", "win-arm64"]),
    fileNameRule: "Afar-Windows-<version>-preview-https-<sourceCommit[0:7]>-<architecture>-unsigned.zip",
    fileNameMatches: (fileName, { version, architecture, sourceCommit }) =>
      fileName === `Afar-Windows-${version}-preview-https-${sourceCommit.slice(0, 7)}-${architecture}-unsigned.zip`
  })
});
const RUN_ID = /^[1-9]\d{0,19}$/u;
const RUN_ATTEMPT = /^[1-9]\d{0,3}$/u;
const GIT_SHA = /^[0-9a-f]{40}$/u;
const HTTP_DATE = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} GMT$/u;
const ISO_UTC = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?Z$/u;
// Preview qualifications keep the recorder's precision (e.g. .8838031Z) verbatim.
const ISO_UTC_FINE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?Z$/u;

export class PublishError extends Error {}

function fail(message) {
  throw new PublishError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** RFC 3339 UTC (YYYY-MM-DDTHH:MM:SS[.mmm]Z) naming a real instant: no rollover such as 2026-02-31. */
export function isIsoUtcTimestamp(value, { fine = false } = {}) {
  const match = typeof value === "string" ? (fine ? ISO_UTC_FINE : ISO_UTC).exec(value) : null;
  if (!match) return false;
  // Date.parse keeps milliseconds only; finer digits cannot change the calendar fields checked below.
  const time = Date.parse(fine ? value.replace(/(\.\d{3})\d+Z$/u, "$1Z") : value);
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

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

/** Validate the reviewed contract. Every field is pinned; nothing is defaulted. */
export function validateContract(raw, { requireAccepted = false } = {}) {
  if (!isPlainObject(raw)) fail("contract must be a JSON object");
  if (Object.hasOwn(raw, "platform")) return validatePreviewContract(raw, { requireAccepted });
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
    publicUrl: `${raw.publicBaseUrl}/${raw.objectKey}`,
    lane: "mac"
  });
}

const PREVIEW_FIELDS = Object.freeze([
  "schemaVersion", "product", "platform", "version", "architecture", "sourceCommit", "artifact",
  "draftReleaseTag", "bucket", "publicBaseUrl", "objectKey", "consistencyProbeKey", "previewQualification"
]);
const PREVIEW_ARTIFACT_FIELDS = Object.freeze(["fileName", "sha256", "size"]);
const PREVIEW_QUALIFICATION_FIELDS = Object.freeze([
  "accepted", "qualifiedArtifactSha256", "evidenceSha256", "acceptedAt", "signed", "notQualified"
]);

function onlyFields(value, allowed, label) {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) fail(`unexpected ${label} field ${key}`);
}

/**
 * An unsigned desktop preview (platform linux-preview or windows-preview).
 * Pinned like the Mac lane, plus: no unknown fields, the full source commit,
 * the exact qualified file name, an explicit unsigned flag, and the list of
 * what is NOT qualified, which the site must show next to any link. Publication
 * needs a recorded qualification of these exact bytes; a clean-GUI claim is
 * never accepted for a preview.
 */
function validatePreviewContract(raw, { requireAccepted }) {
  const lane = raw.platform === "mac" ? undefined : LANES[raw.platform];
  if (!lane || !Object.hasOwn(LANES, raw.platform)) fail("platform must be linux-preview or windows-preview");
  onlyFields(raw, PREVIEW_FIELDS, "contract");
  if (raw.schemaVersion !== 1) fail("contract schemaVersion must be 1");
  if (raw.product !== "Afar") fail("contract product must be Afar");
  const { version, architecture, sourceCommit, artifact } = raw;
  if (typeof version !== "string" || !VERSION.test(version)) fail("version must be MAJOR.MINOR.PATCH");
  if (!lane.architectures.includes(architecture)) fail(`architecture must be one of ${lane.architectures.join(", ")}`);
  if (typeof sourceCommit !== "string" || !GIT_SHA.test(sourceCommit)) fail("sourceCommit must be a full 40-character commit SHA");
  if (!isPlainObject(artifact)) fail("artifact must be an object");
  onlyFields(artifact, PREVIEW_ARTIFACT_FIELDS, "artifact");
  const { fileName } = artifact;
  if (typeof fileName !== "string" || !lane.fileNameMatches(fileName, { version, architecture, sourceCommit })) {
    fail(`artifact.fileName must follow ${lane.fileNameRule} for this version, architecture and commit`);
  }
  if (typeof artifact.sha256 !== "string" || !HEX64.test(artifact.sha256)) {
    fail("artifact.sha256 must be 64 lowercase hex characters");
  }
  if (!Number.isInteger(artifact.size) || artifact.size < 1 || artifact.size > MAX_SINGLE_PUT_BYTES) {
    fail("artifact.size must be a positive integer within a single PUT");
  }
  const tag = `afar-${lane.os}-preview-${version}`;
  if (raw.draftReleaseTag !== tag) fail(`draftReleaseTag must be ${tag}`);
  if (raw.bucket !== EXPECTED_BUCKET) fail(`bucket must be ${EXPECTED_BUCKET}`);
  if (raw.publicBaseUrl !== EXPECTED_PUBLIC_BASE_URL) fail(`publicBaseUrl must be ${EXPECTED_PUBLIC_BASE_URL}`);
  const objectKey = `mission-control/preview/${lane.os}/${version}/${fileName}`;
  if (raw.objectKey !== objectKey) fail(`objectKey must be ${objectKey}`);
  if (raw.consistencyProbeKey !== CONSISTENCY_PROBE_KEY) fail(`consistencyProbeKey must be ${CONSISTENCY_PROBE_KEY}`);
  const qualification = raw.previewQualification;
  if (!isPlainObject(qualification)) fail("previewQualification must be an object");
  onlyFields(qualification, PREVIEW_QUALIFICATION_FIELDS, "previewQualification");
  if (qualification.signed !== false) fail("previewQualification.signed must be false: this lane publishes unsigned previews only");
  const { notQualified } = qualification;
  if (!Array.isArray(notQualified) || notQualified.length === 0 ||
      !notQualified.every((item) => typeof item === "string" && item.trim().length > 0 && item.length <= 120)) {
    fail("previewQualification.notQualified must list what is not qualified");
  }
  if (typeof qualification.accepted !== "boolean") fail("previewQualification.accepted must be true or false");
  if (requireAccepted) {
    if (qualification.accepted !== true) fail("preview qualification is not recorded; refusing to publish");
    if (qualification.qualifiedArtifactSha256 !== artifact.sha256) {
      fail("preview qualification was not recorded for this exact artifact SHA-256");
    }
    if (typeof qualification.evidenceSha256 !== "string" || !HEX64.test(qualification.evidenceSha256)) {
      fail("previewQualification.evidenceSha256 must reference the qualification evidence");
    }
    if (!isIsoUtcTimestamp(qualification.acceptedAt, { fine: true })) {
      fail("previewQualification.acceptedAt must be an RFC 3339 UTC timestamp such as 2026-10-19T00:00:00Z");
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
    objectKey,
    publicUrl: `${raw.publicBaseUrl}/${objectKey}`,
    lane: raw.platform
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
      return { status: response.status, bytes, mediaType: mediaType(response), date: response.headers.get("date") };
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
    mediaTypes: ["application/octet-stream", LANES[contract.lane].mediaType],
    deadlineMs: limits.artifactDeadlineMs,
    idleMs: limits.idleMs
  });
  if (bytes === null) fail("draft asset returned 404");
  if (sha256Hex(bytes) !== contract.sha256) fail("downloaded draft asset SHA-256 does not match the contract");
  return bytes;
}

/**
 * Bind the run budget to GitHub's own record of this job. Lists the jobs of
 * this exact run attempt and requires exactly one in-progress job on this
 * runner, with this run id, attempt, head SHA and job name. Elapsed time is
 * GitHub's Date header minus the job's created_at, plus one second for the
 * header's resolution, plus the local monotonic time since the request was
 * sent; every rounding errs toward more elapsed time. No job timeout can start
 * before the job's record exists, so the result never under-counts it. Any
 * missing, ambiguous or inconsistent metadata fails closed.
 */
export async function resolveJobClock({ repository, token, job, fetchImpl, limits = DEFAULT_LIMITS, now, jobName = PUBLISH_JOB_NAME }) {
  if (!REPOSITORY.test(repository ?? "")) fail("GITHUB_REPOSITORY is malformed");
  if (!token) fail("GH_TOKEN is required to read this job's metadata");
  const { runId, runAttempt, runnerName, headSha } = job ?? {};
  if (!RUN_ID.test(runId ?? "")) fail("GITHUB_RUN_ID is missing or malformed");
  if (!RUN_ATTEMPT.test(runAttempt ?? "")) fail("GITHUB_RUN_ATTEMPT is missing or malformed");
  if (typeof runnerName !== "string" || runnerName.length === 0 || runnerName.length > 255) fail("RUNNER_NAME is missing");
  if (!GIT_SHA.test(headSha ?? "")) fail("GITHUB_SHA is missing or malformed");

  const sent = now();
  const { bytes, date } = await boundedGet(`${GITHUB_API_ORIGIN}/repos/${repository}/actions/runs/${runId}/attempts/${runAttempt}/jobs?per_page=100`, {
    fetchImpl,
    origins: [GITHUB_API_ORIGIN],
    token,
    accept: "application/vnd.github+json",
    maxBytes: limits.apiMaxBytes,
    mediaTypes: ["application/json"],
    deadlineMs: limits.apiDeadlineMs,
    idleMs: limits.idleMs
  });
  if (bytes === null) fail("this run attempt's job listing returned 404");
  if (typeof date !== "string" || !HTTP_DATE.test(date)) fail("the job listing has no valid Date header; cannot read GitHub's clock");
  const serverNow = Date.parse(date);
  const listing = JSON.parse(bytes.toString("utf8"));
  const jobs = listing?.jobs;
  if (!Array.isArray(jobs) || listing.total_count !== jobs.length) fail("the job listing is incomplete or malformed");
  const mine = jobs.filter((entry) => entry?.status === "in_progress" && entry?.runner_name === runnerName);
  if (mine.length !== 1) fail(`expected exactly one in-progress job on runner ${runnerName}, found ${mine.length}`);
  const [record] = mine;
  if (String(record.run_id) !== runId || String(record.run_attempt) !== runAttempt) fail("the job record names another run or attempt");
  if (record.head_sha !== headSha) fail("the job record names another commit");
  if (record.name !== jobName) fail("the job record names another job");
  if (!isIsoUtcTimestamp(record.created_at)) fail("the job record has no valid created_at");
  const createdAt = Date.parse(record.created_at);
  if (createdAt > serverNow + 1000) fail("the job record was created after GitHub's current time");
  const elapsedAtSend = serverNow + 1000 - createdAt;
  return Object.freeze({
    jobId: record.id,
    createdAt: record.created_at,
    elapsedMs: () => elapsedAtSend + (now() - sent)
  });
}

/**
 * Anonymous GET from the public host only, never redirected. Feeds are read
 * cache-busted (query string plus no-cache) to see the bucket's current bytes.
 * The artifact is read exactly as a customer requests it: the canonical URL
 * with no query string and no cache override, so a cached 404 at the edge
 * cannot be masked by a cache-busted read that reaches the bucket.
 */
async function publicGet(contract, key, { fetchImpl, limits, sleep, attempts, artifact = false }) {
  const options = {
    fetchImpl,
    origins: [contract.publicBaseUrl],
    accept: artifact ? LANES[contract.lane].mediaType : "*/*",
    maxBytes: artifact ? contract.size : limits.feedMaxBytes,
    exactBytes: artifact ? contract.size : null,
    mediaTypes: artifact ? [LANES[contract.lane].mediaType] : null,
    deadlineMs: artifact ? limits.publicArtifactDeadlineMs : limits.feedDeadlineMs,
    idleMs: limits.idleMs,
    noCache: !artifact
  };
  let last = null;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const url = artifact ? contract.publicUrl : `${contract.publicBaseUrl}/${key}?afar-verify=${Date.now()}-${attempt}`;
      const result = await boundedGet(url, options);
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
      "--content-type", LANES[contract.lane].mediaType,
      "--cache-control", "public, max-age=31536000, immutable"
    ]
  };
}

/**
 * The post-write reserve for a lane. postWriteReserveMs covers the Mac lane's two
 * feeds; each further feed adds its worst-case re-read (3 attempts at the feed
 * deadline plus 2 s + 4 s of backoff), so the Mac reserve is unchanged.
 */
export function postWriteReserveMs(lane, limits = DEFAULT_LIMITS) {
  const extraFeeds = lane.feedKeys.length - FEED_KEYS.length;
  return limits.postWriteReserveMs + extraFeeds * (3 * limits.feedDeadlineMs + 6000);
}

/** The full guarded publication. Every external effect goes through injected functions. */
export async function publish({ contractRaw, repository, token, accountId, job, fetchImpl, runAws, workDir, sleep, limits = DEFAULT_LIMITS, now = () => performance.now() }) {
  const contract = validateContract(contractRaw, { requireAccepted: true });
  if (!ACCOUNT_ID.test(accountId ?? "")) fail("CLOUDFLARE_ACCOUNT_ID must be 32 lowercase hex characters");
  const lane = LANES[contract.lane];
  const clock = await resolveJobClock({ repository, token, job, fetchImpl, limits, now, jobName: lane.jobName });
  // The write window closes once the post-write reserve is no longer left in the budget.
  const reserveMs = postWriteReserveMs(lane, limits);
  const writeWindowOpen = () => clock.elapsedMs() <= limits.totalBudgetMs - reserveMs;
  if (!writeWindowOpen()) {
    fail("the job's time since GitHub created it already closed the write window; refusing before the draft download or any bucket access");
  }
  const endpoint = `https://${accountId}.r2.cloudflarestorage.com`;
  const io = { fetchImpl, limits, sleep };

  const bytes = await downloadDraftAsset({ contract, repository, token, fetchImpl, limits });
  const artifactPath = join(workDir, contract.fileName);
  writeFileSync(artifactPath, bytes);
  const commands = awsCommands({ contract, endpoint, artifactPath, probePath: join(workDir, "consistency-probe") });

  const feedsBefore = {};
  for (const key of lane.feedKeys) {
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
  if (published === null) {
    fail(`the canonical customer URL still serves 404 (likely a cached negative response); ${result === "published" ? "the object was written" : "the key already exists"}: ask the custodian to purge exactly ${contract.publicUrl} and re-run to verify`);
  }
  if (sha256Hex(published) !== contract.sha256) {
    fail(result === "already-published"
      ? "the key already exists with different bytes; conflict, not overwritten"
      : "public bytes do not match the contract");
  }

  for (const key of lane.feedKeys) {
    const body = await publicGet(contract, key, { ...io, attempts: 3 });
    const after = body === null ? null : sha256Hex(body);
    if (after !== feedsBefore[key]) fail(`OpenBurnBar feed ${key} changed during publication`);
  }

  return {
    result,
    product: "Afar",
    lane: contract.lane,
    version: contract.version,
    url: contract.publicUrl,
    objectKey: contract.objectKey,
    sha256: contract.sha256,
    size: contract.size,
    jobId: clock.jobId,
    jobCreatedAt: clock.createdAt,
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
    job: {
      runId: process.env.GITHUB_RUN_ID,
      runAttempt: process.env.GITHUB_RUN_ATTEMPT,
      runnerName: process.env.RUNNER_NAME,
      headSha: process.env.GITHUB_SHA
    },
    fetchImpl: fetch,
    runAws,
    workDir,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms))
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
