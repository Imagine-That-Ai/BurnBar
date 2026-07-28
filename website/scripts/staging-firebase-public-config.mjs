import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

export const STAGING_FIREBASE_PROJECT_ID = "burnbar-staging";
export const STAGING_FIREBASE_WEB_APP_ID = "1:1079930549647:web:85beff426331ab42e407fa";

const ENV_CONFIG_KEY = "STAGING_FIREBASE_PUBLIC_CONFIG_JSON";

export const PRODUCTION_FIREBASE_FRAGMENTS = Object.freeze([
  "burnbar.firebaseapp.com",
  "burnbar.appspot.com",
  "246956661961",
  "1:246956661961:web:2e267f5d3a84a525480118"
]);

function normalizedConfig(candidate, source) {
  assert.ok(candidate && typeof candidate === "object", `${source} must be a JSON object`);

  const config = {
    PUBLIC_FIREBASE_API_KEY: candidate.PUBLIC_FIREBASE_API_KEY ?? candidate.apiKey,
    PUBLIC_FIREBASE_AUTH_DOMAIN: candidate.PUBLIC_FIREBASE_AUTH_DOMAIN ?? candidate.authDomain,
    PUBLIC_FIREBASE_PROJECT_ID: candidate.PUBLIC_FIREBASE_PROJECT_ID ?? candidate.projectId,
    PUBLIC_FIREBASE_STORAGE_BUCKET:
      candidate.PUBLIC_FIREBASE_STORAGE_BUCKET ?? candidate.storageBucket,
    PUBLIC_FIREBASE_MESSAGING_SENDER_ID:
      candidate.PUBLIC_FIREBASE_MESSAGING_SENDER_ID ??
      candidate.messagingSenderId ??
      candidate.projectNumber,
    PUBLIC_FIREBASE_APP_ID: candidate.PUBLIC_FIREBASE_APP_ID ?? candidate.appId,
    PUBLIC_RECAPTCHA_ENTERPRISE_KEY:
      candidate.PUBLIC_RECAPTCHA_ENTERPRISE_KEY ?? candidate.recaptchaSiteKey
  };

  for (const [name, value] of Object.entries(config)) {
    assert.ok(typeof value === "string" && value.trim().length > 0, `${source} is missing ${name}`);
    config[name] = value.trim();
  }

  assert.equal(
    config.PUBLIC_FIREBASE_PROJECT_ID,
    STAGING_FIREBASE_PROJECT_ID,
    `${source} must target ${STAGING_FIREBASE_PROJECT_ID}`
  );
  assert.equal(
    config.PUBLIC_FIREBASE_APP_ID,
    STAGING_FIREBASE_WEB_APP_ID,
    `${source} must target the reviewed staging website app`
  );
  assert.match(
    config.PUBLIC_FIREBASE_MESSAGING_SENDER_ID,
    /^\d+$/u,
    `${source} has an invalid Firebase project number`
  );

  return Object.freeze(config);
}

export function loadStagingFirebasePublicConfig({
  env = process.env,
  execFile = execFileSync
} = {}) {
  const inline = env[ENV_CONFIG_KEY]?.trim();
  if (inline) {
    let parsed;
    try {
      parsed = JSON.parse(inline);
    } catch (error) {
      throw new Error(
        `${ENV_CONFIG_KEY} must contain valid JSON: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
    return normalizedConfig(parsed, ENV_CONFIG_KEY);
  }

  let output;
  try {
    output = execFile(
      "firebase",
      [
        "apps:sdkconfig",
        "WEB",
        STAGING_FIREBASE_WEB_APP_ID,
        "--project",
        STAGING_FIREBASE_PROJECT_ID
      ],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"]
      }
    );
  } catch (error) {
    throw new Error(
      `Unable to load staging Firebase public config. Set ${ENV_CONFIG_KEY} ` +
        "or authenticate the Firebase CLI for burnbar-staging.",
      { cause: error }
    );
  }

  let parsed;
  try {
    parsed = JSON.parse(String(output));
  } catch (error) {
    throw new Error(
      `Firebase CLI returned invalid SDK config JSON: ${
        error instanceof Error ? error.message : String(error)
      }`
    );
  }
  return normalizedConfig(parsed, "Firebase CLI SDK config");
}
