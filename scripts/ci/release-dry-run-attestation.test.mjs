#!/usr/bin/env node

import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "release-dry-run-attestation.mjs");

const SHA_A = "a".repeat(40);
const SHA_B = "b".repeat(40);
const TAG = "v1.2.3";
const PROD = "deploy-production";
const CLOUD = "deploy-cloud-run";
const RUN_PROD = 101;
const RUN_CLOUD = 202;
const SERVER_URL = "https://github.com";
const REPO = "test/repo";

const WORKFLOW_BY_PLANE = {
  [PROD]: ".github/workflows/deploy-production.yml",
  [CLOUD]: ".github/workflows/deploy-cloud-run.yml",
};

let passed = 0;
let failed = 0;

function assert(label, condition) {
  if (condition) {
    passed += 1;
    console.log(`  PASS: ${label}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${label}`);
  }
}

function runUrl(runId, repo = REPO) {
  return `${SERVER_URL}/${repo}/actions/runs/${runId}`;
}

function statusFor(
  plane,
  runId,
  {
    id = runId,
    state = "success",
    creator = { login: "github-actions[bot]", type: "Bot" },
    targetUrl = runUrl(runId),
    createdAt = `2026-08-15T10:${String(runId % 60).padStart(2, "0")}:00Z`,
    tag = TAG,
  } = {},
) {
  return {
    id,
    state,
    context: `release-attestation/${plane}/${tag}`,
    description: "dry-run passed",
    target_url: targetUrl,
    created_at: createdAt,
    creator,
  };
}

function runFor(
  plane,
  runId,
  {
    id = runId,
    htmlUrl = runUrl(runId),
    repository = REPO,
    path = WORKFLOW_BY_PLANE[plane],
    event = "workflow_dispatch",
    status = "completed",
    conclusion = "success",
    headBranch = "main",
    headSha = SHA_B,
    displayTitle = `release-control/${plane}/dry-run/${TAG}/${SHA_A}/${SHA_B}`,
  } = {},
) {
  return {
    id,
    html_url: htmlUrl,
    repository: { full_name: repository },
    path,
    event,
    status,
    conclusion,
    head_branch: headBranch,
    head_sha: headSha,
    display_title: displayTitle,
  };
}

function validStatuses() {
  return new Map([
    [
      SHA_A,
      [
        statusFor(PROD, RUN_PROD, { createdAt: "2026-08-15T10:01:00Z" }),
        statusFor(CLOUD, RUN_CLOUD, { createdAt: "2026-08-15T10:02:00Z" }),
      ],
    ],
  ]);
}

function validRuns() {
  return new Map([
    [RUN_PROD, runFor(PROD, RUN_PROD)],
    [RUN_CLOUD, runFor(CLOUD, RUN_CLOUD)],
  ]);
}

function createMockApi({
  statuses = new Map(),
  statusPages = null,
  runs = new Map(),
  malformedPagination = false,
} = {}) {
  const requests = [];
  let nextStatusId = 1_000;

  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    requests.push({
      method: request.method,
      pathname: url.pathname,
      search: url.search,
    });

    const postStatus = url.pathname.match(
      /^\/repos\/[^/]+\/[^/]+\/statuses\/([0-9a-f]{40})$/,
    );
    if (request.method === "POST" && postStatus) {
      let raw = "";
      request.on("data", (chunk) => {
        raw += chunk;
      });
      request.on("end", () => {
        const body = JSON.parse(raw);
        const sha = postStatus[1];
        const record = {
          id: nextStatusId,
          ...body,
          created_at: new Date(
            Date.UTC(2026, 7, 15, 12, 0, nextStatusId - 1_000),
          ).toISOString(),
          creator: { login: "github-actions[bot]", type: "Bot" },
        };
        nextStatusId += 1;
        if (!statuses.has(sha)) statuses.set(sha, []);
        statuses.get(sha).push(record);
        response.writeHead(201, { "Content-Type": "application/json" });
        response.end(JSON.stringify(record));
      });
      return;
    }

    const getStatuses = url.pathname.match(
      /^\/repos\/[^/]+\/[^/]+\/commits\/([0-9a-f]{40})\/statuses$/,
    );
    if (request.method === "GET" && getStatuses) {
      const sha = getStatuses[1];
      const pageNumber = Number(url.searchParams.get("page") || "1");
      const pages = statusPages?.get(sha) ?? [statuses.get(sha) ?? []];
      const page = pages[pageNumber - 1] ?? [];
      const headers = { "Content-Type": "application/json" };
      if (pageNumber < pages.length) {
        if (malformedPagination) {
          headers.Link = `not-a-url; rel="next"`;
        } else {
          headers.Link = `<http://127.0.0.1:${server.address().port}/repos/${REPO}/commits/${sha}/statuses?per_page=100&page=${pageNumber + 1}>; rel="next"`;
        }
      }
      response.writeHead(200, headers);
      response.end(JSON.stringify(page));
      return;
    }

    const getRun = url.pathname.match(
      /^\/repos\/[^/]+\/[^/]+\/actions\/runs\/([1-9][0-9]*)$/,
    );
    if (request.method === "GET" && getRun) {
      const run = runs.get(Number(getRun[1]));
      response.writeHead(run ? 200 : 404, {
        "Content-Type": "application/json",
      });
      response.end(JSON.stringify(run ?? { message: "Not Found" }));
      return;
    }

    response.writeHead(404, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ message: "Not Found" }));
  });

  return { server, statuses, requests };
}

async function startApi(options) {
  const api = createMockApi(options);
  await new Promise((resolve) => api.server.listen(0, "127.0.0.1", resolve));
  return {
    ...api,
    baseUrl: `http://127.0.0.1:${api.server.address().port}`,
  };
}

async function closeApi(api) {
  await new Promise((resolve) => api.server.close(resolve));
}

async function runAttestation(mode, args, env = {}) {
  try {
    const { stdout, stderr } = await execFileAsync(
      "node",
      [GATE, mode, ...args],
      {
        env: {
          ...process.env,
          GITHUB_TOKEN: "test-token",
          GITHUB_REPOSITORY: REPO,
          GITHUB_SERVER_URL: SERVER_URL,
          ...env,
        },
        timeout: 10_000,
      },
    );
    return { exitCode: 0, stdout, stderr };
  } catch (error) {
    return {
      exitCode: error.code ?? 1,
      stdout: error.stdout?.toString() ?? "",
      stderr: error.stderr?.toString() ?? "",
    };
  }
}

async function verifyAgainst(options, sha = SHA_A, tag = TAG) {
  const api = await startApi(options);
  const result = await runAttestation(
    "verify",
    [`--sha=${sha}`, `--tag=${tag}`, `--control-sha=${SHA_B}`],
    { GITHUB_API_URL: api.baseUrl },
  );
  await closeApi(api);
  return { result, api };
}

console.log("Functional self-test: release-dry-run-attestation.mjs\n");

{
  const api = await startApi();
  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, `--plane=${PROD}`],
    {
      GITHUB_API_URL: api.baseUrl,
      GITHUB_RUN_ID: String(RUN_PROD),
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: SHA_B,
    },
  );
  const stored = api.statuses.get(SHA_A) ?? [];
  assert("publish succeeds", result.exitCode === 0);
  assert("publish creates one status", stored.length === 1);
  assert(
    "publish binds target_url to the exact same-repo Actions run",
    stored[0]?.target_url === runUrl(RUN_PROD),
  );
  assert(
    "publish binds the exact plane/tag context",
    stored[0]?.context === `release-attestation/${PROD}/${TAG}`,
  );
  await closeApi(api);
}

{
  const { result } = await verifyAgainst({
    statuses: validStatuses(),
    runs: validRuns(),
  });
  assert(
    "verify accepts exact-workflow runs from newer main for the tagged candidate",
    result.exitCode === 0,
  );
}

{
  const olderSuccess = statusFor(PROD, RUN_PROD, {
    id: 10,
    state: "success",
    createdAt: "2026-08-15T10:00:00Z",
  });
  const newerFailure = statusFor(PROD, 303, {
    id: 11,
    state: "failure",
    createdAt: "2026-08-15T11:00:00Z",
  });
  const pages = new Map([
    [
      SHA_A,
      [
        [
          olderSuccess,
          statusFor(CLOUD, RUN_CLOUD, {
            createdAt: "2026-08-15T10:30:00Z",
          }),
        ],
        [newerFailure],
      ],
    ],
  ]);
  const { result, api } = await verifyAgainst({
    statusPages: pages,
    runs: validRuns(),
  });
  assert(
    "newer failure overrides an older success across status pages",
    result.exitCode !== 0,
  );
  assert(
    "verify fetched the second raw-status page",
    api.requests.some(({ search }) => search.includes("page=2")),
  );
}

{
  const statuses = validStatuses();
  statuses.get(SHA_A)[0].creator = { login: "release-admin", type: "User" };
  const { result } = await verifyAgainst({ statuses, runs: validRuns() });
  assert("verify rejects an unrelated status writer", result.exitCode !== 0);
}

{
  const statuses = validStatuses();
  statuses.get(SHA_A)[0].target_url = null;
  const { result } = await verifyAgainst({ statuses, runs: validRuns() });
  assert("verify rejects a null target_url", result.exitCode !== 0);
}

{
  const statuses = validStatuses();
  statuses.get(SHA_A)[0].target_url =
    "https://github.com/foreign/repo/actions/runs/101";
  const { result } = await verifyAgainst({ statuses, runs: validRuns() });
  assert("verify rejects a foreign target_url", result.exitCode !== 0);
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { headBranch: "release-fix" }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert(
    "verify rejects a run outside the main control ref",
    result.exitCode !== 0,
  );
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { headSha: "c".repeat(40) }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert("verify rejects the wrong trusted control SHA", result.exitCode !== 0);
}

{
  const runs = validRuns();
  runs.set(
    RUN_PROD,
    runFor(PROD, RUN_PROD, {
      displayTitle: `release-control/${PROD}/dry-run/${TAG}/${SHA_A}/${"c".repeat(40)}`,
    }),
  );
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert(
    "verify rejects a receipt for the wrong trusted control SHA",
    result.exitCode !== 0,
  );
}

{
  const runs = validRuns();
  runs.set(
    RUN_PROD,
    runFor(PROD, RUN_PROD, {
      displayTitle: `release-control/${PROD}/dry-run/v9.9.9/${SHA_A}/${SHA_B}`,
    }),
  );
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert(
    "verify rejects a successful same-path run for v9.9.9",
    result.exitCode !== 0,
  );
}

{
  const runs = validRuns();
  runs.set(
    RUN_PROD,
    runFor(PROD, RUN_PROD, {
      displayTitle: `release-control/${PROD}/dry-run/${TAG}/${"c".repeat(40)}/${SHA_B}`,
    }),
  );
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert(
    "verify rejects a successful same-path run for the wrong candidate SHA",
    result.exitCode !== 0,
  );
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { repository: "foreign/repo" }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert(
    "verify rejects a run from the wrong repository",
    result.exitCode !== 0,
  );
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { id: 999 }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert("verify rejects a mismatched run ID", result.exitCode !== 0);
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { htmlUrl: runUrl(RUN_CLOUD) }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert("verify rejects a mismatched run URL", result.exitCode !== 0);
}

{
  const runs = validRuns();
  runs.set(
    RUN_PROD,
    runFor(PROD, RUN_PROD, {
      path: ".github/workflows/deploy-cloud-run.yml",
    }),
  );
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert("verify rejects the wrong workflow path", result.exitCode !== 0);
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { event: "push" }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert("verify rejects a non-workflow_dispatch run", result.exitCode !== 0);
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { status: "in_progress" }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert("verify rejects an incomplete run", result.exitCode !== 0);
}

{
  const runs = validRuns();
  runs.set(RUN_PROD, runFor(PROD, RUN_PROD, { conclusion: "failure" }));
  const { result } = await verifyAgainst({ statuses: validStatuses(), runs });
  assert("verify rejects a failed run", result.exitCode !== 0);
}

{
  const pages = new Map([
    [SHA_A, [[validStatuses().get(SHA_A)[0]], [validStatuses().get(SHA_A)[1]]]],
  ]);
  const { result } = await verifyAgainst({
    statusPages: pages,
    runs: validRuns(),
    malformedPagination: true,
  });
  assert("verify fails closed on malformed pagination", result.exitCode !== 0);
}

{
  const { result } = await verifyAgainst({
    statuses: new Map([[SHA_A, [validStatuses().get(SHA_A)[0]]]]),
    runs: validRuns(),
  });
  assert("verify rejects a missing plane", result.exitCode !== 0);
}

{
  const api = await startApi({ runs: validRuns() });
  const env = { GITHUB_API_URL: api.baseUrl };
  const production = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, `--plane=${PROD}`],
    {
      ...env,
      GITHUB_RUN_ID: String(RUN_PROD),
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: SHA_B,
    },
  );
  const cloud = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, `--plane=${CLOUD}`],
    {
      ...env,
      GITHUB_RUN_ID: String(RUN_CLOUD),
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: SHA_B,
    },
  );
  const verify = await runAttestation(
    "verify",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, `--control-sha=${SHA_B}`],
    env,
  );
  assert(
    "round-trip publishes the production attestation",
    production.exitCode === 0,
  );
  assert("round-trip publishes the cloud attestation", cloud.exitCode === 0);
  assert("round-trip verifies both exact Actions runs", verify.exitCode === 0);
  await closeApi(api);
}

{
  const result = await runAttestation(
    "publish",
    [`--sha=abc123`, `--tag=${TAG}`, `--plane=${PROD}`],
    {
      GITHUB_RUN_ID: String(RUN_PROD),
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: SHA_B,
    },
  );
  assert("publish rejects a short SHA", result.exitCode !== 0);
}

{
  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, "--plane=invalid"],
    {
      GITHUB_RUN_ID: String(RUN_PROD),
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: SHA_B,
    },
  );
  assert("publish rejects an invalid plane", result.exitCode !== 0);
}

{
  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, "--tag=v1.2.3-rc.1", `--plane=${PROD}`],
    {
      GITHUB_RUN_ID: String(RUN_PROD),
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: SHA_B,
    },
  );
  assert("publish rejects a prerelease tag", result.exitCode !== 0);
}

{
  const api = await startApi();
  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, `--plane=${PROD}`],
    {
      GITHUB_API_URL: api.baseUrl,
      GITHUB_RUN_ID: "not-a-run",
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: SHA_B,
    },
  );
  assert("publish rejects a malformed GITHUB_RUN_ID", result.exitCode !== 0);
  await closeApi(api);
}

{
  const api = await startApi();
  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, `--plane=${PROD}`],
    {
      GITHUB_API_URL: api.baseUrl,
      GITHUB_RUN_ID: String(RUN_PROD),
      GITHUB_REF: "refs/tags/v1.2.3",
      GITHUB_REF_NAME: "v1.2.3",
      GITHUB_SHA: SHA_B,
    },
  );
  assert("publish rejects a tag-selected dry-run", result.exitCode !== 0);
  await closeApi(api);
}

{
  const api = await startApi();
  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG}`, `--plane=${PROD}`],
    {
      GITHUB_API_URL: api.baseUrl,
      GITHUB_RUN_ID: String(RUN_PROD),
      GITHUB_REF: "refs/heads/main",
      GITHUB_REF_NAME: "main",
      GITHUB_SHA: "not-a-sha",
    },
  );
  assert(
    "publish rejects a malformed trusted control SHA",
    result.exitCode !== 0,
  );
  await closeApi(api);
}

if (failed > 0) {
  console.error(`\nFAIL: ${failed} attestation self-test assertion(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} attestation self-test assertion(s) passed.`);
