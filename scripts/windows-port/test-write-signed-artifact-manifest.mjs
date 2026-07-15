#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const root = mkdtempSync(join(tmpdir(), "openburnbar-signed-manifest-"));
const artifact = join(root, "OpenBurnBar-1.0.30-x64.msix");
const output = join(root, "signed-artifact-x64.json");
const bytes = Buffer.from("signed-artifact-fixture\n", "utf8");
writeFileSync(artifact, bytes);

const baseArgs = [
  "scripts/windows-port/write-signed-artifact-manifest.mjs",
  "--artifact",
  artifact,
  "--architecture",
  "x64",
  "--source-commit",
  "a".repeat(40),
  "--workflow-run-id",
  "123456",
  "--workflow-run-url",
  "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/123456",
  "--signature-identity",
  "CN=Imagine That AI LLC",
  "--output",
  output,
];

const result = spawnSync(process.execPath, baseArgs, { encoding: "utf8" });
assert.equal(result.status, 0, result.stderr || result.stdout);
const manifest = JSON.parse(readFileSync(output, "utf8"));
assert.deepEqual(manifest, {
  schema: "openburnbar.windows.signed-artifact-manifest.v1",
  artifactName: "OpenBurnBar-1.0.30-x64.msix",
  architecture: "x64",
  sourceCommit: "a".repeat(40),
  workflowRunId: "123456",
  workflowRunUrl: "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/123456",
  artifactSha256: createHash("sha256").update(bytes).digest("hex"),
  signatureResult: "verified",
  signatureIdentity: "CN=Imagine That AI LLC",
});

const reject = (replacements, expected) => {
  const badOutput = join(root, `bad-${Math.random().toString(16).slice(2)}.json`);
  const args = [...baseArgs];
  for (const [flag, value] of Object.entries(replacements)) {
    args[args.indexOf(`--${flag}`) + 1] = value;
  }
  args[args.indexOf("--output") + 1] = badOutput;
  const rejected = spawnSync(process.execPath, args, { encoding: "utf8" });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, expected);
};

reject({ architecture: "x86" }, /Unsupported architecture/);
reject({ "source-commit": "abc" }, /full 40-character Git SHA/);
reject({ "workflow-run-url": "http:\/\/github.com\/actions\/runs\/123456" }, /HTTPS github\.com URL/);
reject({ "workflow-run-url": "https:\/\/github.com\/Imagine-That-Ai\/BurnBar\/actions\/runs\/999" }, /supplied workflow run ID/);

console.log("PASS: signed artifact manifest writer");
