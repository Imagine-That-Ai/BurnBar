#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const EXPECTED_REPOSITORY = "Imagine-That-Ai/BurnBar";
export const EXPECTED_ORGANIZATION = "Imagine-That-Ai";
export const MAX_RUNNER_GROUPS = 32;
export const EXPECTED_VM = Object.freeze({
  name: "OpenBurnBar Linux",
  uuid: "7923D0DD-6367-45EA-9064-152EECC1AC65",
});
export const REQUIRED_VARIABLES = Object.freeze([
  "OPENBURNBAR_P16_MACOS_COORDINATION_ROOT",
  "OPENBURNBAR_P16_LINUX_COORDINATION_ROOT",
]);
export const REQUIRED_RUNNER_LABELS = Object.freeze([
  "self-hosted",
  "macOS",
  "ARM64",
  "m5max",
  "ios",
]);

const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/iu;
const DEVICE_IDENTIFIER = /^(?:[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}|[0-9A-F-]{24,40})$/iu;
const SAFE_TEXT = /^[^\u0000-\u001f\u007f]{1,256}$/u;
const SAFE_LABEL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/u;

export class PreflightValidationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "PreflightValidationError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new PreflightValidationError(code, message);
}

function plainObject(value, label) {
  if (
    value === null
    || typeof value !== "object"
    || Array.isArray(value)
    || Object.getPrototypeOf(value) !== Object.prototype
  ) {
    fail("malformed_input", `${label} must be a JSON object`);
  }
  return value;
}

function parseJson(raw, label) {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 10_000_000) {
    fail("malformed_input", `${label} output is missing or unreasonably large`);
  }
  try {
    return JSON.parse(raw);
  } catch {
    fail("malformed_input", `${label} output is not valid JSON`);
  }
}

function safeString(value, label) {
  if (typeof value !== "string" || value !== value.trim() || !SAFE_TEXT.test(value)) {
    fail("malformed_input", `${label} is malformed`);
  }
  return value;
}

function parsePagedCollection(raw, collectionKey, label) {
  const parsed = parseJson(raw, label);
  const pages = Array.isArray(parsed) ? parsed : [parsed];
  if (pages.length === 0) fail("malformed_input", `${label} contains no pages`);

  let totalCount = null;
  const rows = [];
  for (const [index, rawPage] of pages.entries()) {
    const page = plainObject(rawPage, `${label} page ${index + 1}`);
    if (!Number.isSafeInteger(page.total_count) || page.total_count < 0) {
      fail("malformed_input", `${label} total_count is malformed`);
    }
    if (totalCount === null) totalCount = page.total_count;
    if (page.total_count !== totalCount || !Array.isArray(page[collectionKey])) {
      fail("ambiguous_input", `${label} pagination is inconsistent`);
    }
    rows.push(...page[collectionKey]);
  }
  if (rows.length !== totalCount) {
    fail("ambiguous_input", `${label} is truncated, duplicated, or ambiguously paginated`);
  }
  return rows;
}

export function parseRepositoryIdentityOutput(raw) {
  const value = plainObject(parseJson(raw, "GitHub repository identity"), "GitHub repository identity");
  if (Object.keys(value).length !== 1 || value.nameWithOwner !== EXPECTED_REPOSITORY) {
    fail("repository_mismatch", "GitHub did not return the exact expected repository identity");
  }
  return value.nameWithOwner;
}

export function parseUtmListOutput(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.includes("\u0000")) {
    fail("malformed_input", "UTM list output is malformed");
  }
  const lines = raw.replace(/\r\n/gu, "\n").split("\n").filter((line) => line.trim() !== "");
  if (lines.shift()?.trim() !== "UUID                                 Status   Name") {
    fail("malformed_input", "UTM list output has an unexpected header");
  }

  const records = [];
  const uuids = new Set();
  for (const line of lines) {
    const match = line.match(
      /^([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\s+([a-z][a-z-]*)\s{2,}(.+)$/iu,
    );
    if (!match) fail("malformed_input", "UTM list output contains a malformed record");
    const [, rawUuid, status, rawName] = match;
    const uuid = rawUuid.toUpperCase();
    const name = safeString(rawName, "UTM virtual-machine name");
    if (!UUID.test(uuid) || uuids.has(uuid)) {
      fail("duplicate_input", "UTM list output contains a duplicate or malformed UUID");
    }
    uuids.add(uuid);
    records.push({ uuid, status, name });
  }

  const byUuid = records.filter((record) => record.uuid === EXPECTED_VM.uuid);
  const byName = records.filter((record) => record.name === EXPECTED_VM.name);
  if (byUuid.length !== 1 || byName.length !== 1) {
    fail("vm_identity_missing", "the exact documented UTM name and UUID were not found exactly once");
  }
  if (byUuid[0] !== byName[0]) {
    fail("vm_identity_spoofed", "the documented UTM name and UUID belong to different records");
  }
  return byUuid[0];
}

export function parseRepositoryVariablesOutput(raw) {
  const rows = parsePagedCollection(raw, "variables", "GitHub repository variables");
  const variables = new Map();
  for (const rawRow of rows) {
    const row = plainObject(rawRow, "GitHub repository variable");
    const name = safeString(row.name, "GitHub repository variable name");
    if (typeof row.value !== "string" || row.value.length === 0 || row.value.includes("\u0000")) {
      fail("malformed_input", "GitHub repository variable value is malformed");
    }
    if (variables.has(name)) {
      fail("duplicate_input", "GitHub repository variables contain a duplicate name");
    }
    variables.set(name, row.value);
  }
  return variables;
}

function validateLexicalAbsolutePath(value, label) {
  if (
    typeof value !== "string"
    || value.length < 2
    || value.length > 4096
    || /[\u0000-\u001f\u007f]/u.test(value)
    || !path.posix.isAbsolute(value)
    || path.posix.normalize(value) !== value
    || value.endsWith("/")
    || value === "/"
  ) {
    fail("invalid_coordination_root", `${label} must be a canonical absolute non-root POSIX path`);
  }
  return value;
}

export function validateLinuxGuestCoordinationRoot(value) {
  return {
    path: validateLexicalAbsolutePath(value, "Linux guest coordination root"),
    validation: "lexical-only",
    shareEquivalenceValidated: false,
  };
}

export function validateMacCoordinationRoot(value, metadata, currentUid) {
  const root = validateLexicalAbsolutePath(value, "macOS coordination root");
  const info = plainObject(metadata, "macOS coordination-root metadata");
  if (!Number.isSafeInteger(currentUid) || currentUid < 1) {
    fail("invalid_host_identity", "current host user identity is unavailable");
  }
  if (
    typeof info.isDirectory !== "boolean"
    || typeof info.isSymbolicLink !== "boolean"
    || !Number.isSafeInteger(info.uid)
    || !Number.isSafeInteger(info.mode)
    || typeof info.realpath !== "string"
  ) {
    fail("malformed_input", "macOS coordination-root metadata is malformed");
  }
  if (!info.isDirectory || info.isSymbolicLink || info.realpath !== root) {
    fail("untrusted_mac_root", "macOS coordination root must be a real non-symlink directory");
  }
  if (info.uid !== currentUid) {
    fail("untrusted_mac_root", "macOS coordination root must be owned by the invoking user");
  }
  if ((info.mode & 0o7777) !== 0o700) {
    fail("untrusted_mac_root", "macOS coordination root mode must be exactly 0700");
  }
  return {
    path: root,
    ownerUid: info.uid,
    mode: "0700",
    validation: "host-filesystem",
  };
}

function parseXctraceDeviceLine(line, section) {
  const withVersion = line.match(/^(.*?) \(([^()]*)\) \(([0-9A-F-]{24,40})\)$/iu);
  const withoutVersion = line.match(/^(.*?) \(([0-9A-F-]{24,40})\)$/iu);
  const match = withVersion ?? withoutVersion;
  if (!match) fail("malformed_input", "xcrun device output contains a malformed record");

  const name = safeString(match[1], "xcrun device name");
  const identifier = (withVersion ? match[3] : match[2]).toUpperCase();
  if (!DEVICE_IDENTIFIER.test(identifier)) {
    fail("malformed_input", "xcrun device output contains a malformed identifier");
  }
  if (section !== "simulators" && /simulator/iu.test(name)) {
    fail("device_identity_spoofed", "a Simulator-labelled device appeared in a physical-device section");
  }
  return {
    name,
    identifier,
    section,
    isIPad: /\bipad\b/iu.test(name),
  };
}

export function parseXcrunDeviceOutput(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.includes("\u0000")) {
    fail("malformed_input", "xcrun device output is malformed");
  }
  const headerMap = new Map([
    ["== Devices ==", "devices"],
    ["== Devices Offline ==", "offline"],
    ["== Simulators ==", "simulators"],
  ]);
  const seenHeaders = new Set();
  const devices = [];
  const identifiers = new Set();
  let section = null;

  for (const rawLine of raw.replace(/\r\n/gu, "\n").split("\n")) {
    const line = rawLine.trim();
    if (line === "") continue;
    if (line.startsWith("==") && line.endsWith("==")) {
      if (!headerMap.has(line) || seenHeaders.has(line)) {
        fail("ambiguous_input", "xcrun device output contains an unknown or duplicate section");
      }
      section = headerMap.get(line);
      seenHeaders.add(line);
      continue;
    }
    if (section === null) fail("malformed_input", "xcrun device output has a record before its section");
    const device = parseXctraceDeviceLine(line, section);
    if (identifiers.has(device.identifier)) {
      fail("duplicate_input", "xcrun device output contains a duplicate device identifier");
    }
    identifiers.add(device.identifier);
    devices.push(device);
  }
  if (!seenHeaders.has("== Devices ==") || !seenHeaders.has("== Simulators ==")) {
    fail("malformed_input", "xcrun device output is missing required physical or Simulator sections");
  }

  const availableIPads = devices.filter((device) => device.section === "devices" && device.isIPad);
  const offlineIPads = devices.filter((device) => device.section === "offline" && device.isIPad);
  if (availableIPads.length > 1) {
    fail("ambiguous_ipad", "more than one available physical iPad was discovered");
  }
  const selected = availableIPads[0] ?? null;
  return {
    availableCount: availableIPads.length,
    offlineCount: offlineIPads.length,
    selected: selected === null ? null : {
      name: selected.name,
      identifierSha256: crypto.createHash("sha256").update(selected.identifier).digest("hex"),
      simulator: false,
    },
  };
}

function normalizedLabel(value) {
  return value.toLocaleLowerCase("en-US");
}

export function parseOrganizationRunnersOutput(raw) {
  const rows = parsePagedCollection(raw, "runners", "GitHub organization runners");
  const ids = new Set();
  const names = new Set();
  const required = new Set(REQUIRED_RUNNER_LABELS.map(normalizedLabel));
  const runners = [];

  for (const rawRow of rows) {
    const row = plainObject(rawRow, "GitHub organization runner");
    if (!Number.isSafeInteger(row.id) || row.id < 1) {
      fail("malformed_input", "GitHub organization runner id is malformed");
    }
    const name = safeString(row.name, "GitHub organization runner name");
    const os = safeString(row.os, "GitHub organization runner operating system");
    const status = safeString(row.status, "GitHub organization runner status");
    if (!["online", "offline"].includes(status) || typeof row.busy !== "boolean" || !Array.isArray(row.labels)) {
      fail("malformed_input", "GitHub organization runner state is malformed");
    }
    if (ids.has(row.id) || names.has(name)) {
      fail("duplicate_input", "GitHub organization runners contain a duplicate id or name");
    }
    ids.add(row.id);
    names.add(name);

    const labels = new Set();
    for (const rawLabel of row.labels) {
      const label = plainObject(rawLabel, "GitHub organization runner label");
      if (typeof label.name !== "string" || !SAFE_LABEL.test(label.name)) {
        fail("malformed_input", "GitHub organization runner label is malformed");
      }
      const normalized = normalizedLabel(label.name);
      if (labels.has(normalized)) {
        fail("duplicate_input", "GitHub organization runner contains a duplicate label");
      }
      labels.add(normalized);
    }
    const hasRequiredLabels = [...required].every((label) => labels.has(label));
    runners.push({
      id: row.id,
      name,
      os,
      status,
      busy: row.busy,
      hasRequiredLabels,
    });
  }

  const labelMatches = runners.filter((runner) => runner.hasRequiredLabels && normalizedLabel(runner.os) === "macos");
  const onlineMatches = labelMatches.filter((runner) => runner.status === "online");
  const eligible = onlineMatches.filter((runner) => runner.busy === false);
  return {
    totalCount: runners.length,
    labelMatchCount: labelMatches.length,
    onlineMatchCount: onlineMatches.length,
    eligible: eligible.map((runner) => ({ id: runner.id, name: runner.name })),
  };
}

export function parseRunnerGroupsOutput(raw) {
  const rows = parsePagedCollection(raw, "runner_groups", "GitHub organization runner groups");
  const ids = new Set();
  const groups = [];
  for (const rawRow of rows) {
    const row = plainObject(rawRow, "GitHub organization runner group");
    if (!Number.isSafeInteger(row.id) || row.id < 1) {
      fail("malformed_input", "GitHub organization runner group id is malformed");
    }
    if (ids.has(row.id)) {
      fail("duplicate_input", "GitHub organization runner groups contain a duplicate id");
    }
    ids.add(row.id);
    groups.push({
      id: row.id,
      name: safeString(row.name, "GitHub organization runner group name"),
      visibility: safeString(row.visibility, "GitHub organization runner group visibility"),
    });
  }
  if (groups.length > MAX_RUNNER_GROUPS) {
    fail("ambiguous_input", "GitHub organization runner groups exceed the bounded preflight limit");
  }
  return groups;
}

/**
 * An organization runner is only usable by this repository when its runner
 * group grants the repository access: either the group is visible to all
 * repositories, or the repository appears in the group's selected list.
 * Runners that cannot be mapped to exactly one group, and groups whose
 * membership or repository grants cannot be read, fail closed.
 */
export function resolveRunnerGroupRepositoryAccess({
  groups,
  groupRunnersOutputs,
  groupRepositoriesOutputs,
}) {
  const runnerGroupIds = new Map();
  const accessibleRunnerIds = new Set();
  for (const group of groups) {
    const membershipRaw = groupRunnersOutputs?.[group.id];
    if (typeof membershipRaw !== "string") {
      fail("command_failed", `runner group ${group.id} membership could not be read`);
    }
    let grantsRepositoryAccess = false;
    if (group.visibility === "all") {
      grantsRepositoryAccess = true;
    } else if (group.visibility === "selected") {
      const repositoriesRaw = groupRepositoriesOutputs?.[group.id];
      if (typeof repositoriesRaw !== "string") {
        fail("command_failed", `runner group ${group.id} repository grants could not be read`);
      }
      const repositories = parsePagedCollection(
        repositoriesRaw,
        "repositories",
        `runner group ${group.id} repositories`,
      );
      grantsRepositoryAccess = repositories.some((rawRepository) => {
        const repository = plainObject(rawRepository, `runner group ${group.id} repository`);
        return repository.full_name === EXPECTED_REPOSITORY;
      });
    }
    const members = parsePagedCollection(
      membershipRaw,
      "runners",
      `runner group ${group.id} runners`,
    );
    for (const rawMember of members) {
      const member = plainObject(rawMember, `runner group ${group.id} runner`);
      if (!Number.isSafeInteger(member.id) || member.id < 1) {
        fail("malformed_input", `runner group ${group.id} contains a malformed runner id`);
      }
      if (runnerGroupIds.has(member.id)) {
        fail("ambiguous_input", "a runner appears in more than one runner group");
      }
      runnerGroupIds.set(member.id, group.id);
      if (grantsRepositoryAccess) accessibleRunnerIds.add(member.id);
    }
  }
  return { runnerGroupIds, accessibleRunnerIds };
}

function checkError(error, fallbackCode) {
  if (error instanceof PreflightValidationError) {
    return { code: error.code, message: error.message };
  }
  return { code: fallbackCode, message: "the read-only preflight check could not be completed" };
}

export function evaluateP16HostPreflight(input, dependencies = {}) {
  const checks = [];
  const deferredChecks = [{
    code: "guest_share_equivalence_requires_live_validation",
    message: "The Linux guest path and UTM share equivalence are not proven by this host-only checker; validate them live after the documented VM is running.",
  }];
  const commandErrors = input.commandErrors ?? {};
  const currentUid = dependencies.currentUid ?? input.currentUid;
  const inspectMacRoot = dependencies.inspectMacRoot ?? input.inspectMacRoot;

  function addPass(id, summary, details = {}) {
    checks.push({ id, status: "pass", summary, details });
  }
  function addBlocker(id, code, message, details = {}) {
    checks.push({ id, status: "blocker", code, summary: message, details });
  }
  function commandOutput(key) {
    if (commandErrors[key]) {
      fail("command_failed", `${key} read-only command failed`);
    }
    if (typeof input[key] !== "string") {
      fail("command_failed", `${key} read-only command produced no output`);
    }
    return input[key];
  }

  try {
    const repository = parseRepositoryIdentityOutput(commandOutput("repositoryOutput"));
    addPass("repository", "Exact repository identity confirmed.", { nameWithOwner: repository });
  } catch (error) {
    const issue = checkError(error, "repository_check_failed");
    addBlocker("repository", issue.code, issue.message);
  }

  try {
    const vm = parseUtmListOutput(commandOutput("utmOutput"));
    if (vm.status !== "started") {
      addBlocker(
        "utmVm",
        "vm_not_running",
        "The exact documented UTM guest is not running.",
        { name: vm.name, uuid: vm.uuid, status: vm.status },
      );
    } else {
      addPass("utmVm", "The exact documented UTM guest is running.", vm);
    }
  } catch (error) {
    const issue = checkError(error, "utm_check_failed");
    addBlocker("utmVm", issue.code, issue.message);
  }

  let variables = null;
  try {
    variables = parseRepositoryVariablesOutput(commandOutput("variablesOutput"));
    const missing = REQUIRED_VARIABLES.filter((name) => !variables.has(name));
    if (missing.length > 0) {
      addBlocker(
        "repositoryVariables",
        "required_variables_missing",
        "One or more required P16 repository variables are missing.",
        { missing },
      );
    } else {
      addPass("repositoryVariables", "Both required P16 repository variables are present.", {
        names: [...REQUIRED_VARIABLES],
      });
    }
  } catch (error) {
    const issue = checkError(error, "repository_variables_check_failed");
    addBlocker("repositoryVariables", issue.code, issue.message);
  }

  try {
    if (!variables?.has(REQUIRED_VARIABLES[0])) {
      fail("dependency_unavailable", "The macOS coordination root variable is unavailable");
    }
    if (typeof inspectMacRoot !== "function") {
      fail("host_metadata_unavailable", "The macOS coordination root could not be inspected");
    }
    const root = variables.get(REQUIRED_VARIABLES[0]);
    const validated = validateMacCoordinationRoot(root, inspectMacRoot(root), currentUid);
    addPass("macCoordinationRoot", "The macOS coordination root is trusted.", validated);
  } catch (error) {
    const issue = checkError(error, "mac_root_check_failed");
    addBlocker("macCoordinationRoot", issue.code, issue.message);
  }

  try {
    if (!variables?.has(REQUIRED_VARIABLES[1])) {
      fail("dependency_unavailable", "The Linux guest coordination root variable is unavailable");
    }
    const validated = validateLinuxGuestCoordinationRoot(variables.get(REQUIRED_VARIABLES[1]));
    addPass(
      "linuxGuestCoordinationRoot",
      "The Linux guest coordination root is lexically valid; live share validation remains deferred.",
      validated,
    );
  } catch (error) {
    const issue = checkError(error, "linux_root_check_failed");
    addBlocker("linuxGuestCoordinationRoot", issue.code, issue.message);
  }

  try {
    const devices = parseXcrunDeviceOutput(commandOutput("devicesOutput"));
    if (devices.availableCount !== 1 || devices.selected === null) {
      addBlocker(
        "physicalIPad",
        "physical_ipad_unavailable",
        "Exactly one available physical non-Simulator iPad is required.",
        { availableCount: devices.availableCount, offlineCount: devices.offlineCount },
      );
    } else {
      addPass("physicalIPad", "Exactly one available physical non-Simulator iPad was discovered.", {
        ...devices.selected,
        offlineCount: devices.offlineCount,
      });
    }
  } catch (error) {
    const issue = checkError(error, "ipad_check_failed");
    addBlocker("physicalIPad", issue.code, issue.message);
  }

  try {
    const runners = parseOrganizationRunnersOutput(commandOutput("runnersOutput"));
    const groups = parseRunnerGroupsOutput(commandOutput("runnerGroupsOutput"));
    const access = resolveRunnerGroupRepositoryAccess({
      groups,
      groupRunnersOutputs: input.runnerGroupRunnersOutputs,
      groupRepositoriesOutputs: input.runnerGroupRepositoriesOutputs,
    });
    const accessible = runners.eligible.filter((runner) => access.accessibleRunnerIds.has(runner.id));
    if (accessible.length === 0) {
      addBlocker(
        "macRunner",
        "eligible_mac_runner_unavailable",
        "No online, non-busy macOS org runner has every required P16 label and a runner group that grants this repository access.",
        {
          requiredLabels: [...REQUIRED_RUNNER_LABELS],
          totalCount: runners.totalCount,
          labelMatchCount: runners.labelMatchCount,
          onlineMatchCount: runners.onlineMatchCount,
          eligibleCount: runners.eligible.length,
          repositoryAccessibleCount: accessible.length,
        },
      );
    } else {
      addPass("macRunner", "An eligible online, non-busy macOS org runner with repository-visible runner-group access is available.", {
        requiredLabels: [...REQUIRED_RUNNER_LABELS],
        eligible: accessible,
      });
    }
  } catch (error) {
    const issue = checkError(error, "runner_check_failed");
    addBlocker("macRunner", issue.code, issue.message);
  }

  const blockers = checks
    .filter((check) => check.status === "blocker")
    .map((check) => ({ check: check.id, code: check.code, message: check.summary }));
  return {
    schemaVersion: 1,
    id: "openburnbar-p16-live-certification-host-preflight-v1",
    scope: "read-only-host-preflight",
    repository: EXPECTED_REPOSITORY,
    ready: blockers.length === 0,
    checks,
    blockers,
    deferredChecks,
  };
}

export function inspectMacRootReadOnly(root, filesystem = fs) {
  const metadata = filesystem.lstatSync(root);
  const realpath = filesystem.realpathSync.native
    ? filesystem.realpathSync.native(root)
    : filesystem.realpathSync(root);
  return {
    isDirectory: metadata.isDirectory(),
    isSymbolicLink: metadata.isSymbolicLink(),
    uid: metadata.uid,
    mode: metadata.mode,
    realpath,
  };
}

export const READ_ONLY_COMMANDS = Object.freeze([
  Object.freeze({
    key: "repositoryOutput",
    command: "gh",
    args: Object.freeze(["repo", "view", EXPECTED_REPOSITORY, "--json", "nameWithOwner"]),
  }),
  Object.freeze({
    key: "utmOutput",
    command: "utmctl",
    args: Object.freeze(["list"]),
  }),
  Object.freeze({
    key: "variablesOutput",
    command: "gh",
    args: Object.freeze([
      "api",
      "--paginate",
      "--slurp",
      `repos/${EXPECTED_REPOSITORY}/actions/variables?per_page=100`,
    ]),
  }),
  Object.freeze({
    key: "devicesOutput",
    command: "xcrun",
    args: Object.freeze(["xctrace", "list", "devices"]),
  }),
  Object.freeze({
    key: "runnersOutput",
    command: "gh",
    args: Object.freeze([
      "api",
      "--paginate",
      "--slurp",
      `orgs/${EXPECTED_ORGANIZATION}/actions/runners?per_page=100`,
    ]),
  }),
  Object.freeze({
    key: "runnerGroupsOutput",
    command: "gh",
    args: Object.freeze([
      "api",
      "--paginate",
      "--slurp",
      `orgs/${EXPECTED_ORGANIZATION}/actions/runner-groups?per_page=100`,
    ]),
  }),
]);

function runReadOnlyCommand(command, args) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: { ...process.env, GH_PAGER: "cat", PAGER: "cat", NO_COLOR: "1" },
    maxBuffer: 10_000_000,
    timeout: 30_000,
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    failed: result.error !== undefined || result.status !== 0,
  };
}

export function collectReadOnlyCommandOutputs(commandRunner = runReadOnlyCommand) {
  const outputs = { commandErrors: {}, runnerGroupRunnersOutputs: {}, runnerGroupRepositoriesOutputs: {} };
  function collect(key, command, args) {
    const result = commandRunner(command, args);
    if (
      result === null
      || typeof result !== "object"
      || typeof result.stdout !== "string"
      || typeof result.failed !== "boolean"
      || result.failed
    ) {
      return null;
    }
    return result.stdout;
  }
  for (const spec of READ_ONLY_COMMANDS) {
    const stdout = collect(spec.key, spec.command, [...spec.args]);
    if (stdout === null) {
      outputs.commandErrors[spec.key] = true;
      continue;
    }
    outputs[spec.key] = stdout;
  }
  // Bounded second phase: each discovered runner group is inspected with the
  // same read-only `gh api` shape so runner eligibility can be tied to a
  // group that actually grants this repository access.  Any failure to read
  // a group is folded into the runner-groups command error and fails closed.
  if (!outputs.commandErrors.runnerGroupsOutput) {
    try {
      const groups = parseRunnerGroupsOutput(outputs.runnerGroupsOutput);
      for (const group of groups) {
        const membership = collect(
          "runnerGroupRunnersOutputs",
          "gh",
          ["api", "--paginate", "--slurp", `orgs/${EXPECTED_ORGANIZATION}/actions/runner-groups/${group.id}/runners?per_page=100`],
        );
        if (membership === null) {
          outputs.commandErrors.runnerGroupsOutput = true;
          break;
        }
        outputs.runnerGroupRunnersOutputs[group.id] = membership;
        if (group.visibility !== "selected") continue;
        const repositories = collect(
          "runnerGroupRepositoriesOutputs",
          "gh",
          ["api", "--paginate", "--slurp", `orgs/${EXPECTED_ORGANIZATION}/actions/runner-groups/${group.id}/repositories?per_page=100`],
        );
        if (repositories === null) {
          outputs.commandErrors.runnerGroupsOutput = true;
          break;
        }
        outputs.runnerGroupRepositoriesOutputs[group.id] = repositories;
      }
    } catch {
      outputs.commandErrors.runnerGroupsOutput = true;
    }
  }
  return outputs;
}

export function runP16HostPreflight(dependencies = {}) {
  const inputs = collectReadOnlyCommandOutputs(dependencies.commandRunner);
  return evaluateP16HostPreflight(
    {
      ...inputs,
      currentUid: dependencies.currentUid ?? process.getuid?.(),
      inspectMacRoot: dependencies.inspectMacRoot ?? inspectMacRootReadOnly,
    },
  );
}

export function main(argv = process.argv.slice(2), dependencies = {}) {
  if (argv.length !== 0) {
    return {
      schemaVersion: 1,
      id: "openburnbar-p16-live-certification-host-preflight-v1",
      scope: "read-only-host-preflight",
      repository: EXPECTED_REPOSITORY,
      ready: false,
      checks: [],
      blockers: [{
        check: "arguments",
        code: "invalid_arguments",
        message: "This bounded preflight accepts no command-line arguments.",
      }],
      deferredChecks: [],
    };
  }
  return runP16HostPreflight(dependencies);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = main();
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.ready) process.exitCode = 1;
}
