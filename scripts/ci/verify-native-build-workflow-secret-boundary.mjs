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
  {
    file: "iroh-xcframework.yml",
    pullRequestPaths: [
      "crates/openburnbar-iroh/**",
      "scripts/build-iroh-xcframework.sh",
      ".github/workflows/iroh-xcframework.yml",
      "OpenBurnBarCore/Package.swift",
    ],
  },
  {
    file: "build-iroh-android-aar.yml",
    artifactParityStepName: "Verify committed AAR parity",
    pullRequestPaths: [
      "crates/openburnbar-iroh/**",
      "scripts/build-iroh-android-aar.sh",
      ".github/workflows/build-iroh-android-aar.yml",
      "android/openburnbar-iroh-relay/**",
      "Vendor/openburnbar-iroh.aar",
    ],
  },
  {
    file: "build-burnbar-remote-android-aar.yml",
    artifactParityStepName: "Verify committed AAR and Kotlin binding parity",
    pullRequestPaths: [
      "crates/burnbar-remote/**",
      "scripts/build-burnbar-remote-android-aar.sh",
      ".github/workflows/build-burnbar-remote-android-aar.yml",
      "android/burnbar-remote/**",
      "android/app/build.gradle.kts",
      "android/settings.gradle.kts",
      "Vendor/burnbar-remote.aar",
    ],
  },
  {
    file: "burnbar-remote-xcframework.yml",
    pullRequestPaths: [
      "crates/burnbar-remote/**",
      "scripts/build-burnbar-remote-xcframework.sh",
      "scripts/test-burnbar-remote-swift-smoke.sh",
      ".github/workflows/burnbar-remote-xcframework.yml",
      "OpenBurnBarCore/Package.swift",
      "OpenBurnBarCore/Sources/BurnBarRemote/**",
      "OpenBurnBarCore/Sources/BurnBarRemoteEngine/**",
      "OpenBurnBarCore/Tests/BurnBarRemoteEngineTests/**",
    ],
  },
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

function lineIndent(line) {
  return /^\s*/u.exec(line)?.[0].length ?? 0;
}

function yamlKeyPattern(key) {
  return `(?:"${key}"|'${key}'|${key})`;
}

function unquoteYamlScalar(value) {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function splitFlowItems(value) {
  const items = [];
  let current = "";
  let singleQuoted = false;
  let doubleQuoted = false;
  let depth = 0;
  for (let index = 0; index < value.length; index += 1) {
    const char = value[index];
    const previous = index > 0 ? value[index - 1] : "";
    if (char === "'" && !doubleQuoted) singleQuoted = !singleQuoted;
    if (char === '"' && !singleQuoted && previous !== "\\") {
      doubleQuoted = !doubleQuoted;
    }
    if (!singleQuoted && !doubleQuoted) {
      if (char === "{" || char === "[") depth += 1;
      if (char === "}" || char === "]") depth -= 1;
      if (char === "," && depth === 0) {
        items.push(current.trim());
        current = "";
        continue;
      }
    }
    current += char;
  }
  if (current.trim()) items.push(current.trim());
  return items;
}

function parseFlowMapping(value) {
  const trimmed = value.trim();
  if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return null;

  const mapping = new Map();
  for (const item of splitFlowItems(trimmed.slice(1, -1))) {
    const separator = item.indexOf(":");
    if (separator === -1) continue;
    const key = unquoteYamlScalar(item.slice(0, separator));
    const rawValue = unquoteYamlScalar(item.slice(separator + 1));
    mapping.set(key, rawValue);
  }
  return mapping;
}

function parseFlowSequence(value) {
  const trimmed = value.trim();
  if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return null;
  return splitFlowItems(trimmed.slice(1, -1)).map(unquoteYamlScalar);
}

function mappingEntry(line) {
  const match =
    /^\s*(?:"(?<double>[^"]+)"|'(?<single>[^']+)'|(?<plain>[A-Za-z0-9_-]+)):\s*(?<value>.*?)\s*$/u.exec(
      line,
    );
  if (!match?.groups) return null;
  return {
    key: match.groups.double ?? match.groups.single ?? match.groups.plain,
    value: unquoteYamlScalar(match.groups.value),
  };
}

function topLevelKeyLine(lines, key) {
  const pattern = new RegExp(`^${yamlKeyPattern(key)}:\\s*(?<value>.*)$`, "u");
  return lines.findIndex((line) => pattern.test(line));
}

function collectChildBlock(lines, parentIndex) {
  const parentIndent = lineIndent(lines[parentIndex]);
  const block = [];
  for (let index = parentIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    if (lineIndent(line) <= parentIndent) break;
    block.push({ index, line });
  }
  return block;
}

function permissionsMappings(source) {
  const lines = source.split("\n");
  const mappings = [];
  for (const [index, line] of lines.entries()) {
    const match = new RegExp(
      `^(?<indent>\\s*)${yamlKeyPattern("permissions")}:\\s*(?<value>.*)$`,
      "u",
    ).exec(line);
    if (!match?.groups) continue;

    const indent = match.groups.indent.length;
    const value = unquoteYamlScalar(match.groups.value);
    const mapping = {
      indent,
      scalar: "",
      entries: new Map(),
    };

    if (value) {
      const flowMapping = parseFlowMapping(value);
      if (flowMapping) {
        mapping.entries = flowMapping;
      } else {
        mapping.scalar = value;
      }
    }

    if (!value) {
      for (const child of collectChildBlock(lines, index)) {
        if (lineIndent(child.line) <= indent) break;
        const entry = mappingEntry(child.line);
        if (entry) mapping.entries.set(entry.key, entry.value);
      }
    }

    mappings.push(mapping);
  }
  return mappings;
}

function requireReadOnlyPermissions(file, source) {
  const topLevelPermissions = permissionsMappings(source).find(
    (mapping) => mapping.indent === 0,
  );
  if (!topLevelPermissions) {
    fail(file, "missing top-level permissions block");
    return;
  }

  if (topLevelPermissions.entries.get("contents") !== "read") {
    fail(file, "top-level permissions must include contents: read");
  }

  for (const mapping of permissionsMappings(source)) {
    if (mapping.scalar === "write-all") {
      fail(file, "must not grant permissions: write-all");
    }
    for (const [scope, value] of mapping.entries.entries()) {
      if (value === "write") {
        fail(file, `must not grant ${scope}: write`);
      }
    }
  }
}

function checkoutStepBlocks(source) {
  const lines = source.split("\n");
  const blocks = [];
  for (const [index, line] of lines.entries()) {
    if (!/^\s*uses:\s*actions\/checkout@/u.test(line)) continue;

    let start = index;
    while (start > 0 && !/^\s*-\s/u.test(lines[start])) start -= 1;

    const stepIndent = lineIndent(lines[start]);
    let end = index + 1;
    while (end < lines.length) {
      const nextLine = lines[end];
      if (nextLine.trim() && lineIndent(nextLine) <= stepIndent) break;
      if (
        nextLine.trim() &&
        lineIndent(nextLine) === stepIndent &&
        /^\s*-\s/u.test(nextLine)
      ) {
        break;
      }
      end += 1;
    }

    blocks.push(lines.slice(start, end).join("\n"));
  }
  return blocks;
}

function checkoutBlockHasPersistCredentialsFalse(block) {
  const lines = block.split("\n");
  for (const [index, line] of lines.entries()) {
    const match = /^\s*with:\s*(?<value>.*)$/u.exec(line);
    if (!match?.groups) continue;

    const inline = match.groups.value.trim();
    if (inline) {
      return parseFlowMapping(inline)?.get("persist-credentials") === "false";
    }

    const withIndent = lineIndent(line);
    for (let childIndex = index + 1; childIndex < lines.length; childIndex += 1) {
      const child = lines[childIndex];
      if (!child.trim()) continue;
      if (lineIndent(child) <= withIndent) break;
      const entry = mappingEntry(child);
      if (entry?.key === "persist-credentials") {
        return entry.value === "false";
      }
    }
  }
  return false;
}

function requireCheckoutCredentialIsolation(file, source) {
  const blocks = checkoutStepBlocks(source);
  if (blocks.length === 0) {
    fail(file, "missing actions/checkout step");
    return;
  }
  for (const [index, block] of blocks.entries()) {
    if (!checkoutBlockHasPersistCredentialsFalse(block)) {
      fail(
        file,
        `actions/checkout step ${index + 1} must set persist-credentials: false`,
      );
    }
  }
}

function stepBlocks(source) {
  const lines = source.split("\n");
  const blocks = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^\s*-\s+name:\s*(?<name>.+?)\s*$/u.exec(lines[index]);
    if (!match?.groups) continue;

    const stepIndent = lineIndent(lines[index]);
    let end = index + 1;
    while (end < lines.length) {
      const line = lines[end];
      if (line.trim() && lineIndent(line) === stepIndent && /^\s*-\s/u.test(line)) {
        break;
      }
      if (line.trim() && lineIndent(line) < stepIndent) break;
      end += 1;
    }

    blocks.push({
      start: index,
      name: unquoteYamlScalar(match.groups.name),
      source: lines.slice(index, end).join("\n"),
    });
  }
  return blocks;
}

function requireArtifactUploadsAfterParity(file, source, parityStepName) {
  if (!parityStepName) return;

  const steps = stepBlocks(source);
  const parityStep = steps.find((step) => step.name === parityStepName);
  if (!parityStep) {
    fail(file, `missing parity step before artifact upload: ${parityStepName}`);
    return;
  }

  for (const step of steps) {
    if (!/uses:\s*actions\/upload-artifact@/u.test(step.source)) continue;
    if (step.start < parityStep.start) {
      fail(file, `artifact upload step '${step.name}' must run after ${parityStepName}`);
    }
  }
}

function workflowOnValue(source) {
  const lines = source.split("\n");
  const index = topLevelKeyLine(lines, "on");
  if (index === -1) return null;
  const value = lines[index].replace(new RegExp(`^${yamlKeyPattern("on")}:\\s*`, "u"), "");
  return {
    value: unquoteYamlScalar(value),
    block: collectChildBlock(lines, index).map((entry) => entry.line),
  };
}

function triggerLine(block, trigger) {
  const pattern = new RegExp(`^\\s{2}${yamlKeyPattern(trigger)}:\\s*(?<value>.*)$`, "u");
  return block.findIndex((line) => pattern.test(line));
}

function workflowHasTrigger(onValue, trigger) {
  if (!onValue) return false;
  const flowSequence = parseFlowSequence(onValue.value);
  if (flowSequence?.includes(trigger)) return true;
  return triggerLine(onValue.block, trigger) !== -1;
}

function workflowTriggerPaths(onValue, trigger) {
  if (!onValue) return [];
  const triggerIndex = triggerLine(onValue.block, trigger);
  if (triggerIndex === -1) return [];

  const lines = onValue.block;
  let pathsIndex = -1;
  const pathsPattern = /^ {4}paths:\s*(?<value>.*)$/u;
  for (let index = triggerIndex + 1; index < lines.length; index += 1) {
    if (/^ {2}\S/u.test(lines[index])) break;
    if (pathsPattern.test(lines[index])) {
      pathsIndex = index;
      break;
    }
  }

  if (pathsIndex === -1) return [];
  const inline = pathsPattern.exec(lines[pathsIndex])?.groups?.value?.trim() ?? "";
  const flowSequence = parseFlowSequence(inline);
  if (flowSequence) return flowSequence;

  const paths = [];
  for (let index = pathsIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    if (lineIndent(line) <= 4) break;
    const match = /^\s*-\s*(?<value>.+?)\s*$/u.exec(line);
    if (match?.groups) paths.push(unquoteYamlScalar(match.groups.value));
  }
  return paths;
}

function requirePullRequestSafeTriggers(file, source, expectedPaths) {
  const onValue = workflowOnValue(source);
  if (workflowHasTrigger(onValue, "pull_request_target")) {
    fail(file, "must not use pull_request_target");
  }
  if (!workflowHasTrigger(onValue, "pull_request")) {
    fail(file, "must keep pull_request coverage for native build changes");
    return;
  }

  const pullRequestPaths = new Set(workflowTriggerPaths(onValue, "pull_request"));
  for (const expectedPath of expectedPaths) {
    if (!pullRequestPaths.has(expectedPath)) {
      fail(file, `pull_request paths must include ${expectedPath}`);
    }
  }
}

function requireSecretFree(file, source) {
  const expressions = source.matchAll(/\$\{\{(?<body>[\s\S]*?)\}\}/gu);
  for (const match of expressions) {
    const body = match.groups?.body ?? "";
    if (/\bsecrets\b/u.test(body)) {
      fail(file, "pull-request native build workflow must not reference secrets");
    }
    if (/\bgithub\s*(?:\.\s*token|\[\s*['"]token['"]\s*\])/u.test(body)) {
      fail(file, "pull-request native build workflow must not expose github.token");
    }
  }
}

for (const { file, pullRequestPaths, artifactParityStepName } of NATIVE_BUILD_WORKFLOWS) {
  const source = workflowSource(file);
  requirePullRequestSafeTriggers(file, source, pullRequestPaths);
  requireReadOnlyPermissions(file, source);
  requireSecretFree(file, source);
  requireCheckoutCredentialIsolation(file, source);
  requireArtifactUploadsAfterParity(file, source, artifactParityStepName);
}

if (failures.length > 0) {
  console.error("Native build workflow boundary check failed:");
  for (const failure of failures) console.error(` - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: native build workflows keep PR builds secret-free, checkout credentials isolated, and artifacts post-parity.",
);
