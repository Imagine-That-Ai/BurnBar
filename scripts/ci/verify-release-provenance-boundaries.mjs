#!/usr/bin/env node
/**
 * Static release provenance boundary gate.
 *
 * Keyless Sigstore attestations are only meaningful when manual release and
 * provenance dispatches run on the release tag ref, resolve the tag commit,
 * verify that commit is on main, check out that exact commit, and bind the
 * emitted predicate to the same commit/ref. This verifier keeps those release
 * invariants from becoming comment-only policy.
 *
 * This is intentionally a strict tripwire for release workflow shape. If the
 * release shell changes, update this verifier and its mutation tests in the same
 * PR rather than weakening the gate.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.RELEASE_PROVENANCE_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW_DIR = join(ROOT, ".github", "workflows");

const failures = [];
const fail = (file, message) => failures.push(`${file}: ${message}`);

function workflowSource(file) {
  const path = join(WORKFLOW_DIR, file);
  if (!existsSync(path)) {
    console.error(`MISCONFIGURED: workflow not found: ${path}`);
    process.exit(2);
  }
  return stripYamlComments(readFileSync(path, "utf8"));
}

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

function requireIncludes(file, source, needle, message) {
  if (!source.includes(needle)) fail(file, message);
}

function requireMinOccurrences(file, source, needle, minimum, message) {
  const actual = source.split(needle).length - 1;
  if (actual < minimum)
    fail(file, `${message} (found ${actual}, expected at least ${minimum})`);
}

function requirePattern(file, source, pattern, message) {
  if (!pattern.test(source)) fail(file, message);
}

function requireNoPattern(file, source, pattern, message) {
  if (pattern.test(source)) fail(file, message);
}

function workflowTopLevelPermissionsBlock(source) {
  const match = /^permissions:\n(?<body>(?:^[ \t]+[^\n]*\n?)+)/mu.exec(source);
  return match?.groups?.body ?? "";
}

function workflowOnBlock(source) {
  const match = /^on:\n(?<body>(?:^[ \t]+[^\n]*\n?)+)/mu.exec(source);
  return match?.groups?.body ?? "";
}

function workflowJobBlock(source, jobName) {
  const pattern = new RegExp(
    `^  ${jobName.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}:\\n(?<body>(?:^ {4}[^\\n]*\\n?|^\\s*$)+)`,
    "mu",
  );
  return pattern.exec(source)?.groups?.body ?? "";
}

function workflowStepBlock(source, stepName) {
  const escapedName = stepName.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const pattern = new RegExp(
    `^ {6}- name: ${escapedName}\\n(?<body>(?:^ {8}[^\\n]*\\n?|^ {10}[^\\n]*\\n?|^ {12}[^\\n]*\\n?|^\\s*$)+)`,
    "mu",
  );
  return pattern.exec(source)?.groups?.body ?? "";
}

function shellRunBlockFromStep(stepBlock) {
  const lines = stepBlock.split("\n");
  const runIndex = lines.findIndex((line) => /^\s{8}run:\s*\|/u.test(line));
  if (runIndex === -1) return "";
  const body = [];
  for (const line of lines.slice(runIndex + 1)) {
    if (/^\s{10}/u.test(line) || /^\s*$/u.test(line)) {
      body.push(line.replace(/^\s{10}/u, ""));
      continue;
    }
    break;
  }
  return body.join("\n");
}

function requireStepFailClosedMode(file, source, stepName, message) {
  const runBlock = shellRunBlockFromStep(workflowStepBlock(source, stepName));
  if (!runBlock) {
    fail(file, `${message}: missing run block`);
    return;
  }
  if (
    !runBlock.split("\n").some((line) => line.trim() === "set -euo pipefail")
  ) {
    fail(file, `${message}: step must run set -euo pipefail`);
  }
}

function requireExecutableShellLine(file, source, stepName, command, message) {
  const runBlock = shellRunBlockFromStep(workflowStepBlock(source, stepName));
  if (!runBlock) {
    fail(file, `${message}: missing run block`);
    return;
  }
  if (!runBlock.split("\n").some((line) => line.trim() === command)) {
    fail(file, `${message}: missing executable command ${command}`);
  }
}

function requireNoContinueOnError(file, source, message) {
  const offenders = source
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => /^continue-on-error\s*:/u.test(line))
    .filter((line) => !/^continue-on-error\s*:\s*false\s*$/u.test(line));
  if (offenders.length > 0) fail(file, `${message}: ${offenders.join("; ")}`);
}

function permissionValue(block, name) {
  const match = new RegExp(`^\\s*${name}:\\s*(\\S+)`, "mu").exec(block);
  return match?.[1] ?? null;
}

function requireEffectivePermission(
  file,
  source,
  jobName,
  permission,
  expected,
  message,
) {
  const jobBlock = workflowJobBlock(source, jobName);
  if (!jobBlock) {
    fail(file, `${message}: missing job ${jobName}`);
    return;
  }
  const jobPermissions =
    /^    permissions:\n(?<body>(?:^ {6}[^\n]*\n?)+)/mu.exec(jobBlock)?.groups
      ?.body;
  const value = permissionValue(
    jobPermissions ?? workflowTopLevelPermissionsBlock(source),
    permission,
  );
  if (value !== expected) {
    fail(file, `${message}: effective ${permission} must be ${expected}`);
  }
}

function requireNoWorkflowRunBranchFilter(file, source, message) {
  const onBlock = workflowOnBlock(source);
  const workflowRun =
    /workflow_run:\n(?<body>(?:^ {4}[^\n]*\n?|^ {6}[^\n]*\n?)+)/mu.exec(onBlock)
      ?.groups?.body ?? "";
  if (
    /^\s*branches\s*:/mu.test(workflowRun) ||
    /^\s*branches-ignore\s*:/mu.test(workflowRun)
  ) {
    fail(file, message);
  }
}

function shellIfBlock(source, ifNeedle) {
  const start = source.indexOf(ifNeedle);
  if (start === -1) return null;
  const lines = source.slice(start).split("\n");
  const block = [];
  let depth = 0;
  for (const line of lines) {
    const trimmed = line.trim();
    block.push(line);
    if (/^if(?:\s|!|\[\[)/u.test(trimmed)) depth += 1;
    if (trimmed === "fi") {
      depth -= 1;
      if (depth === 0) break;
    }
  }
  if (depth !== 0 || !/^\s*fi\s*$/u.test(block.at(-1) ?? "")) return null;
  return block.join("\n");
}

function requireShellIfExits(file, source, ifNeedle, message) {
  const block = shellIfBlock(source, ifNeedle);
  if (!block) {
    fail(file, `${message}: missing guard block`);
    return;
  }
  const bodyLines = block
    .split("\n")
    .slice(1, -1)
    .map((line) => line.trim())
    .filter(Boolean);
  if (bodyLines.at(-1) !== "exit 1") {
    fail(file, `${message}: guard block must end its then-branch with exit 1`);
  }
  for (const line of bodyLines.slice(0, -1)) {
    if (/^(if|elif|else|fi|for|while|until|case|function)\b/u.test(line)) {
      fail(file, `${message}: guard block must stay flat before exit 1`);
    } else if (
      /\b(?:exit|return)\b/u.test(line) ||
      /(?:&&|\|\||;\s*true\b)/u.test(line)
    ) {
      fail(
        file,
        `${message}: guard block must not contain alternate exits or short-circuit escapes`,
      );
    } else if (!/^echo\s+/u.test(line)) {
      fail(file, `${message}: guard block may only echo before exit 1`);
    }
  }
}

function stripPythonTripleQuotedStrings(source) {
  return source.replace(/(?:[rRuUbBfF]{0,2})("""|''')[\s\S]*?\1/gu, "");
}

function requirePythonIfRaises(file, source, ifNeedle, nextNeedle, message) {
  const executableSource = stripPythonTripleQuotedStrings(source);
  const start = executableSource.indexOf(ifNeedle);
  const end = nextNeedle
    ? executableSource.indexOf(nextNeedle, start + ifNeedle.length)
    : -1;
  if (start === -1 || end === -1) {
    fail(file, `${message}: missing guard block`);
    return;
  }
  const block = executableSource.slice(start, end);
  const bodyLines = block
    .split("\n")
    .slice(1)
    .map((line) => line.trim())
    .filter(Boolean);
  if (!/^raise\s+SystemExit\b/u.test(bodyLines[0] ?? "")) {
    fail(file, `${message}: guard block must directly raise SystemExit`);
  }
}

function requireOrder(file, source, before, after, message) {
  const beforeIndex = source.indexOf(before);
  const afterIndex = source.indexOf(after);
  if (beforeIndex === -1 || afterIndex === -1 || beforeIndex > afterIndex) {
    fail(file, message);
  }
}

function verifyReleaseWorkflow() {
  const file = "release.yml";
  const source = workflowSource(file);

  requireIncludes(
    file,
    source,
    "workflow_dispatch:",
    "release workflow must support explicit manual release dispatch",
  );
  requireIncludes(
    file,
    source,
    "tag:",
    "manual release dispatch must require an explicit tag input",
  );
  requirePattern(
    file,
    source,
    /id-token:\s*write/u,
    "release workflow must keep OIDC enabled for keyless provenance",
  );
  requirePattern(
    file,
    source,
    /attestations:\s*write/u,
    "release workflow must keep attestations enabled",
  );
  requireEffectivePermission(
    file,
    source,
    "build-and-release",
    "id-token",
    "write",
    "release build-and-release job must keep OIDC enabled for keyless provenance",
  );
  requireEffectivePermission(
    file,
    source,
    "build-and-release",
    "attestations",
    "write",
    "release build-and-release job must keep attestations enabled",
  );
  requireNoContinueOnError(
    file,
    source,
    "release provenance guard steps must not continue on error",
  );
  requireStepFailClosedMode(
    file,
    source,
    "Resolve release tag and version",
    "release resolve step",
  );
  requireStepFailClosedMode(
    file,
    source,
    "Check out release tag",
    "release checkout step",
  );
  requireIncludes(
    file,
    source,
    "INPUT_TAG: ${{ github.event.inputs.tag }}",
    "manual tag input must be passed through env before shell use",
  );
  requireIncludes(
    file,
    source,
    'tag_ref="refs/tags/${TAG_NAME}"',
    "release workflow must derive a refs/tags release ref",
  );
  requireIncludes(
    file,
    source,
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual release dispatch must fail unless the workflow ref is the release tag",
  );
  requireIncludes(
    file,
    source,
    "keyless provenance is tag-bound",
    "manual release guard must document the tag-bound keyless provenance reason",
  );
  requireShellIfExits(
    file,
    source,
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual release dispatch tag-ref guard",
  );
  requireOrder(
    file,
    source,
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "manual tag-ref guard must run before fetching/building release artifacts",
  );
  requireIncludes(
    file,
    source,
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "release workflow must fetch the resolved release tag ref",
  );
  requireShellIfExits(
    file,
    source,
    'if ! release_commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "release tag commit resolution guard",
  );
  requireIncludes(
    file,
    source,
    'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
    "release workflow must fetch origin/main before reachability checks",
  );
  requireShellIfExits(
    file,
    source,
    'if ! git merge-base --is-ancestor "$release_commit" origin/main; then',
    "release tag origin/main reachability guard",
  );
  requireIncludes(
    file,
    source,
    'if ! release_commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "release workflow must fail closed when the release tag commit cannot be resolved",
  );
  requireIncludes(
    file,
    source,
    'if ! git merge-base --is-ancestor "$release_commit" origin/main; then',
    "release workflow must fail closed unless the release tag commit is reachable from origin/main",
  );
  requireIncludes(
    file,
    source,
    'git checkout --detach "$RELEASE_COMMIT"',
    "release build must checkout the resolved release commit",
  );
  requireExecutableShellLine(
    file,
    source,
    "Check out release tag",
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    "release build must prove HEAD equals the resolved release commit",
  );
  requireNoPattern(
    file,
    source,
    /test "\$\(git rev-parse HEAD\)" = "\$RELEASE_COMMIT"\s*(?:\|\||\||&&|;)\s*\S/u,
    "release checkout equality assertion must not be chained or neutralized",
  );
  requireOrder(
    file,
    source,
    'git checkout --detach "$RELEASE_COMMIT"',
    "cosign attest-blob --yes",
    "release artifacts must be built from the resolved tag commit before Sigstore attestation",
  );

  requireIncludes(
    file,
    source,
    "RELEASE_COMMIT: ${{ steps.version.outputs.release_commit }}",
    "Sigstore predicate step must receive the resolved release commit",
  );
  requireIncludes(
    file,
    source,
    "RELEASE_REF: ${{ steps.version.outputs.tag_ref }}",
    "Sigstore predicate step must receive the resolved release tag ref",
  );
  requireIncludes(
    file,
    source,
    'commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()',
    "Sigstore predicate must read the actual checked-out commit",
  );
  requireIncludes(
    file,
    source,
    "if commit != release_commit:",
    "Sigstore predicate must fail closed if checkout commit drifts",
  );
  requirePythonIfRaises(
    file,
    source,
    "if commit != release_commit:",
    "predicate = {",
    "Sigstore predicate checkout drift guard",
  );
  requireIncludes(
    file,
    source,
    '"commit": release_commit',
    "Sigstore predicate must publish the resolved release commit",
  );
  requireIncludes(
    file,
    source,
    '"ref": os.environ["RELEASE_REF"]',
    "Sigstore predicate must publish the resolved release ref",
  );
  requireIncludes(
    file,
    source,
    "if ((${#PROVENANCE_PATHS[@]} == 0)); then",
    "publish job must fail closed when provenance bundles are missing",
  );
  requireShellIfExits(
    file,
    source,
    "if ((${#PROVENANCE_PATHS[@]} == 0)); then",
    "publish missing provenance bundle guard",
  );
}

function verifySupplyChainWorkflow() {
  const file = "supply-chain-provenance.yml";
  const source = workflowSource(file);

  requireIncludes(
    file,
    source,
    "workflow_dispatch:",
    "supply-chain provenance must support manual dispatch",
  );
  requireIncludes(
    file,
    source,
    "workflow_run:",
    "supply-chain provenance must support release workflow completion",
  );
  requirePattern(
    file,
    source,
    /contents:\s*read/u,
    "supply-chain provenance must not request contents:write",
  );
  requireNoPattern(
    file,
    source,
    /contents:\s*write/u,
    "supply-chain provenance must not request contents:write",
  );
  requireNoWorkflowRunBranchFilter(
    file,
    source,
    "supply-chain workflow_run trigger must not use branch filters that suppress tag release runs",
  );
  requireNoContinueOnError(
    file,
    source,
    "supply-chain provenance guard steps must not continue on error",
  );
  requirePattern(
    file,
    source,
    /id-token:\s*write/u,
    "supply-chain provenance must keep OIDC enabled",
  );
  requirePattern(
    file,
    source,
    /attestations:\s*write/u,
    "supply-chain provenance must keep attestations enabled",
  );
  requireEffectivePermission(
    file,
    source,
    "attest-release",
    "id-token",
    "write",
    "supply-chain attest-release job must keep OIDC enabled",
  );
  requireEffectivePermission(
    file,
    source,
    "attest-release",
    "attestations",
    "write",
    "supply-chain attest-release job must keep attestations enabled",
  );
  requireEffectivePermission(
    file,
    source,
    "attest-release",
    "contents",
    "read",
    "supply-chain attest-release job must keep contents read-only",
  );
  requireStepFailClosedMode(
    file,
    source,
    "Resolve release tag",
    "supply-chain resolve step",
  );
  requireStepFailClosedMode(
    file,
    source,
    "Check out release tag",
    "supply-chain checkout step",
  );
  requireIncludes(
    file,
    source,
    "INPUT_TAG: ${{ github.event.inputs.tag }}",
    "manual provenance tag input must be passed through env before shell use",
  );
  requireIncludes(
    file,
    source,
    'tag_ref="refs/tags/${TAG}"',
    "provenance workflow must derive a refs/tags release ref",
  );
  requireIncludes(
    file,
    source,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual provenance dispatch must fail unless the workflow ref is the release tag",
  );
  requireIncludes(
    file,
    source,
    "keyless provenance is tag-bound",
    "manual provenance guard must document the tag-bound keyless provenance reason",
  );
  requireShellIfExits(
    file,
    source,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual provenance dispatch tag-ref guard",
  );
  requireOrder(
    file,
    source,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "manual provenance tag-ref guard must run before fetching provenance inputs",
  );
  requireOrder(
    file,
    source,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "cosign attest --yes",
    "manual provenance tag-ref guard must run before any Sigstore attestation",
  );
  requireIncludes(
    file,
    source,
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "provenance workflow must fetch the resolved release tag ref",
  );
  requireShellIfExits(
    file,
    source,
    'if ! commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "provenance tag commit resolution guard",
  );
  requireIncludes(
    file,
    source,
    'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
    "provenance workflow must fetch origin/main before reachability checks",
  );
  requireShellIfExits(
    file,
    source,
    'if ! git merge-base --is-ancestor "$commit" origin/main; then',
    "provenance tag origin/main reachability guard",
  );
  requireIncludes(
    file,
    source,
    'if ! commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "provenance workflow must fail closed when the release tag commit cannot be resolved",
  );
  requireIncludes(
    file,
    source,
    'if ! git merge-base --is-ancestor "$commit" origin/main; then',
    "provenance workflow must fail closed unless the release tag commit is reachable from origin/main",
  );
  requireIncludes(
    file,
    source,
    'if [[ "$EVENT_NAME" != "workflow_dispatch" && ( -z "${RUN_HEAD_SHA:-}" || "$RUN_HEAD_SHA" != "$commit" ) ]]; then',
    "workflow_run provenance must fail unless the release run head is present and matches the tag commit",
  );
  requireShellIfExits(
    file,
    source,
    'if [[ "$EVENT_NAME" != "workflow_dispatch" && ( -z "${RUN_HEAD_SHA:-}" || "$RUN_HEAD_SHA" != "$commit" ) ]]; then',
    "workflow_run head-sha provenance guard",
  );
  requireIncludes(
    file,
    source,
    'git checkout --detach "$RELEASE_COMMIT"',
    "provenance workflow must checkout the resolved release commit",
  );
  requireExecutableShellLine(
    file,
    source,
    "Check out release tag",
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    "provenance workflow must prove HEAD equals the resolved release commit",
  );
  requireOrder(
    file,
    source,
    'git checkout --detach "$RELEASE_COMMIT"',
    "cosign attest --yes",
    "provenance artifacts must be attested only after the resolved tag commit is checked out",
  );
  requireNoPattern(
    file,
    source,
    /test "\$\(git rev-parse HEAD\)" = "\$RELEASE_COMMIT"\s*(?:\|\||\||&&|;)\s*\S/u,
    "supply-chain checkout equality assertion must not be chained or neutralized",
  );
}

verifyReleaseWorkflow();
verifySupplyChainWorkflow();

if (failures.length > 0) {
  console.error("Release provenance boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: release provenance workflows are tag-bound and commit-bound.",
);
