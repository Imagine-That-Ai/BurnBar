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
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { rulesSourceForDeploy } from "./firebase-rules-source.mjs";

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
 * List rulesets and return the most recently created one whose firestore.rules
 * source matches the content that the deploy just uploaded. The Firebase Rules
 * API returns rulesets sorted by createTime descending, but we sort defensively
 * and inspect each candidate so a newer storage or unrelated ruleset cannot be
 * accidentally released. The matching source files are carried along because
 * firebase-tools can upload firestore.rules with an absolute runner path, and
 * the release API rejects that path when the ruleset is attached.
 */
async function getLatestMatchingRuleset({
  project,
  token,
  fetchImpl,
  expectedRulesContent,
}) {
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
  const expected = expectedRulesContent.trimEnd();
  for (const candidate of sorted) {
    if (typeof candidate.name !== "string") continue;
    const ruleset = await rulesApi(candidate.name, {
      token,
      project,
      fetchImpl,
    });
    const files = Array.isArray(ruleset.source?.files)
      ? ruleset.source.files
      : [];
    // A Firestore release must be bound to the complete uploaded source set,
    // not merely one matching file inside an attacker-supplied multi-file
    // ruleset. firebase-tools uploads exactly one Firestore source file here.
    if (files.length !== 1) continue;
    const [rulesFile] = files;
    const canonicalRulesName =
      rulesFile?.name === "firestore.rules" ||
      rulesFile?.name?.endsWith("/firestore.rules");
    if (
      canonicalRulesName &&
      typeof rulesFile?.content === "string" &&
      rulesFile.content.trimEnd() === expected
    ) {
      return { ...candidate, sourceFiles: files };
    }
  }
  throw new Error(
    `No ruleset found for project ${project} matching the deployed firestore.rules source`,
  );
}

/**
 * Firebase CLI uploads can use an absolute runner path for firestore.rules.
 * Create an unattached copy with the canonical source filename before release
 * attachment. This keeps the live release PATCH pointed at a releasable
 * ruleset while preserving the exact uploaded source content.
 */
async function ensureReleaseCompatibleRuleset({
  project,
  token,
  fetchImpl,
  ruleset,
}) {
  const sourceFiles = Array.isArray(ruleset.sourceFiles) ? ruleset.sourceFiles : [];
  if (sourceFiles.length !== 1) {
    throw new Error("Refusing to release a Firestore ruleset that does not contain exactly one source file");
  }
  const needsNormalization = sourceFiles.some(
    (file) => typeof file?.name === "string" && file.name.endsWith("/firestore.rules"),
  );
  if (!needsNormalization) return ruleset.name;

  const files = sourceFiles.map((file) => ({
    name: file.name.endsWith("/firestore.rules") ? "firestore.rules" : file.name,
    content: file.content,
  }));
  const created = await rulesApi(`projects/${project}/rulesets`, {
    method: "POST",
    body: { source: { files } },
    token,
    project,
    fetchImpl,
  });
  if (typeof created.name !== "string") {
    throw new Error("Firebase Rules API returned no name for normalized firestore.rules ruleset");
  }
  return created.name;
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
 * Matches the Firebase Rules API PATCH contract: the Release resource is
 * nested under `release`, and rulesetName is selected by updateMask.
 */
async function patchFirestoreRelease({ project, token, fetchImpl, rulesetName }) {
  const releaseName = `projects/${project}/releases/${FIRESTORE_RELEASE}`;
  return rulesApi(
    `projects/${project}/releases/${FIRESTORE_RELEASE}`,
    {
      method: "PATCH",
      body: {
        release: {
          name: releaseName,
          rulesetName,
        },
        updateMask: "rulesetName",
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
 * @param {string} opts.expectedRulesContent — compacted firestore.rules source
 * @returns {Promise<{repaired: boolean, oldRuleset: string, newRuleset: string}>}
 */
export async function repairFirestoreRelease({
  project,
  token,
  fetchImpl,
  expectedRulesContent,
}) {
  const fetch = fetchImpl || globalThis.fetch;
  if (typeof expectedRulesContent !== "string") {
    throw new Error("expectedRulesContent is required to select the release ruleset");
  }

  // 1. Find the newest ruleset whose firestore.rules source matches the upload.
  const latestRuleset = await getLatestMatchingRuleset({
    project,
    token,
    fetchImpl: fetch,
    expectedRulesContent,
  });
  let newRulesetName = latestRuleset.name;

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

  // Firebase CLI may have uploaded an absolute source filename. Normalize it
  // before the release PATCH; the release API rejects that attached source.
  newRulesetName = await ensureReleaseCompatibleRuleset({
    project,
    token,
    fetchImpl: fetch,
    ruleset: latestRuleset,
  });

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
  const expectedRulesContent = rulesSourceForDeploy(
    "firestore.rules",
    readFileSync(resolve(repoRoot, "firestore.rules"), "utf8"),
  );
  const result = await repairFirestoreRelease({
    project,
    token,
    fetchImpl: globalThis.fetch,
    expectedRulesContent,
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
