#!/usr/bin/env node

import { createHash } from "node:crypto";
import { lstatSync, readFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const TRACKS = new Set(["internal", "alpha", "beta", "production"]);
const RELEASE_STATUSES = new Set(["draft", "completed"]);
const TAG_PATTERN =
  /^v[0-9]{1,3}\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/u;
const ANDROID_GRADLE_PROPERTIES = fileURLToPath(
  new URL("../../android/gradle.properties", import.meta.url),
);

function requireString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${label} is required`);
  }
  return value;
}

function parseBoolean(value, label) {
  if (value === "true" || value === true) return true;
  if (value === "false" || value === false) return false;
  throw new Error(`${label} must be true or false`);
}

function parsePositiveInteger(value, label) {
  if (!/^[1-9][0-9]*$/u.test(String(value))) {
    throw new Error(`${label} must be a positive integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`${label} exceeds the safe integer range`);
  }
  return parsed;
}

function readGradleIntegerProperty(source, name) {
  const values = source
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line.startsWith(`${name}=`))
    .map((line) => line.slice(name.length + 1).trim());
  if (values.length !== 1) {
    throw new Error(
      `${name} must appear exactly once in android/gradle.properties`,
    );
  }
  return parsePositiveInteger(values[0], name);
}

export function parseAndroidReleasePolicy(source) {
  const policy = {
    compileSdk: readGradleIntegerProperty(
      source,
      "openburnbar.android.compileSdk",
    ),
    targetSdk: readGradleIntegerProperty(
      source,
      "openburnbar.android.targetSdk",
    ),
  };
  if (policy.targetSdk > policy.compileSdk) {
    throw new Error("Android target SDK cannot exceed compile SDK");
  }
  return policy;
}

export const ANDROID_RELEASE_POLICY = Object.freeze(
  parseAndroidReleasePolicy(
    readFileSync(ANDROID_GRADLE_PROPERTIES, "utf8"),
  ),
);

function parseArguments(argv) {
  if (argv.length === 0 || argv[0] !== "prepare") {
    throw new Error(
      "usage: prepare --artifact PATH --tag TAG --commit SHA --track TRACK --confirm-non-internal BOOL --dry-run BOOL --release-status STATUS --package PACKAGE --version-name VERSION --version-code CODE --target-sdk SDK --bundletool-version VERSION --sha256 SHA --prepared-at ISO8601 --repository OWNER/REPO --run-id ID --run-attempt ATTEMPT --output PATH",
    );
  }
  const values = new Map();
  for (let index = 1; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`invalid argument near ${key ?? "<end>"}`);
    }
    if (values.has(key)) throw new Error(`duplicate argument: ${key}`);
    values.set(key, value);
  }
  return values;
}

function requireRegularFile(path, label) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error(`${label} must be a nonempty regular non-symlink file`);
  }
  return stat;
}

export function validatePublicationRequest(input) {
  const tag = requireString(input.tag, "tag");
  if (!TAG_PATTERN.test(tag)) {
    throw new Error("tag must be canonical vMAJOR.MINOR.PATCH SemVer");
  }
  const versionName = requireString(input.versionName, "versionName");
  if (versionName !== tag.slice(1)) {
    throw new Error(`versionName ${versionName} does not match ${tag}`);
  }
  const track = requireString(input.track, "track");
  if (!TRACKS.has(track)) throw new Error(`unsupported Google Play track: ${track}`);
  const releaseStatus = requireString(input.releaseStatus, "releaseStatus");
  if (!RELEASE_STATUSES.has(releaseStatus)) {
    throw new Error(`unsupported Google Play release status: ${releaseStatus}`);
  }
  const confirmNonInternal = parseBoolean(
    input.confirmNonInternal,
    "confirmNonInternal",
  );
  const dryRun = parseBoolean(input.dryRun, "dryRun");
  if (track !== "internal" && !confirmNonInternal) {
    throw new Error("non-internal tracks require confirm_non_internal=true");
  }
  if (tag.includes("-") && track !== "internal") {
    throw new Error("prerelease tags may only target the internal track");
  }
  const commit = requireString(input.commit, "commit");
  if (!/^[0-9a-f]{40}$/u.test(commit)) {
    throw new Error("commit must be a lowercase full Git SHA");
  }
  if (input.packageName !== "com.openburnbar") {
    throw new Error(`unexpected Android package: ${input.packageName}`);
  }
  const versionCode = parsePositiveInteger(input.versionCode, "versionCode");
  const targetSdk = parsePositiveInteger(input.targetSdk, "targetSdk");
  if (targetSdk !== ANDROID_RELEASE_POLICY.targetSdk) {
    throw new Error(
      `Google Play publication requires target SDK ${ANDROID_RELEASE_POLICY.targetSdk}; bundle targets ${targetSdk}`,
    );
  }
  const sha256 = requireString(input.sha256, "sha256");
  if (!/^[0-9a-f]{64}$/u.test(sha256)) {
    throw new Error("sha256 must be a lowercase SHA-256 digest");
  }
  const expectedArtifactName = `OpenBurnBar-${versionName}-Android.aab`;
  if (input.artifactName !== expectedArtifactName) {
    throw new Error(
      `unexpected AAB filename: ${input.artifactName} (expected ${expectedArtifactName})`,
    );
  }
  return {
    tag,
    versionName,
    track,
    releaseStatus,
    confirmNonInternal,
    dryRun,
    commit,
    packageName: input.packageName,
    versionCode,
    targetSdk,
    sha256,
    artifactName: input.artifactName,
  };
}

export function buildPublicationManifest(input) {
  const request = validatePublicationRequest(input);
  const sizeBytes = parsePositiveInteger(input.sizeBytes, "sizeBytes");
  const uploadCertificateSha256 = requireString(
    input.uploadCertificateSha256,
    "uploadCertificateSha256",
  );
  if (!/^[0-9a-f]{64}$/u.test(uploadCertificateSha256)) {
    throw new Error(
      "uploadCertificateSha256 must be a lowercase SHA-256 digest",
    );
  }
  const preparedAt = requireString(input.preparedAt, "preparedAt");
  if (Number.isNaN(Date.parse(preparedAt))) {
    throw new Error("preparedAt must be an ISO-8601 timestamp");
  }
  const repository = requireString(input.repository, "repository");
  if (repository !== "Imagine-That-Ai/BurnBar") {
    throw new Error(`unexpected source repository: ${repository}`);
  }
  const bundletoolVersion = requireString(
    input.bundletoolVersion,
    "bundletoolVersion",
  );
  if (!/^[1-9][0-9]*\.[0-9]+\.[0-9]+$/u.test(bundletoolVersion)) {
    throw new Error("bundletoolVersion must be a canonical numeric version");
  }
  return {
    schemaVersion: 1,
    publication: {
      packageName: request.packageName,
      track: request.track,
      releaseStatus: request.releaseStatus,
      dryRun: request.dryRun,
      confirmedNonInternal: request.confirmNonInternal,
    },
    release: {
      tag: request.tag,
      versionName: request.versionName,
      versionCode: request.versionCode,
      targetSdk: request.targetSdk,
      commit: request.commit,
      repository,
      signerWorkflow: ".github/workflows/release.yml",
    },
    artifact: {
      fileName: request.artifactName,
      sha256: request.sha256,
      sizeBytes,
      uploadCertificateSha256,
    },
    validation: {
      requiredTargetSdk: ANDROID_RELEASE_POLICY.targetSdk,
      observedTargetSdk: request.targetSdk,
      bundletoolVersion,
    },
    preparation: {
      preparedAt,
      workflow: ".github/workflows/publish-google-play.yml",
      runId: String(parsePositiveInteger(input.runId, "runId")),
      runAttempt: String(parsePositiveInteger(input.runAttempt, "runAttempt")),
    },
  };
}

export function run(argv) {
  const args = parseArguments(argv);
  const artifact = resolve(requireString(args.get("--artifact"), "artifact"));
  const stat = requireRegularFile(artifact, "Android App Bundle");
  const actualSha256 = createHash("sha256")
    .update(readFileSync(artifact))
    .digest("hex");
  const expectedSha256 = requireString(args.get("--sha256"), "sha256");
  if (actualSha256 !== expectedSha256) {
    throw new Error("AAB SHA-256 changed before manifest creation");
  }
  const manifest = buildPublicationManifest({
    artifactName: basename(artifact),
    tag: args.get("--tag"),
    commit: args.get("--commit"),
    track: args.get("--track"),
    confirmNonInternal: args.get("--confirm-non-internal"),
    dryRun: args.get("--dry-run"),
    releaseStatus: args.get("--release-status"),
    packageName: args.get("--package"),
    versionName: args.get("--version-name"),
    versionCode: args.get("--version-code"),
    targetSdk: args.get("--target-sdk"),
    bundletoolVersion: args.get("--bundletool-version"),
    sha256: expectedSha256,
    sizeBytes: stat.size,
    uploadCertificateSha256: requireString(
      args.get("--upload-certificate-sha256"),
      "uploadCertificateSha256",
    ),
    preparedAt: args.get("--prepared-at"),
    repository: args.get("--repository"),
    runId: args.get("--run-id"),
    runAttempt: args.get("--run-attempt"),
  });
  const output = resolve(requireString(args.get("--output"), "output"));
  writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(`${JSON.stringify({ ok: true, output })}\n`);
  return manifest;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
