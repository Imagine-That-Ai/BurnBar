#!/usr/bin/env node

import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "verify-existing-tag-dry-run-recovery.mjs");
const SHA = "a".repeat(40);
const TAG = "v1.2.3";
const PLANE = "deploy-production";

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

function legacyStatus(overrides = {}) {
  return {
    id: 101,
    context: `release-attestation/${PLANE}/${TAG}`,
    state: "success",
    description: `dry-run passed at ${SHA.slice(0, 12)}`,
    target_url: null,
    created_at: "2026-08-15T15:00:00Z",
    creator: { login: "github-actions[bot]", type: "Bot" },
    ...overrides,
  };
}

async function startApi({
  releaseStatus = 404,
  deployments = [],
  statuses = [],
  paginatedStatuses = null,
} = {}) {
  const requests = [];
  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    requests.push({
      method: request.method,
      pathname: url.pathname,
      search: url.searchParams,
    });

    if (request.method !== "GET") {
      response.writeHead(405);
      response.end("{}");
      return;
    }

    if (url.pathname.endsWith(`/releases/tags/${TAG}`)) {
      response.writeHead(releaseStatus, { "Content-Type": "application/json" });
      response.end(
        JSON.stringify(
          releaseStatus === 404 ? { message: "Not Found" } : { tag_name: TAG },
        ),
      );
      return;
    }

    if (url.pathname.endsWith("/deployments")) {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify(deployments));
      return;
    }

    if (url.pathname.endsWith(`/commits/${SHA}/statuses`)) {
      const page = url.searchParams.get("page") || "1";
      const pageStatuses =
        paginatedStatuses === null
          ? statuses
          : paginatedStatuses[Number(page) - 1] || [];
      const headers = { "Content-Type": "application/json" };
      if (
        paginatedStatuses !== null &&
        Number(page) < paginatedStatuses.length
      ) {
        const port = server.address().port;
        headers.Link = `<http://127.0.0.1:${port}/repos/test/repo/commits/${SHA}/statuses?per_page=100&page=${Number(page) + 1}>; rel="next"`;
      }
      response.writeHead(200, headers);
      response.end(JSON.stringify(pageStatuses));
      return;
    }

    response.writeHead(404, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ message: "Not Found" }));
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    apiBase: `http://127.0.0.1:${server.address().port}`,
    requests,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

async function runGate(apiBase, overrides = {}, args = []) {
  try {
    const { stdout, stderr } = await execFileAsync(
      "node",
      [GATE, `--sha=${SHA}`, `--tag=${TAG}`, `--plane=${PLANE}`, ...args],
      {
        env: {
          ...process.env,
          GITHUB_API_URL: apiBase,
          GITHUB_TOKEN: "test-token",
          GITHUB_REPOSITORY: "test/repo",
          GITHUB_EVENT_NAME: "workflow_dispatch",
          GITHUB_REF: "refs/heads/main",
          GITHUB_SHA: SHA,
          ...overrides,
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

console.log("Self-test: existing stable-tag dry-run recovery gate\n");

{
  const api = await startApi();
  const result = await runGate(api.apiBase);
  assert("eligible untouched tag/SHA passes", result.exitCode === 0);
  assert(
    "deployment lookup binds ref, SHA, and production environment",
    api.requests.some(
      ({ pathname, search }) =>
        pathname.endsWith("/deployments") &&
        search.get("ref") === TAG &&
        search.get("sha") === SHA &&
        search.get("environment") === "production",
    ),
  );
  assert(
    "gate performs only read-only API requests",
    api.requests.every(({ method }) => method === "GET"),
  );
  await api.close();
}

{
  const api = await startApi({ releaseStatus: 200 });
  const result = await runGate(api.apiBase);
  assert("existing GitHub Release blocks recovery", result.exitCode !== 0);
  await api.close();
}

{
  const api = await startApi({
    deployments: [{ id: 1, ref: TAG, sha: SHA, environment: "production" }],
  });
  const result = await runGate(api.apiBase);
  assert(
    "existing production deployment for exact tag/SHA blocks",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi({
    statuses: [
      {
        context: `release-attestation/${PLANE}/${TAG}`,
        state: "success",
      },
    ],
  });
  const result = await runGate(api.apiBase, {}, ["--mode=real-retry"]);
  assert(
    "real retry allows existing attestations after publication absence check",
    result.exitCode === 0,
  );
  assert(
    "real retry does not reuse the dry-run status-absence check",
    !api.requests.some(({ pathname }) => pathname.endsWith("/statuses")),
  );
  await api.close();
}

{
  const api = await startApi({ releaseStatus: 200 });
  const result = await runGate(api.apiBase, {}, ["--mode=real-retry"]);
  assert(
    "real retry refuses an already-published GitHub Release",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi({
    deployments: [{ id: 1, ref: TAG, sha: SHA, environment: "production" }],
  });
  const result = await runGate(api.apiBase, {}, ["--mode=real-retry"]);
  assert(
    "real retry permits the other release plane to have deployed first",
    result.exitCode === 0,
  );
  await api.close();
}

{
  const api = await startApi({
    statuses: [
      {
        context: `release-attestation/${PLANE}/${TAG}`,
        state: "failure",
      },
    ],
  });
  const result = await runGate(api.apiBase);
  assert(
    "any existing exact attestation context blocks overwrite",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi({
    statuses: [
      legacyStatus({
        description: `dry-run ${SHA.slice(0, 12)} control ${"b".repeat(12)}`,
        target_url: "https://github.com/test/repo/actions/runs/202",
      }),
    ],
  });
  const result = await runGate(api.apiBase);
  assert(
    "current run-bound status remains one-shot and blocks overwrite",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi({ statuses: [legacyStatus()] });
  const result = await runGate(api.apiBase);
  assert(
    "one exact legacy null-target bot status is eligible for migration",
    result.exitCode === 0,
  );
  assert(
    "legacy migration gate remains read-only",
    api.requests.every(({ method }) => method === "GET"),
  );
  await api.close();
}

{
  const api = await startApi({
    statuses: [
      legacyStatus({
        creator: { login: "release-admin", type: "User" },
      }),
    ],
  });
  const result = await runGate(api.apiBase);
  assert(
    "legacy-shaped status from a non-Actions creator fails closed",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi({
    statuses: [legacyStatus(), legacyStatus({ id: 102 })],
  });
  const result = await runGate(api.apiBase);
  assert(
    "multiple legacy statuses fail closed instead of reopening migration",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi({
    statuses: [
      legacyStatus({
        description: "dry-run passed at the wrong candidate",
      }),
    ],
  });
  const result = await runGate(api.apiBase);
  assert(
    "legacy null-target status with the wrong candidate receipt fails closed",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi();
  const result = await runGate(api.apiBase, {}, ["--mode=unsafe"]);
  assert("unknown recovery mode fails closed", result.exitCode !== 0);
  await api.close();
}

{
  const api = await startApi({
    paginatedStatuses: [
      [{ context: "unrelated", state: "success" }],
      [{ context: `release-attestation/${PLANE}/${TAG}`, state: "success" }],
    ],
  });
  const result = await runGate(api.apiBase);
  assert(
    "status lookup follows pagination and blocks page-two evidence",
    result.exitCode !== 0,
  );
  await api.close();
}

{
  const api = await startApi();
  const result = await runGate(api.apiBase, {
    GITHUB_EVENT_NAME: "push",
  });
  assert("non-workflow_dispatch invocation fails", result.exitCode !== 0);
  await api.close();
}

{
  const api = await startApi();
  const result = await runGate(api.apiBase, {
    GITHUB_REF: "refs/heads/release-candidate",
  });
  assert("dispatch from a branch other than main fails", result.exitCode !== 0);
  await api.close();
}

{
  const api = await startApi();
  const result = await runGate(api.apiBase, {}, [`--tag=v1.2.3-rc.1`]);
  assert("prerelease tag fails stable-tag validation", result.exitCode !== 0);
  await api.close();
}

{
  const api = await startApi({ releaseStatus: 500 });
  const result = await runGate(api.apiBase);
  assert("ambiguous GitHub API failure fails closed", result.exitCode !== 0);
  await api.close();
}

if (failed > 0) {
  console.error(`\nFAIL: ${failed} recovery self-test assertion(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} recovery self-test assertion(s) passed.`);
