#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const REPOSITORY = "Imagine-That-Ai/BurnBar";
const STABLE_TAG = /^windows-v(\d+\.\d+\.\d+)$/;
const COMMIT = /^[0-9a-f]{40}$/;

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

export function validateRequest(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("Windows release request must be an object");
  }
  const keys = Object.keys(raw).sort();
  const expected = ["commit", "repository", "tag"].sort();
  if (
    keys.length !== expected.length ||
    keys.some((key, index) => key !== expected[index])
  ) {
    throw new Error(
      "Windows release request must contain repository, tag, and commit",
    );
  }
  if (raw.repository !== REPOSITORY) {
    throw new Error(`Windows release repository must be ${REPOSITORY}`);
  }
  const match = typeof raw.tag === "string" ? STABLE_TAG.exec(raw.tag) : null;
  if (!match)
    throw new Error("Windows release tag must be an exact stable tag");
  if (typeof raw.commit !== "string" || !COMMIT.test(raw.commit)) {
    throw new Error("Windows release commit must be a full lowercase Git SHA");
  }
  return { ...raw, version: match[1] };
}

export function validateRelease(release, request) {
  if (!release || typeof release !== "object" || Array.isArray(release)) {
    throw new Error("GitHub returned an invalid Windows release");
  }
  if (release.tag_name !== request.tag) {
    throw new Error("GitHub returned the wrong Windows release tag");
  }
  if (release.draft !== false) {
    throw new Error("Windows domain-core evidence cannot use a draft release");
  }
  if (release.prerelease !== false) {
    throw new Error("Windows domain-core evidence cannot use a prerelease");
  }
  return release;
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
      throw new Error(
        `gh ${arguments_.slice(0, 3).join(" ")} failed: ${detail}`,
      );
    }
    return result;
  }

  lookup(tag) {
    const result = this.run(
      ["api", `repos/${this.repository}/releases/tags/${tag}`],
      { allowFailure: true },
    );
    if (result.status === 0) {
      return parseJson(result.stdout, "Windows release lookup");
    }
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`;
    if (/\bHTTP 404\b/.test(detail)) return null;
    throw new Error(`Windows release lookup failed: ${detail.trim()}`);
  }

  create(request) {
    const result = this.run(
      [
        "release",
        "create",
        request.tag,
        "--repo",
        request.repository,
        "--verify-tag",
        "--title",
        `OpenBurnBar Windows ${request.version}`,
        "--notes",
        `Signed OpenBurnBar Windows ${request.version} release from ${request.commit}.`,
        "--latest=false",
      ],
      { allowFailure: true },
    );
    return result.status === 0;
  }
}

export function ensureRelease(raw, client) {
  const request = validateRequest(raw);
  const release = client.lookup(request.tag);
  if (release) {
    validateRelease(release, request);
    return { created: false };
  }
  if (client.create(request)) return { created: true };

  const concurrent = client.lookup(request.tag);
  if (!concurrent) {
    throw new Error("exact Windows GitHub Release creation failed");
  }
  validateRelease(concurrent, request);
  return { created: false };
}

function parseArguments(argv) {
  const values = {};
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[++index];
    if (!value || value.startsWith("--")) {
      throw new Error(`${argument} requires a value`);
    }
    if (argument === "--repository") values.repository = value;
    else if (argument === "--tag") values.tag = value;
    else if (argument === "--commit") values.commit = value;
    else throw new Error(`unknown argument: ${argument}`);
  }
  return values;
}

export function main(argv = process.argv) {
  const request = parseArguments(argv);
  const result = ensureRelease(
    request,
    new GhReleaseClient(request.repository),
  );
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
