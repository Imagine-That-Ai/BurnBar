#!/usr/bin/env node
/**
 * Static boundary gate for native artifact build workflows.
 *
 * Native build lanes run on pull_request and execute toolchains over checked
 * out source. They must stay secret-free, use read-only repository
 * permissions, and avoid persisting checkout credentials into later build
 * steps.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.NATIVE_BUILD_WORKFLOW_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW_DIR = join(ROOT, ".github", "workflows");

const NATIVE_BUILD_WORKFLOWS = [
  "iroh-xcframework.yml",
  "build-iroh-android-aar.yml",
  "build-burnbar-remote-android-aar.yml",
];

const failures = [];
const fail = (file, message) => failures.push(`${file}: ${message}`);

function stripYamlLineComment(line) {
  let singleQuoted = false;
  let doubleQuoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const previous = index > 0 ? line[index - 1] : "";
    if (char === "'" && !doubleQuoted) {
      singleQuoted = !singleQuoted;
      continue;
    }
    if (char === '"' && !singleQuoted && previous !== "\\") {
      doubleQuoted = !doubleQuoted;
      continue;
    }
    if (
      char === "#" &&
      !singleQuoted &&
      !doubleQuoted &&
      (index === 0 || /\s/u.test(previous))
    ) {
      return line.slice(0, index).trimEnd();
    }
  }
  return line;
}

function stripYamlComments(source) {
  return source
    .split("\n")
    .map((line) => stripYamlLineComment(line))
    .join("\n");
}

function workflowSource(file) {
  const path = join(WORKFLOW_DIR, file);
  if (!existsSync(path)) {
    console.error(`MISCONFIGURED: workflow not found: ${path}`);
    process.exit(2);
  }
  return stripYamlComments(readFileSync(path, "utf8"));
}

function workflowTopLevelPermissionsBlock(source) {
  return /^permissions:\n(?<body>(?:^[ \t]+[^\n]*\n?)+)/mu.exec(source)
    ?.groups?.body ?? "";
}

function requireReadOnlyPermissions(file, source) {
  const permissions = workflowTopLevelPermissionsBlock(source);
  if (!permissions) {
    fail(file, "missing top-level permissions block");
    return;
  }
  if (!/^  contents:\s*read\s*$/mu.test(permissions)) {
    fail(file, "top-level permissions must include contents: read");
  }
  for (const scope of ["actions", "contents", "id-token", "packages"]) {
    const writePattern = new RegExp(`^\\s+${scope}:\\s*write\\s*$`, "mu");
    if (writePattern.test(source)) {
      fail(file, `must not grant ${scope}: write`);
    }
  }
}

function checkoutStepBlocks(source) {
  const lines = source.split("\n");
  const blocks = [];
  for (const [index, line] of lines.entries()) {
    if (!/^\s*uses:\s*actions\/checkout@/u.test(line)) continue;

    let start = index;
    while (start > 0 && !/^ {6}-\s/u.test(lines[start])) start -= 1;

    let end = index + 1;
    while (end < lines.length && !/^ {6}-\s/u.test(lines[end])) end += 1;

    blocks.push(lines.slice(start, end).join("\n"));
  }
  return blocks;
}

function requireCheckoutCredentialIsolation(file, source) {
  const blocks = checkoutStepBlocks(source);
  if (blocks.length === 0) {
    fail(file, "missing actions/checkout step");
    return;
  }
  for (const [index, block] of blocks.entries()) {
    if (!/^\s+persist-credentials:\s*false\s*$/mu.test(block)) {
      fail(
        file,
        `actions/checkout step ${index + 1} must set persist-credentials: false`,
      );
    }
  }
}

function requirePullRequestSafeTriggers(file, source) {
  if (/^ {2}pull_request_target:/mu.test(source)) {
    fail(file, "must not use pull_request_target");
  }
  if (!/^ {2}pull_request:/mu.test(source)) {
    fail(file, "must keep pull_request coverage for native build changes");
  }
}

function requireSecretFree(file, source) {
  if (/\bsecrets\./u.test(source)) {
    fail(file, "pull-request native build workflow must not reference secrets");
  }
}

for (const file of NATIVE_BUILD_WORKFLOWS) {
  const source = workflowSource(file);
  requirePullRequestSafeTriggers(file, source);
  requireReadOnlyPermissions(file, source);
  requireSecretFree(file, source);
  requireCheckoutCredentialIsolation(file, source);
}

if (failures.length > 0) {
  console.error("Native build workflow boundary check failed:");
  for (const failure of failures) console.error(` - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: native build workflows keep PR builds secret-free and checkout credentials isolated.",
);
