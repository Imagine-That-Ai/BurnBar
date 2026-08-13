#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
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
import { parseAppleSigningPolicy } from "./verify-domain-core-apple-signing-identity.mjs";
import { validateManifest } from "./publish-domain-core-release-evidence.mjs";

const COMMIT = /^[0-9a-f]{40}$/u;
const STABLE_TAG =
  /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const OIDC_ISSUER = "https://token.actions.githubusercontent.com";
const RECEIPT_SCHEMA_VERSION = 1;
const APPLE_SIGNING_POLICY = parseAppleSigningPolicy(
  readFileSync(
    new URL("../../config/apple-release-signing-policy.json", import.meta.url),
    "utf8",
  ),
);

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
    "developer-id-signing-receipt.json",
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
    "developer-id-signing-receipt.json",
    `sbom-v${version}.spdx.json`,
    `openburnbar-v${version}.vex.json`,
    `NOTICES-v${version}.txt`,
    "release-metadata.json",
  ]);

  for (const subject of generalProvenanceSubjects(version)) {
    required.add(`${subject}.predicate.json`);
    required.add(`${subject}.sigstore.json`);
  }
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

function requiredPath(downloads, name) {
  const path = downloads.get(name);
  if (!path) throw new Error(`required downloaded release asset is missing: ${name}`);
  return path;
}

function verifyChecksums(version, downloads) {
  const names = [
    `OpenBurnBar-${version}-macOS.dmg`,
    `OpenBurnBar-${version}-macOS.zip`,
    `OpenBurnBar-${version}-corresponding-source.tar.gz`,
    "appcast.xml",
    "latest-macos.json",
    `OpenBurnBar-${version}-legacy-rollback.zip`,
    "developer-id-signing-receipt.json",
  ];
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

function verifyUpdateMetadata(expected, downloads) {
  const dmgName = `OpenBurnBar-${expected.version}-macOS.dmg`;
  const dmgPath = requiredPath(downloads, dmgName);
  const dmg = fileRecord(dmgPath);
  const latest = objectValue(
    parseJson(
      readFileSync(requiredPath(downloads, "latest-macos.json"), "utf8"),
      "latest-macos.json",
    ),
    "latest-macos.json",
  );
  if (
    latest.version !== expected.version ||
    latest.commit !== expected.commit ||
    latest.dmg !== dmgName ||
    latest.zip !== `OpenBurnBar-${expected.version}-macOS.zip` ||
    latest.correspondingSource !==
      `OpenBurnBar-${expected.version}-corresponding-source.tar.gz` ||
    latest.length !== dmg.size ||
    latest.sha256 !== dmg.sha256 ||
    typeof latest.sparkleEdSignature !== "string" ||
    latest.sparkleEdSignature.length === 0
  ) {
    throw new Error("latest-macos.json does not bind the exact audited release");
  }

  const appcast = readFileSync(
    requiredPath(downloads, "appcast.xml"),
    "utf8",
  );
  if (
    !appcast.includes(
      `<sparkle:shortVersionString>${expected.version}</sparkle:shortVersionString>`,
    ) ||
    !appcast.includes(`sparkle:edSignature="${latest.sparkleEdSignature}"`)
  ) {
    throw new Error("appcast.xml does not match the exact signed update metadata");
  }

  const metadata = objectValue(
    parseJson(
      readFileSync(requiredPath(downloads, "release-metadata.json"), "utf8"),
      "release-metadata.json",
    ),
    "release-metadata.json",
  );
  const signingReceiptName = "developer-id-signing-receipt.json";
  if (
    metadata.version !== expected.version ||
    metadata.tag !== expected.tag ||
    metadata.commit !== expected.commit ||
    metadata.channel !== "direct-download" ||
    metadata.correspondingSource !==
      `OpenBurnBar-${expected.version}-corresponding-source.tar.gz` ||
    metadata.appcast !== "appcast.xml" ||
    metadata.latestMetadata !== "latest-macos.json" ||
    metadata.developerIdSigningReceipt !== signingReceiptName ||
    metadata.sparkleEdSignaturePresent !== true
  ) {
    throw new Error("release-metadata.json does not bind the exact release");
  }

  const signingReceipt = objectValue(
    parseJson(
      readFileSync(requiredPath(downloads, signingReceiptName), "utf8"),
      signingReceiptName,
    ),
    signingReceiptName,
  );
  exactObject(
    signingReceipt,
    [
      "appGroup",
      "distribution",
      "host",
      "keychainGroup",
      "safariExtension",
      "schemaVersion",
      "signingCertificateSha1",
      "signingIdentity",
      "teamId",
      "verification",
    ],
    signingReceiptName,
  );
  const hostSigning = exactObject(
    signingReceipt.host,
    ["bundleIdentifier", "profileExpiration", "profileSha256", "signature"],
    `${signingReceiptName} host`,
  );
  const safariSigning = exactObject(
    signingReceipt.safariExtension,
    ["bundleIdentifier", "profileExpiration", "profileSha256", "signature"],
    `${signingReceiptName} Safari extension`,
  );
  const hostSignature = exactObject(
    hostSigning.signature,
    [
      "authority",
      "hardenedRuntime",
      "libraryValidation",
      "secureTimestamp",
    ],
    `${signingReceiptName} host signature`,
  );
  const safariSignature = exactObject(
    safariSigning.signature,
    ["authority", "hardenedRuntime", "libraryValidation"],
    `${signingReceiptName} Safari extension signature`,
  );
  const signingVerification = exactObject(
    signingReceipt.verification,
    [
      "embeddedProfilesByteEqual",
      "getTaskAllow",
      "platform",
      "profileCertificateMembership",
      "signingCertificateSha1Matched",
      "strictDeepNestedSignatures",
    ],
    `${signingReceiptName} verification`,
  );
  const expectedSigningVerification = {
    embeddedProfilesByteEqual: true,
    getTaskAllow: false,
    platform: "OSX",
    profileCertificateMembership: true,
    signingCertificateSha1Matched: true,
    strictDeepNestedSignatures: true,
  };
  if (
    signingReceipt.schemaVersion !== 1 ||
    signingReceipt.distribution !== "developer-id" ||
    signingReceipt.teamId !== APPLE_SIGNING_POLICY.teamIdentifier ||
    signingReceipt.signingIdentity !== APPLE_SIGNING_POLICY.authority ||
    signingReceipt.signingCertificateSha1 !==
      APPLE_SIGNING_POLICY.certificateSha1 ||
    signingReceipt.appGroup !== "group.com.openburnbar.app" ||
    signingReceipt.keychainGroup !==
      `${APPLE_SIGNING_POLICY.teamIdentifier}.com.openburnbar.app` ||
    hostSigning.bundleIdentifier !== "com.openburnbar.app" ||
    safariSigning.bundleIdentifier !==
      "com.openburnbar.app.safari-extension" ||
    !/^[0-9a-f]{64}$/u.test(hostSigning.profileSha256) ||
    !/^[0-9a-f]{64}$/u.test(safariSigning.profileSha256) ||
    typeof hostSigning.profileExpiration !== "string" ||
    !hostSigning.profileExpiration.endsWith("Z") ||
    typeof safariSigning.profileExpiration !== "string" ||
    !safariSigning.profileExpiration.endsWith("Z") ||
    hostSignature.authority !== "Developer ID Application" ||
    hostSignature.hardenedRuntime !== true ||
    hostSignature.libraryValidation !== true ||
    hostSignature.secureTimestamp !== true ||
    safariSignature.authority !== "Developer ID Application" ||
    safariSignature.hardenedRuntime !== true ||
    safariSignature.libraryValidation !== true ||
    Object.entries(expectedSigningVerification).some(
      ([key, value]) => signingVerification[key] !== value,
    )
  ) {
    throw new Error(
      "developer-id-signing-receipt.json does not bind the protected Developer ID signer",
    );
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
    return;
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
}

function verifiedPredicates(client, expected, consumer, artifactPath, bundlePath) {
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
  const output = writeReceipt(
    receiptPath,
    receiptContents(expected, final),
  );
  return { expected, release: final, downloads, receiptPath: output };
}

function validateReceipt(raw) {
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
    throw new Error("release promotion receipt assets must be unique and sorted");
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
  const receipt = validateReceipt(
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
      const detail = (result.stderr || result.stdout || "unknown failure").trim();
      throw new Error(
        `latest promotion failed: ${detail}; ${error.message}`,
      );
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
        : null;
  if (!required || argv.length !== 1 + required.length * 2) {
    throw new Error(
      "usage: audit --tag TAG --commit SHA --notes PATH --asset-dir DIR --receipt PATH --domain-core-profile PROFILE | promote --receipt PATH",
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
      : promoteAuditedRelease(values.get("--receipt"));
  const printable =
    command === "audit"
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
