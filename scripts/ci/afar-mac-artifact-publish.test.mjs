import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  awsArgv,
  awsCommands,
  boundedGet,
  DEFAULT_LIMITS,
  isIsoUtcTimestamp,
  publish,
  PUBLISH_JOB_NAME,
  PublishError,
  sha256Hex,
  validateContract
} from "./afar-mac-artifact-publish.mjs";

const root = new URL("../../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");
const committed = JSON.parse(read("config/afar-mac-release.json"));

const ARTIFACT = Buffer.from("afar blank dmg bytes, streamed in several chunks for the test");
const ACCOUNT = "0123456789abcdef0123456789abcdef";
const REPO = "Imagine-That-Ai/BurnBar";
const API_ASSET_URL = `https://api.github.com/repos/${REPO}/releases/assets/1`;
const STORAGE_URL = "https://release-assets.githubusercontent.com/blob";
const FEEDS = { "latest-macos.json": Buffer.from('{"version":"1.0.0"}'), "appcast.xml": Buffer.from("<rss/>") };
const FAST = { ...DEFAULT_LIMITS, apiDeadlineMs: 500, feedDeadlineMs: 500, artifactDeadlineMs: 500, idleMs: 100 };
// This job, as the runner's environment names it, and GitHub's clock when it answers.
const JOB = { runId: "39149426512", runAttempt: "1", runnerName: "GitHub Actions 1000001", headSha: "a".repeat(40) };
const JOBS_URL = `https://api.github.com/repos/${REPO}/actions/runs/${JOB.runId}/attempts/${JOB.runAttempt}/jobs?per_page=100`;
const SERVER_DATE = "Mon, 19 Oct 2026 00:30:00 GMT";
const iso = (ms) => new Date(ms).toISOString().replace(/\.000Z$/u, "Z");
/** GitHub's job record for this job, created `ageMs` before SERVER_DATE. */
function jobRecord(ageMs = 60_000, overrides = {}) {
  return {
    id: 117739838531,
    run_id: Number(JOB.runId),
    run_attempt: Number(JOB.runAttempt),
    head_sha: JOB.headSha,
    name: PUBLISH_JOB_NAME,
    status: "in_progress",
    runner_name: JOB.runnerName,
    created_at: iso(Date.parse(SERVER_DATE) - ageMs),
    // The runner picked the job up five minutes later; the budget must not start here.
    started_at: iso(Date.parse(SERVER_DATE) - ageMs + 5 * 60_000),
    ...overrides
  };
}

function contract(overrides = {}) {
  const sha = sha256Hex(ARTIFACT);
  return {
    ...committed,
    artifact: { ...committed.artifact, sha256: sha, size: ARTIFACT.length },
    cleanGuiAcceptance: {
      accepted: true,
      installedArtifactSha256: sha,
      evidenceSha256: "e".repeat(64),
      acceptedAt: "2026-10-19T00:00:00Z"
    },
    ...overrides
  };
}

/** A fetch Response stand-in with a real ReadableStream body. */
function response(status, body = Buffer.alloc(0), { headers = {}, chunk = 7, stallAfter = null, declareLength = true } = {}) {
  let offset = 0;
  let sent = 0;
  let cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      if (stallAfter !== null && sent >= stallAfter) return new Promise(() => {});
      if (offset >= body.length) return controller.close();
      controller.enqueue(new Uint8Array(body.subarray(offset, offset + chunk)));
      offset += chunk;
      sent += 1;
    },
    cancel() {
      cancelled = true;
    }
  });
  const all = { ...headers };
  if (declareLength && status === 200) all["content-length"] ??= String(body.length);
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (name) => all[name.toLowerCase()] ?? null },
    body: stream,
    get cancelled() {
      return cancelled;
    }
  };
}

/** A fake GitHub API + asset storage + public host + R2 bucket. */
function world({
  draft = true,
  assetBytes = ARTIFACT,
  assetType = "application/octet-stream",
  assetRedirect = STORAGE_URL,
  assetResponse = null,
  publicType = "application/x-apple-diskimage",
  bucketProbe = FEEDS["latest-macos.json"],
  existing = null,
  changeFeedOnPut = false,
  jobs = [jobRecord()],
  jobsTotal = null,
  jobsDate = SERVER_DATE,
  jobsStatus = 200,
  edgeCached404 = false
} = {}) {
  const c = contract();
  const objects = new Map(Object.entries(FEEDS));
  if (existing) objects.set(c.objectKey, existing);
  const calls = { aws: [], awsTimeouts: [], fetch: [], authOrigins: new Set(), artifactReads: [] };
  let putAttempted = false;
  const fetchImpl = async (url, init = {}) => {
    calls.fetch.push(url);
    if (init.headers?.Authorization) calls.authOrigins.add(new URL(url).origin);
    const parsed = new URL(url);
    if (url === JOBS_URL) {
      const headers = { "content-type": "application/json; charset=utf-8", ...(jobsDate === null ? {} : { date: jobsDate }) };
      const body = Buffer.from(JSON.stringify({ total_count: jobsTotal ?? jobs.length, jobs }));
      return response(jobsStatus, jobsStatus === 200 ? body : Buffer.alloc(0), { headers });
    }
    if (parsed.origin === "https://api.github.com" && parsed.pathname === `/repos/${REPO}/releases`) {
      const release = { tag_name: c.draftReleaseTag, draft, assets: [{ name: c.artifact.fileName, size: c.artifact.size, url: API_ASSET_URL }] };
      return response(200, Buffer.from(JSON.stringify([release])), { headers: { "content-type": "application/json; charset=utf-8" } });
    }
    if (url === API_ASSET_URL) return response(302, Buffer.alloc(0), { headers: { location: assetRedirect } });
    if (url === assetRedirect) {
      return assetResponse ?? response(200, assetBytes, { headers: { "content-type": assetType } });
    }
    if (parsed.origin === "https://downloads.burnbar.ai") {
      const key = parsed.pathname.slice(1);
      if (key.endsWith(".dmg")) {
        calls.artifactReads.push({ url, beforeWrite: !putAttempted, cacheControl: init.headers?.["Cache-Control"] ?? null });
        // The CDN edge caches a 404 for the canonical URL; a query string misses that cache entry.
        if (edgeCached404 && parsed.search === "") return response(404);
      }
      if (!objects.has(key)) return response(404);
      const type = key.endsWith(".dmg") ? publicType : "application/json";
      return response(200, objects.get(key), { headers: { "content-type": type } });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  const runAws = (args, timeoutMs) => {
    calls.aws.push(args);
    calls.awsTimeouts.push(timeoutMs);
    const value = (flag) => args[args.indexOf(flag) + 1];
    if (args[1] === "get-object") {
      writeFileSync(args.at(-1), bucketProbe);
      return { status: 0, stdout: "{}", stderr: "" };
    }
    if (args[1] === "put-object") {
      putAttempted = true;
      const key = value("--key");
      if (objects.has(key)) {
        return { status: 254, stdout: "", stderr: "An error occurred (PreconditionFailed) when calling the PutObject operation" };
      }
      objects.set(key, readFileSync(value("--body")));
      if (changeFeedOnPut) objects.set("appcast.xml", Buffer.from("<rss changed/>"));
      return { status: 0, stdout: "{}", stderr: "" };
    }
    return { status: 1, stdout: "", stderr: "unexpected" };
  };
  return { c, calls, objects, fetchImpl, runAws };
}

async function run(w, overrides = {}) {
  return publish({
    contractRaw: overrides.contractRaw ?? w.c,
    repository: REPO,
    token: "ghs_test",
    accountId: ACCOUNT,
    job: overrides.job ?? JOB,
    fetchImpl: w.fetchImpl,
    runAws: overrides.runAws ?? w.runAws,
    workDir: mkdtempSync(join(tmpdir(), "afar-publish-test-")),
    sleep: async () => {},
    limits: overrides.limits ?? FAST,
    now: overrides.now ?? (() => 0)
  });
}

const puts = (w) => w.calls.aws.filter((args) => args[1] === "put-object");

test("the committed contract pins the exact blank DMG and stays unaccepted", () => {
  const c = validateContract(committed);
  assert.equal(c.sha256, "9e46f299de73cb6510ed8b49f9a32cb7758b98e593fe51b8e568b06bd68aa272");
  assert.equal(c.size, 40624316);
  assert.equal(c.publicUrl, "https://downloads.burnbar.ai/mission-control/0.1.12/MissionControl-blank-0.1.12-universal-release.dmg");
  assert.equal(committed.cleanGuiAcceptance.accepted, false);
  assert.throws(() => validateContract(committed, { requireAccepted: true }), /acceptance is not recorded/);
});

test("acceptance must name the exact artifact and carry evidence", () => {
  const base = contract();
  for (const acceptance of [
    { ...base.cleanGuiAcceptance, accepted: "true" },
    { ...base.cleanGuiAcceptance, installedArtifactSha256: "f".repeat(64) },
    { ...base.cleanGuiAcceptance, evidenceSha256: null },
    { ...base.cleanGuiAcceptance, acceptedAt: "yesterday" },
    { ...base.cleanGuiAcceptance, acceptedAt: "2026" },
    { ...base.cleanGuiAcceptance, acceptedAt: "2026-02-31T00:00:00Z" }
  ]) {
    assert.throws(() => validateContract({ ...base, cleanGuiAcceptance: acceptance }, { requireAccepted: true }), PublishError);
  }
});

test("acceptedAt is a real RFC 3339 UTC instant, not anything Date.parse tolerates", () => {
  for (const good of ["2026-10-19T00:00:00Z", "2026-10-19T23:59:59.123Z", "2028-02-29T12:00:00Z"]) {
    assert.ok(isIsoUtcTimestamp(good), good);
  }
  for (const bad of [
    "2026",
    "0",
    "2026-10-19",
    "2026-02-31T00:00:00Z",
    "2027-02-29T00:00:00Z",
    "2026-10-19T24:00:00Z",
    "2026-10-19T00:00:60Z",
    "2026-10-19T00:00:00",
    "2026-10-19T00:00:00+02:00",
    "2026-10-19 00:00:00Z",
    "Mon, 19 Oct 2026 00:00:00 GMT",
    " 2026-10-19T00:00:00Z",
    0,
    null,
    1792368000000
  ]) {
    assert.equal(isIsoUtcTimestamp(bad), false, String(bad));
  }
});

test("every binding field is pinned, so a changed key, bucket or host fails closed", () => {
  for (const change of [
    { objectKey: "latest-macos.json" },
    { objectKey: "mission-control/0.1.12/other.dmg" },
    { bucket: "another-bucket" },
    { publicBaseUrl: "https://example.com" },
    { draftReleaseTag: "v0.1.12" },
    { consistencyProbeKey: "appcast.xml" },
    { artifact: { ...committed.artifact, fileName: "MissionControl-personal-0.1.12.dmg" } },
    { product: "OpenBurnBar" }
  ]) {
    assert.throws(() => validateContract({ ...committed, ...change }), PublishError, JSON.stringify(change));
  }
});

test("publishes one conditional object, streams in chunks and verifies it publicly", async () => {
  const w = world();
  const receipt = await run(w);
  assert.equal(receipt.result, "published");
  assert.equal(puts(w).length, 1);
  const args = puts(w)[0];
  assert.equal(args[args.indexOf("--key") + 1], w.c.objectKey);
  assert.equal(args[args.indexOf("--bucket") + 1], "openburnbar-downloads");
  assert.equal(args[args.indexOf("--if-none-match") + 1], "*");
  assert.equal(args[args.indexOf("--checksum-sha256") + 1], Buffer.from(w.c.artifact.sha256, "hex").toString("base64"));
  assert.equal(args[args.indexOf("--content-type") + 1], "application/x-apple-diskimage");
  assert.equal(args[args.indexOf("--endpoint-url") + 1], `https://${ACCOUNT}.r2.cloudflarestorage.com`);
  assert.deepEqual(w.calls.aws.map((a) => a[1]), ["get-object", "put-object"]);
  assert.deepEqual(w.calls.awsTimeouts, [FAST.awsProbeTimeoutMs, FAST.awsPutTimeoutMs]);
  assert.deepEqual([...w.calls.authOrigins], ["https://api.github.com"]);
  assert.equal(w.objects.get("latest-macos.json"), FEEDS["latest-macos.json"]);
});

test("refuses without acceptance before any network or bucket access", async () => {
  const w = world();
  await assert.rejects(run(w, { contractRaw: committed }), /acceptance is not recorded/);
  assert.equal(w.calls.fetch.length, 0);
  assert.equal(w.calls.aws.length, 0);
});

test("refuses a published (public) staging release", async () => {
  const w = world({ draft: false });
  await assert.rejects(run(w), /not a draft/);
  assert.equal(w.calls.aws.length, 0);
});

test("refuses staged bytes that differ from the contract", async () => {
  const bad = Buffer.from(ARTIFACT);
  bad[0] ^= 1;
  const w = world({ assetBytes: bad });
  await assert.rejects(run(w), /SHA-256 does not match/);
  assert.equal(w.calls.aws.length, 0);
});

test("stops an oversized artifact by its declared length and while streaming", async () => {
  const big = Buffer.concat([ARTIFACT, Buffer.from("extra")]);
  await assert.rejects(run(world({ assetBytes: big })), /exceeds the \d+-byte cap/);
  const undeclared = response(200, big, { headers: { "content-type": "application/octet-stream" }, declareLength: false });
  const w = world({ assetResponse: undeclared });
  await assert.rejects(run(w), /exceeded the \d+-byte cap/);
  assert.equal(undeclared.cancelled, true);
  assert.equal(w.calls.aws.length, 0);
});

test("accepts an undeclared-length chunked artifact of exactly the right size", async () => {
  const w = world({ assetResponse: response(200, ARTIFACT, { headers: { "content-type": "application/octet-stream" }, declareLength: false, chunk: 3 }) });
  assert.equal((await run(w)).result, "published");
});

test("rejects a short artifact and a stalled stream", async () => {
  await assert.rejects(run(world({ assetResponse: response(200, ARTIFACT.subarray(1), { headers: { "content-type": "application/octet-stream" }, declareLength: false }) })), /expected exactly/);
  const stalled = response(200, ARTIFACT, { headers: { "content-type": "application/octet-stream" }, stallAfter: 2 });
  const w = world({ assetResponse: stalled });
  await assert.rejects(run(w), /stalled|deadline/);
  assert.equal(stalled.cancelled, true);
  assert.equal(w.calls.aws.length, 0);
});

test("refuses prohibited redirects for the artifact", async () => {
  for (const target of [
    "http://release-assets.githubusercontent.com/blob",
    "https://evil.example.com/blob",
    "https://user:pass@release-assets.githubusercontent.com/blob",
    "https://release-assets.githubusercontent.com:8443/blob",
    "https://api.github.com/other"
  ]) {
    const w = world({ assetRedirect: target });
    await assert.rejects(run(w), /refusing/, target);
    assert.equal(w.calls.aws.length, 0);
  }
});

test("the public host is read without redirects", async () => {
  const fetchImpl = async () => response(302, Buffer.alloc(0), { headers: { location: "https://downloads.burnbar.ai/elsewhere" } });
  await assert.rejects(
    boundedGet("https://downloads.burnbar.ai/latest-macos.json", { fetchImpl, origins: ["https://downloads.burnbar.ai"], accept: "*/*", maxBytes: 10, deadlineMs: 500, idleMs: 100 }),
    /refusing redirect/
  );
});

test("never sends the GitHub token outside api.github.com", async () => {
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push([new URL(url).origin, Boolean(init.headers.Authorization)]);
    return new URL(url).origin === "https://api.github.com"
      ? response(302, Buffer.alloc(0), { headers: { location: STORAGE_URL } })
      : response(200, Buffer.from("ok"), { headers: { "content-type": "application/octet-stream" } });
  };
  await boundedGet(API_ASSET_URL, {
    fetchImpl, origins: ["https://api.github.com"], redirectOrigins: ["https://release-assets.githubusercontent.com"],
    maxRedirects: 1, token: "ghs_test", accept: "application/octet-stream", maxBytes: 10, deadlineMs: 500, idleMs: 100
  });
  assert.deepEqual(seen, [["https://api.github.com", true], ["https://release-assets.githubusercontent.com", false]]);
});

test("rejects wrong media types for the staged and the published artifact", async () => {
  const w1 = world({ assetType: "text/html" });
  await assert.rejects(run(w1), /unexpected media type text\/html/);
  assert.equal(w1.calls.aws.length, 0);
  const w2 = world({ publicType: "text/html" });
  await assert.rejects(run(w2), /unexpected media type text\/html/);
});

test("refuses to write when the bucket and the public host disagree", async () => {
  const w = world({ bucketProbe: Buffer.from("different bucket") });
  await assert.rejects(run(w), /disagree on the consistency probe/);
  assert.equal(puts(w).length, 0);
});

// The write window: how long after GitHub created the job a write may still start.
const WINDOW = FAST.totalBudgetMs - FAST.postWriteReserveMs;
// Job age that puts it exactly at the window boundary: elapsed is the age plus
// one second for the Date header's resolution.
const AT_BOUNDARY = WINDOW - 1000;
/** A monotonic clock that reads 0 when the job listing is requested and `later` afterwards. */
const tickAfterFirst = (later) => {
  let reads = 0;
  return () => (reads++ === 0 ? 0 : later);
};
/** True when nothing but the job listing was fetched and the bucket was never touched. */
const onlyJobLookup = (w) => w.calls.fetch.every((url) => url === JOBS_URL) && w.calls.aws.length === 0;

test("the run budget counts from GitHub's job created_at, in GitHub's clock", async () => {
  const w = world();
  const receipt = await run(w);
  assert.equal(receipt.result, "published");
  assert.equal(w.calls.fetch[0], JOBS_URL);
  assert.equal(receipt.jobId, 117739838531);
  assert.equal(receipt.jobCreatedAt, "2026-10-19T00:29:00Z");
});

test("a pre-first-step delay that ends exactly at the write-window boundary still publishes", async () => {
  const w = world({ jobs: [jobRecord(AT_BOUNDARY)] });
  const receipt = await run(w);
  assert.equal(receipt.result, "published");
  assert.equal(puts(w).length, 1);
});

test("a pre-first-step delay past the write window refuses before the draft download or any bucket access", async () => {
  // Queueing, environment approval or runner initialization ("Set up job") before
  // any step ran: GitHub created the job long before this process started.
  for (const [ageMs, now] of [
    [AT_BOUNDARY, tickAfterFirst(1)],
    [AT_BOUNDARY + 1000, () => 0],
    [20 * 60 * 60_000, () => 0]
  ]) {
    const w = world({ jobs: [jobRecord(ageMs)] });
    await assert.rejects(run(w, { now }), /already closed the write window/);
    assert.ok(onlyJobLookup(w), JSON.stringify(w.calls.fetch));
  }
});

test("a pre-write phase that runs past the write window refuses the PUT", async () => {
  const w = world();
  let clock = 0;
  // The bucket probe is the last step before the write; let it end one millisecond late.
  const runAws = (args, timeoutMs) => {
    const result = w.runAws(args, timeoutMs);
    if (args[1] === "get-object") clock = WINDOW - 61_000 + 1;
    return result;
  };
  await assert.rejects(run(w, { now: () => clock, runAws }), /not enough of the run budget remains/);
  assert.equal(puts(w).length, 0);
  assert.equal(w.calls.aws.length, 1);
});

test("missing, ambiguous or inconsistent job metadata fails closed before the draft download", async () => {
  const other = { ...JOB };
  for (const [label, worldOptions, runOptions] of [
    ["listing 404", { jobsStatus: 404 }, {}],
    ["no Date header", { jobsDate: null }, {}],
    ["non-HTTP Date header", { jobsDate: "2026-10-19T00:30:00Z" }, {}],
    ["no job on this runner", { jobs: [jobRecord(60_000, { runner_name: "GitHub Actions 2" })] }, {}],
    ["job not in progress", { jobs: [jobRecord(60_000, { status: "queued" })] }, {}],
    ["two jobs on this runner", { jobs: [jobRecord(), jobRecord(60_000, { id: 2 })] }, {}],
    ["paginated listing", { jobsTotal: 101 }, {}],
    ["another attempt", { jobs: [jobRecord(60_000, { run_attempt: 2 })] }, {}],
    ["another run", { jobs: [jobRecord(60_000, { run_id: 1 })] }, {}],
    ["another commit", { jobs: [jobRecord(60_000, { head_sha: "b".repeat(40) })] }, {}],
    ["another job", { jobs: [jobRecord(60_000, { name: "build" })] }, {}],
    ["no created_at", { jobs: [jobRecord(60_000, { created_at: null })] }, {}],
    ["loose created_at", { jobs: [jobRecord(60_000, { created_at: "2026-10-19" })] }, {}],
    ["created after GitHub's now", { jobs: [jobRecord(-2000)] }, {}],
    ["no run id", {}, { job: { ...other, runId: undefined } }],
    ["attempt 0", {}, { job: { ...other, runAttempt: "0" } }],
    ["no runner name", {}, { job: { ...other, runnerName: "" } }],
    ["short SHA", {}, { job: { ...other, headSha: "abc" } }]
  ]) {
    const w = world(worldOptions);
    await assert.rejects(run(w, runOptions), PublishError, label);
    assert.ok(onlyJobLookup(w), `${label}: ${JSON.stringify(w.calls.fetch)}`);
  }
});

/** Job-level and per-step timeout-minutes of the publish workflow, in order. */
function workflowTiming() {
  const wf = read(".github/workflows/publish-afar-mac-artifact.yml");
  const job = Number(/^    timeout-minutes: (\d+)$/m.exec(wf)[1]);
  const steps = wf.split(/^      - name: /m).slice(1).map((block) => ({
    name: block.split("\n")[0],
    block,
    minutes: Number(/^        timeout-minutes: (\d+)$/m.exec(block)?.[1] ?? Number.NaN)
  }));
  return { wf, job, steps };
}

test("one timing budget: GitHub's job record bounds everything, strictly inside the job timeout", () => {
  const L = DEFAULT_LIMITS;
  const { wf, job, steps } = workflowTiming();
  const min = 60_000;
  for (const step of steps) assert.ok(Number.isInteger(step.minutes) && step.minutes > 0, `step "${step.name}" has no timeout-minutes`);

  // The job can read its own record, read-only, and the helper binds to the runner's identity.
  assert.match(wf, /^      actions: read$/m);
  assert.match(wf, /^    name: Publish one Afar Mac artifact$/m);
  assert.equal(PUBLISH_JOB_NAME, "Publish one Afar Mac artifact");
  const helper = read("scripts/ci/afar-mac-artifact-publish.mjs");
  for (const name of ["GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "RUNNER_NAME", "GITHUB_SHA"]) {
    assert.match(helper, new RegExp(`process\\.env\\.${name}\\b`));
    assert.doesNotMatch(wf, new RegExp(`^\\s+${name}:`, "m"), `${name} must come from the runner, not the workflow`);
  }
  assert.doesNotMatch(wf, /AFAR_JOB_STARTED_AT_MS|GITHUB_ENV/);

  // Worst case after the write starts: the PUT, every public artifact read and
  // the feed re-reads (3 attempts each), all at their full deadlines, plus the
  // retry backoff of 2 s x attempt between reads.
  const backoff = (attempts) => Array.from({ length: attempts - 1 }, (_, i) => (i + 1) * 2000).reduce((x, y) => x + y, 0);
  const postWrite =
    L.awsPutTimeoutMs +
    L.publicArtifactAttempts * L.publicArtifactDeadlineMs +
    backoff(L.publicArtifactAttempts) +
    2 * (3 * L.feedDeadlineMs + backoff(3));
  assert.ok(postWrite < L.postWriteReserveMs, `post-write ${postWrite} >= reserve ${L.postWriteReserveMs}`);

  // Setup steps at their full bounds still leave a write window.
  const publishStep = steps.at(-1);
  assert.match(publishStep.block, /afar-mac-artifact-publish\.mjs publish/);
  const setup = steps.slice(0, -1).reduce((sum, step) => sum + step.minutes * min, 0);
  assert.ok(setup < L.totalBudgetMs - L.postWriteReserveMs, `bounded setup ${setup} closes the write window`);

  // The publish step starts after the job was created, so a bound at least the
  // budget cannot cut the helper short.
  assert.ok(publishStep.minutes * min >= L.totalBudgetMs, "publish step timeout is below the run budget");

  // The budget is counted from the job's creation, which no job timeout can
  // precede, so it only has to sit strictly below the whole-job timeout.
  assert.ok(L.totalBudgetMs < job * min, `run budget is not below the ${job}-minute job timeout`);
});

test("the artifact is verified only at its canonical customer URL, and only after the write", async () => {
  for (const existing of [null, ARTIFACT]) {
    const w = world({ existing });
    await run(w);
    assert.ok(w.calls.artifactReads.length > 0);
    for (const read of w.calls.artifactReads) {
      assert.equal(read.url, committed.publicBaseUrl + "/" + committed.objectKey);
      assert.equal(read.beforeWrite, false, "the canonical URL must not be probed before publication");
      assert.equal(read.cacheControl, null, "the customer URL is read without a cache override");
    }
  }
});

test("a cached canonical 404 cannot be masked by a cache-busted read that reaches the bucket", async () => {
  const purge = new RegExp(`canonical customer URL still serves 404.*the object was written.*purge exactly ${committed.publicBaseUrl}/${committed.objectKey}`);
  const w = world({ edgeCached404: true });
  await assert.rejects(run(w), purge);
  assert.equal(puts(w).length, 1);
  assert.deepEqual(w.objects.get(w.c.objectKey), ARTIFACT, "the bucket holds the bytes; only the edge is stale");
  assert.ok(w.calls.artifactReads.every((read) => !read.url.includes("?")));

  // A re-run after the key exists (412) still requires the canonical URL, and is not misreported as a conflict.
  const again = world({ edgeCached404: true, existing: ARTIFACT });
  await assert.rejects(run(again), /canonical customer URL still serves 404.*the key already exists.*purge exactly/);
});

test("an existing identical object is reported, never overwritten", async () => {
  const w = world({ existing: ARTIFACT });
  const receipt = await run(w);
  assert.equal(receipt.result, "already-published");
  assert.equal(puts(w).length, 1);
});

test("an existing different object is a conflict and is left untouched", async () => {
  const other = Buffer.from(ARTIFACT);
  other[3] ^= 1;
  const w = world({ existing: other });
  await assert.rejects(run(w), /conflict, not overwritten/);
  assert.equal(w.objects.get(w.c.objectKey), other);
});

test("fails if an OpenBurnBar feed changes during publication", async () => {
  const w = world({ changeFeedOnPut: true });
  await assert.rejects(run(w), /feed appcast.xml changed/);
});

test("the AWS argv uses only aws-cli 1.x options", () => {
  const commands = awsCommands({ contract: validateContract(committed), endpoint: `https://${ACCOUNT}.r2.cloudflarestorage.com`, artifactPath: "/tmp/a.dmg", probePath: "/tmp/p" });
  for (const args of Object.values(commands)) {
    const argv = awsArgv(args);
    assert.ok(!argv.includes("--no-cli-pager"));
    assert.deepEqual(argv.slice(-2), ["--output", "json"]);
  }
});

// Offline parse of the exact argv by the pinned CLI: point it at a closed local
// port so a fully parsed command fails only at connect, while any unknown
// option fails at parse time. Runs when AFAR_PINNED_AWS_BIN is set.
test("the pinned AWS CLI parses both exact commands", { skip: !process.env.AFAR_PINNED_AWS_BIN }, () => {
  const dir = mkdtempSync(join(tmpdir(), "afar-awsparse-"));
  writeFileSync(join(dir, "a.dmg"), "x");
  const commands = awsCommands({ contract: validateContract(committed), endpoint: "http://127.0.0.1:9", artifactPath: join(dir, "a.dmg"), probePath: join(dir, "p") });
  for (const args of Object.values(commands)) {
    const result = spawnSync(process.env.AFAR_PINNED_AWS_BIN, awsArgv(args), {
      encoding: "utf8",
      env: { PATH: process.env.PATH, AWS_ACCESS_KEY_ID: "test", AWS_SECRET_ACCESS_KEY: "test", AWS_DEFAULT_REGION: "auto", AWS_MAX_ATTEMPTS: "1", AWS_EC2_METADATA_DISABLED: "true" }
    });
    const output = `${result.stdout}${result.stderr}`;
    assert.doesNotMatch(output, /Unknown options|usage:/);
    assert.match(output, /Could not connect to the endpoint URL/);
  }
});

test("the workflow is dispatch-only, main-only, pinned and scoped to the release environment", () => {
  const wf = read(".github/workflows/publish-afar-mac-artifact.yml");
  assert.match(wf, /^on:\n  workflow_dispatch:\n/m);
  assert.doesNotMatch(wf, /^\s+(push|pull_request|pull_request_target|schedule|release|workflow_run):/m);
  assert.match(wf, /^permissions: \{\}$/m);
  assert.match(wf, /if: github\.ref == 'refs\/heads\/main'/);
  assert.match(wf, /environment: release$/m);
  assert.equal((wf.match(/contents: write/g) ?? []).length, 1);
  assert.doesNotMatch(wf, /(actions|id-token|packages|pull-requests|deployments): write/);
  assert.deepEqual([...wf.matchAll(/^      ([a-z-]+): (read|write)$/gm)].map((m) => `${m[1]}: ${m[2]}`), ["contents: write", "actions: read"]);
  for (const [, ref] of wf.matchAll(/uses:\s*[^@\s]+@(\S+)/g)) assert.match(ref, /^[0-9a-f]{40}$/);
  assert.match(wf, /persist-credentials: false/);
  assert.match(wf, /options:\n\s+- config\/afar-mac-release\.json\n/);
  assert.match(wf, /--require-hashes --only-binary=:all: --no-deps/);
  assert.equal((wf.match(/GH_TOKEN:/g) ?? []).length, 1);
  assert.doesNotMatch(wf, /CLOUDFLARE_API_TOKEN|upload-macos-downloads-r2|setup-macos-downloads-r2|appcast|latest-macos|gh release (create|upload|edit|delete)/);
  // Inputs and secrets reach shell steps only through env, never interpolated into run.
  assert.doesNotMatch(wf, /run:.*\$\{\{/);
});

test("the AWS CLI requirements are fully hash-pinned", () => {
  const text = read("scripts/ci/afar-mac-awscli-requirements.txt");
  const lines = text.split("\n").filter((l) => /^[a-z]/i.test(l));
  assert.ok(lines.some((l) => l.startsWith("awscli==1.46.1 ")));
  for (const line of lines) assert.match(line, /^[a-z0-9-]+==[\w.]+ \\$/);
  assert.equal((text.match(/--hash=sha256:[0-9a-f]{64}/g) ?? []).length, lines.length);
});
