#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "../..");
const args = process.argv.slice(2);

let configPath = path.join(repoRoot, "android/app/google-services.json");
let base64EnvName = "";
let markerPath = "";
let strictRelease = false;

for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === "--config") {
    configPath = path.resolve(args[++index] ?? "");
  } else if (arg === "--write-from-base64-env") {
    base64EnvName = args[++index] ?? "";
  } else if (arg === "--marker") {
    markerPath = path.resolve(args[++index] ?? "");
  } else if (arg === "--strict-release") {
    strictRelease = true;
  } else {
    fail(`Unknown argument: ${arg}`);
  }
}

const expected = {
  projectId: process.env.OPENBURNBAR_FIREBASE_PROJECT_ID || "burnbar",
  projectNumber: process.env.OPENBURNBAR_FIREBASE_PROJECT_NUMBER || "246956661961",
  appId:
    process.env.OPENBURNBAR_ANDROID_FIREBASE_APP_ID ||
    "1:246956661961:android:6ffe560abf1a583a480118",
  packageName: process.env.OPENBURNBAR_ANDROID_PACKAGE_NAME || "com.openburnbar",
};

let raw;
if (base64EnvName) {
  const encoded = process.env[base64EnvName];
  if (!encoded) {
    fail(`${base64EnvName} is required.`);
  }
  try {
    raw = Buffer.from(encoded, "base64").toString("utf8");
  } catch (error) {
    fail(`Unable to decode ${base64EnvName}: ${error.message}`);
  }
} else {
  try {
    raw = fs.readFileSync(configPath, "utf8");
  } catch (error) {
    fail(`Unable to read ${relative(configPath)}: ${error.message}`);
  }
}

let payload;
try {
  payload = JSON.parse(raw);
} catch (error) {
  fail(`google-services.json is invalid JSON: ${error.message}`);
}

const summary = validateConfig(payload, { expected, strictRelease });

if (base64EnvName) {
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, raw, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
  if (markerPath) {
    fs.writeFileSync(markerPath, "ci\n", { mode: 0o600 });
  }
}

console.log(
  [
    "Firebase Android config verified:",
    `project=${summary.projectId}`,
    `app=${summary.appId}`,
    `package=${summary.packageName}`,
    `apiKeys=${summary.apiKeyCount}`,
    `androidOauthCerts=${summary.androidOauthCertificateCount}`,
    `strictRelease=${strictRelease ? "true" : "false"}`,
  ].join(" ")
);

function validateConfig(payload, { expected, strictRelease }) {
  const projectInfo = objectAt(payload, "project_info");
  const clients = arrayAt(payload, "client");
  const client = clients.find((candidate) => {
    return (
      objectAt(objectAt(candidate, "client_info"), "android_client_info").package_name ===
      expected.packageName
    );
  });

  if (!client) {
    fail(`google-services.json does not contain an Android client for ${expected.packageName}.`);
  }

  const clientInfo = objectAt(client, "client_info");
  const androidInfo = objectAt(clientInfo, "android_client_info");
  const apiKeys = arrayAt(client, "api_key")
    .map((entry) => String(objectAt(entry).current_key ?? "").trim())
    .filter(Boolean);
  const androidOauthCertificates = arrayAt(client, "oauth_client")
    .filter((entry) => {
      const oauth = objectAt(entry);
      const oauthAndroidInfo = objectAt(oauth, "android_info");
      return String(oauth.client_type) === "1" && oauthAndroidInfo.package_name === expected.packageName;
    })
    .map((entry) => String(objectAt(objectAt(entry), "android_info").certificate_hash ?? "").trim())
    .filter((certificateHash) => certificateHash.length >= 40 && !isPlaceholder(certificateHash));

  const failures = [];
  requireEqual(failures, "project_id", projectInfo.project_id, expected.projectId);
  requireEqual(failures, "project_number", projectInfo.project_number, expected.projectNumber);
  requireEqual(failures, "mobilesdk_app_id", clientInfo.mobilesdk_app_id, expected.appId);
  requireEqual(failures, "package_name", androidInfo.package_name, expected.packageName);

  if (apiKeys.length === 0 || apiKeys.some(isPlaceholder)) {
    failures.push("api_key must be a real non-placeholder Firebase Android API key");
  }

  if (strictRelease) {
    if (!apiKeys.some((key) => /^[A-Za-z0-9_-]{30,}$/.test(key))) {
      failures.push("api_key must have the shape of a Firebase Android API key");
    }
    if (androidOauthCertificates.length === 0) {
      failures.push(
        `oauth_client must include at least one Android client certificate for ${expected.packageName}`
      );
    }
  }

  if (failures.length > 0) {
    fail(`Invalid Android Firebase config:\n${failures.map((item) => `- ${item}`).join("\n")}`);
  }

  return {
    projectId: String(projectInfo.project_id),
    appId: String(clientInfo.mobilesdk_app_id),
    packageName: String(androidInfo.package_name),
    apiKeyCount: apiKeys.length,
    androidOauthCertificateCount: androidOauthCertificates.length,
  };
}

function objectAt(value, key) {
  const target = key === undefined ? value : value?.[key];
  return target && typeof target === "object" && !Array.isArray(target) ? target : {};
}

function arrayAt(value, key) {
  const target = value?.[key];
  return Array.isArray(target) ? target : [];
}

function requireEqual(failures, label, actual, expectedValue) {
  if (String(actual ?? "") !== expectedValue) {
    failures.push(`${label} must be ${expectedValue}`);
  }
}

function isPlaceholder(value) {
  const normalized = String(value ?? "").trim();
  return (
    normalized.length === 0 ||
    ["YOUR_", "REPLACE_", "EXAMPLE_", "PLACEHOLDER"].some((prefix) => normalized.startsWith(prefix))
  );
}

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function relative(targetPath) {
  return path.relative(repoRoot, targetPath) || targetPath;
}
