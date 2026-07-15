#!/usr/bin/env node
/**
 * Release dry-run attestation helper.
 *
 * Two modes:
 *
 *   publish  — After a successful dry-run, create a GitHub commit status on
 *              the exact candidate SHA. The context encodes both the deploy
 *              plane and the future tag so a tag-push deploy can verify the
 *              same SHA+tag was attested by both planes.
 *
 *   verify   — Before a real deploy (tag push or manual non-dry-run) reaches
 *              credentials, require that BOTH deploy-production and
 *              deploy-cloud-run dry-run attestations exist as `success`
 *              statuses on the exact tag SHA for the exact tag. Missing,
 *              stale, or wrong-tag attestations fail closed.
 *
 * Usage:
 *   node scripts/ci/release-dry-run-attestation.mjs publish \
 *     --sha <40-char-sha> --tag <v*> --plane <deploy-production|deploy-cloud-run>
 *
 *   node scripts/ci/release-dry-run-attestation.mjs verify \
 *     --sha <40-char-sha> --tag <v*>
 *
 * Environment:
 *   GITHUB_TOKEN  — GitHub token with `repo:status` scope (statuses: write).
 *                   For `publish` in dry-run jobs this is the default
 *                   GITHUB_TOKEN; for `verify` in deploy jobs the job must
 *                   carry `statuses: write` permission.
 *   GITHUB_REPOSITORY — owner/repo (auto-set by Actions).
 *   GITHUB_API_URL    — API base (auto-set, defaults to https://api.github.com).
 *
 * The status context is:
 *   release-attestation/<plane>/<tag>
 * e.g. release-attestation/deploy-production/v1.2.3
 *
 * The description encodes the attesting SHA so operators can verify visually.
 */



const API_BASE = process.env.GITHUB_API_URL || "https://api.github.com";
const REPO = process.env.GITHUB_REPOSITORY;
const TOKEN = process.env.GITHUB_TOKEN;

function parseArgs(argv) {
  const mode = argv[0];
  if (!mode || (mode !== "publish" && mode !== "verify")) {
    console.error("Usage: release-dry-run-attestation.mjs <publish|verify> --sha <sha> --tag <tag> [--plane <plane>]");
    process.exit(2);
  }

  const args = {};
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    const eqMatch = arg.match(/^--([^=]+)=(.*)$/s);
    if (eqMatch) {
      args[eqMatch[1]] = eqMatch[2];
    } else if (arg.startsWith("--")) {
      const key = arg.replace(/^--/, "");
      args[key] = argv[i + 1];
      i += 1;
    }
  }

  if (!args.sha || !/^[0-9a-f]{40}$/.test(args.sha)) {
    console.error(`::error::--sha must be a full 40-char hex SHA, got: ${args.sha ?? "(missing)"}`);
    process.exit(2);
  }
  if (!args.tag || !/^v[0-9]/.test(args.tag)) {
    console.error(`::error::--tag must be a SemVer v* tag, got: ${args.tag ?? "(missing)"}`);
    process.exit(2);
  }
  if (mode === "publish") {
    if (!args.plane || !/^deploy-(production|cloud-run)$/.test(args.plane)) {
      console.error(`::error::--plane must be deploy-production or deploy-cloud-run, got: ${args.plane ?? "(missing)"}`);
      process.exit(2);
    }
  }

  return { mode, ...args };
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

  const res = await fetch(url, options);
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // non-JSON response
  }
  return { status: res.status, data: json, raw: text };
}
async function publish({ sha, tag, plane }) {
  if (!TOKEN) {
    console.error("::error::GITHUB_TOKEN is required for publish mode");
    process.exit(1);
  }
  if (!REPO) {
    console.error("::error::GITHUB_REPOSITORY is required");
    process.exit(1);
  }

  const context = `release-attestation/${plane}/${tag}`;
  const description = `dry-run passed at ${sha.slice(0, 12)}`;

  const res = await apiRequest("POST", `/statuses/${sha}`, {
    state: "success",
    context,
    description,
    target_url: null,
  });

  if (res.status < 200 || res.status >= 300) {
    console.error(`::error::GitHub API returned ${res.status} creating status for ${sha}`);
    if (res.raw) console.error(res.raw);
    process.exit(1);
  }

  console.log(`::notice::Published attestation: ${context} → success on ${sha.slice(0, 12)}`);
}

async function verify({ sha, tag }) {
  if (!TOKEN) {
    console.error("::error::GITHUB_TOKEN is required for verify mode");
    process.exit(1);
  }
  if (!REPO) {
    console.error("::error::GITHUB_REPOSITORY is required");
    process.exit(1);
  }

  const requiredPlanes = ["deploy-production", "deploy-cloud-run"];
  const errors = [];

  for (const plane of requiredPlanes) {
    const context = `release-attestation/${plane}/${tag}`;
    const res = await apiRequest("GET", `/commits/${sha}/statuses?per_page=100`);

    if (res.status < 200 || res.status >= 300) {
      errors.push(`GitHub API returned ${res.status} fetching statuses for ${sha.slice(0, 12)}`);
      continue;
    }

    const statuses = Array.isArray(res.data) ? res.data : [];
    const matching = statuses.find((s) => s.context === context && s.state === "success");

    if (!matching) {
      errors.push(
        `Missing dry-run attestation for ${plane}/${tag} on ${sha.slice(0, 12)}. ` +
        `Expected a 'success' status with context '${context}'. ` +
        `Run both dry-runs first: dispatch deploy-production.yml and deploy-cloud-run.yml ` +
        `with dry_run=true, candidate_sha=${sha}, tag=${tag}.`,
      );
    } else {
      console.log(`::notice::Verified attestation: ${context} → ${matching.state}`);
    }
  }

  if (errors.length > 0) {
    for (const error of errors) {
      console.error(`::error::${error}`);
    }
    process.exit(1);
  }

  console.log(`::notice::Both dry-run attestations verified for ${tag} at ${sha.slice(0, 12)}`);
}

const args = parseArgs(process.argv.slice(2));

if (args.mode === "publish") {
  await publish(args);
} else {
  await verify(args);
}