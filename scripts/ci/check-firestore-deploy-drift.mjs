#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { rulesSourceForDeploy } from "./firebase-rules-source.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const project = process.env.FIREBASE_PROJECT || process.argv[2] || "burnbar";

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
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

async function firebaseRulesGet(path, token) {
  const delaysMs = [0, 1_000, 3_000, 7_000, 15_000];
  for (let attempt = 0; attempt < delaysMs.length; attempt += 1) {
    if (delaysMs[attempt] > 0) await sleep(delaysMs[attempt]);
    try {
      const response = await fetch(
        `https://firebaserules.googleapis.com/v1/${path}`,
        {
          headers: {
            Authorization: `Bearer ${token}`,
            "X-Goog-User-Project":
              process.env.GOOGLE_CLOUD_QUOTA_PROJECT || project,
          },
        },
      );
      if (!response.ok) {
        const error = new Error(
          `Firebase Rules API ${path} failed: ${response.status} ${await response.text()}`,
        );
        error.status = response.status;
        throw error;
      }
      return response.json();
    } catch (error) {
      if (
        !isRetryableFirebaseRulesApiError(error) ||
        attempt === delaysMs.length - 1
      ) {
        throw error;
      }
      const nextDelayMs = delaysMs[attempt + 1];
      console.warn(
        `Firebase Rules API GET ${path} failed transiently; retrying in ${nextDelayMs}ms`,
      );
    }
  }
  throw new Error(`unreachable Firebase Rules API retry state: GET ${path}`);
}

async function deployedRulesForRelease(releasePath, fileName, token) {
  const release = await firebaseRulesGet(releasePath, token);
  if (typeof release.rulesetName !== "string") {
    throw new Error(`${releasePath} did not include rulesetName`);
  }
  const ruleset = await firebaseRulesGet(release.rulesetName, token);
  const files = Array.isArray(ruleset.source?.files)
    ? ruleset.source.files
    : [];
  const rulesFile = files.find(
    (file) =>
      file?.name === fileName || file?.name?.endsWith(`/${fileName}`),
  );
  if (typeof rulesFile?.content !== "string") {
    throw new Error(
      `ruleset ${release.rulesetName} did not include ${fileName} content`,
    );
  }
  return rulesFile.content;
}

async function storageReleasePaths(token) {
  const listing = await firebaseRulesGet(`projects/${project}/releases`, token);
  const releases = Array.isArray(listing.releases) ? listing.releases : [];
  return releases
    .map((release) => release?.name)
    .filter(
      (name) =>
        typeof name === "string" && name.includes("/releases/firebase.storage/"),
    );
}

function normalizedIndexSpec(raw) {
  const indexes = Array.isArray(raw.indexes) ? raw.indexes : [];
  const fieldOverrides = Array.isArray(raw.fieldOverrides)
    ? raw.fieldOverrides
    : [];
  const compact = (entry) =>
    Object.fromEntries(
      Object.entries(entry).filter(
        ([, value]) => value !== undefined && value !== null,
      ),
    );
  return {
    indexes: indexes
      .map((index) => ({
        collectionGroup: index.collectionGroup,
        queryScope: index.queryScope,
        fields: Array.isArray(index.fields)
          ? index.fields
              .filter((field) => field.fieldPath !== "__name__")
              .map((field) =>
                compact({
                  fieldPath: field.fieldPath,
                  order: field.order,
                  arrayConfig: field.arrayConfig,
                  vectorConfig: field.vectorConfig,
                }),
              )
          : [],
      }))
      .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
    fieldOverrides: fieldOverrides
      .map((override) =>
        compact({
          collectionGroup: override.collectionGroup,
          fieldPath: override.fieldPath,
          indexes: Array.isArray(override.indexes)
            ? override.indexes.map((index) =>
                compact({
                  order: index.order,
                  arrayConfig: index.arrayConfig,
                  queryScope: index.queryScope,
                }),
              )
            : [],
          ttl: override.ttl || undefined,
        }),
      )
      .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
  };
}

function deployedFirestoreIndexes() {
  const firebaseBin = process.env.FIREBASE_TOOLS_BIN;
  const command = firebaseBin && firebaseBin.trim() ? firebaseBin : "firebase";
  const output = execFileSync(
    command,
    [
      "--project",
      project,
      "--json",
      "firestore:indexes",
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    },
  );
  const parsed = JSON.parse(output);
  return parsed.result ?? parsed;
}

const token = accessToken();
const localRules = rulesSourceForDeploy(
  "firestore.rules",
  readFileSync(resolve(repoRoot, "firestore.rules"), "utf8"),
);
const remoteRules = await deployedRulesForRelease(
  `projects/${project}/releases/cloud.firestore`,
  "firestore.rules",
  token,
);
const localRulesHash = sha256(localRules.trimEnd());
const remoteRulesHash = sha256(remoteRules.trimEnd());
if (localRulesHash !== remoteRulesHash) {
  throw new Error(
    `Firestore rules drift: repo=${localRulesHash} deployed=${remoteRulesHash}. Deploy firestore.rules to ${project}.`,
  );
}

const localIndexes = normalizedIndexSpec(
  JSON.parse(readFileSync(resolve(repoRoot, "firestore.indexes.json"), "utf8")),
);
const remoteIndexes = normalizedIndexSpec(deployedFirestoreIndexes());
const localIndexesHash = sha256(JSON.stringify(localIndexes));
const remoteIndexesHash = sha256(JSON.stringify(remoteIndexes));
if (localIndexesHash !== remoteIndexesHash) {
  throw new Error(
    `Firestore indexes drift: repo=${localIndexesHash} deployed=${remoteIndexesHash}. Deploy firestore.indexes.json to ${project}.`,
  );
}

// Storage rules drift: the deploy workflow ships storage.rules, so the gate
// must watch it too (diligence 2026-06-11 LB-3 residual: the step summary
// claimed storage in scope while only firestore was hash-checked). One local
// file governs every bucket release.
const localStorageRules = readFileSync(resolve(repoRoot, "storage.rules"), "utf8");
const localStorageHash = sha256(localStorageRules.trimEnd());
const storageReleases = await storageReleasePaths(token);
if (storageReleases.length === 0) {
  throw new Error(
    `no firebase.storage releases found for ${project}; expected at least the default bucket`,
  );
}
for (const releasePath of storageReleases) {
  const remoteStorageRules = await deployedRulesForRelease(
    releasePath,
    "storage.rules",
    token,
  );
  const remoteStorageHash = sha256(remoteStorageRules.trimEnd());
  if (localStorageHash !== remoteStorageHash) {
    throw new Error(
      `Storage rules drift (${releasePath}): repo=${localStorageHash} deployed=${remoteStorageHash}. Deploy storage.rules to ${project}.`,
    );
  }
}

console.log(
  `firestore deploy drift ok project=${project} rules=${localRulesHash} indexes=${localIndexesHash} storage=${localStorageHash} storageReleases=${storageReleases.length}`,
);
