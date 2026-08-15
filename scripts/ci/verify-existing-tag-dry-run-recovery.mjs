#!/usr/bin/env node
/**
 * Fail-closed eligibility gate for recovering dry-run attestations after a
 * stable release tag already exists.
 *
 * Git binding stays in the calling workflow: it fetches the remote tag,
 * requires an annotated tag that peels to the exact candidate, verifies that
 * candidate is reachable from current origin/main, and binds the dispatch
 * workflow SHA to current main. This helper verifies the remote GitHub state
 * that git cannot prove:
 *
 *   - workflow_dispatch is running from main;
 *   - no GitHub Release exists for the tag;
 *   - no production GitHub Deployment exists for the exact tag + SHA pair; and
 *   - this plane's release-attestation status context is absent.
 *
 * It performs read-only API calls. Publishing the status remains the final
 * step of the normal dry-run workflow after all build/verifier work succeeds.
 */

const API_BASE = process.env.GITHUB_API_URL || "https://api.github.com";
const REPO = process.env.GITHUB_REPOSITORY;
const TOKEN = process.env.GITHUB_TOKEN;

function fail(message, exitCode = 1) {
  console.error(`::error::${message}`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const equals = arg.match(/^--([^=]+)=(.*)$/s);
    if (equals) {
      args[equals[1]] = equals[2];
      continue;
    }
    if (arg.startsWith("--")) {
      args[arg.slice(2)] = argv[index + 1];
      index += 1;
    }
  }

  if (!args.sha || !/^[0-9a-f]{40}$/.test(args.sha)) {
    fail(
      `--sha must be a full 40-char lowercase hex SHA, got: ${args.sha ?? "(missing)"}`,
      2,
    );
  }
  if (
    !args.tag ||
    !/^v[0-9]{1,3}\.[0-9]+\.[0-9]+(?:\+[0-9A-Za-z.-]+)?$/.test(args.tag)
  ) {
    fail(
      `--tag must be a stable SemVer v* tag without a prerelease suffix, got: ${args.tag ?? "(missing)"}`,
      2,
    );
  }
  if (!args.plane || !/^deploy-(?:production|cloud-run)$/.test(args.plane)) {
    fail(
      `--plane must be deploy-production or deploy-cloud-run, got: ${args.plane ?? "(missing)"}`,
      2,
    );
  }
  args.mode ??= "dry-run";
  if (args.mode !== "dry-run" && args.mode !== "real-retry") {
    fail(
      `--mode must be dry-run or real-retry, got: ${args.mode ?? "(missing)"}`,
      2,
    );
  }

  return args;
}

function requireRuntimeBoundary() {
  if (process.env.GITHUB_EVENT_NAME !== "workflow_dispatch") {
    fail("Existing-tag dry-run recovery requires workflow_dispatch.");
  }
  if (process.env.GITHUB_REF !== "refs/heads/main") {
    fail(
      `Existing-tag dry-run recovery must be dispatched from refs/heads/main, got: ${process.env.GITHUB_REF ?? "(missing)"}`,
    );
  }
  if (!TOKEN) {
    fail("GITHUB_TOKEN is required for existing-tag recovery verification.");
  }
  if (!REPO || !/^[^/]+\/[^/]+$/.test(REPO)) {
    fail(`GITHUB_REPOSITORY must be owner/repo, got: ${REPO ?? "(missing)"}`);
  }
}

async function apiRequest(path) {
  const response = await fetch(`${API_BASE}/repos/${REPO}${path}`, {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${TOKEN}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "existing-tag-dry-run-recovery",
    },
  });
  const raw = await response.text();
  let data = null;
  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {
    // The caller reports the HTTP failure without trusting an unparseable body.
  }
  return { response, data, raw };
}

async function getAllPages(path) {
  const records = [];
  let nextPath = path;

  while (nextPath) {
    const result = await apiRequest(nextPath);
    if (!result.response.ok) {
      fail(
        `GitHub API returned ${result.response.status} for ${nextPath}${result.raw ? `: ${result.raw}` : ""}`,
      );
    }
    if (!Array.isArray(result.data)) {
      fail(`GitHub API returned a non-array response for ${nextPath}.`);
    }
    records.push(...result.data);

    const link = result.response.headers.get("link") || "";
    const next = link
      .split(",")
      .map((part) => part.trim())
      .find((part) => /;\s*rel="next"$/.test(part));
    if (!next) {
      nextPath = "";
      continue;
    }
    const match = next.match(/^<([^>]+)>/);
    if (!match) {
      fail("GitHub API returned a malformed pagination Link header.");
    }
    const url = new URL(match[1]);
    const apiUrl = new URL(API_BASE);
    const apiPath = apiUrl.pathname.replace(/\/$/u, "");
    const repositoryPrefix = `${apiPath}/repos/${REPO}`;
    if (
      url.origin !== apiUrl.origin ||
      (url.pathname !== repositoryPrefix &&
        !url.pathname.startsWith(`${repositoryPrefix}/`))
    ) {
      fail("GitHub API pagination escaped the configured repository boundary.");
    }
    nextPath = `${url.pathname.slice(repositoryPrefix.length)}${url.search}`;
  }

  return records;
}

async function verifyNoRelease(tag) {
  const result = await apiRequest(`/releases/tags/${encodeURIComponent(tag)}`);
  if (result.response.status === 404) return;
  if (result.response.ok) {
    fail(
      `GitHub Release ${tag} already exists; existing-tag dry-run recovery is no longer eligible.`,
    );
  }
  fail(
    `GitHub API returned ${result.response.status} checking release ${tag}${result.raw ? `: ${result.raw}` : ""}`,
  );
}

async function verifyNoDeployment(tag, sha) {
  const query = new URLSearchParams({
    ref: tag,
    sha,
    environment: "production",
    per_page: "100",
  });
  const deployments = await getAllPages(`/deployments?${query}`);
  if (deployments.length > 0) {
    fail(
      `Found ${deployments.length} production GitHub deployment(s) for ${tag} at ${sha}; recovery refuses an already-deployed tag/SHA pair.`,
    );
  }
}

async function verifyStatusAbsent(tag, sha, plane) {
  const statuses = await getAllPages(
    `/commits/${sha}/statuses?${new URLSearchParams({ per_page: "100" })}`,
  );
  const context = `release-attestation/${plane}/${tag}`;
  if (statuses.some((status) => status?.context === context)) {
    fail(
      `Commit status context ${context} already exists on ${sha}; recovery is one-shot per plane and will not overwrite prior evidence.`,
    );
  }
}

const args = parseArgs(process.argv.slice(2));
requireRuntimeBoundary();
await verifyNoRelease(args.tag);
if (args.mode === "dry-run") {
  await verifyNoDeployment(args.tag, args.sha);
  await verifyStatusAbsent(args.tag, args.sha, args.plane);
}

console.log(
  `::notice::Existing-tag ${args.mode} eligible for ${args.plane}/${args.tag} at ${args.sha.slice(0, 12)}.`,
);
