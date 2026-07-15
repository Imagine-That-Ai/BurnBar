#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { fileURLToPath } from "node:url";

import {
  DOMAIN_CORE_PROMOTION_PREDICATE_TYPE,
  DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW,
  DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
  DOMAIN_CORE_REPOSITORY,
  DOMAIN_CORE_SOURCE_WORKFLOW,
  RELEASE_CONSUMERS,
  canonicalSha256,
  exactObject,
  expectedArtifactName,
  regularFile,
  safeAssetName,
  sha256File,
  validateDomainCoreCandidateIdentity,
  validateReleaseActivation,
} from "../lib/domain-core-release-evidence.mjs";
import { validateAndroidUniversalManifest } from "./verify-domain-core-android-universal-artifact.mjs";

const OIDC_ISSUER = "https://token.actions.githubusercontent.com";
const SHA256 = /^[0-9a-f]{64}$/u;
const FULL_SHA = /^[0-9a-f]{40}$/u;
const STABLE_VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const APPLE_ANDROID_VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const NATIVE_CONSUMERS = new Set(["apple", "android", "ios", "windows"]);
const RELEASE_STATES = new Set(["published", "draft-then-publish"]);
const FINAL_ABSENCE_ROWS = Object.freeze({
  "apple/quota": [
    "quota.anthropic_headers",
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
  ],
  "apple/cloudVault": ["cloudvault.portable_primitives"],
  "apple/cloudVaultRewrap": ["cloudvault.document_rewrap"],
  "apple/cloudVaultSearch": ["cloudvault.search"],
  "apple/hermes": ["hermes.ratchet_transforms", "hermes.relay_crypto"],
  "apple/pricing": ["pricing.token_cost"],
  "ios/cloudVault": ["cloudvault.portable_primitives"],
  "ios/cloudVaultRewrap": ["cloudvault.document_rewrap"],
  "ios/cloudVaultSearch": ["cloudvault.search"],
  "ios/hermes": ["hermes.ratchet_transforms", "hermes.relay_crypto"],
  "android/cloudVault": ["cloudvault.portable_primitives"],
  "android/cloudVaultRewrap": ["cloudvault.document_rewrap"],
  "android/cloudVaultSearch": ["cloudvault.search"],
  "android/hermes": ["hermes.ratchet_transforms", "hermes.relay_crypto"],
  "windows/quota": [
    "quota.anthropic_headers",
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
  ],
  "windows/cloudVault": ["cloudvault.portable_primitives"],
  "linux/quota": [
    "quota.anthropic_headers",
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
  ],
  "linux/cloudVault": ["cloudvault.portable_primitives"],
  "linux/cloudVaultRewrap": ["cloudvault.document_rewrap"],
  "linux/cloudVaultSearch": ["cloudvault.search"],
  "linux/hermes": ["hermes.ratchet_transforms", "hermes.relay_crypto"],
  "linux/pricing": ["pricing.token_cost"],
  "console/cloudVault": ["cloudvault.portable_primitives"],
  "functions/pricing": ["pricing.kimi_historical", "pricing.token_cost"],
});

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

function positiveInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${label} must be a positive safe integer`);
  }
  return value;
}

function digest(value, label) {
  if (typeof value !== "string" || !SHA256.test(value)) {
    throw new Error(`${label} must be a lowercase SHA-256 digest`);
  }
  return value;
}

function validateActivationBinding(value, candidate, releaseCommit, label) {
  const activation = exactObject(
    value,
    [
      "candidateCommit",
      "activationCommit",
      "coreVersion",
      "abiVersion",
      "sourceSha256",
      "changedPathsSha256",
    ],
    label,
  );
  if (
    activation.candidateCommit !== candidate.candidateCommit ||
    activation.coreVersion !== candidate.coreVersion ||
    activation.abiVersion !== candidate.abiVersion ||
    activation.sourceSha256 !== candidate.sourceSha256 ||
    !FULL_SHA.test(activation.activationCommit) ||
    !FULL_SHA.test(releaseCommit)
  ) {
    throw new Error(
      `${label} activation commit does not bind candidate C to release activation P`,
    );
  }
  digest(activation.changedPathsSha256, `${label} changed paths`);
  return activation;
}

function validateLegacyAbsence(
  value,
  { activation, artifact, artifactPath, consumer, releaseCommit, domain },
) {
  const absence = exactObject(
    value,
    [
      "schemaVersion",
      "predicateType",
      "releaseCommit",
      "authorityActivationCommit",
      "deletionInventorySha256",
      "rowIds",
      "artifactScan",
    ],
    `predicate legacy absence for ${domain}`,
  );
  if (
    absence.schemaVersion !== 1 ||
    absence.predicateType !==
      "https://openburnbar.dev/attestations/domain-core-final-legacy-absence/v1" ||
    absence.releaseCommit !== releaseCommit ||
    absence.authorityActivationCommit !== activation.activationCommit ||
    absence.authorityActivationCommit === absence.releaseCommit ||
    !SHA256.test(absence.deletionInventorySha256) ||
    !Array.isArray(absence.rowIds) ||
    absence.rowIds.length === 0 ||
    absence.rowIds.some(
      (rowId) =>
        typeof rowId !== "string" || !/^[a-z][a-z0-9_.-]*$/u.test(rowId),
    ) ||
    JSON.stringify(absence.rowIds) !==
      JSON.stringify(FINAL_ABSENCE_ROWS[`${consumer}/${domain}`] ?? [])
  ) {
    throw new Error(
      `predicate legacy absence for ${domain} does not bind release D to authority P`,
    );
  }
  const scan = exactObject(
    absence.artifactScan,
    [
      "reportSha256",
      "artifactSha256",
      "ruleSetSha256",
      "inspectedMemberCount",
      "report",
    ],
    `predicate artifact scan for ${domain}`,
  );
  const report = exactObject(
    scan.report,
    [
      "schemaVersion",
      "consumer",
      "artifact",
      "ruleSetSha256",
      "inspectedMembers",
      "matches",
      "result",
    ],
    `predicate artifact scan report for ${domain}`,
  );
  const reportArtifact = exactObject(
    report.artifact,
    ["fileName", "sha256", "size"],
    `predicate scanned artifact for ${domain}`,
  );
  if (!Array.isArray(report.inspectedMembers)) {
    throw new Error(
      `predicate artifact scan for ${domain} has invalid inspected members`,
    );
  }
  const members = report.inspectedMembers.map((rawMember, index) => {
    const member = exactObject(
      rawMember,
      ["path", "sha256", "size", "matches"],
      `predicate artifact scan member ${index} for ${domain}`,
    );
    if (
      typeof member.path !== "string" ||
      member.path.length === 0 ||
      !SHA256.test(member.sha256) ||
      !Number.isSafeInteger(member.size) ||
      member.size < 0 ||
      !Array.isArray(member.matches) ||
      member.matches.length !== 0
    ) {
      throw new Error(
        `predicate artifact scan member ${index} for ${domain} is invalid`,
      );
    }
    return member;
  });
  if (
    report.schemaVersion !== 1 ||
    report.consumer !== consumer ||
    report.result !== "absent" ||
    !Array.isArray(report.matches) ||
    report.matches.length !== 0 ||
    members.length === 0 ||
    reportArtifact.fileName !== artifact.fileName ||
    reportArtifact.sha256 !== artifact.sha256 ||
    reportArtifact.size !== readFileSync(artifactPath).length ||
    !SHA256.test(report.ruleSetSha256) ||
    scan.reportSha256 !== canonicalSha256(report) ||
    scan.artifactSha256 !== artifact.sha256 ||
    scan.ruleSetSha256 !== report.ruleSetSha256 ||
    scan.inspectedMemberCount !== members.length
  ) {
    throw new Error(
      `predicate artifact scan for ${domain} does not bind exact clean release bytes`,
    );
  }
  return absence;
}

function validatePredicate(
  predicate,
  manifest,
  contract,
  domain,
  artifactPath,
) {
  const predicateKeys = [
    "schemaVersion",
    "predicateType",
    "consumer",
    "domain",
    "artifactKind",
    "target",
    "candidate",
    "sourceRun",
    "promotionProof",
    "rollbackArtifact",
    "activation",
    "publicProfile",
    "artifact",
    "release",
  ];
  if (manifest.consumer === "android") predicateKeys.push("androidUniversal");
  if (Object.hasOwn(predicate ?? {}, "legacyAbsence"))
    predicateKeys.push("legacyAbsence");
  const value = exactObject(
    predicate,
    predicateKeys,
    `predicate for ${domain}`,
  );
  const candidate = validateDomainCoreCandidateIdentity(value.candidate);
  const activation = validateActivationBinding(
    value.activation,
    candidate,
    manifest.commit,
    `predicate activation for ${domain}`,
  );
  if (
    Object.hasOwn(value, "legacyAbsence") !==
    (activation.activationCommit !== manifest.commit)
  ) {
    throw new Error(
      `predicate for ${domain} must carry final legacy absence exactly when release D follows activation P`,
    );
  }
  if (
    value.schemaVersion !== 2 ||
    value.predicateType !== DOMAIN_CORE_RELEASE_PREDICATE_TYPE ||
    value.consumer !== manifest.consumer ||
    value.domain !== domain ||
    value.artifactKind !== contract.artifactKind ||
    value.target !== contract.target
  ) {
    throw new Error(
      `predicate for ${domain} does not match its consumer contract`,
    );
  }
  if (manifest.consumer === "android") {
    const androidUniversal = exactObject(
      value.androidUniversal,
      [
        "manifestSha256",
        "schemaVersion",
        "target",
        "library",
        "candidateAar",
        "abis",
      ],
      `Android universal identity for ${domain}`,
    );
    digest(
      androidUniversal.manifestSha256,
      `Android universal manifest for ${domain}`,
    );
    const abiManifest = structuredClone(androidUniversal);
    delete abiManifest.manifestSha256;
    validateAndroidUniversalManifest(abiManifest);
  }
  const release = exactObject(
    value.release,
    ["version", "tag", "commit", "publicProfileSha256"],
    `predicate release for ${domain}`,
  );
  const version = manifest.tag.replace(/^(?:windows-)?v/u, "");
  const versionPattern = new Set(["apple", "android", "ios"]).has(
    manifest.consumer,
  )
    ? APPLE_ANDROID_VERSION
    : STABLE_VERSION;
  if (
    !versionPattern.test(release.version) ||
    release.version !== version ||
    release.tag !== manifest.tag ||
    release.commit !== manifest.commit
  ) {
    throw new Error(
      `predicate for ${domain} does not bind the exact activation tag commit`,
    );
  }
  validateReleaseActivation(value.activation, {
    candidate,
    releaseCommit: manifest.commit,
  });
  digest(release.publicProfileSha256, `predicate public profile for ${domain}`);
  const publicProfile = exactObject(
    value.publicProfile,
    ["profile", "domain", "mode", "sha256"],
    `predicate public profile object for ${domain}`,
  );
  if (
    publicProfile.profile !== "public-production" ||
    publicProfile.domain !== domain ||
    publicProfile.mode !== "rust" ||
    publicProfile.sha256 !== release.publicProfileSha256
  ) {
    throw new Error(
      `predicate for ${domain} does not bind its Rust-active public profile`,
    );
  }
  const sourceRun = exactObject(
    value.sourceRun,
    [
      "repository",
      "workflowPath",
      "runId",
      "runAttempt",
      "event",
      "ref",
      "headSha",
    ],
    `predicate source run for ${domain}`,
  );
  if (
    sourceRun.repository !== DOMAIN_CORE_REPOSITORY ||
    sourceRun.workflowPath !== DOMAIN_CORE_SOURCE_WORKFLOW ||
    sourceRun.event !== "push" ||
    sourceRun.ref !== "refs/heads/main" ||
    sourceRun.headSha !== candidate.candidateCommit
  ) {
    throw new Error(
      `predicate for ${domain} has an invalid deterministic source run`,
    );
  }
  positiveInteger(sourceRun.runId, `predicate source run ID for ${domain}`);
  positiveInteger(
    sourceRun.runAttempt,
    `predicate source run attempt for ${domain}`,
  );
  const promotionProof = exactObject(
    value.promotionProof,
    [
      "signerWorkflow",
      "predicateType",
      "signerRun",
      "attestationSubject",
      "attestationBundleSha256",
    ],
    `predicate promotion proof for ${domain}`,
  );
  const signerRun = exactObject(
    promotionProof.signerRun,
    ["runId", "runAttempt"],
    `predicate promotion signer run for ${domain}`,
  );
  const attestationSubject = exactObject(
    promotionProof.attestationSubject,
    ["fileName", "sha256"],
    `predicate promotion subject for ${domain}`,
  );
  if (
    promotionProof.signerWorkflow !== DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW ||
    promotionProof.predicateType !== DOMAIN_CORE_PROMOTION_PREDICATE_TYPE ||
    attestationSubject.fileName !== "domain-core-candidate-bundle.json"
  ) {
    throw new Error(
      `predicate for ${domain} does not bind the protected promotion proof`,
    );
  }
  digest(
    attestationSubject.sha256,
    `predicate promotion subject for ${domain}`,
  );
  digest(
    promotionProof.attestationBundleSha256,
    `predicate promotion attestation bundle for ${domain}`,
  );
  positiveInteger(
    signerRun.runId,
    `predicate promotion signer run ID for ${domain}`,
  );
  positiveInteger(
    signerRun.runAttempt,
    `predicate promotion signer run attempt for ${domain}`,
  );
  const rollbackArtifact = exactObject(
    value.rollbackArtifact,
    ["fileName", "sha256", "candidate", "activation"],
    `predicate rollback artifact for ${domain}`,
  );
  if (
    !isDeepStrictEqual(
      validateDomainCoreCandidateIdentity(rollbackArtifact.candidate),
      candidate,
    ) ||
    !isDeepStrictEqual(
      validateActivationBinding(
        rollbackArtifact.activation,
        candidate,
        manifest.commit,
        `predicate rollback activation for ${domain}`,
      ),
      activation,
    )
  ) {
    throw new Error(
      `predicate for ${domain} does not bind a candidate-matched rollback artifact`,
    );
  }
  safeAssetName(
    rollbackArtifact.fileName,
    `predicate rollback artifact for ${domain}`,
  );
  digest(rollbackArtifact.sha256, `predicate rollback artifact for ${domain}`);
  const artifact = exactObject(
    value.artifact,
    ["fileName", "sha256"],
    `predicate artifact for ${domain}`,
  );
  const expectedArtifact = {
    fileName: basename(artifactPath),
    sha256: sha256File(artifactPath),
  };
  safeAssetName(artifact.fileName, `predicate artifact for ${domain}`);
  digest(artifact.sha256, `predicate artifact for ${domain}`);
  if (!isDeepStrictEqual(artifact, expectedArtifact)) {
    throw new Error(
      `predicate for ${domain} does not bind the exact release artifact bytes`,
    );
  }
  if (Object.hasOwn(value, "legacyAbsence")) {
    validateLegacyAbsence(value.legacyAbsence, {
      activation,
      artifact,
      artifactPath,
      consumer: manifest.consumer,
      releaseCommit: manifest.commit,
      domain,
    });
  }
  return value;
}

export function validateManifest(raw) {
  const optionalKeys = ["releaseState", "nativeArtifactOnly"].filter((key) =>
    Object.hasOwn(raw ?? {}, key),
  );
  const manifest = exactObject(
    raw,
    [
      "schemaVersion",
      "repository",
      "tag",
      "commit",
      "consumer",
      "signerWorkflow",
      "artifactPath",
      "bundles",
      ...optionalKeys,
    ],
    "publication manifest",
  );
  if (manifest.schemaVersion !== 2) {
    throw new Error("publication manifest schemaVersion must be 2");
  }
  if (manifest.repository !== DOMAIN_CORE_REPOSITORY) {
    throw new Error(`publication repository must be ${DOMAIN_CORE_REPOSITORY}`);
  }
  const contract = RELEASE_CONSUMERS[manifest.consumer];
  if (!contract || manifest.signerWorkflow !== contract.signerWorkflow) {
    throw new Error(
      "publication consumer does not match its exact signer workflow",
    );
  }
  if (!/^[0-9a-f]{40}$/u.test(manifest.commit)) {
    throw new Error("publication commit must be a full lowercase Git SHA-1");
  }
  const releaseState = manifest.releaseState ?? "published";
  const nativeArtifactOnly = manifest.nativeArtifactOnly ?? false;
  if (!RELEASE_STATES.has(releaseState)) {
    throw new Error(
      "publication releaseState must be published or draft-then-publish",
    );
  }
  if (typeof nativeArtifactOnly !== "boolean") {
    throw new Error("publication nativeArtifactOnly must be a boolean");
  }
  if (
    (releaseState === "draft-then-publish" &&
      !NATIVE_CONSUMERS.has(manifest.consumer)) ||
    (nativeArtifactOnly && !NATIVE_CONSUMERS.has(manifest.consumer))
  ) {
    throw new Error(
      "native publication controls do not match the publication consumer",
    );
  }
  const version = manifest.tag?.replace(/^(?:windows-)?v/u, "");
  const expectedTag =
    manifest.consumer === "windows" ? `windows-v${version}` : `v${version}`;
  if (!version || manifest.tag !== expectedTag) {
    throw new Error(
      "publication tag does not match its consumer release train",
    );
  }
  const artifactPath = regularFile(
    manifest.artifactPath,
    "publication artifact",
  );
  const artifactAssetName = safeAssetName(
    basename(artifactPath),
    "publication artifact basename",
  );
  if (artifactAssetName !== expectedArtifactName(manifest.consumer, version)) {
    throw new Error(
      `publication artifact must be named ${expectedArtifactName(manifest.consumer, version)}`,
    );
  }
  if (!Array.isArray(manifest.bundles)) {
    throw new Error("publication manifest bundles must be an array");
  }
  if (nativeArtifactOnly !== (manifest.bundles.length === 0)) {
    throw new Error(
      "nativeArtifactOnly must be true exactly when no attestation bundles exist",
    );
  }
  const seenAssets = new Set([artifactAssetName]);
  const seenDomains = new Set();
  let canonicalPredicateBindings = null;
  const bundles = manifest.bundles.map((rawBundle, index) => {
    const bundle = exactObject(
      rawBundle,
      ["domain", "assetName", "bundlePath", "predicatePath"],
      `bundles[${index}]`,
    );
    if (
      !contract.domains.includes(bundle.domain) ||
      seenDomains.has(bundle.domain)
    ) {
      throw new Error(
        `invalid or duplicate ${manifest.consumer} domain: ${String(bundle.domain)}`,
      );
    }
    seenDomains.add(bundle.domain);
    const assetName = safeAssetName(
      bundle.assetName,
      `bundles[${index}].assetName`,
    );
    if (seenAssets.has(assetName))
      throw new Error(`duplicate release asset name: ${assetName}`);
    seenAssets.add(assetName);
    const bundlePath = regularFile(
      bundle.bundlePath,
      `bundles[${index}].bundlePath`,
    );
    const predicatePath = regularFile(
      bundle.predicatePath,
      `bundles[${index}].predicatePath`,
    );
    const predicate = validatePredicate(
      objectValue(
        parseJson(
          readFileSync(predicatePath, "utf8"),
          `bundles[${index}] predicate`,
        ),
        `bundles[${index}] predicate`,
      ),
      manifest,
      contract,
      bundle.domain,
      artifactPath,
    );
    const predicateBindings = {
      candidate: predicate.candidate,
      sourceRun: predicate.sourceRun,
      promotionProof: predicate.promotionProof,
      rollbackArtifact: predicate.rollbackArtifact,
      release: predicate.release,
      legacyAbsence: predicate.legacyAbsence
        ? {
            schemaVersion: predicate.legacyAbsence.schemaVersion,
            predicateType: predicate.legacyAbsence.predicateType,
            releaseCommit: predicate.legacyAbsence.releaseCommit,
            authorityActivationCommit:
              predicate.legacyAbsence.authorityActivationCommit,
            deletionInventorySha256:
              predicate.legacyAbsence.deletionInventorySha256,
            artifactScan: predicate.legacyAbsence.artifactScan,
          }
        : null,
    };
    if (canonicalPredicateBindings === null) {
      canonicalPredicateBindings = predicateBindings;
    } else {
      for (const key of Object.keys(predicateBindings)) {
        if (
          !isDeepStrictEqual(
            predicateBindings[key],
            canonicalPredicateBindings[key],
          )
        ) {
          throw new Error(
            `predicate for ${bundle.domain} has a ${key} that differs from the first validated predicate for commit ${manifest.commit}`,
          );
        }
      }
    }
    return {
      domain: bundle.domain,
      assetName,
      bundlePath,
      predicatePath,
      predicate,
    };
  });
  return {
    schemaVersion: 2,
    repository: DOMAIN_CORE_REPOSITORY,
    tag: manifest.tag,
    commit: manifest.commit,
    consumer: manifest.consumer,
    signerWorkflow: manifest.signerWorkflow,
    releaseState,
    nativeArtifactOnly,
    artifactPath,
    artifactAssetName,
    bundles,
  };
}

export function createGhClient(runner = spawnSync) {
  return {
    run(args, { allowFailure = false } = {}) {
      const result = runner("gh", args, {
        encoding: "utf8",
        env: process.env,
        maxBuffer: 16 * 1024 * 1024,
      });
      if (result.error) throw result.error;
      if (result.status !== 0 && !allowFailure) {
        const detail = (
          result.stderr ||
          result.stdout ||
          "gh command failed"
        ).trim();
        throw new Error(`gh ${args.slice(0, 3).join(" ")} failed: ${detail}`);
      }
      return result;
    },
  };
}

export function verifyBundle(
  client,
  manifest,
  bundle,
  artifactPath,
  bundlePath,
) {
  const result = client.run([
    "attestation",
    "verify",
    artifactPath,
    "--bundle",
    bundlePath,
    "--repo",
    manifest.repository,
    "--signer-workflow",
    `${manifest.repository}/${manifest.signerWorkflow}`,
    "--source-digest",
    manifest.commit,
    "--source-ref",
    `refs/tags/${manifest.tag}`,
    "--signer-digest",
    manifest.commit,
    "--cert-oidc-issuer",
    OIDC_ISSUER,
    "--deny-self-hosted-runners",
    "--predicate-type",
    DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
    "--format",
    "json",
  ]);
  const verified = parseJson(result.stdout, "gh attestation verify");
  if (!Array.isArray(verified) || verified.length === 0) {
    throw new Error("gh attestation verify returned no verification results");
  }
  const exact = verified.some((entry) =>
    isDeepStrictEqual(
      entry?.verificationResult?.statement?.predicate,
      bundle.predicate,
    ),
  );
  if (!exact) {
    throw new Error(
      `verified bundle ${bundle.assetName} does not contain its exact predicate`,
    );
  }
}

function verifyPublishedBundle(
  client,
  manifest,
  bundle,
  artifactPath,
  actualBundlePath,
) {
  // Sigstore bundle encoding is nondeterministic; the verified statement is not.
  verifyBundle(client, manifest, bundle, artifactPath, actualBundlePath);
}

function requireReleaseState(client, manifest, allowedStates) {
  const result = client.run([
    "api",
    `repos/${manifest.repository}/releases/tags/${manifest.tag}`,
  ]);
  const release = objectValue(
    parseJson(result.stdout, "release lookup"),
    "release lookup",
  );
  const state = release.draft === true ? "draft" : "published";
  if (
    release.tag_name !== manifest.tag ||
    typeof release.draft !== "boolean" ||
    release.prerelease !== false ||
    !allowedStates.has(state)
  ) {
    throw new Error(
      `release evidence requires the exact ${[...allowedStates].join(
        " or ",
      )} stable release`,
    );
  }
  const resolvedCommit = objectValue(
    parseJson(
      client.run([
        "api",
        `repos/${manifest.repository}/commits/${encodeURIComponent(manifest.tag)}`,
      ]).stdout,
      "release tag commit lookup",
    ),
    "release tag commit lookup",
  );
  if (resolvedCommit.sha !== manifest.commit) {
    throw new Error(
      "published release tag does not resolve to the exact candidate commit",
    );
  }
  return state;
}

function publishDraft(client, manifest) {
  return client.run(
    [
      "release",
      "edit",
      manifest.tag,
      "--repo",
      manifest.repository,
      "--draft=false",
      "--prerelease=false",
      "--latest=false",
    ],
    { allowFailure: true },
  );
}

function releaseAssets(client, manifest) {
  const result = client.run([
    "release",
    "view",
    manifest.tag,
    "--repo",
    manifest.repository,
    "--json",
    "assets",
  ]);
  const value = objectValue(
    parseJson(result.stdout, "release assets"),
    "release assets",
  );
  if (!Array.isArray(value.assets))
    throw new Error("release asset listing must contain assets");
  const names = value.assets.map((asset) => asset?.name);
  if (
    names.some((name) => typeof name !== "string") ||
    new Set(names).size !== names.length
  ) {
    throw new Error(
      "release asset listing contains invalid or duplicate names",
    );
  }
  return new Set(names);
}

function downloadAsset(client, manifest, name, directory) {
  mkdirSync(directory, { recursive: true });
  const path = join(directory, name);
  rmSync(path, { force: true });
  client.run([
    "release",
    "download",
    manifest.tag,
    "--repo",
    manifest.repository,
    "--pattern",
    name,
    "--dir",
    directory,
  ]);
  return regularFile(path, `downloaded asset ${name}`);
}

function identical(first, second) {
  return readFileSync(first).equals(readFileSync(second));
}

function uploadCreateOnly(client, manifest, path) {
  return client.run(
    ["release", "upload", manifest.tag, path, "--repo", manifest.repository],
    { allowFailure: true },
  );
}

export function publishManifest(manifest, { client = createGhClient() } = {}) {
  const workspace = mkdtempSync(join(tmpdir(), "domain-core-release-"));
  try {
    const staged = join(workspace, "staged");
    mkdirSync(staged);
    const artifact = join(staged, manifest.artifactAssetName);
    copyFileSync(manifest.artifactPath, artifact);
    const stagedBundles = new Map();
    for (const bundle of manifest.bundles) {
      const path = join(staged, bundle.assetName);
      copyFileSync(bundle.bundlePath, path);
      stagedBundles.set(bundle.assetName, path);
      verifyBundle(client, manifest, bundle, artifact, path);
    }

    const initialState = requireReleaseState(
      client,
      manifest,
      manifest.releaseState === "draft-then-publish"
        ? new Set(["draft", "published"])
        : new Set(["published"]),
    );
    const assets = releaseAssets(client, manifest);
    const preflight = join(workspace, "preflight");

    // Complete every collision check before the first release mutation.
    if (assets.has(manifest.artifactAssetName)) {
      const existing = downloadAsset(
        client,
        manifest,
        manifest.artifactAssetName,
        preflight,
      );
      if (!identical(artifact, existing)) {
        throw new Error(
          `refusing to replace non-identical ${manifest.artifactAssetName}`,
        );
      }
    }
    for (const bundle of manifest.bundles) {
      if (assets.has(bundle.assetName)) {
        verifyPublishedBundle(
          client,
          manifest,
          bundle,
          artifact,
          downloadAsset(client, manifest, bundle.assetName, preflight),
        );
      }
    }

    if (
      initialState === "published" &&
      manifest.releaseState === "draft-then-publish"
    ) {
      const requiredAssets = [
        manifest.artifactAssetName,
        ...manifest.bundles.map((bundle) => bundle.assetName),
      ];
      const missing = requiredAssets.filter((name) => !assets.has(name));
      if (missing.length > 0) {
        throw new Error(
          `published Windows release is incomplete; missing immutable assets: ${missing.join(", ")}`,
        );
      }
    }

    const uploaded = [];
    for (const bundle of manifest.bundles) {
      if (assets.has(bundle.assetName)) continue;
      if (manifest.releaseState === "draft-then-publish") {
        requireReleaseState(client, manifest, new Set(["draft"]));
      }
      const result = uploadCreateOnly(
        client,
        manifest,
        stagedBundles.get(bundle.assetName),
      );
      if (result.status === 0) {
        uploaded.push(bundle.assetName);
      } else {
        verifyPublishedBundle(
          client,
          manifest,
          bundle,
          artifact,
          downloadAsset(client, manifest, bundle.assetName, preflight),
        );
      }
    }
    if (!assets.has(manifest.artifactAssetName)) {
      if (manifest.releaseState === "draft-then-publish") {
        requireReleaseState(client, manifest, new Set(["draft"]));
      }
      const result = uploadCreateOnly(client, manifest, artifact);
      if (result.status === 0) {
        uploaded.push(manifest.artifactAssetName);
      } else {
        const concurrent = downloadAsset(
          client,
          manifest,
          manifest.artifactAssetName,
          preflight,
        );
        if (!identical(artifact, concurrent)) {
          throw new Error(
            "concurrent immutable release artifact differs from local bytes",
          );
        }
      }
    }

    const final = join(workspace, "final");
    const finalArtifact = downloadAsset(
      client,
      manifest,
      manifest.artifactAssetName,
      final,
    );
    if (!identical(artifact, finalArtifact)) {
      throw new Error(
        "published artifact bytes differ from the signed local artifact",
      );
    }
    for (const bundle of manifest.bundles) {
      verifyPublishedBundle(
        client,
        manifest,
        bundle,
        finalArtifact,
        downloadAsset(client, manifest, bundle.assetName, final),
      );
    }
    if (manifest.releaseState === "draft-then-publish") {
      if (initialState === "draft") {
        const finalState = requireReleaseState(
          client,
          manifest,
          new Set(["draft", "published"]),
        );
        if (finalState === "draft") {
          publishDraft(client, manifest);
          requireReleaseState(client, manifest, new Set(["published"]));
        }
      } else {
        requireReleaseState(client, manifest, new Set(["published"]));
      }
    } else {
      requireReleaseState(client, manifest, new Set(["published"]));
    }
    return { uploaded };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

function parseArguments(argv) {
  if (argv.length !== 2 || argv[0] !== "--manifest" || !argv[1]) {
    throw new Error(
      "usage: publish-domain-core-release-evidence.mjs --manifest PATH",
    );
  }
  return resolve(argv[1]);
}

export function run(argv) {
  const manifest = validateManifest(
    parseJson(
      readFileSync(parseArguments(argv), "utf8"),
      "publication manifest",
    ),
  );
  const result = publishManifest(manifest);
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
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
