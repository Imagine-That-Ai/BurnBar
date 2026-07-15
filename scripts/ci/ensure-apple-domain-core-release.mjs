#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { DOMAIN_CORE_REPOSITORY } from "../lib/domain-core-release-evidence.mjs";

const COMMIT = /^[0-9a-f]{40}$/u;
const APPLE_TAG =
  /^v(\d+\.\d+\.\d+)(-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/u;

function parseJson(value, label) {
  try {
    return JSON.parse(value);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

export function validateRequest(raw) {
  const keys = Object.keys(raw ?? {}).sort();
  const expected = ["commit", "repository", "tag"];
  if (JSON.stringify(keys) !== JSON.stringify(expected)) {
    throw new Error(
      `Apple release request must contain exactly: ${expected.join(", ")}`,
    );
  }
  if (raw.repository !== DOMAIN_CORE_REPOSITORY) {
    throw new Error(
      `Apple release repository must be ${DOMAIN_CORE_REPOSITORY}`,
    );
  }
  const match = typeof raw.tag === "string" ? APPLE_TAG.exec(raw.tag) : null;
  if (!match)
    throw new Error("Apple release tag must be exact v-prefixed SemVer");
  if (typeof raw.commit !== "string" || !COMMIT.test(raw.commit)) {
    throw new Error("Apple release commit must be a full lowercase Git SHA");
  }
  return {
    ...raw,
    prerelease: match[2] !== undefined,
    version: `${match[1]}${match[2] ?? ""}${match[3] ?? ""}`,
  };
}

function validateRelease(raw, request) {
  if (
    !raw ||
    typeof raw !== "object" ||
    raw.tag_name !== request.tag ||
    raw.target_commitish !== request.commit ||
    typeof raw.draft !== "boolean" ||
    raw.prerelease !== request.prerelease ||
    !Array.isArray(raw.assets)
  ) {
    throw new Error(
      "Apple release must match the exact tag, commit, prerelease state, and draft state",
    );
  }
  return raw;
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
      throw new Error(
        `gh command failed: ${(result.stderr || result.stdout || "unknown failure").trim()}`,
      );
    }
    return result;
  }

  resolveTagCommit(tag) {
    const result = this.run([
      "api",
      `repos/${this.repository}/commits/${encodeURIComponent(tag)}`,
    ]);
    const value = parseJson(result.stdout, "Apple release tag lookup");
    if (!value || typeof value.sha !== "string" || !COMMIT.test(value.sha)) {
      throw new Error("GitHub returned an invalid Apple release tag commit");
    }
    return value.sha;
  }

  lookup(tag) {
    const result = this.run(
      ["api", `repos/${this.repository}/releases/tags/${tag}`],
      { allowFailure: true },
    );
    if (result.status === 0)
      return parseJson(result.stdout, "Apple release lookup");
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`;
    if (/\bHTTP 404\b/u.test(detail)) return null;
    throw new Error(`Apple release lookup failed: ${detail.trim()}`);
  }

  createDraft(request) {
    const arguments_ = [
      "release",
      "create",
      request.tag,
      "--repo",
      request.repository,
      "--draft",
      "--verify-tag",
      "--target",
      request.commit,
      "--title",
      `OpenBurnBar ${request.version}`,
      "--latest=false",
    ];
    if (request.prerelease) arguments_.push("--prerelease");
    return this.run(arguments_, { allowFailure: true });
  }
}

export function ensureAppleRelease(raw, client) {
  const request = validateRequest(raw);
  if (client.resolveTagCommit(request.tag) !== request.commit) {
    throw new Error(
      "Apple release tag does not resolve to the requested commit",
    );
  }
  const existing = client.lookup(request.tag);
  if (existing) {
    validateRelease(existing, request);
    return { created: false, draft: existing.draft };
  }
  const result = client.createDraft(request);
  if (result.status === 0) {
    const created = client.lookup(request.tag);
    if (!created) throw new Error("created Apple draft release is missing");
    validateRelease(created, request);
    if (!created.draft) throw new Error("new Apple release must remain draft");
    return { created: true, draft: true };
  }
  const concurrent = client.lookup(request.tag);
  if (!concurrent) throw new Error("Apple draft release creation failed");
  validateRelease(concurrent, request);
  return { created: false, draft: concurrent.draft };
}

function parseArguments(argv) {
  if (
    argv.length !== 6 ||
    argv[0] !== "--repository" ||
    argv[2] !== "--tag" ||
    argv[4] !== "--commit"
  ) {
    throw new Error("usage: --repository OWNER/REPO --tag TAG --commit SHA");
  }
  return { repository: argv[1], tag: argv[3], commit: argv[5] };
}

export function run(argv) {
  const request = parseArguments(argv);
  const result = ensureAppleRelease(
    request,
    new GhReleaseClient(request.repository),
  );
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
