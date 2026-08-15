#!/usr/bin/env node
/**
 * Publish and verify release dry-run attestations.
 *
 * A publish records a success commit status whose context binds the release
 * plane and tag, and whose target URL binds the status to this exact same-repo
 * GitHub Actions run.
 *
 * A verify reads every raw status page, selects the newest exact-context
 * record, requires that record to be a GitHub Actions bot success, and then
 * validates the referenced run through the official Actions API. The run must
 * belong to this repository, use the expected workflow, be a successful
 * workflow_dispatch, and match the status URL exactly. The status itself is
 * read from the exact candidate SHA; an existing-tag recovery run may execute
 * from a newer main commit than that immutable candidate.
 */

const API_BASE = process.env.GITHUB_API_URL || "https://api.github.com";
const SERVER_URL = process.env.GITHUB_SERVER_URL || "https://github.com";
const REPO = process.env.GITHUB_REPOSITORY;
const TOKEN = process.env.GITHUB_TOKEN;

const WORKFLOW_BY_PLANE = {
  "deploy-production": ".github/workflows/deploy-production.yml",
  "deploy-cloud-run": ".github/workflows/deploy-cloud-run.yml",
};

function fail(message, exitCode = 1) {
  console.error(`::error::${message}`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const mode = argv[0];
  if (mode !== "publish" && mode !== "verify") {
    fail(
      "Usage: release-dry-run-attestation.mjs <publish|verify> --sha <sha> --tag <tag> [--plane <plane>]",
      2,
    );
  }

  const args = {};
  for (let index = 1; index < argv.length; index += 1) {
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
      `--sha must be a full 40-char hex SHA, got: ${args.sha ?? "(missing)"}`,
      2,
    );
  }
  if (
    !args.tag ||
    !/^v[0-9]{1,3}\.[0-9]+\.[0-9]+(?:\+[0-9A-Za-z.-]+)?$/.test(args.tag)
  ) {
    fail(
      `--tag must be a stable SemVer v* tag, got: ${args.tag ?? "(missing)"}`,
      2,
    );
  }
  if (mode === "publish" && !WORKFLOW_BY_PLANE[args.plane]) {
    fail(
      `--plane must be deploy-production or deploy-cloud-run, got: ${args.plane ?? "(missing)"}`,
      2,
    );
  }
  if (
    mode === "verify" &&
    (!args["control-sha"] || !/^[0-9a-f]{40}$/.test(args["control-sha"]))
  ) {
    fail(
      `--control-sha must be the full trusted workflow SHA, got: ${args["control-sha"] ?? "(missing)"}`,
      2,
    );
  }

  return { mode, ...args };
}

function requireRuntime() {
  if (!TOKEN) fail("GITHUB_TOKEN is required.");
  if (!REPO || !/^[^/]+\/[^/]+$/.test(REPO)) {
    fail(`GITHUB_REPOSITORY must be owner/repo, got: ${REPO ?? "(missing)"}`);
  }
}

async function apiRequest(method, path, body) {
  const url = `${API_BASE}/repos/${REPO}${path}`;
  const headers = {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${TOKEN}`,
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "release-dry-run-attestation",
  };
  const options = { method, headers };
  if (body) {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  const response = await fetch(url, options);
  const raw = await response.text();
  let data = null;
  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {
    // Callers fail closed on an unexpected response shape.
  }
  return { response, data, raw };
}

function nextRepositoryPath(link) {
  const next = link
    .split(",")
    .map((part) => part.trim())
    .find((part) => /;\s*rel="next"$/.test(part));
  if (!next) return "";

  const match = next.match(/^<([^>]+)>/);
  if (!match) {
    throw new Error("GitHub API returned a malformed pagination Link header.");
  }

  const nextUrl = new URL(match[1]);
  const apiUrl = new URL(API_BASE);
  const apiPath = apiUrl.pathname.replace(/\/$/u, "");
  const repositoryPrefix = `${apiPath}/repos/${REPO}`;
  if (
    nextUrl.origin !== apiUrl.origin ||
    (nextUrl.pathname !== repositoryPrefix &&
      !nextUrl.pathname.startsWith(`${repositoryPrefix}/`))
  ) {
    throw new Error(
      "GitHub API pagination escaped the configured repository boundary.",
    );
  }

  return `${nextUrl.pathname.slice(repositoryPrefix.length)}${nextUrl.search}`;
}

async function getAllPages(path) {
  const records = [];
  const seenPaths = new Set();
  let nextPath = path;

  while (nextPath) {
    if (seenPaths.has(nextPath)) {
      throw new Error(`GitHub API pagination repeated ${nextPath}.`);
    }
    seenPaths.add(nextPath);

    const result = await apiRequest("GET", nextPath);
    if (!result.response.ok) {
      throw new Error(
        `GitHub API returned ${result.response.status} for ${nextPath}${result.raw ? `: ${result.raw}` : ""}`,
      );
    }
    if (!Array.isArray(result.data)) {
      throw new Error(
        `GitHub API returned a non-array response for ${nextPath}.`,
      );
    }
    records.push(...result.data);
    nextPath = nextRepositoryPath(result.response.headers.get("link") || "");
  }

  return records;
}

function actionsRunUrl(runId) {
  if (!/^[1-9][0-9]*$/.test(runId ?? "")) {
    fail(
      `GITHUB_RUN_ID must be a positive decimal run ID, got: ${runId ?? "(missing)"}`,
    );
  }
  if (!Number.isSafeInteger(Number(runId))) {
    fail(`GITHUB_RUN_ID is not a safe positive integer: ${runId}`);
  }

  const server = new URL(SERVER_URL);
  if (server.protocol !== "https:" || server.username || server.password) {
    fail(
      `GITHUB_SERVER_URL must be an authenticated-free HTTPS origin, got: ${SERVER_URL}`,
    );
  }
  server.pathname = `${server.pathname.replace(/\/$/u, "")}/${REPO}/actions/runs/${runId}`;
  server.search = "";
  server.hash = "";
  return server.href;
}

function receiptTitle({ plane, tag, sha, controlSha }) {
  return `release-control/${plane}/dry-run/${tag}/${sha}/${controlSha}`;
}

function parseRunId(targetUrl) {
  if (typeof targetUrl !== "string" || targetUrl.length === 0) {
    throw new Error("Attestation target_url is missing.");
  }

  let target;
  let server;
  try {
    target = new URL(targetUrl);
    server = new URL(SERVER_URL);
  } catch {
    throw new Error(`Attestation target_url is not a valid URL: ${targetUrl}`);
  }

  const serverPath = server.pathname.replace(/\/$/u, "");
  const runPathPrefix = `${serverPath}/${REPO}/actions/runs/`;
  const runIdText = target.pathname.startsWith(runPathPrefix)
    ? target.pathname.slice(runPathPrefix.length)
    : "";
  if (
    target.origin !== server.origin ||
    target.search ||
    target.hash ||
    !/^[1-9][0-9]*$/.test(runIdText)
  ) {
    throw new Error(
      `Attestation target_url must be an exact same-repository GitHub Actions run URL, got: ${targetUrl}`,
    );
  }

  const runId = Number(runIdText);
  if (!Number.isSafeInteger(runId)) {
    throw new Error(
      `Attestation run ID is not a safe positive integer: ${runIdText}`,
    );
  }
  return runId;
}

function statusTimestamp(status) {
  const timestamp = Date.parse(status?.created_at);
  if (!Number.isFinite(timestamp)) {
    throw new Error(
      `Exact-context status ${status?.id ?? "(missing id)"} has an invalid created_at timestamp.`,
    );
  }
  return timestamp;
}

function newestExactStatus(statuses, context) {
  const exact = statuses.filter((status) => status?.context === context);
  if (exact.length === 0) return null;
  for (const status of exact) statusTimestamp(status);

  return exact.reduce((newest, candidate) => {
    const candidateTime = statusTimestamp(candidate);
    const newestTime = statusTimestamp(newest);
    if (candidateTime !== newestTime) {
      return candidateTime > newestTime ? candidate : newest;
    }

    const candidateId = Number(candidate?.id);
    const newestId = Number(newest?.id);
    if (!Number.isSafeInteger(candidateId) || !Number.isSafeInteger(newestId)) {
      throw new Error(
        "Exact-context statuses with equal timestamps require safe integer IDs.",
      );
    }
    return candidateId > newestId ? candidate : newest;
  });
}

async function verifyRun({ runId, targetUrl, plane, tag, sha, controlSha }) {
  const result = await apiRequest("GET", `/actions/runs/${runId}`);
  if (!result.response.ok) {
    throw new Error(
      `GitHub API returned ${result.response.status} fetching Actions run ${runId}${result.raw ? `: ${result.raw}` : ""}`,
    );
  }

  const run = result.data;
  const workflowPath = WORKFLOW_BY_PLANE[plane];
  const checks = [
    [
      Number.isSafeInteger(run?.id) && run.id === runId,
      `run id ${run?.id ?? "(missing)"} != ${runId}`,
    ],
    [
      run?.html_url === targetUrl,
      "run html_url does not match status target_url",
    ],
    [
      run?.repository?.full_name === REPO,
      `run repository is ${run?.repository?.full_name ?? "(missing)"}`,
    ],
    [
      run?.head_branch === "main",
      `run head_branch is ${run?.head_branch ?? "(missing)"}, expected main`,
    ],
    [
      run?.head_sha === controlSha,
      `run head_sha is ${run?.head_sha ?? "(missing)"}, expected trusted control ${controlSha}`,
    ],
    [
      run?.display_title === receiptTitle({ plane, tag, sha, controlSha }),
      `run display_title does not bind the exact plane/tag/candidate/control receipt`,
    ],
    [
      run?.path === workflowPath,
      `run workflow path is ${run?.path ?? "(missing)"}, expected ${workflowPath}`,
    ],
    [
      run?.event === "workflow_dispatch",
      `run event is ${run?.event ?? "(missing)"}, expected workflow_dispatch`,
    ],
    [
      run?.status === "completed",
      `run status is ${run?.status ?? "(missing)"}, expected completed`,
    ],
    [
      run?.conclusion === "success",
      `run conclusion is ${run?.conclusion ?? "(missing)"}, expected success`,
    ],
  ];
  const failures = checks
    .filter(([passed]) => !passed)
    .map(([, message]) => message);
  if (failures.length > 0) {
    throw new Error(
      `Actions run ${runId} is not a valid ${plane} dry-run: ${failures.join("; ")}.`,
    );
  }
}

async function publish({ sha, tag, plane }) {
  requireRuntime();

  const controlSha = process.env.GITHUB_SHA;
  if (!controlSha || !/^[0-9a-f]{40}$/.test(controlSha)) {
    fail(
      `GITHUB_SHA must be the full trusted workflow SHA, got: ${controlSha ?? "(missing)"}`,
    );
  }
  if (
    process.env.GITHUB_REF !== "refs/heads/main" ||
    process.env.GITHUB_REF_NAME !== "main"
  ) {
    fail(
      `Dry-run attestation publication must execute from main, got ${process.env.GITHUB_REF ?? "(missing ref)"}/${process.env.GITHUB_REF_NAME ?? "(missing ref name)"}.`,
    );
  }

  const context = `release-attestation/${plane}/${tag}`;
  const description = `dry-run ${sha.slice(0, 12)} control ${controlSha.slice(0, 12)}`;
  const targetUrl = actionsRunUrl(process.env.GITHUB_RUN_ID);
  const result = await apiRequest("POST", `/statuses/${sha}`, {
    state: "success",
    context,
    description,
    target_url: targetUrl,
  });

  if (!result.response.ok) {
    fail(
      `GitHub API returned ${result.response.status} creating status for ${sha}${result.raw ? `: ${result.raw}` : ""}`,
    );
  }

  console.log(
    `::notice::Published attestation: ${context} → success on ${sha.slice(0, 12)} (${targetUrl})`,
  );
}

async function verify({ sha, tag, "control-sha": controlSha }) {
  requireRuntime();

  let statuses;
  try {
    statuses = await getAllPages(`/commits/${sha}/statuses?per_page=100`);
  } catch (error) {
    fail(error.message);
  }

  const errors = [];
  for (const plane of Object.keys(WORKFLOW_BY_PLANE)) {
    const context = `release-attestation/${plane}/${tag}`;
    try {
      const status = newestExactStatus(statuses, context);
      if (!status) {
        throw new Error(`Missing exact status context ${context}.`);
      }
      if (status.state !== "success") {
        throw new Error(
          `Newest exact status ${context} is ${status.state ?? "(missing state)"}, not success.`,
        );
      }
      if (
        status.creator?.login !== "github-actions[bot]" ||
        status.creator?.type !== "Bot"
      ) {
        throw new Error(
          `Newest exact status ${context} was created by ${status.creator?.login ?? "(missing creator)"}/${status.creator?.type ?? "(missing type)"}, not github-actions[bot]/Bot.`,
        );
      }

      const runId = parseRunId(status.target_url);
      await verifyRun({
        runId,
        targetUrl: status.target_url,
        plane,
        tag,
        sha,
        controlSha,
      });
      console.log(
        `::notice::Verified attestation: ${context} → ${status.state} via Actions run ${runId}`,
      );
    } catch (error) {
      errors.push(`${plane}/${tag}: ${error.message}`);
    }
  }

  if (errors.length > 0) {
    for (const error of errors) console.error(`::error::${error}`);
    process.exit(1);
  }

  console.log(
    `::notice::Both dry-run attestations verified for ${tag} at ${sha.slice(0, 12)}`,
  );
}

const args = parseArgs(process.argv.slice(2));
if (args.mode === "publish") {
  await publish(args);
} else {
  await verify(args);
}
