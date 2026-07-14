#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, isAbsolute, join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { pathToFileURL } from "node:url";

import {
  canonicalSha256,
  RELEASE_PREDICATE_TYPE,
  sha256File,
} from "./create-domain-core-release-evidence.mjs";

const REPOSITORY = "Imagine-That-Ai/BurnBar";
const OIDC_ISSUER = "https://token.actions.githubusercontent.com";
const ALLOWED_SIGNER_WORKFLOWS = new Set([
  ".github/workflows/release.yml",
  ".github/workflows/openburnbar-release-windows.yml",
  ".github/workflows/domain-core-console-release-evidence.yml",
  ".github/workflows/domain-core-functions-release-evidence.yml",
]);
const ASSET_NAME_PATTERN = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,254}$/;
const WINDOWS_SIGNER_WORKFLOW =
  ".github/workflows/openburnbar-release-windows.yml";
const CONSUMERS = Object.freeze({
  apple: {
    signerWorkflow: ".github/workflows/release.yml",
    artifactKind: "macos-dmg",
    target: "macos-arm64",
    domains: [
      "quota",
      "cloudVault",
      "cloudVaultRewrap",
      "cloudVaultSearch",
      "hermes",
      "pricing",
    ],
    fileName: (version) => `OpenBurnBar-${version}-macOS.dmg`,
  },
  android: {
    signerWorkflow: ".github/workflows/release.yml",
    artifactKind: "android-aab",
    target: "android-universal",
    domains: ["cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes"],
    fileName: (version) => `OpenBurnBar-${version}-Android.aab`,
  },
  windows: {
    signerWorkflow: WINDOWS_SIGNER_WORKFLOW,
    artifactKind: "windows-release-bundle",
    target: "windows-x64-arm64",
    domains: ["quota", "cloudVault"],
    fileName: (version) => `OpenBurnBar-${version}-windows-release.zip`,
  },
  console: {
    signerWorkflow:
      ".github/workflows/domain-core-console-release-evidence.yml",
    artifactKind: "console-deployment-receipt",
    target: "firebase-hosting-production",
    domains: ["cloudVault"],
    fileName: (version) => `OpenBurnBar-${version}-console-deployment.json`,
  },
  functions: {
    signerWorkflow:
      ".github/workflows/domain-core-functions-release-evidence.yml",
    artifactKind: "functions-deployment-receipt",
    target: "firebase-functions-production",
    domains: ["pricing"],
    fileName: (version) => `OpenBurnBar-${version}-functions-deployment.json`,
  },
});

function exactObject(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new Error(`${label} must contain exactly: ${expected.join(", ")}`);
  }
  return value;
}

function objectValue(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function regularFile(path, label) {
  if (!isAbsolute(path)) throw new Error(`${label} must be an absolute path`);
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error(`${label} must be a nonempty regular file, not a symlink`);
  }
  return resolve(path);
}

function assetName(value, label) {
  if (typeof value !== "string" || !ASSET_NAME_PATTERN.test(value)) {
    throw new Error(`${label} must be a safe release asset basename`);
  }
  return value;
}

export function validateManifest(raw) {
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
    ],
    "publication manifest",
  );
  if (manifest.schemaVersion !== 1)
    throw new Error("publication manifest schemaVersion must be 1");
  if (manifest.repository !== REPOSITORY)
    throw new Error(`publication repository must be ${REPOSITORY}`);
  if (
    typeof manifest.tag !== "string" ||
    !/^(?:windows-)?v\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/.test(manifest.tag)
  ) {
    throw new Error("publication tag must be an exact stable release tag");
  }
  if (
    typeof manifest.commit !== "string" ||
    !/^[0-9a-f]{40}$/.test(manifest.commit)
  ) {
    throw new Error("publication commit must be a full lowercase Git SHA");
  }
  if (!ALLOWED_SIGNER_WORKFLOWS.has(manifest.signerWorkflow)) {
    throw new Error("publication signer workflow is not allowlisted");
  }
  const consumer = CONSUMERS[manifest.consumer];
  if (!consumer || consumer.signerWorkflow !== manifest.signerWorkflow) {
    throw new Error("publication consumer does not match its signer workflow");
  }
  const version = manifest.tag.replace(/^(?:windows-)?v/, "");
  const expectedTag =
    manifest.consumer === "windows" ? `windows-v${version}` : `v${version}`;
  if (manifest.tag !== expectedTag) {
    throw new Error("publication tag train does not match its consumer");
  }
  const artifactPath = regularFile(manifest.artifactPath, "artifactPath");
  const artifactAssetName = assetName(
    basename(artifactPath),
    "artifact basename",
  );
  const expectedArtifactName = consumer.fileName(version);
  if (artifactAssetName !== expectedArtifactName) {
    throw new Error(
      `publication artifact must be named ${expectedArtifactName}`,
    );
  }
  const artifactSha256 = sha256File(artifactPath);
  if (!Array.isArray(manifest.bundles) || manifest.bundles.length === 0) {
    throw new Error("publication manifest must contain at least one bundle");
  }
  const seenAssets = new Set([artifactAssetName]);
  const seenDomains = new Set();
  const bundles = manifest.bundles.map((value, index) => {
    const bundle = exactObject(
      value,
      ["domain", "assetName", "bundlePath", "predicatePath"],
      `bundles[${index}]`,
    );
    const releaseAssetName = assetName(
      bundle.assetName,
      `bundles[${index}].assetName`,
    );
    if (seenAssets.has(releaseAssetName))
      throw new Error(`duplicate release asset name: ${releaseAssetName}`);
    seenAssets.add(releaseAssetName);
    if (
      !consumer.domains.includes(bundle.domain) ||
      seenDomains.has(bundle.domain)
    ) {
      throw new Error(
        `invalid or duplicate ${manifest.consumer} domain: ${bundle.domain}`,
      );
    }
    seenDomains.add(bundle.domain);
    const bundlePath = regularFile(
      bundle.bundlePath,
      `bundles[${index}].bundlePath`,
    );
    const predicatePath = regularFile(
      bundle.predicatePath,
      `bundles[${index}].predicatePath`,
    );
    const predicate = objectValue(
      JSON.parse(readFileSync(predicatePath, "utf8")),
      `bundles[${index}] predicate`,
    );
    const expectedPredicate = {
      schemaVersion: 1,
      consumer: manifest.consumer,
      artifactKind: consumer.artifactKind,
      target: consumer.target,
      artifact: { fileName: expectedArtifactName, sha256: artifactSha256 },
      release: {
        version,
        tag: manifest.tag,
        commit: manifest.commit,
        publicProfileSha256: canonicalSha256({
          artifactAuthority: "signed",
          distribution: "public",
          rolloutChannel: null,
          evidenceEnabled: false,
          domain: bundle.domain,
          mode: "rust",
        }),
      },
    };
    if (!isDeepStrictEqual(predicate, expectedPredicate)) {
      throw new Error(
        `bundles[${index}] predicate does not bind the exact release identity`,
      );
    }
    return {
      domain: bundle.domain,
      assetName: releaseAssetName,
      bundlePath,
      predicatePath,
      predicate,
    };
  });
  return {
    schemaVersion: 1,
    repository: REPOSITORY,
    tag: manifest.tag,
    commit: manifest.commit,
    consumer: manifest.consumer,
    signerWorkflow: manifest.signerWorkflow,
    artifactPath,
    artifactAssetName,
    bundles,
  };
}

function gh(args, { allowFailure = false } = {}) {
  const result = spawnSync("gh", args, {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && !allowFailure) {
    throw new Error(
      `gh ${args.slice(0, 3).join(" ")} failed: ${(result.stderr || result.stdout).trim()}`,
    );
  }
  return result;
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

function sleep(milliseconds) {
  if (milliseconds <= 0) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function verifyBundle(manifest, bundle, bundlePath) {
  const result = gh([
    "attestation",
    "verify",
    manifest.artifactPath,
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
    RELEASE_PREDICATE_TYPE,
    "--format",
    "json",
  ]);
  const verified = parseJson(result.stdout, "gh attestation verify");
  if (!Array.isArray(verified) || verified.length === 0) {
    throw new Error("gh attestation verify returned no verification results");
  }
  const predicates = verified
    .map((entry) => entry?.verificationResult?.statement?.predicate)
    .filter(
      (value) => value && typeof value === "object" && !Array.isArray(value),
    );
  if (
    !predicates.some((predicate) =>
      isDeepStrictEqual(predicate, bundle.predicate),
    )
  ) {
    throw new Error(
      `verified bundle ${bundle.assetName} does not contain its exact predicate`,
    );
  }
}

function waitForRelease(manifest, timeoutSeconds, pollSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (true) {
    const result = gh(
      ["api", `repos/${manifest.repository}/releases/tags/${manifest.tag}`],
      { allowFailure: true },
    );
    if (result.status === 0) {
      const release = objectValue(
        parseJson(result.stdout, "release lookup"),
        "release lookup",
      );
      if (release.tag_name !== manifest.tag || release.prerelease === true) {
        throw new Error(
          "release lookup returned a wrong-tag or prerelease release",
        );
      }
      if (release.draft === false) return;
    }
    if (Date.now() >= deadline) {
      throw new Error(
        `release ${manifest.tag} was not published before timeout`,
      );
    }
    sleep(pollSeconds * 1000);
  }
}

function releaseAssets(manifest) {
  const result = gh([
    "release",
    "view",
    manifest.tag,
    "--repo",
    manifest.repository,
    "--json",
    "assets",
  ]);
  const value = parseJson(result.stdout, "release asset listing");
  if (!value || typeof value !== "object" || !Array.isArray(value.assets)) {
    throw new Error("release asset listing must contain an assets array");
  }
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

function downloadAsset(manifest, name, directory) {
  mkdirSync(directory, { recursive: true });
  const path = join(directory, name);
  rmSync(path, { force: true });
  gh([
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
  regularFile(path, `downloaded asset ${name}`);
  return path;
}

function identicalFiles(first, second) {
  return readFileSync(first).equals(readFileSync(second));
}

export function publishManifest(
  manifest,
  { releaseTimeoutSeconds = 3600, pollSeconds = 30 } = {},
) {
  if (!Number.isInteger(releaseTimeoutSeconds) || releaseTimeoutSeconds < 0)
    throw new Error("releaseTimeoutSeconds must be a nonnegative integer");
  if (!Number.isInteger(pollSeconds) || pollSeconds < 0)
    throw new Error("pollSeconds must be a nonnegative integer");

  const workspace = mkdtempSync(
    join(tmpdir(), "domain-core-release-publisher-"),
  );
  try {
    const staged = join(workspace, "staged");
    mkdirSync(staged);
    const stagedArtifact = join(staged, manifest.artifactAssetName);
    copyFileSync(manifest.artifactPath, stagedArtifact);
    const publication = { ...manifest, artifactPath: stagedArtifact };
    const stagedBundles = new Map();
    for (const bundle of publication.bundles) {
      const stagedPath = join(staged, bundle.assetName);
      copyFileSync(bundle.bundlePath, stagedPath);
      stagedBundles.set(bundle.assetName, stagedPath);
      verifyBundle(publication, bundle, stagedPath);
    }

    waitForRelease(publication, releaseTimeoutSeconds, pollSeconds);
    const assets = releaseAssets(publication);
    const existing = join(workspace, "existing");

    if (assets.has(publication.artifactAssetName)) {
      const downloaded = downloadAsset(
        publication,
        publication.artifactAssetName,
        existing,
      );
      if (!identicalFiles(publication.artifactPath, downloaded)) {
        throw new Error(
          `refusing to replace non-identical immutable release asset ${publication.artifactAssetName}`,
        );
      }
    }
    for (const bundle of publication.bundles) {
      if (assets.has(bundle.assetName)) {
        verifyBundle(
          publication,
          bundle,
          downloadAsset(publication, bundle.assetName, existing),
        );
      }
    }

    const uploaded = [];
    for (const bundle of publication.bundles) {
      if (assets.has(bundle.assetName)) continue;
      const result = gh(
        [
          "release",
          "upload",
          publication.tag,
          stagedBundles.get(bundle.assetName),
          "--repo",
          publication.repository,
        ],
        { allowFailure: true },
      );
      if (result.status === 0) {
        uploaded.push(bundle.assetName);
      } else {
        verifyBundle(
          publication,
          bundle,
          downloadAsset(publication, bundle.assetName, existing),
        );
      }
    }

    if (!assets.has(publication.artifactAssetName)) {
      const result = gh(
        [
          "release",
          "upload",
          publication.tag,
          publication.artifactPath,
          "--repo",
          publication.repository,
        ],
        { allowFailure: true },
      );
      if (result.status === 0) {
        uploaded.push(publication.artifactAssetName);
      } else {
        const downloaded = downloadAsset(
          publication,
          publication.artifactAssetName,
          existing,
        );
        if (!identicalFiles(publication.artifactPath, downloaded)) {
          throw new Error(
            "concurrent immutable release artifact differs from local evidence",
          );
        }
      }
    }

    const published = join(workspace, "published");
    const publishedArtifact = downloadAsset(
      publication,
      publication.artifactAssetName,
      published,
    );
    if (!identicalFiles(publication.artifactPath, publishedArtifact)) {
      throw new Error(
        "published artifact bytes differ from the signed local artifact",
      );
    }
    for (const bundle of publication.bundles) {
      verifyBundle(
        publication,
        bundle,
        downloadAsset(publication, bundle.assetName, published),
      );
    }
    return { uploaded };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

function parseArguments(argv) {
  const result = { releaseTimeoutSeconds: 3600, pollSeconds: 30 };
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--"))
      throw new Error(`unexpected positional argument: ${argument}`);
    const value = argv[++index];
    if (!value || value.startsWith("--"))
      throw new Error(`${argument} requires a value`);
    if (argument === "--manifest") result.manifest = value;
    else if (argument === "--release-timeout-seconds")
      result.releaseTimeoutSeconds = Number(value);
    else if (argument === "--poll-seconds") result.pollSeconds = Number(value);
    else throw new Error(`unknown argument: ${argument}`);
  }
  if (!result.manifest) throw new Error("--manifest is required");
  return result;
}

export function main(argv = process.argv) {
  const arguments_ = parseArguments(argv);
  const manifest = validateManifest(
    JSON.parse(readFileSync(resolve(arguments_.manifest), "utf8")),
  );
  const result = publishManifest(manifest, arguments_);
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(
      `ERROR: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  }
}
