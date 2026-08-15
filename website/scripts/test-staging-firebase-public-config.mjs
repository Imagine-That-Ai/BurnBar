#!/usr/bin/env node

import assert from "node:assert/strict";

import {
  STAGING_FIREBASE_PROJECT_ID,
  STAGING_FIREBASE_WEB_APP_ID,
  loadStagingFirebasePublicConfig
} from "./staging-firebase-public-config.mjs";

const sdkConfig = {
  projectId: STAGING_FIREBASE_PROJECT_ID,
  appId: STAGING_FIREBASE_WEB_APP_ID,
  storageBucket: "staging.example.invalid",
  apiKey: "public-browser-identifier",
  authDomain: "staging-auth.example.invalid",
  messagingSenderId: "1079930549647",
  recaptchaSiteKey: "public-app-check-identifier"
};

const fromVariable = loadStagingFirebasePublicConfig({
  env: {
    STAGING_FIREBASE_PUBLIC_CONFIG_JSON: JSON.stringify(sdkConfig)
  },
  execFile: () => {
    throw new Error("Firebase CLI must not run when the repository variable is present");
  }
});
assert.deepEqual(fromVariable, {
  PUBLIC_FIREBASE_API_KEY: sdkConfig.apiKey,
  PUBLIC_FIREBASE_AUTH_DOMAIN: sdkConfig.authDomain,
  PUBLIC_FIREBASE_PROJECT_ID: sdkConfig.projectId,
  PUBLIC_FIREBASE_STORAGE_BUCKET: sdkConfig.storageBucket,
  PUBLIC_FIREBASE_MESSAGING_SENDER_ID: sdkConfig.messagingSenderId,
  PUBLIC_FIREBASE_APP_ID: sdkConfig.appId,
  PUBLIC_RECAPTCHA_ENTERPRISE_KEY: sdkConfig.recaptchaSiteKey
});

let firebaseArgs;
const fromCli = loadStagingFirebasePublicConfig({
  env: {},
  execFile: (command, args) => {
    firebaseArgs = { command, args };
    return JSON.stringify(sdkConfig);
  }
});
assert.deepEqual(fromCli, fromVariable);
assert.deepEqual(firebaseArgs, {
  command: "firebase",
  args: [
    "apps:sdkconfig",
    "WEB",
    STAGING_FIREBASE_WEB_APP_ID,
    "--project",
    STAGING_FIREBASE_PROJECT_ID
  ]
});

assert.throws(
  () =>
    loadStagingFirebasePublicConfig({
      env: {
        STAGING_FIREBASE_PUBLIC_CONFIG_JSON: JSON.stringify({
          ...sdkConfig,
          projectId: "wrong-project"
        })
      }
    }),
  /must target burnbar-staging/u
);
assert.throws(
  () =>
    loadStagingFirebasePublicConfig({
      env: { STAGING_FIREBASE_PUBLIC_CONFIG_JSON: "not-json" }
    }),
  /must contain valid JSON/u
);

console.log(
  "✓ Staging Firebase public config loads from the repository variable or authenticated Firebase CLI."
);
