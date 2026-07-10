#!/usr/bin/env node
import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const REQUIRED_SCENARIO_IDS = [
  "chat.executable.setup",
  "chat.executable.approve",
  "chat.executable.rotate",
  "chat.executable.remove",
  "chat.executable.denial.missing",
  "chat.executable.denial.replaced",
  "chat.executable.denial.unapproved",
  "chat.history.unavailable",
  "chat.history.corrupt",
  "chat.history.locked",
  "chat.history.retry",
  "chat.restart.process",
  "chat.restart.durable-rehydrate",
  "chat.attachment.file",
  "chat.attachment.paste",
  "chat.attachment.drop",
  "chat.attachment.missing",
  "chat.retrieval.degraded",
  "storage.fresh-install",
  "storage.restart-idempotency",
  "storage.generated-db-write-seams",
  "storage.wrong-key",
  "storage.corrupt-database",
  "storage.locked-file",
  "storage.interrupted-migration",
  "storage.unsupported-schema",
  "storage.full-disk",
  "storage.access-denied",
  "storage.archive-reset",
  "storage.retry",
  "storage.reveal-redacted-log",
  "process.environment.chat-scrubbed",
  "process.metacharacters",
  "process.quotes",
  "process.unicode",
  "process.newlines",
  "process.long-input",
  "process.blocked-stderr",
  "process.infinite-output",
  "process.grandchildren",
  "process.cancellation",
  "process.timeout",
  "process.malformed-output",
  "process.nonzero-exit",
  "process.unapproved-denial",
  "process.replaced-denial",
  "process.missing-denial",
  "process.unavailable-backend",
  "diagnostics.config",
  "diagnostics.log",
  "diagnostics.support-bundle",
  "diagnostics.screenshot",
  "diagnostics.secret-scan",
];

const UI_SCENARIO_PREFIXES = [
  "chat.executable.",
  "chat.history.",
  "chat.restart.",
  "chat.attachment.paste",
];

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function fail(errors, message) {
  errors.push(message);
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function resolveArtifactPath(baseDir, artifact) {
  if (!isRecord(artifact)) return null;
  if (typeof artifact.relativePath === "string" && artifact.relativePath.length > 0) {
    return join(baseDir, artifact.relativePath);
  }
  if (typeof artifact.path === "string" && artifact.path.length > 0) {
    return isAbsolute(artifact.path) ? artifact.path : join(baseDir, artifact.path);
  }
  return null;
}

function readJson(path, errors, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(errors, `${label}: cannot read JSON: ${error.message}`);
    return null;
  }
}

function validateArtifactHashes(manifest, baseDir, errors) {
  for (const artifact of asArray(manifest.artifacts)) {
    const path = resolveArtifactPath(baseDir, artifact);
    if (!path) {
      fail(errors, "artifact is missing path/relativePath");
      continue;
    }
    if (!existsSync(path)) {
      fail(errors, `artifact missing on disk: ${artifact.relativePath ?? artifact.path}`);
      continue;
    }
    const stat = statSync(path);
    if (typeof artifact.size === "number" && artifact.size !== stat.size) {
      fail(errors, `artifact size mismatch: ${artifact.relativePath ?? artifact.path}`);
    }
    if (typeof artifact.sha256 === "string" && artifact.sha256 !== sha256(path)) {
      fail(errors, `artifact sha256 mismatch: ${artifact.relativePath ?? artifact.path}`);
    }
  }
}

function validateProcessEvidence(manifest, baseDir, errors) {
  const processArtifact = asArray(manifest.artifacts).find((artifact) => artifact.kind === "process-evidence");
  if (!processArtifact) {
    fail(errors, "process-evidence artifact is required");
    return;
  }
  const path = resolveArtifactPath(baseDir, processArtifact);
  if (!path || !existsSync(path)) {
    fail(errors, "process-evidence artifact path is missing");
    return;
  }
  const evidence = readJson(path, errors, "process-evidence");
  if (!evidence) return;
  if (evidence.schema !== "openburnbar.windows.foundation-process-evidence.v1") {
    fail(errors, "process-evidence schema mismatch");
  }
  if (!evidence.host?.osArchitecture || !evidence.host?.processArchitecture) {
    fail(errors, "process-evidence host architecture is required");
  }
  if (!/^[a-f0-9]{64}$/.test(evidence.host?.userIdentitySha256 ?? "")) {
    fail(errors, "process-evidence user identity hash is required");
  }
  if (!/^[a-f0-9]{64}$/.test(evidence.host?.machineIdentitySha256 ?? "")) {
    fail(errors, "process-evidence machine identity hash is required");
  }
  const byId = new Map(asArray(evidence.scenarios).map((scenario) => [scenario?.id, scenario]));
  for (const id of REQUIRED_SCENARIO_IDS.filter((scenarioId) => scenarioId.startsWith("process."))) {
    const scenario = byId.get(id);
    if (!scenario) {
      fail(errors, `process-evidence missing scenario: ${id}`);
      continue;
    }
    if (scenario.status !== "captured") fail(errors, `process scenario not captured: ${id}`);
    if (asArray(scenario.survivorPids).length !== 0) fail(errors, `process survivor pids remain: ${id}`);
    if (scenario.launch?.useShellExecute === true) fail(errors, `process scenario used shell execute: ${id}`);
    if (asArray(scenario.launch?.forbiddenEnvironmentNamesPresent).length !== 0) {
      fail(errors, `process scenario leaked forbidden environment names: ${id}`);
    }
  }
}

function validateSecretScan(manifest, baseDir, errors) {
  if ((manifest.failClosedChecks?.secretFindings ?? 0) !== 0) {
    fail(errors, "manifest reports secret findings");
  }
  const scanArtifact = asArray(manifest.artifacts).find((artifact) => artifact.kind === "secret-scan");
  if (!scanArtifact) {
    fail(errors, "secret-scan artifact is required");
    return;
  }
  const path = resolveArtifactPath(baseDir, scanArtifact);
  if (!path || !existsSync(path)) {
    fail(errors, "secret-scan artifact path is missing");
    return;
  }
  const scan = readJson(path, errors, "secret-scan");
  if (!scan) return;
  if (scan.status !== "passed") fail(errors, "secret-scan status must be passed");
  if (asArray(scan.findings).length !== 0) fail(errors, "secret-scan findings must be empty");
}

function isUiScenario(id) {
  return UI_SCENARIO_PREFIXES.some((prefix) => id.startsWith(prefix));
}

export function validateWindowsFoundationHostEvidence(manifest, options = {}) {
  const errors = [];
  if (!isRecord(manifest)) return { ok: false, errors: ["manifest must be an object"] };
  const baseDir = options.baseDir ?? (options.manifestPath ? dirname(options.manifestPath) : process.cwd());

  if (manifest.schema !== "openburnbar.windows.foundation-host-evidence-manifest.v1") {
    fail(errors, "schema mismatch");
  }
  if (manifest.status !== "passed") fail(errors, "manifest status must be passed");
  if (options.expectedCandidate && manifest.candidate?.commit !== options.expectedCandidate) {
    fail(errors, `candidate mismatch: expected ${options.expectedCandidate} actual ${manifest.candidate?.commit ?? "<missing>"}`);
  }
  if (!/^[a-f0-9]{64}$/.test(manifest.vmIdentitySha256 ?? "")) {
    fail(errors, "vmIdentitySha256 is required");
  }
  if (!manifest.host?.osArchitecture || !manifest.host?.processArchitecture) {
    fail(errors, "host OS/process architecture is required");
  }
  if (manifest.host?.vmIdentitySha256 !== manifest.vmIdentitySha256) {
    fail(errors, "host VM identity hash does not match manifest");
  }
  if (!/^[a-f0-9]{64}$/.test(manifest.host?.computerIdentitySha256 ?? "")) {
    fail(errors, "host computer identity hash is required");
  }
  if (!/^[a-f0-9]{64}$/.test(manifest.host?.currentIdentitySha256 ?? "")) {
    fail(errors, "host current identity hash is required");
  }
  if ((manifest.failClosedChecks?.missingRows ?? 0) !== 0) fail(errors, "manifest reports missing rows");
  if ((manifest.failClosedChecks?.failedCommands ?? 0) !== 0) fail(errors, "manifest reports failed commands");
  if (manifest.failClosedChecks?.session0Ui === true) fail(errors, "manifest reports session 0 UI");
  if (manifest.failClosedChecks?.staleCandidate === true) fail(errors, "manifest reports stale candidate");

  for (const step of asArray(manifest.steps)) {
    if (step?.exitCode !== 0) fail(errors, `step failed: ${step?.name ?? "<unnamed>"}`);
  }

  const scenarios = new Map(asArray(manifest.scenarios).map((scenario) => [scenario?.id, scenario]));
  for (const id of REQUIRED_SCENARIO_IDS) {
    const scenario = scenarios.get(id);
    if (!scenario) {
      fail(errors, `missing scenario: ${id}`);
      continue;
    }
    if (scenario.status !== "captured") fail(errors, `scenario not captured: ${id}`);
    if (asArray(scenario.artifacts).length === 0) fail(errors, `scenario has no artifacts: ${id}`);
    if (isUiScenario(id) && Number(scenario.actor?.sessionId ?? 0) === 0) {
      fail(errors, `UI scenario captured from session 0: ${id}`);
    }
    if (isUiScenario(id) && !/^[a-f0-9]{64}$/.test(scenario.actor?.identitySha256 ?? "")) {
      fail(errors, `UI scenario identity hash is missing: ${id}`);
    }
  }

  validateArtifactHashes(manifest, baseDir, errors);
  validateProcessEvidence(manifest, baseDir, errors);
  validateSecretScan(manifest, baseDir, errors);
  return { ok: errors.length === 0, errors };
}

function parseArgs(argv) {
  const args = { manifestPath: "", expectedCandidate: "" };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--expected-candidate" && i + 1 < argv.length) {
      args.expectedCandidate = argv[++i];
    } else if (!args.manifestPath) {
      args.manifestPath = argv[i];
    } else {
      throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  if (!args.manifestPath) throw new Error("manifest path is required");
  return args;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const manifestPath = resolve(args.manifestPath);
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    const result = validateWindowsFoundationHostEvidence(manifest, {
      manifestPath,
      expectedCandidate: args.expectedCandidate,
    });
    if (!result.ok) {
      console.error("FAIL: Windows foundation host evidence manifest is incomplete.");
      for (const error of result.errors) console.error(`- ${error}`);
      process.exit(1);
    }
    console.log("PASS: Windows foundation host evidence manifest is complete.");
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(2);
  }
}
