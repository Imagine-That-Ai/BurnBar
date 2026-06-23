#!/usr/bin/env node
/**
 * Guard the wiki mem0 workflow boundary: the mem0 sync job may receive the
 * mem0 API key, and the manifest commit job may receive contents:write, but no
 * job may receive both.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.WIKI_MEM0_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW = join(ROOT, ".github/workflows/wiki-mem0-reconcile.yml");
const MEM0 = "${{ secrets.MEM0_BURNBAR_API_KEY }}";
const MEM0_NAME = "MEM0_BURNBAR_API_KEY";
const ARTIFACT = "wiki-mem0-manifest";

const failures = [];
const fail = (message) => failures.push(message);
const stripComments = (source) =>
  source
    .split("\n")
    .map((line) => (/^\s*#/u.test(line) ? "" : line.replace(/\s+#.*$/u, "")))
    .join("\n");
const indent = (line) => line.match(/^(\s*)/u)[1].length;
const scalar = (value = "") => value.trim().replace(/^(['"])(.*)\1$/u, "$2");
const blockText = (lines, start, end) => lines.slice(start, end).join("\n");
const hasWriteTokenUse = (source) =>
  /\bGITHUB_TOKEN\b/u.test(source) ||
  /\$\{\{\s*github\.token\s*\}\}/u.test(source) ||
  /\bgit\s+push\b/u.test(source);
const splitFlowEntries = (value = "") => {
  const trimmed = scalar(value);
  if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return [];
  return trimmed
    .slice(1, -1)
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const [key, ...rest] = entry.split(":");
      return { key: scalar(key), value: scalar(rest.join(":")) };
    });
};

function topMapping(source, section, key) {
  const lines = source.split("\n");
  const start = lines.findIndex((line) => line === `${section}:`);
  if (start === -1) return null;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim() && indent(line) === 0) return null;
    const match = line.match(/^\s{2}([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
    if (match?.[1] === key) return scalar(match[2]);
  }
  return null;
}

function topScalar(source, section) {
  const match = source.match(
    new RegExp(`^${section}:\\s*([^\\n#]+?)\\s*$`, "mu"),
  );
  return match ? scalar(match[1]) : null;
}

function topSection(source, section) {
  const lines = source.split("\n");
  const start = lines.findIndex((line) => line === `${section}:`);
  if (start === -1) return "";
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (lines[index].trim() && indent(lines[index]) === 0) {
      end = index;
      break;
    }
  }
  return blockText(lines, start, end);
}

function jobs(source) {
  const lines = source.split("\n");
  const start = lines.findIndex((line) => line === "jobs:");
  const result = new Map();
  if (start === -1) return result;
  for (let index = start + 1; index < lines.length; index += 1) {
    const match = lines[index].match(/^  ([A-Za-z0-9_-]+):\s*$/u);
    if (!match) continue;
    let end = lines.length;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      if (
        lines[cursor].trim() &&
        /^  [A-Za-z0-9_-]+:\s*$/u.test(lines[cursor])
      ) {
        end = cursor;
        break;
      }
    }
    result.set(match[1], {
      name: match[1],
      source: blockText(lines, index, end),
    });
    index = end - 1;
  }
  return result;
}

function directJobValue(job, key) {
  for (const line of job.source.split("\n")) {
    const match = line.match(/^\s{4}([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
    if (match?.[1] === key) return scalar(match[2]);
  }
  return null;
}

function jobSection(job, section) {
  const lines = job.source.split("\n");
  const start = lines.findIndex((line) => line === `    ${section}:`);
  if (start === -1) return "";
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (lines[index].trim() && indent(lines[index]) <= 4) {
      end = index;
      break;
    }
  }
  return blockText(lines, start, end);
}

function jobMappingEntries(job, section) {
  const entries = [];
  for (const line of jobSection(job, section).split("\n")) {
    const match = line.match(/^\s{6}([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
    if (match) entries.push({ key: match[1], value: scalar(match[2]) });
  }
  entries.push(...splitFlowEntries(directJobValue(job, section) ?? ""));
  return entries;
}

function jobMapping(job, section, key) {
  return (
    jobMappingEntries(job, section).find((entry) => entry.key === key)?.value ??
    null
  );
}

function steps(job) {
  const lines = job.source.split("\n");
  const start = lines.findIndex((line) => line === "    steps:");
  const result = [];
  if (start === -1) return result;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (!/^      -\s+/u.test(lines[index])) continue;
    let end = lines.length;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      if (
        lines[cursor].trim() &&
        (indent(lines[cursor]) <= 4 || /^      -\s+/u.test(lines[cursor]))
      ) {
        end = cursor;
        break;
      }
    }
    result.push(blockText(lines, index, end));
    index = end - 1;
  }
  return result;
}

function stepName(step) {
  return (
    step.match(/^      -\s+name:\s*(.*?)\s*$/mu)?.[1] ??
    step.match(/\n        name:\s*(.*?)\s*(?:\n|$)/u)?.[1] ??
    ""
  ).trim();
}

function needsReconcile(job) {
  const needs = directJobValue(job, "needs");
  return (
    needs === "reconcile" ||
    (needs?.startsWith("[") &&
      needs
        .slice(1, -1)
        .split(",")
        .map((entry) => scalar(entry.trim()))
        .includes("reconcile")) ||
    /(?:^|\n)    needs:\s*\n(?:      -\s+reconcile\s*(?:\n|$)|      reconcile:\s*)/u.test(
      job.source,
    )
  );
}

function effectiveContents(job, topContents) {
  const permissions = directJobValue(job, "permissions");
  if (permissions === "write-all") return "write";
  if (permissions === "read-all") return "read";
  return jobMapping(job, "permissions", "contents") ?? topContents;
}

function writePermissionEntries(job) {
  const permissions = directJobValue(job, "permissions");
  if (permissions === "write-all") return [{ key: "*", value: "write" }];
  return jobMappingEntries(job, "permissions").filter(
    (entry) => entry.value === "write",
  );
}

if (!existsSync(WORKFLOW)) {
  console.error(`MISCONFIGURED: workflow not found: ${WORKFLOW}`);
  process.exit(2);
}

const source = stripComments(readFileSync(WORKFLOW, "utf8"));
const topPermissions = topScalar(source, "permissions");
const topContents =
  topMapping(source, "permissions", "contents") ??
  (topPermissions === "read-all" ? "read" : null);
const topEnv = topSection(source, "env");
const allJobs = jobs(source);
const reconcile = allJobs.get("reconcile");
const commit = allJobs.get("commit-refreshed-manifest");

if (topContents !== "read")
  fail("workflow scope must default to contents:read");
if (/^permissions:\s*write-all\s*$/mu.test(source))
  fail("workflow scope must not use write-all");
if (new RegExp(`\\b${MEM0_NAME}\\b`, "u").test(topEnv))
  fail("workflow scope must not export the mem0 key through env");
if (!reconcile) fail("missing read-only reconcile job");
if (!commit) fail("missing manifest commit job");

if (reconcile) {
  const contents = effectiveContents(reconcile, topContents);
  const reconcileIf = directJobValue(reconcile, "if");
  if (contents !== "read")
    fail("reconcile job must run with contents:read only");
  if (writePermissionEntries(reconcile).length > 0)
    fail("reconcile job must not request any write permission");
  if (
    !reconcileIf?.includes("github.event_name == 'schedule'") ||
    !reconcileIf?.includes(
      "github.ref_name == github.event.repository.default_branch",
    )
  ) {
    fail("reconcile job must run only on schedule or default-branch dispatch");
  }
  if (
    !reconcile.source.includes(
      "ref: ${{ github.event.repository.default_branch }}",
    )
  ) {
    fail("reconcile job checkout must be pinned to the repository default branch");
  }
  if (!reconcile.source.includes(MEM0))
    fail("reconcile job must receive the mem0 key");
  if (hasWriteTokenUse(reconcile.source))
    fail("reconcile job must not use repository write tokens");
  if (
    !reconcile.source.includes("actions/upload-artifact@") ||
    !reconcile.source.includes(ARTIFACT) ||
    !reconcile.source.includes("mem0-manifest.json")
  ) {
    fail("reconcile job must hand off the manifest by artifact");
  }
  if (
    !reconcile.source.includes("outputs:") ||
    !reconcile.source.includes("base-sha:") ||
    !reconcile.source.includes("git rev-parse HEAD")
  ) {
    fail("reconcile job must publish its checkout SHA for the commit job");
  }
  const secretSteps = steps(reconcile).filter((step) => step.includes(MEM0));
  if (
    secretSteps.length !== 1 ||
    stepName(secretSteps[0]) !== "Reconcile droid-wiki to mem0"
  ) {
    fail("mem0 key must appear only on the reconcile execution step");
  }
}

if (commit) {
  const contents = effectiveContents(commit, topContents);
  if (contents !== "write")
    fail("manifest commit job must be the only contents:write job");
  if (
    writePermissionEntries(commit).some((entry) => entry.key !== "contents")
  ) {
    fail("manifest commit job must not request non-contents write permissions");
  }
  if (!needsReconcile(commit))
    fail("manifest commit job must depend on reconcile");
  if (
    new RegExp(`\\b${MEM0_NAME}\\b`, "u").test(stripComments(commit.source))
  ) {
    fail("manifest commit job must not reference the mem0 key");
  }
  if (
    !commit.source.includes("actions/download-artifact@") ||
    !commit.source.includes(ARTIFACT) ||
    !commit.source.includes("droid-wiki/.mem0-manifest.json")
  ) {
    fail("manifest commit job must restore the manifest from the artifact");
  }
  if (!commit.source.includes("ref: ${{ needs.reconcile.outputs.base-sha }}")) {
    fail("manifest commit job must check out the reconcile base SHA");
  }
}

for (const job of allJobs.values()) {
  const contents = effectiveContents(job, topContents);
  if (job.source.includes(MEM0) && contents !== "read") {
    fail(`job ${job.name} combines mem0 key with contents:${contents}`);
  }
  if (job.name !== "commit-refreshed-manifest" && contents === "write") {
    fail(`job ${job.name} unexpectedly has contents:write`);
  }
  if (job.source.includes(MEM0) && hasWriteTokenUse(job.source)) {
    fail(`job ${job.name} combines mem0 key with repository write-token use`);
  }
}

if (failures.length > 0) {
  console.error("Wiki mem0 workflow boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: wiki mem0 sync secrets are separated from repository write tokens.",
);
