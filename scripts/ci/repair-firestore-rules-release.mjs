#!/usr/bin/env node
/**
 * Repair the cloud.firestore release on HTTP 409 from firebaserules.googleapis.com.
 *
 * After PR #1572, `firebase deploy --only firestore` uploads the correct ruleset
 * but gets HTTP 409 "Requested entity already exists" when trying to create the
 * cloud.firestore release (the existing release still points at an old ruleset).
 * firebase-tools falls back from PATCH to POST and hits the 409.
 *
 * This script runs AFTER the deploy step fails. It:
 *   1. Lists rulesets to find the most recently created one (the one firebase-tools
 *      just uploaded, which has the repo-matching rules hash).
 *   2. Gets the current cloud.firestore release to find the old ruleset it points to.
 *   3. PATCHes the release to point to the new ruleset.
 *   4. Verifies the release now points to the new ruleset by re-reading it.
 *
 * Fail-closed: if the PATCH or verification fails, exit non-zero.
 * Idempotent: if the release already points to the matching ruleset, exit 0 (no-op).
 * Non-409 errors are NOT masked (the workflow only invokes this script when the
 * deploy failure output contains "409" and "Requested entity already exists").
 *
 * Auth mirrors check-firestore-deploy-drift.mjs (gcloud auth print-access-token).
 * Usage: node scripts/ci/repair-firestore-rules-release.mjs <project>
 */
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const RULES_API_BASE = "https://firebaserules.googleapis.com/v1";
const FIRESTORE_RELEASE = "cloud.firestore";

// ─── Pure helpers (exported for unit testing) ─────────────────────────────

/**
 * Detect whether a deploy failure output is a 409 "Requested entity already
 * exists" error on the rules release. This is the gate: the repair should only
 * proceed when this returns true.
 *
 * @param {string} text — deploy step stderr/stdout or error message
 * @returns {boolean}
 */
export function is409ReleaseError(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  return text.includes("409") && /Requested entity already exists/i.test(text);
}

// ─── Firebase Rules API helpers ───────────────────────────────────────────

/**
 * Perform a Firebase Rules API request, returning parsed JSON.
 * Throws an Error with `.status` on non-2xx responses.
 */
async function rulesApi(path, { method = "GET", body, token, project, fetchImpl }) {
  const url = `${RULES_API_BASE}/${path}`;
  const headers = {
    Authorization: `Bearer ${token}`,
    "X-Goog-User-Project": process.env.GOOGLE_CLOUD_QUOTA_PROJECT || project,
  };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
  }
  const response = await fetchImpl(url, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok) {
    const error = new Error(
      `Firebase Rules API ${method} ${path} failed: ${response.status} ${text}`,
    );
    error.status = response.status;
    error.body = text;
    throw error;
  }
  return text ? JSON.parse(text) : {};
}

/**
 * List rulesets and return the most recently created one. The Firebase Rules
 * API returns rulesets sorted by createTime descending, but we sort defensively.
 */
async function getLatestRuleset({ project, token, fetchImpl }) {
  const listing = await rulesApi(`projects/${project}/rulesets`, {
    token,
    project,
    fetchImpl,
  });
  const rulesets = Array.isArray(listing.rulesets) ? listing.rulesets : [];
  if (rulesets.length === 0) {
    throw new Error(`No rulesets found for project ${project}`);
  }
  const sorted = [...rulesets].sort((a, b) => {
    const aTime = a.createTime || "";
    const bTime = b.createTime || "";
    return bTime.localeCompare(aTime);
  });
  const latest = sorted[0];
  if (typeof latest.name !== "string") {
    throw new Error("Latest ruleset response did not include a name");
  }
  return latest;
}

/**
 * Get the current cloud.firestore release (returns { name, rulesetName, ... }).
 */
async function getFirestoreRelease({ project, token, fetchImpl }) {
  return rulesApi(`projects/${project}/releases/${FIRESTORE_RELEASE}`, {
    token,
    project,
    fetchImpl,
  });
}

/**
 * PATCH the cloud.firestore release to point to a new ruleset.
 * Matches firebase-tools' production PATCH shape (no updateMask).
 */
async function patchFirestoreRelease({ project, token, fetchImpl, rulesetName }) {
  const releaseName = `projects/${project}/releases/${FIRESTORE_RELEASE}`;
  return rulesApi(
    `projects/${project}/releases/${FIRESTORE_RELEASE}`,
    {
      method: "PATCH",
      body: {
        name: releaseName,
        rulesetName,
      },
      token,
      project,
      fetchImpl,
    },
  );
}

// ─── Core repair logic (exported for unit testing) ────────────────────────

/**
 * Repair the cloud.firestore release to point to the most recently uploaded
 * ruleset. Returns { repaired, oldRuleset, newRuleset }.
 *
 * @param {object} opts
 * @param {string} opts.project     — Firebase project ID
 * @param {string} opts.token       — gcloud access token
 * @param {function} opts.fetchImpl — fetch implementation (for testing)
 * @returns {Promise<{repaired: boolean, oldRuleset: string, newRuleset: string}>}
 */
export async function repairFirestoreRelease({ project, token, fetchImpl }) {
  const fetch = fetchImpl || globalThis.fetch;

  // 1. Find the most recently created ruleset (the one firebase-tools uploaded).
  const latestRuleset = await getLatestRuleset({ project, token, fetchImpl: fetch });
  const newRulesetName = latestRuleset.name;

  // 2. Get the current release to find the old ruleset.
  const release = await getFirestoreRelease({ project, token, fetchImpl: fetch });
  const currentRulesetName = release.rulesetName;

  // 3. Idempotent: if the release already points to the latest ruleset, no-op.
  if (currentRulesetName === newRulesetName) {
    return {
      repaired: false,
      oldRuleset: currentRulesetName,
      newRuleset: newRulesetName,
    };
  }

  // 4. PATCH the release to point to the new ruleset.
  await patchFirestoreRelease({
    project,
    token,
    fetchImpl: fetch,
    rulesetName: newRulesetName,
  });

  // 5. Verify the release now points to the new ruleset.
  const verified = await getFirestoreRelease({
    project,
    token,
    fetchImpl: fetch,
  });
  if (verified.rulesetName !== newRulesetName) {
    throw new Error(
      `Release verification failed: expected ${newRulesetName} but got ${verified.rulesetName || "<missing>"}`,
    );
  }

  return {
    repaired: true,
    oldRuleset: currentRulesetName,
    newRuleset: newRulesetName,
  };
}

// ─── CLI entry point ──────────────────────────────────────────────────────

function accessToken(project) {
  if (process.env.GOOGLE_OAUTH_ACCESS_TOKEN)
    return process.env.GOOGLE_OAUTH_ACCESS_TOKEN;
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

async function main() {
  const project = process.env.FIREBASE_PROJECT || process.argv[2];
  if (!project) {
    console.error("Usage: repair-firestore-rules-release.mjs <project>");
    process.exit(2);
  }

  const token = accessToken(project);
  const result = await repairFirestoreRelease({
    project,
    token,
    fetchImpl: globalThis.fetch,
  });

  if (result.repaired) {
    console.log(
      `repair-firestore-rules-release: PATCHed ${FIRESTORE_RELEASE} ` +
        `from ${result.oldRuleset} to ${result.newRuleset} project=${project}`,
    );
  } else {
    console.log(
      `repair-firestore-rules-release: ${FIRESTORE_RELEASE} already ` +
        `points at ${result.newRuleset} (no-op) project=${project}`,
    );
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(`repair-firestore-rules-release: ${err.message}`);
    process.exit(1);
  });
}
