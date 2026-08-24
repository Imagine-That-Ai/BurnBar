#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DOMAIN_CORE_REPOSITORY,
  exactObject,
  regularFile,
  safeAssetName,
} from "../lib/domain-core-release-evidence.mjs";
import {
  validateManifest as validateEvidenceManifest,
  verifyBundle,
} from "./publish-domain-core-release-evidence.mjs";

const COMMIT = /^[0-9a-f]{40}$/u;
const TAG =
  /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)$/u;

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

function expectedKeys(value, keys, label) {
  return exactObject(value, keys, label);
}

function exactAsset(raw, label) {
  const value = expectedKeys(raw, ["path"], label);
  const path = regularFile(value.path, label);
  return { name: safeAssetName(basename(path), `${label} name`), path };
}

function evidenceAssets(manifest) {
  return manifest.bundles.map((bundle) => ({
    name: bundle.assetName,
    path: bundle.bundlePath,
    evidence: { manifest, bundle, artifactPath: manifest.artifactPath },
  }));
}

export function validateAppleAndroidPublication(raw) {
  const value = expectedKeys(
    raw,
    [
      "schemaVersion",
      "repository",
      "tag",
      "commit",
      "title",
      "notesPath",
      "prerelease",
      "promote",
      "apple",
      "android",
      "assets",
    ],
    "Apple and Android publication",
  );
  if (value.schemaVersion !== 1) {
    throw new Error("Apple and Android publication schemaVersion must be 1");
  }
  if (value.repository !== DOMAIN_CORE_REPOSITORY) {
    throw new Error(`publication repository must be ${DOMAIN_CORE_REPOSITORY}`);
  }
  const match = typeof value.tag === "string" ? TAG.exec(value.tag) : null;
  if (!match) throw new Error("publication tag must be canonical SemVer");
  if (typeof value.commit !== "string" || !COMMIT.test(value.commit)) {
    throw new Error("publication commit must be a full lowercase Git SHA");
  }
  if (
    typeof value.title !== "string" ||
    value.title !== `OpenBurnBar ${match[1]}`
  ) {
    throw new Error("publication title must match its exact version");
  }
  const notesPath = regularFile(value.notesPath, "release notes");
  const prerelease = match[1].split("+", 1)[0].includes("-");
  if (value.prerelease !== prerelease || typeof value.promote !== "boolean") {
    throw new Error("publication prerelease and promote controls are invalid");
  }
  if (prerelease && value.promote) {
    throw new Error("a prerelease cannot become latest");
  }

  const apple = validateEvidenceManifest(value.apple);
  const android = validateEvidenceManifest(value.android);
  if (
    apple.consumer !== "apple" ||
    android.consumer !== "android" ||
    apple.tag !== value.tag ||
    android.tag !== value.tag ||
    apple.commit !== value.commit ||
    android.commit !== value.commit
  ) {
    throw new Error("native evidence manifests must bind the exact release");
  }
  if (!Array.isArray(value.assets)) {
    throw new Error("publication assets must be an array");
  }
  const assets = [
    { name: apple.artifactAssetName, path: apple.artifactPath },
    { name: android.artifactAssetName, path: android.artifactPath },
    ...evidenceAssets(apple),
    ...evidenceAssets(android),
    ...value.assets.map((asset, index) =>
      exactAsset(asset, `assets[${index}]`),
    ),
  ];
  const names = assets.map((asset) => asset.name);
  if (new Set(names).size !== names.length) {
    throw new Error("publication asset names must be globally unique");
  }
  return {
    schemaVersion: 1,
    repository: DOMAIN_CORE_REPOSITORY,
    tag: value.tag,
    version: match[1],
    commit: value.commit,
    title: value.title,
    notesPath,
    notes: readFileSync(notesPath, "utf8"),
    prerelease,
    promote: value.promote,
    apple,
    android,
    assets,
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
        throw new Error(
          `gh command failed: ${(result.stderr || result.stdout || "unknown failure").trim()}`,
        );
      }
      return result;
    },
  };
}

function resolveTag(client, publication) {
  const result = client.run([
    "api",
    `repos/${publication.repository}/commits/${encodeURIComponent(publication.tag)}`,
  ]);
  const value = objectValue(
    parseJson(result.stdout, "tag lookup"),
    "tag lookup",
  );
  if (value.sha !== publication.commit) {
    throw new Error(
      "release tag does not resolve to the exact candidate commit",
    );
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
  return JSON.stringify({
    releaseID,
    assets: assets
      .map(({ id, name, size, digest }) => ({ id, name, size, digest }))
      .sort((left, right) => left.name.localeCompare(right.name)),
  });
}

function parseRelease(raw, publication) {
  const value = objectValue(raw, "release lookup");
  if (
    !Number.isSafeInteger(value.id) ||
    value.id <= 0 ||
    value.tag_name !== publication.tag ||
    value.target_commitish !== publication.commit ||
    value.name !== publication.title ||
    value.body !== publication.notes ||
    typeof value.draft !== "boolean" ||
    value.prerelease !== publication.prerelease ||
    !Array.isArray(value.assets)
  ) {
    throw new Error(
      "GitHub release metadata does not match the exact publication",
    );
  }
  const assets = value.assets.map((asset, index) =>
    releaseAsset(asset, `GitHub release assets[${index}]`),
  );
  const names = assets.map((asset) => asset.name);
  if (new Set(names).size !== names.length) {
    throw new Error("GitHub release assets are invalid or duplicated");
  }
  return {
    state: value.draft ? "draft" : "published",
    names: new Set(names),
    assets: new Map(assets.map((asset) => [asset.name, asset])),
    identity: releaseIdentity(value.id, assets),
  };
}

function lookupRelease(client, publication, { allowAbsent = false } = {}) {
  resolveTag(client, publication);
  const result = client.run(
    [
      "api",
      `repos/${publication.repository}/releases/tags/${encodeURIComponent(publication.tag)}`,
    ],
    { allowFailure: true },
  );
  if (result.status !== 0) {
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`;
    if (/\bHTTP 404\b/u.test(detail)) {
      const listed = client.run(
        ["api", `repos/${publication.repository}/releases?per_page=100`],
        { allowFailure: true },
      );
      if (listed.status !== 0) {
        const listDetail = `${listed.stderr || ""}\n${listed.stdout || ""}`;
        throw new Error(`GitHub release list lookup failed: ${listDetail.trim()}`);
      }
      const releases = parseJson(listed.stdout, "release list lookup");
      if (!Array.isArray(releases)) {
        throw new Error("release list lookup returned a non-array response");
      }
      const matches = releases.filter(
        (release) => release?.tag_name === publication.tag,
      );
      if (matches.length > 1) {
        throw new Error(`multiple GitHub releases resolve to ${publication.tag}`);
      }
      if (matches.length === 1) {
        return parseRelease(matches[0], publication);
      }
      if (allowAbsent) return null;
    }
    throw new Error(`GitHub release lookup failed: ${detail.trim()}`);
  }
  return parseRelease(parseJson(result.stdout, "release lookup"), publication);
}

function lookupLatestRelease(client, publication) {
  resolveTag(client, publication);
  const result = client.run(
    ["api", `repos/${publication.repository}/releases/latest`],
    { allowFailure: true },
  );
  if (result.status !== 0) {
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`;
    throw new Error(`GitHub latest release lookup failed: ${detail.trim()}`);
  }
  return parseRelease(
    parseJson(result.stdout, "latest release lookup"),
    publication,
  );
}

function requireAssetNames(publication, names, { complete }) {
  const expected = new Set(publication.assets.map((asset) => asset.name));
  const unexpected = [...names].filter((name) => !expected.has(name));
  const missing = [...expected].filter((name) => !names.has(name));
  if (unexpected.length > 0 || (complete && missing.length > 0)) {
    throw new Error(
      `release asset set mismatch; missing=${missing.join(",") || "none"} unexpected=${unexpected.join(",") || "none"}`,
    );
  }
  return missing;
}

function createDraft(client, publication) {
  const args = [
    "release",
    "create",
    publication.tag,
    "--repo",
    publication.repository,
    "--draft",
    "--verify-tag",
    "--target",
    publication.commit,
    "--title",
    publication.title,
    "--notes-file",
    publication.notesPath,
    "--latest=false",
  ];
  if (publication.prerelease) args.push("--prerelease");
  return client.run(args, { allowFailure: true });
}

function downloadAsset(client, publication, name, directory) {
  mkdirSync(directory, { recursive: true });
  const path = join(directory, name);
  rmSync(path, { force: true });
  client.run([
    "release",
    "download",
    publication.tag,
    "--repo",
    publication.repository,
    "--pattern",
    name,
    "--dir",
    directory,
  ]);
  return regularFile(path, `downloaded release asset ${name}`);
}

function identical(first, second) {
  return readFileSync(first).equals(readFileSync(second));
}

function verifyEvidence(client, asset, path) {
  verifyBundle(
    client,
    asset.evidence.manifest,
    asset.evidence.bundle,
    asset.evidence.artifactPath,
    path,
  );
}

function verifyOrAdoptExisting(client, asset, downloaded, stagedPath) {
  if (asset.evidence) {
    verifyEvidence(client, asset, downloaded);
    if (!identical(stagedPath, downloaded))
      copyFileSync(downloaded, stagedPath);
    return;
  }
  if (!identical(stagedPath, downloaded)) {
    throw new Error(
      `release asset ${asset.name} differs from exact local bytes`,
    );
  }
}

function verifyGitHubAssetDigest(remote, path) {
  const bytes = readFileSync(path);
  if (bytes.length !== remote.size) {
    throw new Error(
      `release asset ${remote.name} size ${bytes.length} does not match GitHub metadata ${remote.size}`,
    );
  }
  const digest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  if (digest !== remote.digest) {
    throw new Error(
      `release asset ${remote.name} digest does not match GitHub metadata`,
    );
  }
}

function requireSameReleaseIdentity(expected, actual, context) {
  if (expected.identity !== actual.identity) {
    throw new Error(`${context} changed the audited release or asset identity`);
  }
}

function auditCompleteRelease(client, publication, staged, directory) {
  const release = lookupRelease(client, publication);
  if (release.state !== "published") {
    throw new Error(
      "release must be published for read-only retry verification",
    );
  }
  requireAssetNames(publication, release.names, { complete: true });
  for (const asset of publication.assets) {
    const downloaded = downloadAsset(
      client,
      publication,
      asset.name,
      directory,
    );
    verifyOrAdoptExisting(client, asset, downloaded, staged.get(asset.name));
    verifyGitHubAssetDigest(release.assets.get(asset.name), downloaded);
  }
  const final = lookupRelease(client, publication);
  if (final.state !== "published")
    throw new Error("release state changed during audit");
  requireAssetNames(publication, final.names, { complete: true });
  requireSameReleaseIdentity(release, final, "release asset audit");
  return final;
}

function requireExactLatestRelease(client, publication, audited) {
  const latest = lookupLatestRelease(client, publication);
  if (latest.state !== "published") {
    throw new Error("GitHub latest release is not published");
  }
  requireAssetNames(publication, latest.names, { complete: true });
  requireSameReleaseIdentity(audited, latest, "latest release verification");
}

function promoteAuditedRelease(client, publication, audited) {
  const current = lookupRelease(client, publication);
  if (current.state !== "published") {
    throw new Error("release left published state before latest promotion");
  }
  requireAssetNames(publication, current.names, { complete: true });
  requireSameReleaseIdentity(
    audited,
    current,
    "latest promotion precondition",
  );

  const result = client.run(
    [
      "release",
      "edit",
      publication.tag,
      "--repo",
      publication.repository,
      "--latest",
    ],
    { allowFailure: true },
  );
  try {
    requireExactLatestRelease(client, publication, audited);
  } catch (error) {
    if (result.status !== 0) {
      const detail = (result.stderr || result.stdout || "unknown failure").trim();
      throw new Error(
        `latest promotion failed: ${detail}; ${error.message}`,
      );
    }
    throw error;
  }
  return result.status === 0;
}

function publishDraft(client, publication) {
  return client.run(
    [
      "release",
      "edit",
      publication.tag,
      "--repo",
      publication.repository,
      "--draft=false",
      `--prerelease=${publication.prerelease ? "true" : "false"}`,
      publication.promote ? "--latest" : "--latest=false",
      "--title",
      publication.title,
      "--notes-file",
      publication.notesPath,
      "--target",
      publication.commit,
    ],
    { allowFailure: true },
  );
}

function redraftAfterFailedAudit(client, publication) {
  return client.run(
    [
      "release",
      "edit",
      publication.tag,
      "--repo",
      publication.repository,
      "--draft=true",
      "--latest=false",
    ],
    { allowFailure: true },
  );
}

export function publishAppleAndroidRelease(
  publication,
  { client = createGhClient() } = {},
) {
  const workspace = mkdtempSync(join(tmpdir(), "apple-android-release-"));
  try {
    const stagedDirectory = join(workspace, "staged");
    mkdirSync(stagedDirectory);
    const staged = new Map();
    for (const asset of publication.assets) {
      const path = join(stagedDirectory, asset.name);
      copyFileSync(asset.path, path);
      staged.set(asset.name, path);
      if (asset.evidence) verifyEvidence(client, asset, path);
    }

    let release = lookupRelease(client, publication, { allowAbsent: true });
    if (!release) {
      const result = createDraft(client, publication);
      release = lookupRelease(client, publication);
      if (result.status === 0 && release.state !== "draft") {
        throw new Error("new Apple release did not remain draft");
      }
    }

    if (release.state === "published") {
      requireAssetNames(publication, release.names, { complete: true });
      const audited = auditCompleteRelease(
        client,
        publication,
        staged,
        join(workspace, "published"),
      );
      if (publication.promote) {
        const promotionApplied = promoteAuditedRelease(
          client,
          publication,
          audited,
        );
        return {
          published: false,
          uploaded: [],
          readOnly: false,
          promoted: true,
          promotionApplied,
        };
      }
      return { published: false, uploaded: [], readOnly: true };
    }

    requireAssetNames(publication, release.names, { complete: false });
    const preflight = join(workspace, "preflight");
    for (const asset of publication.assets) {
      if (!release.names.has(asset.name)) continue;
      verifyOrAdoptExisting(
        client,
        asset,
        downloadAsset(client, publication, asset.name, preflight),
        staged.get(asset.name),
      );
    }

    const uploaded = [];
    for (const asset of publication.assets) {
      if (release.names.has(asset.name)) continue;
      const current = lookupRelease(client, publication);
      if (current.state !== "draft") {
        throw new Error("release left draft state before create-only upload");
      }
      requireAssetNames(publication, current.names, { complete: false });
      const result = client.run(
        [
          "release",
          "upload",
          publication.tag,
          staged.get(asset.name),
          "--repo",
          publication.repository,
        ],
        { allowFailure: true },
      );
      if (result.status === 0) {
        uploaded.push(asset.name);
      } else {
        verifyOrAdoptExisting(
          client,
          asset,
          downloadAsset(client, publication, asset.name, preflight),
          staged.get(asset.name),
        );
      }
      release = lookupRelease(client, publication);
      if (release.state !== "draft") {
        throw new Error("release left draft state during create-only upload");
      }
    }

    release = lookupRelease(client, publication);
    if (release.state !== "draft")
      throw new Error("release is not draft before final verification");
    requireAssetNames(publication, release.names, { complete: true });
    const finalDirectory = join(workspace, "final");
    for (const asset of publication.assets) {
      verifyOrAdoptExisting(
        client,
        asset,
        downloadAsset(client, publication, asset.name, finalDirectory),
        staged.get(asset.name),
      );
    }

    const finalState = lookupRelease(client, publication);
    if (finalState.state !== "draft") {
      throw new Error("release left draft state before final publication");
    }
    requireAssetNames(publication, finalState.names, { complete: true });
    const result = publishDraft(client, publication);
    if (result.status !== 0) {
      const concurrent = lookupRelease(client, publication);
      if (concurrent.state !== "published") {
        throw new Error("final draft publication failed");
      }
    }
    try {
      const audited = auditCompleteRelease(
        client,
        publication,
        staged,
        join(workspace, "post-publish"),
      );
      if (publication.promote) {
        requireExactLatestRelease(client, publication, audited);
      }
    } catch (error) {
      if (result.status === 0) {
        const redraft = redraftAfterFailedAudit(client, publication);
        if (redraft.status !== 0) {
          throw new Error(
            `post-publication audit failed and emergency redraft failed: ${error.message}`,
          );
        }
      }
      throw error;
    }
    return { published: result.status === 0, uploaded, readOnly: false };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

function parseArguments(argv) {
  if (argv.length !== 2 || argv[0] !== "--manifest" || !argv[1]) {
    throw new Error("usage: --manifest PATH");
  }
  return resolve(argv[1]);
}

export function run(argv) {
  const manifestPath = regularFile(
    parseArguments(argv),
    "publication manifest",
  );
  const publication = validateAppleAndroidPublication(
    parseJson(readFileSync(manifestPath, "utf8"), "publication manifest"),
  );
  const result = publishAppleAndroidRelease(publication);
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
