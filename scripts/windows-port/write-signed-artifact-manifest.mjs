#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";

const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith("--") || value === undefined) {
    throw new Error(`Invalid argument near ${key ?? "<end>"}`);
  }
  options.set(key.slice(2), value);
}

const required = (name) => {
  const value = options.get(name)?.trim();
  if (!value) throw new Error(`Missing --${name}`);
  return value;
};

const artifactPath = resolve(required("artifact"));
const outputPath = resolve(required("output"));
const architecture = required("architecture");
const sourceCommit = required("source-commit").toLowerCase();
const workflowRunId = required("workflow-run-id");
const workflowRunUrl = required("workflow-run-url");
const signatureIdentity = required("signature-identity");

if (!new Set(["x64", "ARM64"]).has(architecture)) {
  throw new Error(`Unsupported architecture: ${architecture}`);
}
if (!/^[a-f0-9]{40}$/.test(sourceCommit)) {
  throw new Error("--source-commit must be a full 40-character Git SHA");
}
if (!/^\d+$/.test(workflowRunId)) {
  throw new Error("--workflow-run-id must be numeric");
}
const parsedWorkflowUrl = new URL(workflowRunUrl);
if (parsedWorkflowUrl.protocol !== "https:" || !/^github\.com$/i.test(parsedWorkflowUrl.hostname)) {
  throw new Error("--workflow-run-url must be an HTTPS github.com URL");
}
if (!parsedWorkflowUrl.pathname.endsWith(`/actions/runs/${workflowRunId}`)) {
  throw new Error("--workflow-run-url must end with the supplied workflow run ID");
}

const artifact = readFileSync(artifactPath);
const manifest = {
  schema: "openburnbar.windows.signed-artifact-manifest.v1",
  artifactName: basename(artifactPath),
  architecture,
  sourceCommit,
  workflowRunId,
  workflowRunUrl: parsedWorkflowUrl.toString(),
  artifactSha256: createHash("sha256").update(artifact).digest("hex"),
  signatureResult: "verified",
  signatureIdentity,
};

writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
console.log(`Wrote ${outputPath} for ${manifest.artifactName} (${manifest.artifactSha256}).`);
