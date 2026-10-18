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
 *   3. Binding probe: the bucket's copy of the probe key must equal the public
 *      host's copy, proving the bucket serves downloads.burnbar.ai. Zero writes
 *      happen before this passes.
 *   4. One conditional PutObject (If-None-Match: *) of the one contract key, with
 *      an x-amz-checksum-sha256 for server-side verification. An existing key
 *      (412) is never overwritten: identical public bytes mean "already
 *      published", anything else is a conflict.
 *   5. Anonymous public re-fetch must match size and SHA-256, and the OpenBurnBar
 *      feeds (latest-macos.json, appcast.xml) must be byte-identical to the
 *      snapshot taken before the write.
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
export const BINDING_PROBE_KEY = "latest-macos.json";
export const FEED_KEYS = Object.freeze(["latest-macos.json", "appcast.xml"]);
const MAX_SINGLE_PUT_BYTES = 5 * 1024 ** 3;
const HEX64 = /^[a-f0-9]{64}$/u;
const VERSION = /^\d+\.\d+\.\d+$/u;
const ACCOUNT_ID = /^[a-f0-9]{32}$/u;
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;

export class PublishError extends Error {}

function fail(message) {
  throw new PublishError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
  if (raw.bindingProbeKey !== BINDING_PROBE_KEY) fail(`bindingProbeKey must be ${BINDING_PROBE_KEY}`);
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
    if (typeof acceptance.acceptedAt !== "string" || !Number.isFinite(Date.parse(acceptance.acceptedAt))) {
      fail("cleanGuiAcceptance.acceptedAt must be an ISO date");
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

const GITHUB_HEADERS = {
  Accept: "application/vnd.github+json",
  "X-GitHub-Api-Version": "2022-11-28"
};

/** Read the artifact from the single DRAFT release carrying the contract tag. */
export async function downloadDraftAsset({ contract, repository, token, fetchImpl }) {
  if (!REPOSITORY.test(repository ?? "")) fail("GITHUB_REPOSITORY is malformed");
  if (!token) fail("GH_TOKEN is required to read the draft release");
  const auth = { ...GITHUB_HEADERS, Authorization: `Bearer ${token}` };
  const matches = [];
  for (let page = 1; page <= 10; page++) {
    const response = await fetchImpl(
      `https://api.github.com/repos/${repository}/releases?per_page=100&page=${page}`,
      { headers: auth }
    );
    if (!response.ok) fail(`listing releases failed with HTTP ${response.status}`);
    const releases = await response.json();
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
  // Follow the storage redirect manually so the token is never sent to another origin.
  const first = await fetchImpl(asset.url, {
    headers: { ...auth, Accept: "application/octet-stream" },
    redirect: "manual"
  });
  let response = first;
  if (first.status >= 300 && first.status < 400) {
    const location = first.headers.get("location");
    if (!location) fail("asset redirect has no location");
    response = await fetchImpl(location, { redirect: "follow" });
  }
  if (!response.ok) fail(`downloading the draft asset failed with HTTP ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length !== contract.size) fail("downloaded draft asset size does not match the contract");
  if (sha256Hex(bytes) !== contract.sha256) fail("downloaded draft asset SHA-256 does not match the contract");
  return bytes;
}

/** Anonymous, uncached public GET. Returns null on 404 so callers can decide. */
export async function publicGet(url, { fetchImpl, attempts = 1, sleep = async () => {} }) {
  let lastStatus = 0;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const separator = url.includes("?") ? "&" : "?";
    const response = await fetchImpl(`${url}${separator}afar-verify=${Date.now()}-${attempt}`, {
      headers: { "Cache-Control": "no-cache" },
      redirect: "follow"
    });
    lastStatus = response.status;
    if (response.ok) return Buffer.from(await response.arrayBuffer());
    if (response.status === 404 && attempt === attempts) return null;
    if (attempt < attempts) await sleep(attempt * 2000);
  }
  if (lastStatus === 404) return null;
  fail(`public GET ${url} failed with HTTP ${lastStatus}`);
}

function isPreconditionFailed(result) {
  return /PreconditionFailed|\(412\)|status code: 412/u.test(`${result.stderr}\n${result.stdout}`);
}

/** The full guarded publication. Every external effect goes through injected functions. */
export async function publish({ contractRaw, repository, token, accountId, fetchImpl, runAws, workDir, sleep }) {
  const contract = validateContract(contractRaw, { requireAccepted: true });
  if (!ACCOUNT_ID.test(accountId ?? "")) fail("CLOUDFLARE_ACCOUNT_ID must be 32 lowercase hex characters");
  const endpoint = `https://${accountId}.r2.cloudflarestorage.com`;

  const bytes = await downloadDraftAsset({ contract, repository, token, fetchImpl });
  const artifactPath = join(workDir, contract.fileName);
  writeFileSync(artifactPath, bytes);

  const feedsBefore = {};
  for (const key of FEED_KEYS) {
    const body = await publicGet(`${contract.publicBaseUrl}/${key}`, { fetchImpl, attempts: 3, sleep });
    feedsBefore[key] = body === null ? null : sha256Hex(body);
  }

  const probePublic = await publicGet(`${contract.publicBaseUrl}/${BINDING_PROBE_KEY}`, { fetchImpl, attempts: 3, sleep });
  if (probePublic === null) fail("binding probe key is not served by the public host; refusing to write");
  const probePath = join(workDir, "binding-probe");
  const probe = runAws([
    "s3api", "get-object", "--endpoint-url", endpoint,
    "--bucket", contract.bucket, "--key", BINDING_PROBE_KEY, probePath
  ]);
  if (probe.status !== 0) fail("binding probe could not read the bucket; refusing to write");
  const probeSha = sha256Hex(readFileSync(probePath));
  if (probeSha !== sha256Hex(probePublic)) {
    fail("bucket and public host disagree on the binding probe; refusing to write");
  }

  const checksum = Buffer.from(contract.sha256, "hex").toString("base64");
  const put = runAws([
    "s3api", "put-object", "--endpoint-url", endpoint,
    "--bucket", contract.bucket, "--key", contract.objectKey, "--body", artifactPath,
    "--if-none-match", "*",
    "--checksum-sha256", checksum,
    "--content-type", "application/x-apple-diskimage",
    "--cache-control", "public, max-age=31536000, immutable"
  ]);
  let result = "published";
  if (put.status !== 0) {
    if (!isPreconditionFailed(put)) fail("conditional PutObject failed; nothing was overwritten");
    result = "already-published";
  }

  const published = await publicGet(contract.publicUrl, { fetchImpl, attempts: 6, sleep });
  if (published === null) fail("published object is not reachable on the public host");
  if (published.length !== contract.size || sha256Hex(published) !== contract.sha256) {
    fail(result === "already-published"
      ? "the key already exists with different bytes; conflict, not overwritten"
      : "public bytes do not match the contract");
  }

  for (const key of FEED_KEYS) {
    const body = await publicGet(`${contract.publicBaseUrl}/${key}`, { fetchImpl, attempts: 3, sleep });
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
    bindingProbeSha256: probeSha,
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
    AWS_EC2_METADATA_DISABLED: "true"
  };
  const runAws = (awsArgs) => {
    const result = spawnSync(awsBin, [...awsArgs, "--no-cli-pager", "--output", "json"], {
      env: awsEnv,
      encoding: "utf8"
    });
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
