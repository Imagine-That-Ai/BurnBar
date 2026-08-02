#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { join } from "node:path";

import {
  buildPublicationManifest,
  validatePublicationRequest,
} from "./google-play-publication.mjs";

const root = join(import.meta.dirname, "..", "..");
const workflow = readFileSync(
  join(root, ".github", "workflows", "publish-google-play.yml"),
  "utf8",
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

test("workflow has a protected two-job trust boundary and safe defaults", () => {
  assert.match(workflow, /default: internal/u);
  assert.match(workflow, /default: true/u);
  assert.match(workflow, /group: google-play-\$\{\{ inputs\.tag \}\}-\$\{\{ inputs\.track \}\}/u);
  assert.match(workflow, /ref: main/u);
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
  assert.match(publishJob, /DELETE/u);
  assert.match(publishJob, /edits\/\$edit_id:commit/u);
});

test("prepare job has no publisher credential or release environment", () => {
  const prepareStart = workflow.indexOf("\n  prepare-google-play-publication:");
  const publishStart = workflow.indexOf("\n  publish-google-play:");
  const prepareJob = workflow.slice(prepareStart, publishStart);
  assert.doesNotMatch(prepareJob, /GOOGLE_PLAY_SERVICE_ACCOUNT_JSON/u);
  assert.doesNotMatch(prepareJob, /environment:\s*release/u);
  assert.match(prepareJob, /com\.openburnbar/u);
  assert.match(prepareJob, /android:versionCode/u);
  assert.match(prepareJob, /android-upload-certificate\.sha256/u);
});
