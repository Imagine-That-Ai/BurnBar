import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const verifier = path.join(scriptDir, "verify-android-firebase-release-config.mjs");

test("successful verification never logs Firebase configuration values", () => {
  const scratch = mkdtempSync(path.join(tmpdir(), "openburnbar-firebase-config-test-"));
  try {
    const configPath = path.join(scratch, "google-services.json");
    const apiKey = "AIzaSyOpenBurnBarRegressionSecret123456789";
    const appId = "1:246956661961:android:6ffe560abf1a583a480118";
    const packageName = "com.openburnbar";
    writeFileSync(
      configPath,
      JSON.stringify({
        project_info: {
          project_id: "burnbar",
          project_number: "246956661961",
        },
        client: [
          {
            client_info: {
              mobilesdk_app_id: appId,
              android_client_info: { package_name: packageName },
            },
            api_key: [{ current_key: apiKey }],
            oauth_client: [],
          },
        ],
      }),
      { mode: 0o600 },
    );

    const result = spawnSync(process.execPath, [verifier, "--config", configPath], {
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      result.stdout.trim(),
      "Firebase Android config verified: strictRelease=false",
    );
    assert.doesNotMatch(result.stdout, new RegExp(apiKey));
    assert.doesNotMatch(result.stdout, new RegExp(appId));
    assert.doesNotMatch(result.stdout, new RegExp(packageName));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
