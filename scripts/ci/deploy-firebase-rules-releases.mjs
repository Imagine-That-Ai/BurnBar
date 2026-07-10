#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { fileURLToPath } from "node:url";

import { rulesSourceForDeploy } from "./firebase-rules-source.mjs";

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

export function isRetryableFirebaseRulesApiError(error) {
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

function accessToken() {
  if (process.env.GOOGLE_OAUTH_ACCESS_TOKEN)
    return process.env.GOOGLE_OAUTH_ACCESS_TOKEN;
  const args = ["auth", "print-access-token"];
  if (process.env.GOOGLE_IMPERSONATE_SERVICE_ACCOUNT) {
    args.push(
      "--impersonate-service-account",
      process.env.GOOGLE_IMPERSONATE_SERVICE_ACCOUNT,
    );
  }
  return execFileSync("gcloud", args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
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

async function releasePathsForStorage(token) {
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

export function rulesetFileContentHash(ruleset, fileName) {
  const files = ruleset?.source?.files;
  if (!Array.isArray(files)) return null;
  const file = files.find((candidate) => candidate?.name === fileName);
  if (typeof file?.content !== "string") return null;
  return sha256(file.content.trimEnd());
}

export async function releasesNeedingRulesetDeploy({
  releaseNames,
  desiredContentHash,
  fileName,
  fetchResource,
}) {
  const staleReleaseNames = [];
  const rulesetHashCache = new Map();
  let unchangedReleaseCount = 0;

  for (const releaseName of releaseNames) {
    let release;
    try {
      release = await fetchResource(releaseName);
    } catch (error) {
      if (error?.status !== 404) throw error;
      staleReleaseNames.push(releaseName);
      continue;
    }

    const rulesetName = release?.rulesetName;
    if (typeof rulesetName !== "string" || rulesetName.length === 0) {
      staleReleaseNames.push(releaseName);
      continue;
    }

    if (!rulesetHashCache.has(rulesetName)) {
      try {
        const ruleset = await fetchResource(rulesetName);
        rulesetHashCache.set(
          rulesetName,
          rulesetFileContentHash(ruleset, fileName),
        );
      } catch (error) {
        if (error?.status !== 404) throw error;
        rulesetHashCache.set(rulesetName, null);
      }
    }

    if (rulesetHashCache.get(rulesetName) === desiredContentHash) {
      unchangedReleaseCount += 1;
    } else {
      staleReleaseNames.push(releaseName);
    }
  }

  return { staleReleaseNames, unchangedReleaseCount };
}

function isRulesetPropagationError(error) {
  return (
    error?.status === 400 &&
    /INVALID_ARGUMENT|invalid argument/i.test(error?.message || "")
  );
}

async function patchExistingRelease(token, releaseName, update) {
  const delaysMs = [0, 2_000, 5_000, 10_000, 20_000];
  for (let attempt = 0; attempt < delaysMs.length; attempt += 1) {
    if (delaysMs[attempt] > 0) await sleep(delaysMs[attempt]);
    try {
      return await firebaseRulesJson(releaseName, token, {
        ...buildReleasePatchRequest(update.name, update.rulesetName),
      });
    } catch (error) {
      if (
        !isRulesetPropagationError(error) ||
        attempt === delaysMs.length - 1
      ) {
        throw error;
      }
      const nextDelayMs = delaysMs[attempt + 1];
      console.warn(
        `firebase rules release ${releaseName} rejected newly-created ruleset; retrying in ${nextDelayMs}ms`,
      );
    }
  }
  throw new Error(`unreachable Firebase Rules release retry state: ${releaseName}`);
}

async function patchRelease(token, releaseName, rulesetName) {
  const update = {
    name: releaseName,
    rulesetName,
  };
  let release;
  try {
    release = await patchExistingRelease(token, releaseName, update);
  } catch (error) {
    if (error?.status !== 404) throw error;
    release = await firebaseRulesJson(`projects/${project}/releases`, token, {
      ...buildReleaseCreateRequest(releaseName, rulesetName),
    });
  }
  if (release.rulesetName !== rulesetName) {
    throw new Error(
      `Firebase Rules release ${releaseName} points at ${release.rulesetName || "<missing>"} instead of ${rulesetName}`,
    );
  }
}

function requireFirebaseResourceName(fieldName, value, expectedSegment) {
  if (typeof value !== "string" || value.trim() !== value || value.length === 0) {
    throw new TypeError(`${fieldName} must be a non-empty trimmed string`);
  }
  if (!value.startsWith("projects/") || !value.includes(expectedSegment)) {
    throw new TypeError(
      `${fieldName} must be a Firebase resource name containing ${expectedSegment}`,
    );
  }
  return value;
}

export function buildReleaseUpdate(releaseName, rulesetName) {
  return {
    name: requireFirebaseResourceName("releaseName", releaseName, "/releases/"),
    rulesetName: requireFirebaseResourceName(
      "rulesetName",
      rulesetName,
      "/rulesets/",
    ),
  };
}

export function buildReleasePatchRequest(releaseName, rulesetName) {
  const update = buildReleaseUpdate(releaseName, rulesetName);
  return {
    method: "PATCH",
    // Firebase Rules PATCH updates only rulesetName. The nested release payload
    // keeps the release name immutable while the field mask prevents accidental
    // expansion if the REST shape grows new writable fields.
    body: JSON.stringify({
      release: update,
      updateMask: "rulesetName",
    }),
  };
}

export function buildReleaseCreateRequest(releaseName, rulesetName) {
  return {
    method: "POST",
    body: JSON.stringify(buildReleaseUpdate(releaseName, rulesetName)),
  };
}

async function verifyRelease(token, releaseName, rulesetName) {
  const release = await firebaseRulesJson(releaseName, token);
  if (release.rulesetName !== rulesetName) {
    throw new Error(
      `Firebase Rules release verification failed for ${releaseName}: ${release.rulesetName || "<missing>"} != ${rulesetName}`,
    );
  }
}

async function deployRulesFile(token, fileName, releaseNames) {
  const source = readFileSync(resolve(repoRoot, fileName), "utf8");
  const content = rulesSourceForDeploy(fileName, source);
  const contentHash = sha256(content.trimEnd());
  const { staleReleaseNames, unchangedReleaseCount } =
    await releasesNeedingRulesetDeploy({
      releaseNames,
      desiredContentHash: contentHash,
      fileName,
      fetchResource: (path) => firebaseRulesJson(path, token),
    });

  if (staleReleaseNames.length === 0) {
    console.log(
      `firebase rules release unchanged project=${project} file=${fileName} releases=${releaseNames.length} rules=${contentHash}`,
    );
    return;
  }

  const { rulesetName } = await createRuleset(token, fileName, content);
  for (const releaseName of staleReleaseNames) {
    await patchRelease(token, releaseName, rulesetName);
    await verifyRelease(token, releaseName, rulesetName);
  }
  console.log(
    `firebase rules release deployed project=${project} file=${fileName} releases=${releaseNames.length} updated=${staleReleaseNames.length} unchanged=${unchangedReleaseCount} ruleset=${rulesetName} rules=${contentHash}`,
  );
}

async function main() {
  const token = accessToken();
  await deployRulesFile(token, "firestore.rules", [
    `projects/${project}/releases/cloud.firestore`,
  ]);

  const storageReleaseNames = await releasePathsForStorage(token);
  if (storageReleaseNames.length === 0) {
    throw new Error(
      `no firebase.storage releases found for ${project}; expected at least one Storage bucket release`,
    );
  }
  await deployRulesFile(token, "storage.rules", storageReleaseNames);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
