#!/usr/bin/env node
// Propagate storage.rules to every secondary Storage bucket release after the
// main `firebase deploy --only storage` step.
//
// Why this exists: `firebase deploy --only storage` deploys rules only to the
// default bucket (the one declared in firebase.json). The deleted
// deploy-firebase-rules-releases.mjs helper enumerated every firebase.storage/
// release and propagated storage.rules to each. check-firestore-deploy-drift.mjs
// still verifies every storage release, so without this step any secondary
// bucket would drift and fail the gate.
//
// This script reuses the Firebase Rules REST API but avoids the updateMask
// field that caused the 400 INVALID_ARGUMENT errors that killed the old helper
// (diligence 2026-07-12 LB-2).
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const project = process.env.FIREBASE_PROJECT || process.argv[2] || "burnbar";

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function accessToken() {
  if (process.env.GOOGLE_OAUTH_ACCESS_TOKEN)
    return process.env.GOOGLE_OAUTH_ACCESS_TOKEN;
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

function firebaseRulesErrorMessage(error) {
  const messages = [];
  let cursor = error;
  while (cursor) {
    if (typeof cursor.message === "string") messages.push(cursor.message);
    if (typeof cursor.code === "string") messages.push(cursor.code);
    cursor = cursor.cause;
  }
  return messages.join(" ");
}

function isRetryableFirebaseRulesApiError(error) {
  if (
    error?.status === 408 ||
    error?.status === 429 ||
    (typeof error?.status === "number" && error.status >= 500)
  ) {
    return true;
  }
  return /fetch failed|UND_ERR_CONNECT_TIMEOUT|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENOTFOUND/i.test(
    firebaseRulesErrorMessage(error),
  );
}

async function firebaseRulesJson(path, token, init = {}) {
  const method = init.method || "GET";
  const delaysMs = [0, 1_000, 3_000, 7_000, 15_000];
  for (let attempt = 0; attempt < delaysMs.length; attempt += 1) {
    if (delaysMs[attempt] > 0) await sleep(delaysMs[attempt]);
    try {
      const response = await fetch(
        `https://firebaserules.googleapis.com/v1/${path}`,
        {
          ...init,
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
            "X-Goog-User-Project":
              process.env.GOOGLE_CLOUD_QUOTA_PROJECT || project,
            ...init.headers,
          },
        },
      );
      const body = await response.text();
      if (!response.ok) {
        const error = new Error(
          `Firebase Rules API ${method} ${path} failed: ${response.status} ${body}`,
        );
        error.status = response.status;
        throw error;
      }
      return JSON.parse(body || "{}");
    } catch (error) {
      if (
        !isRetryableFirebaseRulesApiError(error) ||
        attempt === delaysMs.length - 1
      ) {
        throw error;
      }
      const nextDelayMs = delaysMs[attempt + 1];
      console.warn(
        `Firebase Rules API ${method} ${path} failed transiently; retrying in ${nextDelayMs}ms`,
      );
    }
  }
  throw new Error(`unreachable Firebase Rules API retry state: ${method} ${path}`);
}

async function storageReleasePaths(token) {
  const releaseNames = [];
  let pageToken = "";
  do {
    const query = pageToken ? `?pageToken=${encodeURIComponent(pageToken)}` : "";
    const listing = await firebaseRulesJson(
      `projects/${project}/releases${query}`,
      token,
    );
    const releases = Array.isArray(listing.releases) ? listing.releases : [];
    releaseNames.push(...releases.map((release) => release?.name));
    pageToken =
      typeof listing.nextPageToken === "string" ? listing.nextPageToken : "";
  } while (pageToken);

  return releaseNames
    .filter(
      (name) =>
        typeof name === "string" && name.includes("/releases/firebase.storage/"),
    )
    .sort();
}

function rulesetFileContentHash(ruleset, fileName) {
  const files = ruleset?.source?.files;
  if (!Array.isArray(files)) return null;
  const file = files.find((candidate) => candidate?.name === fileName);
  if (typeof file?.content !== "string") return null;
  return sha256(file.content.trimEnd());
}

async function createRuleset(token, fileName, content) {
  const ruleset = await firebaseRulesJson(`projects/${project}/rulesets`, token, {
    method: "POST",
    body: JSON.stringify({
      source: {
        files: [
          {
            name: fileName,
            content,
          },
        ],
      },
    }),
  });
  if (typeof ruleset.name !== "string") {
    throw new Error(
      `Firebase Rules API create ruleset response omitted name for ${fileName}`,
    );
  }
  return { rulesetName: ruleset.name };
}

// PATCH the release WITHOUT updateMask — supplying updateMask causes the
// backend to reject an otherwise valid release update with INVALID_ARGUMENT
// (diligence 2026-07-12 LB-2). Match firebase-tools' production request shape.
function buildReleasePatchRequest(releaseName, rulesetName) {
  return {
    method: "PATCH",
    body: JSON.stringify({
      release: {
        name: releaseName,
        rulesetName,
      },
    }),
  };
}

async function patchRelease(token, releaseName, rulesetName) {
  let release;
  try {
    release = await firebaseRulesJson(
      releaseName,
      token,
      buildReleasePatchRequest(releaseName, rulesetName),
    );
  } catch (error) {
    if (error?.status !== 404) throw error;
    release = await firebaseRulesJson(`projects/${project}/releases`, token, {
      method: "POST",
      body: JSON.stringify({
        name: releaseName,
        rulesetName,
      }),
    });
  }
  if (release.rulesetName !== rulesetName) {
    throw new Error(
      `Firebase Rules release ${releaseName} points at ${release.rulesetName || "<missing>"} instead of ${rulesetName}`,
    );
  }
}

const token = accessToken();
const storageSource = readFileSync(resolve(repoRoot, "storage.rules"), "utf8");
const storageHash = sha256(storageSource.trimEnd());

const allStorageReleases = await storageReleasePaths(token);
if (allStorageReleases.length === 0) {
  throw new Error(
    `no firebase.storage releases found for ${project}; expected at least the default bucket`,
  );
}

// Identify releases whose deployed ruleset content differs from storage.rules.
// The default bucket was already deployed by `firebase deploy --only storage`,
// so it will match and be skipped.
const staleReleases = [];
let unchangedCount = 0;

for (const releaseName of allStorageReleases) {
  let release;
  try {
    release = await firebaseRulesJson(releaseName, token);
  } catch (error) {
    if (error?.status !== 404) throw error;
    staleReleases.push(releaseName);
    continue;
  }

  const rulesetName = release?.rulesetName;
  if (typeof rulesetName !== "string" || rulesetName.length === 0) {
    staleReleases.push(releaseName);
    continue;
  }

  let ruleset;
  try {
    ruleset = await firebaseRulesJson(rulesetName, token);
  } catch (error) {
    if (error?.status !== 404) throw error;
    staleReleases.push(releaseName);
    continue;
  }

  const remoteHash = rulesetFileContentHash(ruleset, "storage.rules");
  if (remoteHash === storageHash) {
    unchangedCount += 1;
  } else {
    staleReleases.push(releaseName);
  }
}

if (staleReleases.length === 0) {
  console.log(
    `storage rules secondary buckets already up-to-date project=${project} releases=${allStorageReleases.length} rules=${storageHash}`,
  );
} else {
  const { rulesetName } = await createRuleset(token, "storage.rules", storageSource);
  for (const releaseName of staleReleases) {
    await patchRelease(token, releaseName, rulesetName);
  }
  console.log(
    `storage rules propagated to secondary buckets project=${project} total=${allStorageReleases.length} updated=${staleReleases.length} unchanged=${unchangedCount} ruleset=${rulesetName} rules=${storageHash}`,
  );
}
