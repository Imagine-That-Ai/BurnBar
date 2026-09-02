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
  // Blank lines must consume their newline (`^[ \t]*\n`) rather than match
  // zero-width (`^\s*$`), or the capture stops at the first empty line inside
  // a job and silently truncates the block.
  const pattern = new RegExp(
    `^  ${jobName.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}:\\n(?<body>(?:^ {4}[^\\n]*\\n?|^[ \\t]*\\n)+)`,
    "mu",
  );
  return pattern.exec(source)?.groups?.body ?? "";
}

function yamlStepNameValue(line) {
  const match = /^ {6}- name:\s*(?<raw>.+?)\s*$/u.exec(line);
  if (!match?.groups?.raw) return null;

  let value = match.groups.raw.trim();
  let stripped = true;
  while (stripped) {
    stripped = false;
    const anchored = /^&[A-Za-z0-9_-]+(?:\s+|$)/u.exec(value);
    if (anchored) {
      value = value.slice(anchored[0].length).trimStart();
      stripped = true;
      continue;
    }
    const tagged =
      /^!(?:![A-Za-z0-9_-]+|<[^>]+>|[A-Za-z0-9_-]+)(?:\s+|$)/u.exec(value);
    if (tagged) {
      value = value.slice(tagged[0].length).trimStart();
      stripped = true;
    }
  }

  const singleQuoted = /^'(?<body>(?:[^']|'')*)'$/u.exec(value);
  if (singleQuoted?.groups?.body !== undefined) {
    return singleQuoted.groups.body.replaceAll("''", "'");
  }

  const doubleQuoted = /^"(?<body>(?:[^"\\]|\\.)*)"$/u.exec(value);
  if (doubleQuoted?.groups?.body !== undefined) {
    try {
      return JSON.parse(value);
    } catch {
      return doubleQuoted.groups.body.replaceAll('\\"', '"');
    }
  }

  return value;
}

function workflowStepBlocks(source, stepName) {
  const lines = source.split("\n");
  const blocks = [];
  for (const [index, line] of lines.entries()) {
    if (yamlStepNameValue(line) !== stepName) continue;
    const block = [line];
    for (const nextLine of lines.slice(index + 1)) {
      if (yamlStepNameValue(nextLine) !== null) break;
      if (/^ {4}\S/u.test(nextLine)) break;
      block.push(nextLine);
    }
    blocks.push(block.join("\n"));
  }
  return blocks;
}

function shellRunBlockFromStep(stepBlock) {
  const lines = stepBlock.split("\n");
  const runIndex = lines.findIndex((line) => /^\s{8}run:\s*\|/u.test(line));
  if (runIndex === -1) {
    const inlineRun = lines.find((line) => /^\s{8}run:\s*\S/u.test(line));
    if (!inlineRun) return "";
    const match = /^\s{8}run:\s*(?<command>.+?)\s*$/u.exec(inlineRun);
    return match?.groups?.command ?? "";
  }
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

function stripShellHeredocBodies(source) {
  const output = [];
  let delimiter = null;
  for (const line of source.split("\n")) {
    if (delimiter) {
      if (line.trim() === delimiter) delimiter = null;
      continue;
    }
    output.push(line);
    const heredoc = /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/u.exec(line);
    if (heredoc) delimiter = heredoc[1];
  }
  return output.join("\n");
}

function hasShellFlag(source, flag) {
  const escaped = flag.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return new RegExp(`(^|\\s)${escaped}(\\s|$)`, "u").test(source);
}

function namedStepBlock(file, source, stepName, message, { allowedIf } = {}) {
  const stepBlocks = workflowStepBlocks(source, stepName);
  if (stepBlocks.length === 0) {
    fail(file, `${message}: missing step`);
    return "";
  }
  if (stepBlocks.length > 1) {
    fail(file, `${message}: duplicate step name ${stepName}`);
  }
  const stepBlock = stepBlocks[0];
  const ifLines = [...stepBlock.matchAll(/^ {8}if\s*:\s*(.*\S)\s*$/gmu)];
  if (ifLines.length > 0) {
    if (!allowedIf) {
      fail(file, `${message}: protected step must not be conditional`);
    } else if (ifLines.length > 1 || !allowedIf.test(ifLines[0][1])) {
      fail(
        file,
        `${message}: protected step condition must match the approved guard`,
      );
    }
  }
  return stepBlock;
}

function conditionalNamedStepBlock(file, source, stepName, message) {
  const stepBlocks = workflowStepBlocks(source, stepName);
  if (stepBlocks.length === 0) {
    fail(file, `${message}: missing step`);
    return "";
  }
  if (stepBlocks.length > 1) {
    fail(file, `${message}: duplicate step name ${stepName}`);
  }
  return stepBlocks[0];
}

function namedStepRunBlock(file, source, stepName, message) {
  const runBlock = shellRunBlockFromStep(
    namedStepBlock(file, source, stepName, message),
  );
  if (!runBlock) fail(file, `${message}: missing run block`);
  return runBlock;
}

function conditionalNamedStepRunBlock(file, source, stepName, message) {
  const runBlock = shellRunBlockFromStep(
    conditionalNamedStepBlock(file, source, stepName, message),
  );
  if (!runBlock) fail(file, `${message}: missing run block`);
  return runBlock;
}

function requireStepFailClosedMode(file, source, stepName, message) {
  const runBlock = stripShellHeredocBodies(
    namedStepRunBlock(file, source, stepName, message),
  );
  if (!runBlock) {
    return;
  }
  if (
    !runBlock.split("\n").some((line) => line.trim() === "set -euo pipefail")
  ) {
    fail(file, `${message}: step must run set -euo pipefail`);
  }
}

function requireExecutableShellLine(file, source, stepName, command, message) {
  const runBlock = stripShellHeredocBodies(
    namedStepRunBlock(file, source, stepName, message),
  );
  if (!runBlock) {
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

// Dry-runs prove tag binding and source integrity without claiming the
// product lane is launch-ready, so the production deploy workflow may skip
// the product preflight for dry-runs only. This is the sole condition the
// protected step may carry, and only where allowDryRunSkip is set.
const DRY_RUN_SKIP_GUARD =
  /^(?:\$\{\{\s*)?steps\.tag\.outputs\.dry_run\s*!=\s*'true'(?:\s*\}\})?$/u;

function requireProductReleasePreflight(
  file,
  source,
  message,
  { allowOwnerEmergencyApproval = false, allowDryRunSkip = false } = {},
) {
  requireNoPattern(
    file,
    source,
    /\brelease_hold_bypass_reason\b/u,
    `${message}: release hold bypass inputs are not allowed`,
  );

  const stepBlock = namedStepBlock(
    file,
    source,
    "BurnBar product release preflight",
    message,
    allowDryRunSkip ? { allowedIf: DRY_RUN_SKIP_GUARD } : {},
  );
  const runBlock = shellRunBlockFromStep(stepBlock);
  if (!runBlock) {
    fail(file, `${message}: missing run block`);
    return;
  }

  const executableRunBlock = stripShellHeredocBodies(runBlock);
  if (
    !/(^|\s)python3\s+scripts\/ci\/check_burnbar_release_preflight\.py(\s|$)/u.test(
      executableRunBlock,
    )
  ) {
    fail(file, `${message}: must run the full product release preflight`);
  }
  if (
    !allowOwnerEmergencyApproval &&
    hasShellFlag(executableRunBlock, "--allow-owner-emergency-approval")
  ) {
    fail(
      file,
      `${message}: owner-emergency approval is not allowed in this workflow`,
    );
  }
  if (
    allowOwnerEmergencyApproval &&
    hasShellFlag(executableRunBlock, "--allow-owner-emergency-approval") &&
    !/--expected-release-tag\s+["']?\$\{\{\s*steps\.version\.outputs\.tag_name\s*\}\}["']?/u.test(
      executableRunBlock,
    )
  ) {
    fail(
      file,
      `${message}: owner-emergency approval must be bound to the resolved release tag`,
    );
  }
  if (hasShellFlag(executableRunBlock, "--source-provenance-only")) {
    fail(file, `${message}: product preflight must not be source-only`);
  }
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
  const executableSource = stripShellHeredocBodies(source);
  const start = executableSource.indexOf(ifNeedle);
  if (start === -1) return null;
  const lines = executableSource.slice(start).split("\n");
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
  const releaseResolveStep = namedStepBlock(
    file,
    source,
    "Resolve release tag and version",
    "release resolve step",
  );
  const releaseResolveRun = namedStepRunBlock(
    file,
    source,
    "Resolve release tag and version",
    "release resolve step",
  );
  const releaseAttestationStep = namedStepBlock(
    file,
    source,
    "Sigstore blob attestations (SBOM + VEX + checksums + binaries)",
    "release Sigstore attestation step",
  );
  const releaseAttestationRun = namedStepRunBlock(
    file,
    source,
    "Sigstore blob attestations (SBOM + VEX + checksums + binaries)",
    "release Sigstore attestation step",
  );
  const sparkleSignerRun = namedStepRunBlock(
    file,
    source,
    "Install Sparkle signing tools",
    "Sparkle signer installation step",
  );
  const releaseFeedRun = namedStepRunBlock(
    file,
    source,
    "Generate direct-download update feeds",
    "release update-feed generation step",
  );
  const releasePublicationStageRun = namedStepRunBlock(
    file,
    source,
    "Stage the complete general release asset set",
    "release publication staging step",
  );
  const atomicReleasePublishRun = namedStepRunBlock(
    file,
    source,
    "Publish the complete verified release set from one draft state machine",
    "atomic release publish step",
  );
  const mobileBypassStep = conditionalNamedStepBlock(
    file,
    source,
    "Validate mobile unit test bypass reason",
    "release mobile-test bypass validation step",
  );
  const mobileBypassRun = conditionalNamedStepRunBlock(
    file,
    source,
    "Validate mobile unit test bypass reason",
    "release mobile-test bypass validation step",
  );

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
  requireProductReleasePreflight(
    file,
    source,
    "release product preflight must be mandatory",
    { allowOwnerEmergencyApproval: true },
  );
  requireIncludes(
    file,
    source,
    "run_mobile_unit_tests:",
    "release workflow must expose the mobile test gate input",
  );
  requireIncludes(
    file,
    source,
    "mobile_unit_test_bypass_reason:",
    "release workflow must expose a named mobile test bypass evidence input",
  );
  requireIncludes(
    file,
    mobileBypassStep,
    "github.event_name == 'workflow_dispatch' && !inputs.run_mobile_unit_tests",
    "mobile test bypass validation must run only for explicit manual bypasses",
  );
  requireIncludes(
    file,
    mobileBypassRun,
    "set -euo pipefail",
    "mobile test bypass validation must fail closed",
  );
  requireIncludes(
    file,
    mobileBypassRun,
    "if ((${#MOBILE_UNIT_TEST_BYPASS_REASON} < 80)); then",
    "mobile test bypass validation must reject weak one-line reasons",
  );
  requireIncludes(
    file,
    mobileBypassRun,
    "\\b(owner|approved|approval|approver)\\b",
    "mobile test bypass validation must require owner approval evidence",
  );
  requireIncludes(
    file,
    mobileBypassRun,
    "\\b(mobile|ios|simulator|OpenBurnBarMobileTests|test-openburnbar-mobile)\\b",
    "mobile test bypass validation must require mobile validation evidence",
  );
  requireIncludes(
    file,
    mobileBypassRun,
    "https://github\\.com/Imagine-That-Ai/BurnBar/(actions/runs/[0-9]+|pull/[0-9]+)|[0-9a-f]{40}",
    "mobile test bypass validation must require an auditable run, PR, or commit reference",
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
  requireStepFailClosedMode(
    file,
    source,
    "Install Sparkle signing tools",
    "Sparkle signer installation step",
  );
  requireIncludes(
    file,
    sparkleSignerRun,
    'find "$SPARKLE_CASKROOM" -name sign_update -type f -print -quit',
    "Sparkle signer must be resolved as a regular file inside the Homebrew Sparkle cask",
  );
  requireNoPattern(
    file,
    sparkleSignerRun,
    /find\s+"\$SPARKLE_CASKROOM"\s+\/Applications/u,
    "Sparkle signer discovery must not search globally writable or pre-existing application paths",
  );
  requireNoPattern(
    file,
    sparkleSignerRun,
    /-type\s+l/u,
    "Sparkle signer discovery must not accept symlinked tools",
  );
  requireNoPattern(
    file,
    sparkleSignerRun,
    /chmod\s+\+x\s+"\$SPARKLE_SIGN_UPDATE"/u,
    "Sparkle signer discovery must not mutate tool executability after discovery",
  );
  requireIncludes(
    file,
    sparkleSignerRun,
    'SPARKLE_CASKROOM_REAL="$(python3 -c',
    "Sparkle signer boundary must canonicalize the cask root",
  );
  requireIncludes(
    file,
    sparkleSignerRun,
    'SPARKLE_SIGN_UPDATE_REAL="$(python3 -c',
    "Sparkle signer boundary must canonicalize the selected signer",
  );
  requireIncludes(
    file,
    sparkleSignerRun,
    'if [[ -L "$SPARKLE_SIGN_UPDATE" ]]; then',
    "Sparkle signer boundary must fail closed on symlinked signer tools",
  );
  requireShellIfExits(
    file,
    sparkleSignerRun,
    'if [[ -L "$SPARKLE_SIGN_UPDATE" ]]; then',
    "Sparkle signer symlink guard",
  );
  requireIncludes(
    file,
    sparkleSignerRun,
    'case "$SPARKLE_SIGN_UPDATE_REAL" in',
    "Sparkle signer boundary must enforce canonical signer path containment",
  );
  requireIncludes(
    file,
    releaseResolveStep,
    "INPUT_TAG: ${{ github.event.inputs.tag }}",
    "manual tag input must be passed through env before shell use",
  );
  requireIncludes(
    file,
    releaseResolveRun,
    'tag_ref="refs/tags/${TAG_NAME}"',
    "release workflow must derive a refs/tags release ref",
  );
  requireIncludes(
    file,
    releaseResolveRun,
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual release dispatch must fail unless the workflow ref is the release tag",
  );
  requireIncludes(
    file,
    releaseResolveRun,
    "keyless provenance is tag-bound",
    "manual release guard must document the tag-bound keyless provenance reason",
  );
  requireShellIfExits(
    file,
    releaseResolveRun,
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual release dispatch tag-ref guard",
  );
  requireOrder(
    file,
    releaseResolveRun,
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "manual tag-ref guard must run before fetching/building release artifacts",
  );
  requireIncludes(
    file,
    releaseResolveRun,
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "release workflow must fetch the resolved release tag ref",
  );
  requireShellIfExits(
    file,
    releaseResolveRun,
    'if ! release_commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "release tag commit resolution guard",
  );
  requireIncludes(
    file,
    releaseResolveRun,
    'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
    "release workflow must fetch origin/main before reachability checks",
  );
  requireShellIfExits(
    file,
    releaseResolveRun,
    'if ! git merge-base --is-ancestor "$release_commit" origin/main; then',
    "release tag origin/main reachability guard",
  );
  requireIncludes(
    file,
    releaseResolveRun,
    'if ! release_commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "release workflow must fail closed when the release tag commit cannot be resolved",
  );
  requireIncludes(
    file,
    releaseResolveRun,
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
    releaseFeedRun,
    'DMG_NAME="$(basename "$DMG_PATH")"',
    "release feed generation must pass only the DMG basename to the appcast generator",
  );
  requireIncludes(
    file,
    releaseFeedRun,
    'ZIP_NAME="$(basename "$ZIP_PATH")"',
    "release feed generation must pass only the ZIP basename to the appcast generator",
  );
  requireIncludes(
    file,
    releaseFeedRun,
    'SOURCE_NAME="$(basename "$SOURCE_PATH")"',
    "release feed generation must pass only the source archive basename to the appcast generator",
  );
  requireIncludes(
    file,
    releaseFeedRun,
    '--release-dir "$RUNNER_TEMP"',
    "release feed generation must scope appcast inputs to the runner temp release directory",
  );
  requireIncludes(
    file,
    releaseFeedRun,
    '--appcast-name "$(basename "$APPCAST_PATH")"',
    "release feed generation must pass only the appcast output basename",
  );
  requireIncludes(
    file,
    releaseFeedRun,
    '--latest-name "$(basename "$LATEST_PATH")"',
    "release feed generation must pass only the latest-metadata output basename",
  );

  requireIncludes(
    file,
    releaseAttestationStep,
    "RELEASE_COMMIT: ${{ needs.release-preflight.outputs.release_commit }}",
    "Sigstore predicate step must receive the resolved release commit",
  );
  requireIncludes(
    file,
    releaseAttestationStep,
    "RELEASE_REF: ${{ needs.release-preflight.outputs.tag_ref }}",
    "Sigstore predicate step must receive the resolved release tag ref",
  );

  // Parallel-lane shape invariants: the resolve/scan/preflight steps live in
  // the release-preflight job, packaging consumes its outputs through `needs`,
  // and publication preparation gates on every validation lane. Atomic
  // publication then consumes that prepared set plus the native evidence
  // chain. These keep the split job graph from silently dropping a gate or
  // resolving the tag twice.
  const releasePreflightJob = workflowJobBlock(source, "release-preflight");
  if (!releasePreflightJob) {
    fail(file, "release workflow must define the release-preflight job");
  }
  for (const requiredStep of [
    "- name: Resolve release tag and version",
    "- name: Check out release tag",
    "- name: BurnBar product release preflight",
    "- name: Scan publishable tree for secrets",
  ]) {
    requireIncludes(
      file,
      releasePreflightJob,
      requiredStep,
      `release-preflight job must own the protected step "${requiredStep.replace("- name: ", "")}"`,
    );
  }

  const packagingJob = workflowJobBlock(source, "build-and-release");
  if (
    !packagingJob.includes("needs: release-preflight") &&
    !/^ {8}(?:- )?release-preflight,?\s*$/mu.test(packagingJob)
  ) {
    fail(
      file,
      "packaging job must consume the resolved release tag from release-preflight",
    );
  }
  requireStepFailClosedMode(
    file,
    source,
    "Check out release tag for packaging",
    "release packaging checkout step",
  );
  requireExecutableShellLine(
    file,
    source,
    "Check out release tag for packaging",
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    "release packaging checkout must prove HEAD equals the resolved release commit",
  );

  const publicationPreparationJob = workflowJobBlock(
    source,
    "prepare-release-publication",
  );
  if (!publicationPreparationJob) {
    fail(file, "release workflow must define the publication preparation job");
  }
  for (const requiredNeed of [
    "release-preflight",
    "release-swift-gate",
    "release-app-gate",
    "release-sqlcipher-gate",
    "release-mobile-gate",
    "release-android-gate",
    "release-functions-gate",
    "release-extension-gate",
    "release-supply-chain-gate",
    "build-and-release",
    "domain-core-ios-release-evidence",
    "smoke-test",
    "apple-native-prepublication",
  ]) {
    requirePattern(
      file,
      publicationPreparationJob,
      new RegExp(`^      - ${requiredNeed}$`, "mu"),
      `publication preparation must gate on ${requiredNeed} via needs`,
    );
  }
  // Job-level `if:` sits at 4-space indent; step-level cleanup ifs (8-space)
  // such as `if: always()` on config cleanup are fine.
  requireNoPattern(
    file,
    publicationPreparationJob,
    /^    if\s*:.*always\(\)/mu,
    "publication preparation must not use always() to bypass failed release lanes",
  );

  const atomicPublicationJob = workflowJobBlock(
    source,
    "domain-core-native-release-evidence",
  );
  if (!atomicPublicationJob) {
    fail(file, "release workflow must define the atomic publication job");
  }
  for (const requiredNeed of [
    "release-preflight",
    "domain-core-native-release-gate",
    "build-and-release",
    "apple-native-prepublication",
    "prepare-release-publication",
  ]) {
    requirePattern(
      file,
      atomicPublicationJob,
      new RegExp(`^      - ${requiredNeed}$`, "mu"),
      `atomic publication must gate on ${requiredNeed} via needs`,
    );
  }
  requireIncludes(
    file,
    atomicPublicationJob,
    "needs.prepare-release-publication.result == 'success' && needs.apple-native-prepublication.result == 'success'",
    "atomic publication must require successful preparation and Apple prepublication",
  );
  requireNoPattern(
    file,
    atomicPublicationJob,
    /^    if\s*:.*always\(\)/mu,
    "atomic publication must not use always() to bypass failed release lanes",
  );
  requireIncludes(
    file,
    releaseAttestationRun,
    'commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()',
    "Sigstore predicate must read the actual checked-out commit",
  );
  requireIncludes(
    file,
    releaseAttestationRun,
    "if commit != release_commit:",
    "Sigstore predicate must fail closed if checkout commit drifts",
  );
  requirePythonIfRaises(
    file,
    releaseAttestationRun,
    "if commit != release_commit:",
    "predicate = {",
    "Sigstore predicate checkout drift guard",
  );
  requireIncludes(
    file,
    releaseAttestationRun,
    '"commit": release_commit',
    "Sigstore predicate must publish the resolved release commit",
  );
  requireIncludes(
    file,
    releaseAttestationRun,
    '"ref": os.environ["RELEASE_REF"]',
    "Sigstore predicate must publish the resolved release ref",
  );
  requireIncludes(
    file,
    releasePublicationStageRun,
    "if ((${#PROVENANCE_PATHS[@]} == 0)); then",
    "publication preparation must fail closed when provenance bundles are missing",
  );
  requireNoPattern(
    file,
    releasePublicationStageRun,
    /\b(?:mapfile|readarray)\b/u,
    "publication preparation must stay compatible with the macOS runner's Bash 3.2 shell",
  );
  requireShellIfExits(
    file,
    releasePublicationStageRun,
    "if ((${#PROVENANCE_PATHS[@]} == 0)); then",
    "publication preparation missing provenance bundle guard",
  );
  requireStepFailClosedMode(
    file,
    source,
    "Stage the complete general release asset set",
    "release publication staging step",
  );
  requireStepFailClosedMode(
    file,
    source,
    "Publish the complete verified release set from one draft state machine",
    "atomic release publish step",
  );
  requireIncludes(
    file,
    atomicReleasePublishRun,
    "if ((${#asset_args[@]} == 0)); then",
    "atomic publication must fail closed when the retained release set is empty",
  );
  requireShellIfExits(
    file,
    atomicReleasePublishRun,
    "if ((${#asset_args[@]} == 0)); then",
    "atomic publication missing retained release-set guard",
  );
  requireIncludes(
    file,
    atomicReleasePublishRun,
    'node scripts/ci/publish-apple-android-release.mjs --manifest "$manifest"',
    "atomic publication must publish the verified Apple and Android manifest",
  );
}

function verifyProductionDeployWorkflow() {
  const file = "deploy-production.yml";
  const source = workflowSource(file);

  requireIncludes(
    file,
    source,
    "workflow_dispatch:",
    "production deploy workflow must support explicit manual dispatch",
  );
  requireProductReleasePreflight(
    file,
    source,
    "production deploy product preflight must be mandatory",
    { allowDryRunSkip: true },
  );
}

function verifySupplyChainWorkflow() {
  const file = "supply-chain-provenance.yml";
  const source = workflowSource(file);
  const provenanceResolveStep = namedStepBlock(
    file,
    source,
    "Resolve release tag",
    "supply-chain resolve step",
  );
  const provenanceResolveRun = namedStepRunBlock(
    file,
    source,
    "Resolve release tag",
    "supply-chain resolve step",
  );

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
    "supply-chain provenance must request contents:read",
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
    provenanceResolveStep,
    "INPUT_TAG: ${{ github.event.inputs.tag }}",
    "manual provenance tag input must be passed through env before shell use",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    'tag_ref="refs/tags/${TAG}"',
    "provenance workflow must derive a refs/tags release ref",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual provenance dispatch must fail unless the workflow ref is the release tag",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    "keyless provenance is tag-bound",
    "manual provenance guard must document the tag-bound keyless provenance reason",
  );
  requireShellIfExits(
    file,
    provenanceResolveRun,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    "manual provenance dispatch tag-ref guard",
  );
  requireOrder(
    file,
    provenanceResolveRun,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "manual provenance tag-ref guard must run before fetching provenance inputs",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    "provenance workflow must fetch the resolved release tag ref",
  );
  requireShellIfExits(
    file,
    provenanceResolveRun,
    'if ! commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "provenance tag commit resolution guard",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
    "provenance workflow must fetch origin/main before reachability checks",
  );
  requireShellIfExits(
    file,
    provenanceResolveRun,
    'if ! git merge-base --is-ancestor "$commit" origin/main; then',
    "provenance tag origin/main reachability guard",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    'if ! commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then',
    "provenance workflow must fail closed when the release tag commit cannot be resolved",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    'if ! git merge-base --is-ancestor "$commit" origin/main; then',
    "provenance workflow must fail closed unless the release tag commit is reachable from origin/main",
  );
  requireIncludes(
    file,
    provenanceResolveRun,
    'if [[ "$EVENT_NAME" != "workflow_dispatch" && ( -z "${RUN_HEAD_SHA:-}" || "$RUN_HEAD_SHA" != "$commit" ) ]]; then',
    "workflow_run provenance must fail unless the release run head is present and matches the tag commit",
  );
  requireShellIfExits(
    file,
    provenanceResolveRun,
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
    "cosign attest-blob --yes",
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
verifyProductionDeployWorkflow();
verifySupplyChainWorkflow();

if (failures.length > 0) {
  console.error("Release provenance boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: release provenance workflows are tag-bound and commit-bound.",
);
