#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
  DOMAIN_CORE_REPOSITORY,
  RELEASE_CONSUMERS,
  exactObject,
  regularFile,
  safeAssetName,
} from "../lib/domain-core-release-evidence.mjs";
import {
  DOMAIN_CORE_PUBLIC_PROFILE,
  DOMAIN_CORE_ROLLBACK_PROFILE,
} from "../lib/domain-core-native-release.mjs";
import { validateManifest } from "./publish-domain-core-release-evidence.mjs";

const COMMIT = /^[0-9a-f]{40}$/u;
const STABLE_TAG =
  /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const OIDC_ISSUER = "https://token.actions.githubusercontent.com";
const RECEIPT_SCHEMA_VERSION = 1;
const ROLLBACK_TARGET_RECEIPT_KIND = "macos-rollback-target";

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

function objectValue(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function hashBytes(algorithm, bytes) {
  return createHash(algorithm).update(bytes).digest("hex");
}

function hashFile(algorithm, path) {
  return hashBytes(algorithm, readFileSync(path));
}

function fileRecord(path) {
  const bytes = readFileSync(path);
  return {
    size: bytes.length,
    sha256: hashBytes("sha256", bytes),
    sha512: hashBytes("sha512", bytes),
  };
}

export function createGhClient(runner = spawnSync) {
  return {
    run(args, { allowFailure = false } = {}) {
      const result = runner("gh", args, {
        encoding: "utf8",
        env: process.env,
        maxBuffer: 32 * 1024 * 1024,
      });
      if (result.error) throw result.error;
      if (result.status !== 0 && !allowFailure) {
        throw new Error(
          `gh command failed: ${(result.stderr || result.stdout || "unknown failure").trim()}`,
        );
      }
      return result;
    },
  };
}

function resolveTag(client, tag, commit) {
  const result = client.run([
    "api",
    `repos/${DOMAIN_CORE_REPOSITORY}/commits/${encodeURIComponent(tag)}`,
  ]);
  const value = objectValue(
    parseJson(result.stdout, "release tag lookup"),
    "release tag lookup",
  );
  if (value.sha !== commit) {
    throw new Error("release tag does not resolve to the audited commit");
  }
}

function releaseAsset(raw, label) {
  const value = objectValue(raw, label);
  const name = safeAssetName(value.name, `${label} name`);
  if (!Number.isSafeInteger(value.id) || value.id <= 0) {
    throw new Error(`${label} id must be a positive integer`);
  }
  if (!Number.isSafeInteger(value.size) || value.size < 0) {
    throw new Error(`${label} size must be a non-negative integer`);
  }
  if (
    typeof value.digest !== "string" ||
    !/^sha256:[0-9a-f]{64}$/iu.test(value.digest)
  ) {
    throw new Error(`${label} digest must be a GitHub SHA-256 digest`);
  }
  return {
    id: value.id,
    name,
    size: value.size,
    digest: value.digest.toLowerCase(),
  };
}

function releaseIdentity(releaseID, assets) {
  return {
    releaseID,
    assets: assets
      .map(({ id, name, size, digest }) => ({ id, name, size, digest }))
      .sort((left, right) => left.name.localeCompare(right.name)),
  };
}

function sameIdentity(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function parseRelease(raw, expected) {
  const value = objectValue(raw, "GitHub release");
  if (
    !Number.isSafeInteger(value.id) ||
    value.id <= 0 ||
    value.tag_name !== expected.tag ||
    value.target_commitish !== expected.commit ||
    value.name !== `OpenBurnBar ${expected.version}` ||
    typeof value.body !== "string" ||
    hashBytes("sha256", Buffer.from(value.body)) !== expected.notesSha256 ||
    value.draft !== false ||
    value.prerelease !== false ||
    !Array.isArray(value.assets)
  ) {
    throw new Error(
      "GitHub release metadata does not match the exact stable publication",
    );
  }
  const assets = value.assets.map((asset, index) =>
    releaseAsset(asset, `GitHub release assets[${index}]`),
  );
  const names = assets.map((asset) => asset.name);
  if (new Set(names).size !== names.length) {
    throw new Error("GitHub release assets are duplicated");
  }
  return {
    identity: releaseIdentity(value.id, assets),
    assets: new Map(assets.map((asset) => [asset.name, asset])),
  };
}

function lookupRelease(client, expected, { latest = false } = {}) {
  resolveTag(client, expected.tag, expected.commit);
  const endpoint = latest
    ? `repos/${DOMAIN_CORE_REPOSITORY}/releases/latest`
    : `repos/${DOMAIN_CORE_REPOSITORY}/releases/tags/${expected.tag}`;
  const result = client.run(["api", endpoint], { allowFailure: true });
  if (result.status !== 0) {
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`.trim();
    throw new Error(
      `${latest ? "GitHub latest" : "GitHub tagged"} release lookup failed: ${detail}`,
    );
  }
  return parseRelease(parseJson(result.stdout, "release lookup"), expected);
}

function generalProvenanceSubjects(version) {
  return [
    `OpenBurnBar-${version}-macOS.dmg`,
    `OpenBurnBar-${version}-macOS.zip`,
    `OpenBurnBar-${version}-corresponding-source.tar.gz`,
    "appcast.xml",
    "latest-macos.json",
    `checksums-v${version}.txt`,
    `sbom-v${version}.spdx.json`,
    `openburnbar-v${version}.vex.json`,
  ];
}

export function validateDomainCoreProfile(domainCoreProfile) {
  if (
    domainCoreProfile !== DOMAIN_CORE_PUBLIC_PROFILE &&
    domainCoreProfile !== DOMAIN_CORE_ROLLBACK_PROFILE
  ) {
    throw new Error(
      "promotion requires a governed public-production or public-production-rollback domain-core profile",
    );
  }
  return domainCoreProfile;
}

export function domainCoreBundleAssetName(consumer, version, domain) {
  return consumer === "ios"
    ? `OpenBurnBar-${version}-iOS-${domain}-domain-core-attestation.sigstore.json`
    : `OpenBurnBar-${version}-${consumer}-${domain}-domain-core.sigstore.json`;
}

/// Sidecar stem for a subject signed through `attest_release_blob`.
///
/// cosign writes its bundles under a filesystem-safe form of the subject name,
/// so every `+` in a `1.0.40+repair.N` version becomes `_`. The producer emits
/// that form and scripts/ci/verify-release-attestations.sh re-derives the same
/// sanitisation (`[^A-Za-z0-9._-]` -> `_`) when it looks the bundles up. This
/// expected-asset set was the only place still building sidecar names from the
/// raw version, so the audit demanded `...+repair.30-macOS.dmg.sigstore.json`
/// while the release legitimately carried `..._repair.30-macOS.dmg.sigstore.json`.
///
/// The mismatch was unreachable until now: no release had ever passed the
/// earlier notes and asset checks to reach this comparison, and renaming the
/// assets to satisfy it simply moved the failure to the attestation verifier,
/// which wants the sanitised form. Derive it the same way here.
function sigstoreSidecarStem(subject) {
  return subject.replace(/[^A-Za-z0-9._-]/gu, "_");
}

export function expectedReleaseAssets(version, domainCoreProfile) {
  validateDomainCoreProfile(domainCoreProfile);
  const required = new Set([
    `OpenBurnBar-${version}-macOS.dmg`,
    `OpenBurnBar-${version}-macOS.zip`,
    `OpenBurnBar-${version}-Android.aab`,
    `OpenBurnBar-${version}-corresponding-source.tar.gz`,
    `OpenBurnBar-${version}-corresponding-source.tar.gz.sha256`,
    `OpenBurnBar-${version}-legacy-rollback.zip`,
    "appcast.xml",
    "latest-macos.json",
    `checksums-v${version}.txt`,
    `sbom-v${version}.spdx.json`,
    `openburnbar-v${version}.vex.json`,
    `NOTICES-v${version}.txt`,
    "release-metadata.json",
  ]);

  for (const subject of generalProvenanceSubjects(version)) {
    required.add(`${sigstoreSidecarStem(subject)}.predicate.json`);
    required.add(`${sigstoreSidecarStem(subject)}.sigstore.json`);
  }
  // The rollback sidecars are NOT cosign-named: release.yml builds them
  // directly from `${ROLLBACK_PATH##*/}`, so they keep the raw `+`. Only the
  // subjects above go through attest_release_blob.
  const rollback = `OpenBurnBar-${version}-legacy-rollback.zip`;
  required.add(`${rollback}.predicate.json`);
  required.add(`${rollback}.sigstore.json`);

  // Domain-core evidence exists exactly when the release was published with a
  // Rust-active public-production profile. A governed public-production-rollback
  // release publishes the legacy artifacts with no native domain-core evidence
  // and no App Store iOS lane, so those assets become verify-if-present.
  const domainCoreEvidence = new Set([
    `OpenBurnBar-${version}-iOS.xcarchive.zip`,
    `OpenBurnBar-${version}-iOS-app-store-connect-receipt.json`,
  ]);
  for (const consumer of ["apple", "android", "ios"]) {
    for (const domain of RELEASE_CONSUMERS[consumer].domains) {
      domainCoreEvidence.add(
        domainCoreBundleAssetName(consumer, version, domain),
      );
    }
  }

  const optional = new Set([`checksums-v${version}.txt.asc`]);
  for (const name of domainCoreEvidence) {
    (domainCoreProfile === DOMAIN_CORE_ROLLBACK_PROFILE
      ? optional
      : required
    ).add(name);
  }

  return { required, optional };
}

function requireExactAssetSet(version, assets, domainCoreProfile) {
  const { required, optional } = expectedReleaseAssets(
    version,
    domainCoreProfile,
  );
  const names = new Set(assets.keys());
  const missing = [...required].filter((name) => !names.has(name));
  const unexpected = [...names].filter(
    (name) => !required.has(name) && !optional.has(name),
  );
  if (missing.length > 0 || unexpected.length > 0) {
    throw new Error(
      `release asset set mismatch; missing=${missing.join(",") || "none"} unexpected=${unexpected.join(",") || "none"}`,
    );
  }
}

function prepareAssetDirectory(path) {
  mkdirSync(path, { recursive: true });
  if (readdirSync(path).length !== 0) {
    throw new Error("promotion asset directory must start empty");
  }
}

function downloadAssets(client, expected, release, directory) {
  const downloads = new Map();
  for (const asset of release.identity.assets) {
    client.run([
      "release",
      "download",
      expected.tag,
      "--repo",
      DOMAIN_CORE_REPOSITORY,
      "--pattern",
      asset.name,
      "--dir",
      directory,
    ]);
    const path = regularFile(
      join(directory, asset.name),
      `downloaded release asset ${asset.name}`,
    );
    const record = fileRecord(path);
    if (
      record.size !== asset.size ||
      `sha256:${record.sha256}` !== asset.digest
    ) {
      throw new Error(
        `downloaded release asset ${asset.name} does not match GitHub size and digest metadata`,
      );
    }
    downloads.set(asset.name, path);
  }
  return downloads;
}

function rollbackTargetAssetNames(version) {
  const source = `OpenBurnBar-${version}-corresponding-source.tar.gz`;
  return [
    `OpenBurnBar-${version}-macOS.dmg`,
    `OpenBurnBar-${version}-macOS.zip`,
    source,
    `${source}.sha256`,
    "appcast.xml",
    "latest-macos.json",
    `checksums-v${version}.txt`,
    "release-metadata.json",
  ];
}

function rollbackTargetRelease(raw, expected) {
  const value = objectValue(raw, "GitHub rollback target release");
  if (
    !Number.isSafeInteger(value.id) ||
    value.id <= 0 ||
    value.tag_name !== expected.tag ||
    value.draft !== false ||
    value.prerelease !== false ||
    !Array.isArray(value.assets)
  ) {
    throw new Error(
      "GitHub rollback target release metadata is not an exact stable publication",
    );
  }
  const assets = value.assets.map((asset, index) =>
    releaseAsset(asset, `GitHub rollback target assets[${index}]`),
  );
  const byName = new Map(assets.map((asset) => [asset.name, asset]));
  if (byName.size !== assets.length) {
    throw new Error("GitHub rollback target assets are duplicated");
  }
  const required = rollbackTargetAssetNames(expected.version);
  const missing = required.filter((name) => !byName.has(name));
  if (missing.length > 0) {
    throw new Error(
      `GitHub rollback target is missing required assets: ${missing.join(",")}`,
    );
  }
  const selected = required.map((name) => byName.get(name));
  return {
    identity: releaseIdentity(value.id, selected),
    assets: new Map(selected.map((asset) => [asset.name, asset])),
  };
}

function lookupRollbackTargetRelease(
  client,
  expected,
  { latest = false } = {},
) {
  resolveTag(client, expected.tag, expected.commit);
  const endpoint = latest
    ? `repos/${DOMAIN_CORE_REPOSITORY}/releases/latest`
    : `repos/${DOMAIN_CORE_REPOSITORY}/releases/tags/${expected.tag}`;
  const result = client.run(["api", endpoint], { allowFailure: true });
  if (result.status !== 0) {
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`.trim();
    throw new Error(
      `GitHub ${latest ? "latest rollback target" : "rollback target"} lookup failed: ${detail}`,
    );
  }
  return rollbackTargetRelease(
    parseJson(result.stdout, "rollback target release lookup"),
    expected,
  );
}

function requiredPath(downloads, name) {
  const path = downloads.get(name);
  if (!path)
    throw new Error(`required downloaded release asset is missing: ${name}`);
  return path;
}

export function verifyChecksums(
  version,
  downloads,
  { includeRollback = true } = {},
) {
  const names = [
    `OpenBurnBar-${version}-macOS.dmg`,
    `OpenBurnBar-${version}-macOS.zip`,
    `OpenBurnBar-${version}-corresponding-source.tar.gz`,
    "appcast.xml",
    "latest-macos.json",
  ];
  if (includeRollback) {
    names.push(`OpenBurnBar-${version}-legacy-rollback.zip`);
  }
  const lines = readFileSync(
    requiredPath(downloads, `checksums-v${version}.txt`),
    "utf8",
  ).split(/\r?\n/u);
  const observed = new Map();
  for (const line of lines) {
    const match = /^([0-9a-f]{64}|[0-9a-f]{128})\s+\*?(.+)$/iu.exec(line);
    if (!match) continue;
    const algorithm = match[1].length === 64 ? "sha256" : "sha512";
    observed.set(`${algorithm}:${basename(match[2])}`, match[1].toLowerCase());
  }
  for (const name of names) {
    const path = requiredPath(downloads, name);
    for (const algorithm of ["sha256", "sha512"]) {
      const expected = observed.get(`${algorithm}:${name}`);
      if (!expected || expected !== hashFile(algorithm, path)) {
        throw new Error(
          `checksums-v${version}.txt does not verify ${algorithm} for ${name}`,
        );
      }
    }
  }

  const sourceName = `OpenBurnBar-${version}-corresponding-source.tar.gz`;
  const sourceSidecar = readFileSync(
    requiredPath(downloads, `${sourceName}.sha256`),
    "utf8",
  );
  const sourceMatch = /^([0-9a-f]{64})\s+\*?(.+)\s*$/iu.exec(sourceSidecar);
  if (
    !sourceMatch ||
    basename(sourceMatch[2]) !== sourceName ||
    sourceMatch[1].toLowerCase() !==
      hashFile("sha256", requiredPath(downloads, sourceName))
  ) {
    throw new Error("corresponding-source SHA-256 sidecar is invalid");
  }
}

function exactKeys(value, keys, label) {
  return exactObject(value, keys, label);
}

function requiredString(value, label) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${label} must be a nonempty string`);
  }
  return value;
}

function canonicalHttpsBaseUrl(value, label) {
  const raw = requiredString(value, label);
  let url;
  try {
    url = new URL(raw);
  } catch (error) {
    throw new Error(`${label} must be a valid URL: ${error.message}`);
  }
  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    url.search !== "" ||
    url.hash !== ""
  ) {
    throw new Error(`${label} must be a credential-free HTTPS base URL`);
  }
  url.pathname = url.pathname.replace(/\/+$/u, "");
  return url.toString().replace(/\/$/u, "");
}

function releaseUrl(baseUrl, name) {
  return `${baseUrl}/${encodeURIComponent(name)}`;
}

function validIsoTimestamp(value) {
  return (
    typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(value) &&
    Number.isFinite(Date.parse(value))
  );
}

function validSparkleSignature(value) {
  if (typeof value !== "string" || value === "") return false;
  try {
    const decoded = Buffer.from(value, "base64");
    return decoded.length === 64 && decoded.toString("base64") === value;
  } catch {
    return false;
  }
}

function appcastItemForVersion(appcast, version) {
  const versionMarker = `<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`;
  return (
    appcast
      .match(/<item\b[\s\S]*?<\/item>/gu)
      ?.find((item) => item.includes(versionMarker)) ?? ""
  );
}

export function verifyUpdateMetadata(
  expected,
  downloads,
  { verifyIosReceipt = true } = {},
) {
  const dmgName = `OpenBurnBar-${expected.version}-macOS.dmg`;
  const zipName = `OpenBurnBar-${expected.version}-macOS.zip`;
  const sourceName = `OpenBurnBar-${expected.version}-corresponding-source.tar.gz`;
  const dmgPath = requiredPath(downloads, dmgName);
  const dmg = fileRecord(dmgPath);
  const latest = exactKeys(
    parseJson(
      readFileSync(requiredPath(downloads, "latest-macos.json"), "utf8"),
      "latest-macos.json",
    ),
    [
      "appcastUrl",
      "build",
      "bundleId",
      "channel",
      "commit",
      "correspondingSource",
      "createdAt",
      "critical",
      "dmg",
      "downloadUrl",
      "length",
      "minimumSystemVersion",
      "releaseNotesUrl",
      "sha256",
      "sparkleEdSignature",
      "version",
      "zip",
    ],
    "latest-macos.json",
  );
  const metadata = exactKeys(
    parseJson(
      readFileSync(requiredPath(downloads, "release-metadata.json"), "utf8"),
      "release-metadata.json",
    ),
    [
      "appcast",
      "build_timestamp",
      "channel",
      "commit",
      "correspondingSource",
      "latestMetadata",
      "runner_arch",
      "runner_name",
      "runner_os",
      "sparkleEdSignaturePresent",
      "tag",
      "updateBaseUrl",
      "version",
    ],
    "release-metadata.json",
  );
  const updateBaseUrl = canonicalHttpsBaseUrl(
    metadata.updateBaseUrl,
    "release-metadata.json updateBaseUrl",
  );
  if (
    latest.version !== expected.version ||
    latest.commit !== expected.commit ||
    latest.dmg !== dmgName ||
    latest.zip !== zipName ||
    latest.correspondingSource !== sourceName ||
    latest.bundleId !== "com.openburnbar.app" ||
    latest.channel !== "direct-download" ||
    requiredString(latest.build, "latest-macos.json build") !== latest.build ||
    requiredString(
      latest.minimumSystemVersion,
      "latest-macos.json minimumSystemVersion",
    ) !== latest.minimumSystemVersion ||
    !validIsoTimestamp(latest.createdAt) ||
    typeof latest.critical !== "boolean" ||
    latest.length !== dmg.size ||
    latest.sha256 !== dmg.sha256 ||
    !validSparkleSignature(latest.sparkleEdSignature) ||
    latest.downloadUrl !== releaseUrl(updateBaseUrl, dmgName) ||
    latest.appcastUrl !== releaseUrl(updateBaseUrl, "appcast.xml") ||
    latest.releaseNotesUrl !==
      releaseUrl(updateBaseUrl, "release-metadata.json")
  ) {
    throw new Error(
      "latest-macos.json does not bind the exact audited release",
    );
  }

  const appcast = readFileSync(requiredPath(downloads, "appcast.xml"), "utf8");
  const appcastItem = appcastItemForVersion(appcast, expected.version);
  if (
    !appcast.includes(`<link>${latest.appcastUrl}</link>`) ||
    !appcastItem.includes(
      `<sparkle:version>${latest.build}</sparkle:version>`,
    ) ||
    !appcastItem.includes(
      `<sparkle:shortVersionString>${expected.version}</sparkle:shortVersionString>`,
    ) ||
    !appcastItem.includes(
      `<sparkle:minimumSystemVersion>${latest.minimumSystemVersion}</sparkle:minimumSystemVersion>`,
    ) ||
    !appcastItem.includes(
      `<sparkle:releaseNotesLink>${latest.releaseNotesUrl}</sparkle:releaseNotesLink>`,
    ) ||
    !appcastItem.includes(`url="${latest.downloadUrl}"`) ||
    !appcastItem.includes(`length="${latest.length}"`) ||
    !appcastItem.includes('type="application/x-apple-diskimage"') ||
    !appcastItem.includes(
      `sparkle:edSignature="${latest.sparkleEdSignature}"`,
    ) ||
    (latest.critical &&
      !appcastItem.includes(
        "<sparkle:criticalUpdate></sparkle:criticalUpdate>",
      )) ||
    (!latest.critical && appcastItem.includes("<sparkle:criticalUpdate"))
  ) {
    throw new Error(
      "appcast.xml does not match the exact signed update metadata",
    );
  }

  if (
    metadata.version !== expected.version ||
    metadata.tag !== expected.tag ||
    metadata.commit !== expected.commit ||
    metadata.channel !== "direct-download" ||
    metadata.correspondingSource !== sourceName ||
    metadata.appcast !== "appcast.xml" ||
    metadata.latestMetadata !== "latest-macos.json" ||
    metadata.sparkleEdSignaturePresent !== true ||
    !validIsoTimestamp(metadata.build_timestamp) ||
    requiredString(metadata.runner_os, "release-metadata.json runner_os") !==
      metadata.runner_os ||
    requiredString(
      metadata.runner_arch,
      "release-metadata.json runner_arch",
    ) !== metadata.runner_arch ||
    requiredString(
      metadata.runner_name,
      "release-metadata.json runner_name",
    ) !== metadata.runner_name
  ) {
    throw new Error("release-metadata.json does not bind the exact release");
  }

  if (!verifyIosReceipt) {
    return { latest, metadata, dmg };
  }

  const iosReceiptName = `OpenBurnBar-${expected.version}-iOS-app-store-connect-receipt.json`;
  const iosArchiveName = `OpenBurnBar-${expected.version}-iOS.xcarchive.zip`;
  if (
    expected.domainCoreProfile === DOMAIN_CORE_ROLLBACK_PROFILE &&
    !downloads.has(iosReceiptName) &&
    !downloads.has(iosArchiveName)
  ) {
    // A governed rollback release has no App Store iOS lane; when neither iOS
    // asset was published there is nothing to bind.
    return { latest, metadata, dmg };
  }
  const iosReceipt = objectValue(
    parseJson(
      readFileSync(requiredPath(downloads, iosReceiptName), "utf8"),
      "App Store Connect receipt",
    ),
    "App Store Connect receipt",
  );
  if (
    iosReceipt.schemaVersion !== 1 ||
    iosReceipt.status !== "processed" ||
    iosReceipt.release?.version !== expected.version ||
    iosReceipt.release?.tag !== expected.tag ||
    iosReceipt.release?.commit !== expected.commit ||
    iosReceipt.archiveSha256 !==
      hashFile("sha256", requiredPath(downloads, iosArchiveName))
  ) {
    throw new Error(
      "App Store Connect receipt does not bind the exact processed iOS archive",
    );
  }
  return { latest, metadata, dmg };
}

function verifiedPredicates(
  client,
  expected,
  consumer,
  artifactPath,
  bundlePath,
) {
  const contract = RELEASE_CONSUMERS[consumer];
  const result = client.run([
    "attestation",
    "verify",
    artifactPath,
    "--bundle",
    bundlePath,
    "--repo",
    DOMAIN_CORE_REPOSITORY,
    "--signer-workflow",
    `${DOMAIN_CORE_REPOSITORY}/${contract.signerWorkflow}`,
    "--source-digest",
    expected.commit,
    "--source-ref",
    `refs/tags/${expected.tag}`,
    "--signer-digest",
    expected.commit,
    "--cert-oidc-issuer",
    OIDC_ISSUER,
    "--deny-self-hosted-runners",
    "--predicate-type",
    DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
    "--format",
    "json",
  ]);
  const value = parseJson(result.stdout, "gh attestation verify");
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error("gh attestation verify returned no verification results");
  }
  return value
    .map((entry) => entry?.verificationResult?.statement?.predicate)
    .filter((predicate) => predicate && typeof predicate === "object");
}

export function verifyDomainCoreBundles(
  client,
  expected,
  downloads,
  predicateDirectory,
) {
  mkdirSync(predicateDirectory, { recursive: true });
  const rollbackProfile =
    validateDomainCoreProfile(expected.domainCoreProfile) ===
    DOMAIN_CORE_ROLLBACK_PROFILE;
  for (const consumer of ["apple", "android", "ios"]) {
    const contract = RELEASE_CONSUMERS[consumer];
    const bundleNames = contract.domains.map((domain) => [
      domain,
      domainCoreBundleAssetName(consumer, expected.version, domain),
    ]);
    if (
      rollbackProfile &&
      bundleNames.every(([, assetName]) => !downloads.has(assetName))
    ) {
      // A governed rollback release publishes no domain-core evidence for this
      // consumer; anything that is present is still verified below.
      continue;
    }
    const artifactPath = requiredPath(
      downloads,
      contract.fileName(expected.version),
    );
    for (const [domain, assetName] of bundleNames) {
      if (rollbackProfile && !downloads.has(assetName)) continue;
      const bundlePath = requiredPath(downloads, assetName);
      const predicates = verifiedPredicates(
        client,
        expected,
        consumer,
        artifactPath,
        bundlePath,
      );
      let validated = false;
      for (const [index, predicate] of predicates.entries()) {
        const predicatePath = join(
          predicateDirectory,
          `${consumer}-${domain}-${index}.predicate.json`,
        );
        writeFileSync(predicatePath, `${JSON.stringify(predicate)}\n`, {
          mode: 0o600,
        });
        try {
          validateManifest({
            schemaVersion: 2,
            repository: DOMAIN_CORE_REPOSITORY,
            tag: expected.tag,
            commit: expected.commit,
            consumer,
            signerWorkflow: contract.signerWorkflow,
            releaseState: "published",
            nativeArtifactOnly: false,
            artifactPath,
            bundles: [
              {
                domain,
                assetName,
                bundlePath,
                predicatePath,
              },
            ],
          });
          validated = true;
          break;
        } catch {
          // Continue until an authenticated result matches the exact consumer,
          // domain, release, artifact bytes, rollback chain, and store receipt.
        }
      }
      if (!validated) {
        throw new Error(
          `${consumer} ${domain} bundle has no exact valid release predicate`,
        );
      }
    }
  }
}

function validateExpectedCoordinates({
  tag,
  commit,
  notesPath,
  domainCoreProfile,
}) {
  const match = typeof tag === "string" ? STABLE_TAG.exec(tag) : null;
  if (!match) {
    throw new Error("promotion tag must be stable canonical SemVer");
  }
  if (typeof commit !== "string" || !COMMIT.test(commit)) {
    throw new Error("promotion commit must be a full lowercase Git SHA");
  }
  const notes = readFileSync(regularFile(notesPath, "release notes"), "utf8");
  return {
    repository: DOMAIN_CORE_REPOSITORY,
    tag,
    version: match[1],
    commit,
    notesSha256: hashBytes("sha256", Buffer.from(notes)),
    domainCoreProfile: validateDomainCoreProfile(domainCoreProfile),
  };
}

function receiptContents(expected, release) {
  return {
    schemaVersion: RECEIPT_SCHEMA_VERSION,
    repository: DOMAIN_CORE_REPOSITORY,
    tag: expected.tag,
    version: expected.version,
    commit: expected.commit,
    notesSha256: expected.notesSha256,
    domainCoreProfile: expected.domainCoreProfile,
    releaseIdentity: release.identity,
  };
}

function writeReceipt(path, receipt) {
  const output = resolve(path);
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(receipt, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  return output;
}

export function auditRollbackTargetRelease(
  { tag, commit, assetDirectory, receiptPath },
  { client = createGhClient() } = {},
) {
  const match = typeof tag === "string" ? STABLE_TAG.exec(tag) : null;
  if (!match || typeof commit !== "string" || !COMMIT.test(commit)) {
    throw new Error(
      "rollback target requires a stable tag and full lowercase commit",
    );
  }
  const expected = {
    repository: DOMAIN_CORE_REPOSITORY,
    tag,
    version: match[1],
    commit,
  };
  const directory = resolve(assetDirectory);
  prepareAssetDirectory(directory);
  const release = lookupRollbackTargetRelease(client, expected);
  const downloads = downloadAssets(client, expected, release, directory);
  verifyChecksums(expected.version, downloads, { includeRollback: false });
  verifyUpdateMetadata(expected, downloads, { verifyIosReceipt: false });

  const final = lookupRollbackTargetRelease(client, expected);
  if (!sameIdentity(release.identity, final.identity)) {
    throw new Error("rollback target release changed during its audit");
  }
  const output = writeReceipt(receiptPath, {
    schemaVersion: RECEIPT_SCHEMA_VERSION,
    kind: ROLLBACK_TARGET_RECEIPT_KIND,
    repository: DOMAIN_CORE_REPOSITORY,
    tag,
    version: expected.version,
    commit,
    releaseIdentity: final.identity,
  });
  return { expected, release: final, downloads, receiptPath: output };
}

export function validateRollbackTargetReceipt(raw) {
  const value = exactObject(
    raw,
    [
      "schemaVersion",
      "kind",
      "repository",
      "tag",
      "version",
      "commit",
      "releaseIdentity",
    ],
    "rollback target receipt",
  );
  if (
    value.schemaVersion !== RECEIPT_SCHEMA_VERSION ||
    value.kind !== ROLLBACK_TARGET_RECEIPT_KIND ||
    value.repository !== DOMAIN_CORE_REPOSITORY ||
    value.tag !== `v${value.version}` ||
    !STABLE_TAG.test(value.tag) ||
    !COMMIT.test(value.commit)
  ) {
    throw new Error("rollback target receipt coordinates are invalid");
  }
  const identity = objectValue(
    value.releaseIdentity,
    "rollback target receipt identity",
  );
  if (
    !Number.isSafeInteger(identity.releaseID) ||
    identity.releaseID <= 0 ||
    !Array.isArray(identity.assets)
  ) {
    throw new Error("rollback target receipt identity is invalid");
  }
  const assets = identity.assets.map((asset, index) =>
    releaseAsset(asset, `rollback target receipt assets[${index}]`),
  );
  const expectedNames = rollbackTargetAssetNames(value.version);
  if (
    JSON.stringify(assets.map((asset) => asset.name)) !==
    JSON.stringify(
      [...expectedNames].sort((left, right) => left.localeCompare(right)),
    )
  ) {
    throw new Error(
      "rollback target receipt must contain the exact required asset set",
    );
  }
  return {
    repository: DOMAIN_CORE_REPOSITORY,
    tag: value.tag,
    version: value.version,
    commit: value.commit,
    identity: releaseIdentity(identity.releaseID, assets),
  };
}

export function auditExistingRelease(
  { tag, commit, notesPath, assetDirectory, receiptPath, domainCoreProfile },
  {
    client = createGhClient(),
    domainCoreVerifier = verifyDomainCoreBundles,
  } = {},
) {
  const expected = validateExpectedCoordinates({
    tag,
    commit,
    notesPath,
    domainCoreProfile,
  });
  const directory = resolve(assetDirectory);
  prepareAssetDirectory(directory);
  const release = lookupRelease(client, expected);
  requireExactAssetSet(
    expected.version,
    release.assets,
    expected.domainCoreProfile,
  );
  const downloads = downloadAssets(client, expected, release, directory);
  verifyChecksums(expected.version, downloads);
  verifyUpdateMetadata(expected, downloads);
  domainCoreVerifier(
    client,
    expected,
    downloads,
    join(directory, ".domain-core-predicates"),
  );

  const final = lookupRelease(client, expected);
  requireExactAssetSet(
    expected.version,
    final.assets,
    expected.domainCoreProfile,
  );
  if (!sameIdentity(release.identity, final.identity)) {
    throw new Error("release changed during the promotion audit");
  }
  const output = writeReceipt(receiptPath, receiptContents(expected, final));
  return { expected, release: final, downloads, receiptPath: output };
}

export function validatePromotionReceipt(raw) {
  const value = exactObject(
    raw,
    [
      "schemaVersion",
      "repository",
      "tag",
      "version",
      "commit",
      "notesSha256",
      "domainCoreProfile",
      "releaseIdentity",
    ],
    "release promotion receipt",
  );
  validateDomainCoreProfile(value.domainCoreProfile);
  if (
    value.schemaVersion !== RECEIPT_SCHEMA_VERSION ||
    value.repository !== DOMAIN_CORE_REPOSITORY ||
    value.tag !== `v${value.version}` ||
    !STABLE_TAG.test(value.tag) ||
    !COMMIT.test(value.commit) ||
    typeof value.notesSha256 !== "string" ||
    !SHA256.test(value.notesSha256)
  ) {
    throw new Error("release promotion receipt coordinates are invalid");
  }
  const identity = objectValue(
    value.releaseIdentity,
    "release promotion receipt identity",
  );
  if (
    !Number.isSafeInteger(identity.releaseID) ||
    identity.releaseID <= 0 ||
    !Array.isArray(identity.assets)
  ) {
    throw new Error("release promotion receipt identity is invalid");
  }
  const assets = identity.assets.map((asset, index) =>
    releaseAsset(asset, `release promotion receipt assets[${index}]`),
  );
  if (
    new Set(assets.map((asset) => asset.name)).size !== assets.length ||
    JSON.stringify(assets) !==
      JSON.stringify(
        [...assets].sort((left, right) => left.name.localeCompare(right.name)),
      )
  ) {
    throw new Error(
      "release promotion receipt assets must be unique and sorted",
    );
  }
  requireExactAssetSet(
    value.version,
    new Map(assets.map((asset) => [asset.name, asset])),
    value.domainCoreProfile,
  );
  return {
    repository: DOMAIN_CORE_REPOSITORY,
    tag: value.tag,
    version: value.version,
    commit: value.commit,
    notesSha256: value.notesSha256,
    domainCoreProfile: value.domainCoreProfile,
    identity: releaseIdentity(identity.releaseID, assets),
  };
}

export function promoteAuditedRelease(
  receiptPath,
  { client = createGhClient() } = {},
) {
  const receipt = validatePromotionReceipt(
    parseJson(
      readFileSync(
        regularFile(resolve(receiptPath), "release promotion receipt"),
        "utf8",
      ),
      "release promotion receipt",
    ),
  );
  const current = lookupRelease(client, receipt);
  if (!sameIdentity(receipt.identity, current.identity)) {
    throw new Error("release changed after its promotion audit");
  }

  try {
    const latest = lookupRelease(client, receipt, { latest: true });
    if (sameIdentity(receipt.identity, latest.identity)) {
      return { promoted: true, promotionApplied: false };
    }
  } catch {
    // No exact latest release yet; the audited mutation below is required.
  }

  const result = client.run(
    [
      "release",
      "edit",
      receipt.tag,
      "--repo",
      DOMAIN_CORE_REPOSITORY,
      "--latest",
    ],
    { allowFailure: true },
  );
  let latest;
  try {
    latest = lookupRelease(client, receipt, { latest: true });
  } catch (error) {
    if (result.status !== 0) {
      const detail = (
        result.stderr ||
        result.stdout ||
        "unknown failure"
      ).trim();
      throw new Error(`latest promotion failed: ${detail}; ${error.message}`);
    }
    throw error;
  }
  if (!sameIdentity(receipt.identity, latest.identity)) {
    throw new Error(
      "GitHub latest release is not the unchanged audited release",
    );
  }
  return { promoted: true, promotionApplied: result.status === 0 };
}

export function promoteAuditedRollbackTarget(
  receiptPath,
  { client = createGhClient() } = {},
) {
  const receipt = validateRollbackTargetReceipt(
    parseJson(
      readFileSync(
        regularFile(resolve(receiptPath), "rollback target receipt"),
        "utf8",
      ),
      "rollback target receipt",
    ),
  );
  const current = lookupRollbackTargetRelease(client, receipt);
  if (!sameIdentity(receipt.identity, current.identity)) {
    throw new Error("rollback target changed after its audit");
  }

  try {
    const latest = lookupRollbackTargetRelease(client, receipt, {
      latest: true,
    });
    if (sameIdentity(receipt.identity, latest.identity)) {
      return { promoted: true, promotionApplied: false };
    }
  } catch {
    // The audited rollback target is not latest yet.
  }

  const result = client.run(
    [
      "release",
      "edit",
      receipt.tag,
      "--repo",
      DOMAIN_CORE_REPOSITORY,
      "--latest",
    ],
    { allowFailure: true },
  );
  let latest;
  try {
    latest = lookupRollbackTargetRelease(client, receipt, { latest: true });
  } catch (error) {
    if (result.status !== 0) {
      const detail = (
        result.stderr ||
        result.stdout ||
        "unknown failure"
      ).trim();
      throw new Error(
        `rollback latest promotion failed: ${detail}; ${error.message}`,
      );
    }
    throw error;
  }
  if (!sameIdentity(receipt.identity, latest.identity)) {
    throw new Error(
      "GitHub latest release is not the unchanged audited rollback target",
    );
  }
  return { promoted: true, promotionApplied: result.status === 0 };
}

function parseArguments(argv) {
  const command = argv[0];
  const required =
    command === "audit"
      ? [
          "--tag",
          "--commit",
          "--notes",
          "--asset-dir",
          "--receipt",
          "--domain-core-profile",
        ]
      : command === "promote"
        ? ["--receipt"]
        : command === "promote-rollback-target"
          ? ["--receipt"]
          : command === "audit-rollback-target"
            ? ["--tag", "--commit", "--asset-dir", "--receipt"]
            : null;
  if (!required || argv.length !== 1 + required.length * 2) {
    throw new Error(
      "usage: audit --tag TAG --commit SHA --notes PATH --asset-dir DIR --receipt PATH --domain-core-profile PROFILE | promote --receipt PATH | audit-rollback-target --tag TAG --commit SHA --asset-dir DIR --receipt PATH | promote-rollback-target --receipt PATH",
    );
  }
  const values = new Map();
  for (let index = 1; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.includes(flag) || values.has(flag) || !value) {
      throw new Error(`invalid promotion argument: ${String(flag)}`);
    }
    values.set(flag, value);
  }
  return { command, values };
}

export function run(argv) {
  const { command, values } = parseArguments(argv);
  const result =
    command === "audit"
      ? auditExistingRelease({
          tag: values.get("--tag"),
          commit: values.get("--commit"),
          notesPath: values.get("--notes"),
          assetDirectory: values.get("--asset-dir"),
          receiptPath: values.get("--receipt"),
          domainCoreProfile: values.get("--domain-core-profile"),
        })
      : command === "promote"
        ? promoteAuditedRelease(values.get("--receipt"))
        : command === "promote-rollback-target"
          ? promoteAuditedRollbackTarget(values.get("--receipt"))
          : auditRollbackTargetRelease({
              tag: values.get("--tag"),
              commit: values.get("--commit"),
              assetDirectory: values.get("--asset-dir"),
              receiptPath: values.get("--receipt"),
            });
  const printable =
    command === "audit" || command === "audit-rollback-target"
      ? { audited: true, receiptPath: result.receiptPath }
      : result;
  process.stdout.write(`${JSON.stringify({ ok: true, ...printable })}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
