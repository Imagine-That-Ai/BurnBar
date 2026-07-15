#!/usr/bin/env node
/**
 * Functional self-test for the release dry-run attestation helper.
 *
 * Starts a local HTTP server that mocks the GitHub statuses API, then exercises
 * publish and verify modes to prove:
 *   - publish creates a success status with the correct context
 *   - verify succeeds when both planes have attested the same SHA+tag
 *   - verify fails when one plane's attestation is missing
 *   - verify fails when attestation is for a different tag
 *   - verify fails when attestation is for a different SHA
 *   - verify fails when no attestations exist (un-attested tag deploy denied)
 */

import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "release-dry-run-attestation.mjs");

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

/**
 * Mock GitHub API server. Stores statuses keyed by SHA.
 */
function createMockApi(initialStatuses = new Map()) {
  const statuses = initialStatuses;

  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    const path = url.pathname;

    const postMatch = path.match(/^\/repos\/[^/]+\/[^/]+\/statuses\/([0-9a-f]{40})$/);
    if (req.method === "POST" && postMatch) {
      const sha = postMatch[1];
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        const data = JSON.parse(body);
        if (!statuses.has(sha)) statuses.set(sha, []);
        statuses.get(sha).push({
          state: data.state,
          context: data.context,
          description: data.description,
        });
        res.writeHead(201, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ id: Date.now(), ...data }));
      });
      return;
    }

    const getMatch = path.match(/^\/repos\/[^/]+\/[^/]+\/commits\/([0-9a-f]{40})\/statuses$/);
    if (req.method === "GET" && getMatch) {
      const sha = getMatch[1];
      const list = statuses.get(sha) || [];
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(list));
      return;
    }

    res.writeHead(404);
    res.end("{}");
  });

  return server;
}

async function startServer(statuses) {
  const server = createMockApi(statuses);
  await new Promise((resolve) => server.listen(0, resolve));
  return server;
}

async function runAttestation(mode, args, env) {
  try {
    const { stdout } = await execFileAsync(
      "node",
      [GATE, mode, ...args],
      {
        env: { ...process.env, ...env },
        timeout: 10000,
      },
    );
    return { exitCode: 0, stdout };
  } catch (error) {
    return {
      exitCode: error.code ?? 1,
      stdout: error.stdout?.toString() ?? "",
      stderr: error.stderr?.toString() ?? "",
    };
  }
}

console.log("Functional self-test: release-dry-run-attestation.mjs\n");

const SHA_A = "a".repeat(40);
const SHA_B = "b".repeat(40);
const TAG_V1 = "v1.2.3";
const TAG_V2 = "v2.0.0";
const PLANE_PROD = "deploy-production";
const PLANE_CLOUD = "deploy-cloud-run";

/* ── Test 1: publish creates success status ── */
{
  const statuses = new Map();
  const server = await startServer(statuses);
  const port = server.address().port;
  const apiBase = `http://localhost:${port}`;

  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG_V1}`, `--plane=${PLANE_PROD}`],
    { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase },
  );

  assert("publish exits 0 on success", result.exitCode === 0);

  const stored = statuses.get(SHA_A) || [];
  assert("publish creates a status entry", stored.length === 1);
  if (stored.length === 1) {
    assert("  state is success", stored[0].state === "success");
    assert("  context encodes plane+tag", stored[0].context === `release-attestation/${PLANE_PROD}/${TAG_V1}`);
  }

  server.close();
}

/* ── Test 2: verify succeeds when both planes attested same SHA+tag ── */
{
  const statuses = new Map();
  statuses.set(SHA_A, [
    { state: "success", context: `release-attestation/${PLANE_PROD}/${TAG_V1}`, description: "ok" },
    { state: "success", context: `release-attestation/${PLANE_CLOUD}/${TAG_V1}`, description: "ok" },
  ]);
  const server = await startServer(statuses);
  const apiBase = `http://localhost:${server.address().port}`;

  const result = await runAttestation(
    "verify",
    [`--sha=${SHA_A}`, `--tag=${TAG_V1}`],
    { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase },
  );

  assert("verify succeeds when both planes attested", result.exitCode === 0);
  server.close();
}

/* ── Test 3: verify fails when one plane missing ── */
{
  const statuses = new Map();
  statuses.set(SHA_A, [
    { state: "success", context: `release-attestation/${PLANE_PROD}/${TAG_V1}`, description: "ok" },
  ]);
  const server = await startServer(statuses);
  const apiBase = `http://localhost:${server.address().port}`;

  const result = await runAttestation(
    "verify",
    [`--sha=${SHA_A}`, `--tag=${TAG_V1}`],
    { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase },
  );

  assert("verify fails when one plane's attestation is missing", result.exitCode !== 0);
  server.close();
}

/* ── Test 4: verify fails when attestation is for a different tag ── */
{
  const statuses = new Map();
  statuses.set(SHA_A, [
    { state: "success", context: `release-attestation/${PLANE_PROD}/${TAG_V2}`, description: "ok" },
    { state: "success", context: `release-attestation/${PLANE_CLOUD}/${TAG_V2}`, description: "ok" },
  ]);
  const server = await startServer(statuses);
  const apiBase = `http://localhost:${server.address().port}`;

  const result = await runAttestation(
    "verify",
    [`--sha=${SHA_A}`, `--tag=${TAG_V1}`],
    { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase },
  );

  assert("verify fails when attestation is for a different tag", result.exitCode !== 0);
  server.close();
}

/* ── Test 5: verify fails when attestation is for a different SHA ── */
{
  const statuses = new Map();
  statuses.set(SHA_A, [
    { state: "success", context: `release-attestation/${PLANE_PROD}/${TAG_V1}`, description: "ok" },
    { state: "success", context: `release-attestation/${PLANE_CLOUD}/${TAG_V1}`, description: "ok" },
  ]);
  const server = await startServer(statuses);
  const apiBase = `http://localhost:${server.address().port}`;

  const result = await runAttestation(
    "verify",
    [`--sha=${SHA_B}`, `--tag=${TAG_V1}`],
    { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase },
  );

  assert("verify fails when attestation is for a different SHA", result.exitCode !== 0);
  server.close();
}

/* ── Test 6: verify fails when no attestations exist ── */
{
  const statuses = new Map();
  const server = await startServer(statuses);
  const apiBase = `http://localhost:${server.address().port}`;

  const result = await runAttestation(
    "verify",
    [`--sha=${SHA_A}`, `--tag=${TAG_V1}`],
    { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase },
  );

  assert("verify fails when no attestations exist (un-attested tag deploy denied)", result.exitCode !== 0);
  server.close();
}

/* ── Test 7: verify fails when attestation state is not success ── */
{
  const statuses = new Map();
  statuses.set(SHA_A, [
    { state: "failure", context: `release-attestation/${PLANE_PROD}/${TAG_V1}`, description: "failed" },
    { state: "success", context: `release-attestation/${PLANE_CLOUD}/${TAG_V1}`, description: "ok" },
  ]);
  const server = await startServer(statuses);
  const apiBase = `http://localhost:${server.address().port}`;

  const result = await runAttestation(
    "verify",
    [`--sha=${SHA_A}`, `--tag=${TAG_V1}`],
    { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase },
  );

  assert("verify fails when one attestation state is not success", result.exitCode !== 0);
  server.close();
}

/* ── Test 8: publish then verify full round-trip ── */
{
  const statuses = new Map();
  const server = await startServer(statuses);
  const apiBase = `http://localhost:${server.address().port}`;
  const env = { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "test/repo", GITHUB_API_URL: apiBase };

  const pub1 = await runAttestation("publish", [`--sha=${SHA_A}`, `--tag=${TAG_V1}`, `--plane=${PLANE_PROD}`], env);
  assert("round-trip: publish production succeeds", pub1.exitCode === 0);

  const pub2 = await runAttestation("publish", [`--sha=${SHA_A}`, `--tag=${TAG_V1}`, `--plane=${PLANE_CLOUD}`], env);
  assert("round-trip: publish cloud-run succeeds", pub2.exitCode === 0);

  const verifyResult = await runAttestation("verify", [`--sha=${SHA_A}`, `--tag=${TAG_V1}`], env);
  assert("round-trip: verify succeeds after both publishes", verifyResult.exitCode === 0);

  server.close();
}

/* ── Test 9: invalid SHA rejected ── */
{
  const result = await runAttestation(
    "publish",
    [`--sha=abc123`, `--tag=${TAG_V1}`, `--plane=${PLANE_PROD}`],
    { GITHUB_TOKEN: "test", GITHUB_REPOSITORY: "test/repo" },
  );
  assert("publish rejects short SHA", result.exitCode !== 0);
}

/* ── Test 10: invalid plane rejected ── */
{
  const result = await runAttestation(
    "publish",
    [`--sha=${SHA_A}`, `--tag=${TAG_V1}`, `--plane=invalid-plane`],
    { GITHUB_TOKEN: "test", GITHUB_REPOSITORY: "test/repo" },
  );
  assert("publish rejects invalid plane", result.exitCode !== 0);
}

if (failed > 0) {
  console.error(`\nFAIL: ${failed} attestation self-test case(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} attestation self-test case(s) passed.`);