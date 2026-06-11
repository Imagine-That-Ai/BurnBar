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
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

async function firebaseRulesGet(path, token) {
  const response = await fetch(
    `https://firebaserules.googleapis.com/v1/${path}`,
    {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-Goog-User-Project": process.env.GOOGLE_CLOUD_QUOTA_PROJECT || project,
      },
    },
  );
  if (!response.ok) {
    throw new Error(
      `Firebase Rules API ${path} failed: ${response.status} ${await response.text()}`,
    );
  }
  return response.json();
}

async function deployedFirestoreRules(token) {
  const release = await firebaseRulesGet(
    `projects/${project}/releases/cloud.firestore`,
    token,
  );
  if (typeof release.rulesetName !== "string") {
    throw new Error(
      `cloud.firestore release for ${project} did not include rulesetName`,
    );
  }
  const ruleset = await firebaseRulesGet(release.rulesetName, token);
  const files = Array.isArray(ruleset.source?.files)
    ? ruleset.source.files
    : [];
  const rulesFile = files.find(
    (file) =>
      file?.name === "firestore.rules" ||
      file?.name?.endsWith("/firestore.rules"),
  );
  if (typeof rulesFile?.content !== "string") {
    throw new Error(
      `ruleset ${release.rulesetName} did not include firestore.rules content`,
    );
  }
  return rulesFile.content;
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
  const output = execFileSync(
    "npx",
    [
      "--prefix",
      "functions",
      "firebase",
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
const localRules = readFileSync(resolve(repoRoot, "firestore.rules"), "utf8");
const remoteRules = await deployedFirestoreRules(token);
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

console.log(
  `firestore deploy drift ok project=${project} rules=${localRulesHash} indexes=${localIndexesHash}`,
);
