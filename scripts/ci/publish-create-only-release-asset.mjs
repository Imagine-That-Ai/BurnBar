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
import { basename, join } from "node:path";
import { pathToFileURL } from "node:url";

import {
  DOMAIN_CORE_REPOSITORY,
  regularFile,
  safeAssetName,
} from "../lib/domain-core-release-evidence.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const APPLE_TAG =
  /^v(\d+\.\d+\.\d+)(-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/u;
const PHASES = new Set(["preflight", "publish"]);

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

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

export function validateRequest(raw) {
  const value = exactObject(
    raw,
    ["phase", "repository", "tag", "commit", "artifact", "expectedPrerelease"],
    "create-only release asset request",
  );
  if (!PHASES.has(value.phase)) {
    throw new Error("phase must be preflight or publish");
  }
  if (value.repository !== DOMAIN_CORE_REPOSITORY) {
    throw new Error(`repository must be ${DOMAIN_CORE_REPOSITORY}`);
  }
  const tagMatch =
    typeof value.tag === "string" ? APPLE_TAG.exec(value.tag) : null;
  if (!tagMatch) {
    throw new Error("tag must be an exact v-prefixed Apple SemVer tag");
  }
  if (typeof value.commit !== "string" || !FULL_SHA.test(value.commit)) {
    throw new Error("commit must be a full lowercase Git SHA");
  }
  if (typeof value.expectedPrerelease !== "boolean") {
    throw new Error("expectedPrerelease must be a boolean");
  }
  const tagHasPrerelease = tagMatch[2] !== undefined;
  if (tagHasPrerelease !== value.expectedPrerelease) {
    throw new Error(
      "expectedPrerelease must agree with the prerelease component in tag",
    );
  }
  const artifact = regularFile(value.artifact, "release artifact");
  const assetName = safeAssetName(
    basename(artifact),
    "release artifact asset name",
  );
  const version = `${tagMatch[1]}${tagMatch[2] ?? ""}${tagMatch[3] ?? ""}`;
  const expectedName = `OpenBurnBar-${version}-macOS.dmg`;
  if (assetName !== expectedName) {
    throw new Error(`release artifact must be named ${expectedName}`);
  }
  return { ...value, artifact, assetName };
}

function validateRelease(raw, request) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("GitHub returned an invalid release");
  }
  if (
    raw.tag_name !== request.tag ||
    raw.target_commitish !== request.commit ||
    raw.draft !== false ||
    raw.prerelease !== request.expectedPrerelease
  ) {
    throw new Error(
      "release must have the exact tag, target commit, published state, and prerelease state",
    );
  }
  if (!Array.isArray(raw.assets)) {
    throw new Error("release asset listing must be an array");
  }
  const names = raw.assets.map((asset) => asset?.name);
  if (
    names.some((name) => typeof name !== "string") ||
    new Set(names).size !== names.length
  ) {
    throw new Error(
      "release asset listing contains invalid or duplicate names",
    );
  }
  for (const name of names) safeAssetName(name, "existing release asset");
  return new Set(names);
}

function identical(first, second) {
  return readFileSync(first).equals(readFileSync(second));
}

export class GhReleaseClient {
  constructor(repository, runner = spawnSync) {
    this.repository = repository;
    this.runner = runner;
  }

  run(arguments_, { allowFailure = false } = {}) {
    const result = this.runner("gh", arguments_, {
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
      throw new Error(`gh command failed: ${detail}`);
    }
    return result;
  }

  resolveTagCommit(tag) {
    const result = this.run([
      "api",
      `repos/${this.repository}/commits/${encodeURIComponent(tag)}`,
    ]);
    const value = parseJson(result.stdout, "release tag commit lookup");
    if (!value || typeof value !== "object" || !FULL_SHA.test(value.sha)) {
      throw new Error("GitHub returned an invalid release tag commit");
    }
    return value.sha;
  }

  lookup(tag) {
    const result = this.run(
      ["api", `repos/${this.repository}/releases/tags/${tag}`],
      { allowFailure: true },
    );
    if (result.status === 0) {
      return parseJson(result.stdout, "release lookup");
    }
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`;
    if (/\bHTTP 404\b/u.test(detail)) return null;
    throw new Error(`release lookup failed: ${detail.trim()}`);
  }

  download(tag, assetName, directory) {
    mkdirSync(directory, { recursive: true });
    const path = join(directory, assetName);
    rmSync(path, { force: true });
    this.run([
      "release",
      "download",
      tag,
      "--repo",
      this.repository,
      "--pattern",
      assetName,
      "--dir",
      directory,
    ]);
    return regularFile(path, `downloaded release asset ${assetName}`);
  }

  upload(tag, path) {
    return this.run(
      ["release", "upload", tag, path, "--repo", this.repository],
      { allowFailure: true },
    );
  }
}

function requireTagCommit(request, client) {
  if (client.resolveTagCommit(request.tag) !== request.commit) {
    throw new Error(
      "release tag does not resolve to the requested candidate commit",
    );
  }
}

function releaseState(request, client, { allowAbsent }) {
  requireTagCommit(request, client);
  const release = client.lookup(request.tag);
  if (!release) {
    if (allowAbsent) return null;
    throw new Error("exact published GitHub release does not exist");
  }
  return validateRelease(release, request);
}

function snapshotArtifact(request, workspace) {
  const path = join(workspace, request.assetName);
  copyFileSync(request.artifact, path);
  return regularFile(path, "snapshotted release artifact");
}

function verifyExisting(request, client, asset, directory, errorMessage) {
  const downloaded = client.download(request.tag, request.assetName, directory);
  if (!identical(asset, downloaded)) throw new Error(errorMessage);
}

export function preflightAsset(raw, { client } = {}) {
  const request = validateRequest({ ...raw, phase: "preflight" });
  const gh = client ?? new GhReleaseClient(request.repository);
  const workspace = mkdtempSync(join(tmpdir(), "create-only-preflight-"));
  try {
    const asset = snapshotArtifact(request, workspace);
    const assets = releaseState(request, gh, { allowAbsent: true });
    if (!assets) return { releaseExists: false, assetExists: false };
    if (assets.has(request.assetName)) {
      verifyExisting(
        request,
        gh,
        asset,
        join(workspace, "existing"),
        `refusing to replace non-identical ${request.assetName}`,
      );
      return { releaseExists: true, assetExists: true };
    }
    return { releaseExists: true, assetExists: false };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

export function publishAsset(raw, { client } = {}) {
  const request = validateRequest({ ...raw, phase: "publish" });
  const gh = client ?? new GhReleaseClient(request.repository);
  const workspace = mkdtempSync(join(tmpdir(), "create-only-publish-"));
  try {
    const asset = snapshotArtifact(request, workspace);
    const assets = releaseState(request, gh, { allowAbsent: false });
    let uploaded = false;

    // Finish the collision check before the only permitted mutation.
    if (assets.has(request.assetName)) {
      verifyExisting(
        request,
        gh,
        asset,
        join(workspace, "preflight"),
        `refusing to replace non-identical ${request.assetName}`,
      );
    } else {
      // Recheck the immutable release identity immediately before mutation.
      releaseState(request, gh, { allowAbsent: false });
      const result = gh.upload(request.tag, asset);
      if (result.status === 0) {
        uploaded = true;
      } else {
        verifyExisting(
          request,
          gh,
          asset,
          join(workspace, "collision"),
          "concurrent immutable release asset differs from local bytes",
        );
      }
    }

    releaseState(request, gh, { allowAbsent: false });
    verifyExisting(
      request,
      gh,
      asset,
      join(workspace, "final"),
      "published release asset differs from local bytes",
    );
    return { uploaded };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

function parseBoolean(value, label) {
  if (value === "true") return true;
  if (value === "false") return false;
  throw new Error(`${label} must be true or false`);
}

function parseArguments(argv) {
  const values = {};
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[++index];
    if (!value || value.startsWith("--")) {
      throw new Error(`${argument} requires a value`);
    }
    if (argument === "--phase") values.phase = value;
    else if (argument === "--repository") values.repository = value;
    else if (argument === "--tag") values.tag = value;
    else if (argument === "--commit") values.commit = value;
    else if (argument === "--artifact") values.artifact = value;
    else if (argument === "--expected-prerelease") {
      values.expectedPrerelease = parseBoolean(value, "--expected-prerelease");
    } else throw new Error(`unknown argument: ${argument}`);
  }
  return values;
}

export function main(argv = process.argv) {
  const request = parseArguments(argv);
  const result =
    request.phase === "preflight"
      ? preflightAsset(request)
      : request.phase === "publish"
        ? publishAsset(request)
        : validateRequest(request);
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
