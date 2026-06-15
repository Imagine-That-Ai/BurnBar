#!/usr/bin/env node
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
  const response = await fetch(`https://firebaserules.googleapis.com/v1/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-Goog-User-Project": process.env.GOOGLE_CLOUD_QUOTA_PROJECT || project,
      ...init.headers,
    },
  });
  const body = await response.text();
  if (!response.ok) {
    const error = new Error(
      `Firebase Rules API ${init.method || "GET"} ${path} failed: ${response.status} ${body}`,
    );
    error.status = response.status;
    throw error;
  }
  return JSON.parse(body || "{}");
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
  const contentHash = sha256(content.trimEnd());
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
  return { contentHash, rulesetName: ruleset.name };
}

async function patchRelease(token, releaseName, rulesetName) {
  const update = {
    name: releaseName,
    rulesetName,
  };
  let release;
  try {
    release = await firebaseRulesJson(releaseName, token, {
      method: "PATCH",
      body: JSON.stringify({
        release: update,
        updateMask: "ruleset_name",
      }),
    });
  } catch (error) {
    if (error?.status !== 404) throw error;
    release = await firebaseRulesJson(`projects/${project}/releases`, token, {
      method: "POST",
      body: JSON.stringify(update),
    });
  }
  if (release.rulesetName !== rulesetName) {
    throw new Error(
      `Firebase Rules release ${releaseName} points at ${release.rulesetName || "<missing>"} instead of ${rulesetName}`,
    );
  }
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
  const content = readFileSync(resolve(repoRoot, fileName), "utf8");
  const { contentHash, rulesetName } = await createRuleset(
    token,
    fileName,
    content,
  );
  for (const releaseName of releaseNames) {
    await patchRelease(token, releaseName, rulesetName);
    await verifyRelease(token, releaseName, rulesetName);
  }
  console.log(
    `firebase rules release deployed project=${project} file=${fileName} releases=${releaseNames.length} ruleset=${rulesetName} rules=${contentHash}`,
  );
}

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
