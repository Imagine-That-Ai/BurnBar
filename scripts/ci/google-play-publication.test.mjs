#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { join } from "node:path";

import {
  ANDROID_RELEASE_POLICY,
  buildPublicationManifest,
  parseAndroidReleasePolicy,
  validatePublicationRequest,
} from "./google-play-publication.mjs";

const root = join(import.meta.dirname, "..", "..");
const workflow = readFileSync(
  join(root, ".github", "workflows", "publish-google-play.yml"),
  "utf8",
);
const androidCiWorkflows = [
  "release.yml",
  "openburnbar-pr-harness.yml",
].map((path) =>
  readFileSync(join(root, ".github", "workflows", path), "utf8"),
);

function valid(overrides = {}) {
  return {
    artifactName: "OpenBurnBar-1.2.3-Android.aab",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    track: "internal",
    confirmNonInternal: false,
    dryRun: true,
    releaseStatus: "draft",
    packageName: "com.openburnbar",
    versionName: "1.2.3",
    versionCode: "41",
    targetSdk: "36",
    bundletoolVersion: "1.18.3",
    sha256: "b".repeat(64),
    sizeBytes: 123,
    uploadCertificateSha256: "c".repeat(64),
    preparedAt: "2026-08-01T12:00:00Z",
    repository: "Imagine-That-Ai/BurnBar",
    runId: "1234",
    runAttempt: "1",
    ...overrides,
  };
}

test("safe defaults produce an internal dry-run draft manifest", () => {
  const manifest = buildPublicationManifest(valid());
  assert.equal(manifest.publication.track, "internal");
  assert.equal(manifest.publication.dryRun, true);
  assert.equal(manifest.publication.releaseStatus, "draft");
  assert.equal(manifest.release.versionCode, 41);
  assert.equal(manifest.release.targetSdk, 36);
  assert.deepEqual(manifest.validation, {
    requiredTargetSdk: 36,
    observedTargetSdk: 36,
    bundletoolVersion: "1.18.3",
  });
});

test("non-internal tracks require explicit confirmation", () => {
  assert.throws(
    () => validatePublicationRequest(valid({ track: "production" })),
    /confirm_non_internal=true/u,
  );
  assert.equal(
    validatePublicationRequest(
      valid({ track: "production", confirmNonInternal: true }),
    ).track,
    "production",
  );
});

test("prerelease tags cannot leave the internal track", () => {
  assert.throws(
    () =>
      validatePublicationRequest(
        valid({
          artifactName: "OpenBurnBar-1.2.3-beta.1-Android.aab",
          tag: "v1.2.3-beta.1",
          versionName: "1.2.3-beta.1",
          track: "beta",
          confirmNonInternal: true,
        }),
      ),
    /prerelease tags/u,
  );
});

test("package, version, version code, signing digest, and artifact name fail closed", () => {
  assert.throws(
    () => validatePublicationRequest(valid({ packageName: "dev.attacker" })),
    /unexpected Android package/u,
  );
  assert.throws(
    () => validatePublicationRequest(valid({ versionName: "1.2.4" })),
    /does not match/u,
  );
  assert.throws(
    () => validatePublicationRequest(valid({ versionCode: "0" })),
    /positive integer/u,
  );
  assert.throws(
    () => validatePublicationRequest(valid({ sha256: "bad" })),
    /SHA-256/u,
  );
  assert.throws(
    () => buildPublicationManifest(valid({ uploadCertificateSha256: "bad" })),
    /uploadCertificateSha256/u,
  );
  assert.throws(
    () =>
      validatePublicationRequest(
        valid({ artifactName: "renamed-or-wrong.aab" }),
      ),
    /unexpected AAB filename/u,
  );
});

test("the signed bundle must match the canonical Android SDK policy", () => {
  assert.deepEqual(ANDROID_RELEASE_POLICY, {
    compileSdk: 36,
    targetSdk: 36,
  });
  assert.throws(
    () => validatePublicationRequest(valid({ targetSdk: "35" })),
    /requires target SDK 36; bundle targets 35/u,
  );
  assert.throws(
    () => validatePublicationRequest(valid({ targetSdk: "" })),
    /targetSdk must be a positive integer/u,
  );
  assert.throws(
    () => buildPublicationManifest(valid({ bundletoolVersion: "latest" })),
    /bundletoolVersion must be a canonical numeric version/u,
  );
});

test("malformed Android SDK policies fail closed", () => {
  const validPolicy =
    "openburnbar.android.compileSdk=36\nopenburnbar.android.targetSdk=36\n";
  assert.deepEqual(parseAndroidReleasePolicy(validPolicy), {
    compileSdk: 36,
    targetSdk: 36,
  });
  for (const source of [
    "openburnbar.android.compileSdk=36\n",
    `${validPolicy}openburnbar.android.targetSdk=36\n`,
    "openburnbar.android.compileSdk=36\nopenburnbar.android.targetSdk=0\n",
  ]) {
    assert.throws(() => parseAndroidReleasePolicy(source));
  }
  assert.throws(
    () =>
      parseAndroidReleasePolicy(
        "openburnbar.android.compileSdk=35\nopenburnbar.android.targetSdk=36\n",
      ),
    /target SDK cannot exceed compile SDK/u,
  );
});

test("every Android module consumes the shared SDK policy", () => {
  const scripts = [
    "app/build.gradle.kts",
    "burnbar-remote/build.gradle.kts",
    "macrobenchmark/build.gradle.kts",
    "openburnbar-domain-core/build.gradle.kts",
    "openburnbar-iroh-relay/build.gradle.kts",
  ].map((path) =>
    readFileSync(join(root, "android", path), "utf8"),
  );
  for (const script of scripts) {
    assert.match(script, /compileSdk = openBurnBarCompileSdk/u);
    assert.doesNotMatch(script, /compileSdk\s*=\s*36/u);
  }
  assert.match(scripts[0], /targetSdk = openBurnBarTargetSdk/u);
  assert.match(scripts[2], /targetSdk = openBurnBarTargetSdk/u);
});

test("explicit Android CI SDK installs provision API 36", () => {
  for (const source of androidCiWorkflows) {
    assert.doesNotMatch(source, /platforms;android-35/u);
    assert.match(source, /platforms;android-36 build-tools;36\.0\.0/u);
  }
});

test("workflow has a protected two-job trust boundary and safe defaults", () => {
  assert.match(workflow, /default: internal/u);
  assert.match(workflow, /default: true/u);
  assert.match(workflow, /group: google-play-\$\{\{ inputs\.tag \}\}-\$\{\{ inputs\.track \}\}/u);
  assert.match(workflow, /ref: \$\{\{ github\.workflow_sha \}\}/u);
  assert.match(
    workflow,
    /"\$checked_out_commit" != "\$GITHUB_WORKFLOW_SHA"/u,
  );
  assert.match(workflow, /environment: release/u);
  assert.match(workflow, /if: \$\{\{ needs\.prepare-google-play-publication\.result == 'success' && inputs\.dry_run == false \}\}/u);
  assert.match(workflow, /GOOGLE_PLAY_SERVICE_ACCOUNT_JSON/u);
  assert.match(workflow, /androidpublisher/u);
  assert.match(workflow, /gh attestation verify/u);
  assert.match(workflow, /--signer-workflow "\$GITHUB_REPOSITORY\/\.github\/workflows\/release\.yml"/u);
  assert.match(workflow, /--source-digest "\$commit"/u);
  assert.match(workflow, /--source-ref "refs\/tags\/\$TAG"/u);
});

test("credentialed job does not check out or consume repository scripts", () => {
  const publishStart = workflow.indexOf("\n  publish-google-play:");
  assert.ok(publishStart > 0);
  const publishJob = workflow.slice(publishStart);
  assert.doesNotMatch(publishJob, /actions\/checkout/u);
  assert.doesNotMatch(publishJob, /scripts\/ci|scripts\/lib/u);
  assert.match(publishJob, /actions\/download-artifact/u);
  assert.match(publishJob, /sha256sum --check --strict/u);
  assert.match(
    publishJob,
    /node "\$stage\/google-play-safe-retry\.mjs"/u,
  );
  assert.match(
    publishJob,
    /google-play-provider-result\.json/u,
  );
  assert.match(publishJob, /targetSdk: \$manifest\[0\]\.release\.targetSdk/u);
  assert.match(
    publishJob,
    /bundletoolVersion: \$manifest\[0\]\.validation\.bundletoolVersion/u,
  );
  assert.match(publishJob, /- Target SDK: \\`\$TARGET_SDK\\`/u);
  assert.doesNotMatch(publishJob, /curl .*androidpublisher/u);
});

test("prepare job has no publisher credential or release environment", () => {
  const prepareStart = workflow.indexOf("\n  prepare-google-play-publication:");
  const publishStart = workflow.indexOf("\n  publish-google-play:");
  const prepareJob = workflow.slice(prepareStart, publishStart);
  assert.doesNotMatch(prepareJob, /GOOGLE_PLAY_SERVICE_ACCOUNT_JSON/u);
  assert.doesNotMatch(prepareJob, /environment:\s*release/u);
  assert.match(prepareJob, /com\.openburnbar/u);
  assert.match(prepareJob, /android:versionCode/u);
  assert.match(prepareJob, /uses-sdk\/@android:targetSdkVersion/u);
  assert.match(
    prepareJob,
    /openburnbar\\\.android\\\.targetSdk/u,
  );
  assert.match(prepareJob, /--target-sdk "\$TARGET_SDK"/u);
  assert.match(
    prepareJob,
    /--bundletool-version "\$BUNDLETOOL_VERSION"/u,
  );
  assert.match(
    prepareJob,
    /Google Play publication requires target SDK \$required_target_sdk/u,
  );
  assert.match(prepareJob, /android-upload-certificate\.sha256/u);
  assert.match(
    prepareJob,
    /cp scripts\/ci\/google-play-safe-retry\.mjs "\$stage\/google-play-safe-retry\.mjs"/u,
  );
  assert.match(
    prepareJob,
    /sha256sum .*google-play-safe-retry\.mjs > SHA256SUMS/u,
  );
});
