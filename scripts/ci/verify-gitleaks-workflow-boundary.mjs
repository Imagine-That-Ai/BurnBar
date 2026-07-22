#!/usr/bin/env node
/**
 * Verifies that PR secret scanning does not trust head-branch gitleaks policy.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const DEFAULT_WORKFLOW = ".github/workflows/security-pr.yml";

export function findGitleaksWorkflowBoundaryViolations(workflowText) {
  const failures = [];
  const runGitleaksStep = extractNamedStep(workflowText, "Run gitleaks");
  if (!runGitleaksStep) {
    return ["security-pr.yml is missing the Run gitleaks step"];
  }

  requireIncludes(
    failures,
    runGitleaksStep,
    "EVENT_NAME: ${{ github.event_name }}",
    "Run gitleaks must receive github.event_name",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'GITLEAKS_CONFIG_PATH=".gitleaks.toml"',
    "Run gitleaks must default to the checked-out config for push-to-main scans",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'GITLEAKS_IGNORE_PATH=".gitleaksignore"',
    "Run gitleaks must default to the checked-out ignore file for push-to-main scans",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'if [[ "${EVENT_NAME}" != "push" ]]; then',
    "Run gitleaks must switch away from head config for PR/merge-group scans",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'GITLEAKS_CONFIG_PATH="${RUNNER_TEMP}/gitleaks-base.toml"',
    "Run gitleaks must write a trusted base config to RUNNER_TEMP",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'GITLEAKS_IGNORE_PATH="${RUNNER_TEMP}/gitleaks-base.ignore"',
    "Run gitleaks must write a trusted base ignore file to RUNNER_TEMP",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'git show "${BASE_SHA}:.gitleaks.toml" > "${GITLEAKS_CONFIG_PATH}"',
    "Run gitleaks must load .gitleaks.toml from BASE_SHA",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'git show "${BASE_SHA}:.gitleaksignore" > "${GITLEAKS_IGNORE_PATH}"',
    "Run gitleaks must load .gitleaksignore from BASE_SHA",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'Refusing to use head .gitleaks.toml',
    "Run gitleaks must fail closed when the trusted base config cannot be resolved",
  );
  requireIncludes(
    failures,
    runGitleaksStep,
    'Refusing to use head .gitleaksignore',
    "Run gitleaks must fail closed when the trusted base ignore file cannot be resolved",
  );

  const directHeadConfig = runGitleaksStep.match(/--config\s+\.gitleaks\.toml/u);
  if (directHeadConfig) {
    failures.push("Run gitleaks still passes --config .gitleaks.toml directly");
  }

  const directHeadIgnore = runGitleaksStep.match(
    /--gitleaks-ignore-path\s+\.gitleaksignore/u,
  );
  if (directHeadIgnore) {
    failures.push(
      "Run gitleaks still passes --gitleaks-ignore-path .gitleaksignore directly",
    );
  }

  const configReferences = countNeedle(runGitleaksStep, '--config "${GITLEAKS_CONFIG_PATH}"');
  if (configReferences !== 2) {
    failures.push(
      `Run gitleaks should use GITLEAKS_CONFIG_PATH in both scan branches (found ${configReferences})`,
    );
  }

  const ignoreReferences = countNeedle(
    runGitleaksStep,
    '--gitleaks-ignore-path "${GITLEAKS_IGNORE_PATH}"',
  );
  if (ignoreReferences !== 2) {
    failures.push(
      `Run gitleaks should use GITLEAKS_IGNORE_PATH in both scan branches (found ${ignoreReferences})`,
    );
  }

  return failures;
}

function stripYamlComment(line) {
  let singleQuoted = false;
  let doubleQuoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const previous = line[index - 1];
    if (char === "'" && !doubleQuoted) singleQuoted = !singleQuoted;
    if (char === '"' && !singleQuoted && previous !== "\\") {
      doubleQuoted = !doubleQuoted;
    }
    if (char === "#" && !singleQuoted && !doubleQuoted) {
      return line.slice(0, index).trimEnd();
    }
  }
  return line;
}

function stripYamlComments(source) {
  return source.split("\n").map(stripYamlComment).join("\n");
}

function indentOf(line) {
  return line.match(/^(\s*)/u)[1].length;
}

function isBlank(line) {
  return line.trim().length === 0;
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function extractNamedStep(source, stepName) {
  const lines = stripYamlComments(source).split("\n");
  const start = lines.findIndex((line) =>
    line.match(new RegExp(`^      - name:\\s*${escapeRegex(stepName)}\\s*$`, "u")),
  );
  if (start === -1) return "";

  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    if (indentOf(line) === 6 && /^      - (?:name|uses|run):/u.test(line)) {
      end = index;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}

function requireIncludes(failures, source, needle, message) {
  if (!source.includes(needle)) failures.push(message);
}

function countNeedle(source, needle) {
  let count = 0;
  let index = source.indexOf(needle);
  while (index !== -1) {
    count += 1;
    index = source.indexOf(needle, index + needle.length);
  }
  return count;
}

export function main(argv = process.argv) {
  const workflowPath = argv[2] ?? DEFAULT_WORKFLOW;
  const workflowText = readFileSync(workflowPath, "utf8");
  const failures = findGitleaksWorkflowBoundaryViolations(workflowText);
  if (failures.length === 0) {
    console.log("OK: security-pr gitleaks scan uses trusted base policy for PR checks.");
    return 0;
  }

  console.error("security-pr gitleaks workflow boundary check failed:");
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  return 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
