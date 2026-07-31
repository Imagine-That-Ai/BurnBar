#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const verifier = join(scriptDir, "verify-android-firebase-release-config.mjs");
const fixtureRoot = mkdtempSync(
  join(tmpdir(), "openburnbar-android-firebase-config-"),
);
const configPath = join(fixtureRoot, "google-services.json");
const apiKey = "AIzaSyAndroidFirebaseReleaseConfigFixtureKey";
const certificateHash = "0123456789ABCDEF0123456789ABCDEF01234567";
const packageName = "com.openburnbar";

writeFileSync(
  configPath,
  `${JSON.stringify(
    {
      project_info: {
        project_number: "246956661961",
        project_id: "burnbar",
      },
      client: [
        {
          client_info: {
            mobilesdk_app_id: "1:246956661961:android:6ffe560abf1a583a480118",
            android_client_info: { package_name: packageName },
          },
          oauth_client: [
            {
              client_type: 1,
              android_info: {
                package_name: packageName,
                certificate_hash: certificateHash,
              },
            },
          ],
          api_key: [{ current_key: apiKey }],
        },
      ],
    },
    null,
    2,
  )}\n`,
  { mode: 0o600 },
);

try {
  const result = spawnSync(
    process.execPath,
    [verifier, "--config", configPath, "--strict-release"],
    { encoding: "utf8" },
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(
    result.stdout.trim(),
    "Firebase Android config verified: identity=matched credentials=present strictRelease=true",
  );
  for (const sensitiveValue of [apiKey, certificateHash, packageName]) {
    assert.doesNotMatch(result.stdout, new RegExp(sensitiveValue, "u"));
    assert.doesNotMatch(result.stderr, new RegExp(sensitiveValue, "u"));
  }
  console.log(
    "PASS: Android Firebase release config logging stays value-free.",
  );
} finally {
  rmSync(fixtureRoot, { recursive: true, force: true });
}
