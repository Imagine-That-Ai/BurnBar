#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  REQUIRED_SCENARIO_IDS,
  validateWindowsFoundationHostEvidence,
} from "./validate-windows-foundation-host-evidence.mjs";

const CANDIDATE = "0123456789abcdef0123456789abcdef01234567";
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function writeJSON(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function artifact(baseDir, relativePath, scenario, kind, payload = { ok: true }) {
  const path = join(baseDir, relativePath);
  mkdirSync(join(path, ".."), { recursive: true });
  if (typeof payload === "string") writeFileSync(path, payload);
  else writeJSON(path, payload);
  const stat = statSync(path);
  return {
    scenario,
    kind,
    path,
    relativePath,
    sha256: sha256(path),
    size: stat.size,
    lastWriteTimeUtc: new Date().toISOString(),
  };
}

function processEvidence() {
  return {
    schema: "openburnbar.windows.foundation-process-evidence.v1",
    generatedAtUtc: new Date().toISOString(),
    host: {
      osArchitecture: "Arm64",
      processArchitecture: "X64",
      userIdentitySha256: "b".repeat(64),
      machineIdentitySha256: "c".repeat(64),
    },
    scenarios: REQUIRED_SCENARIO_IDS
      .filter((id) => id.startsWith("process."))
      .map((id) => ({
        id,
        status: "captured",
        survivorPids: [],
        launch: {
          useShellExecute: false,
          forbiddenEnvironmentNamesPresent: [],
        },
      })),
  };
}

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "obb-foundation-evidence-"));
  const artifacts = [];
  const processArtifact = artifact(
    dir,
    "process-traces/process-evidence.json",
    "process.all",
    "process-evidence",
    processEvidence(),
  );
  artifacts.push(processArtifact);
  const secretArtifact = artifact(
    dir,
    "artifact-secret-scan.json",
    "diagnostics.secret-scan",
    "secret-scan",
    {
      schema: "openburnbar.windows.foundation-secret-scan.v1",
      status: "passed",
      findings: [],
    },
  );
  artifacts.push(secretArtifact);

  const scenarios = REQUIRED_SCENARIO_IDS.map((id) => {
    if (id.startsWith("process.")) {
      return {
        id,
        status: "captured",
        source: "foundation-process-tool",
        artifacts: [processArtifact],
      };
    }
    if (id === "diagnostics.secret-scan") {
      return {
        id,
        status: "captured",
        source: "artifact-secret-scan",
        artifacts: [secretArtifact],
      };
    }
    const ref = artifact(
      dir,
      `scenario-artifacts/${id.replaceAll(".", "-")}.json`,
      id,
      id.startsWith("chat.") ? "uia-or-screenshot" : "focused-foundation-artifact",
      { id, captured: true },
    );
    artifacts.push(ref);
    return {
      id,
      status: "captured",
      source: id.startsWith("chat.") ? "interactive-uia" : "focused-foundation-evidence",
      actor: id.startsWith("chat.")
        ? { identitySha256: "d".repeat(64), sessionId: 1 }
        : undefined,
      artifacts: [ref],
    };
  });

  const manifest = {
    schema: "openburnbar.windows.foundation-host-evidence-manifest.v1",
    status: "passed",
    vmIdentitySha256: "a".repeat(64),
    candidate: { commit: CANDIDATE, tree: "tree" },
    host: {
      osArchitecture: "ARM 64-bit Processor",
      processArchitecture: "X64",
      vmIdentitySha256: "a".repeat(64),
      computerIdentitySha256: "e".repeat(64),
      currentIdentitySha256: "f".repeat(64),
    },
    steps: [{ name: "all", exitCode: 0 }],
    failClosedChecks: {
      missingRows: 0,
      failedCommands: 0,
      secretFindings: 0,
      session0Ui: false,
      staleCandidate: false,
    },
    scenarios,
    artifacts,
  };
  return { dir, manifest };
}

{
  const { dir, manifest } = fixture();
  const result = validateWindowsFoundationHostEvidence(manifest, {
    baseDir: dir,
    expectedCandidate: CANDIDATE,
  });
  assert.equal(result.ok, true, result.errors.join("\n"));
}

{
  const { dir, manifest } = fixture();
  manifest.scenarios = manifest.scenarios.filter((scenario) => scenario.id !== "chat.executable.setup");
  const result = validateWindowsFoundationHostEvidence(manifest, { baseDir: dir });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /missing scenario: chat\.executable\.setup/);
}

{
  const { dir, manifest } = fixture();
  manifest.scenarios.find((scenario) => scenario.id === "chat.executable.approve").actor.sessionId = 0;
  const result = validateWindowsFoundationHostEvidence(manifest, { baseDir: dir });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /session 0/);
}

{
  const { dir, manifest } = fixture();
  manifest.failClosedChecks.secretFindings = 1;
  const result = validateWindowsFoundationHostEvidence(manifest, { baseDir: dir });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /secret findings/);
}

{
  const { dir, manifest } = fixture();
  const result = validateWindowsFoundationHostEvidence(manifest, {
    baseDir: dir,
    expectedCandidate: "ffffffffffffffffffffffffffffffffffffffff",
  });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /candidate mismatch/);
}

{
  const { dir, manifest } = fixture();
  manifest.artifacts.find((ref) => ref.kind === "secret-scan").sha256 = "bad";
  const result = validateWindowsFoundationHostEvidence(manifest, { baseDir: dir });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /sha256 mismatch/);
}

{
  const { dir, manifest } = fixture();
  const processPath = join(dir, "process-traces/process-evidence.json");
  const evidence = JSON.parse(readFileSync(processPath, "utf8"));
  evidence.scenarios.find((scenario) => scenario.id === "process.timeout").survivorPids = [1234];
  writeJSON(processPath, evidence);
  const processRef = manifest.artifacts.find((ref) => ref.kind === "process-evidence");
  processRef.sha256 = sha256(processPath);
  processRef.size = statSync(processPath).size;

  const result = validateWindowsFoundationHostEvidence(manifest, { baseDir: dir });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /survivor pids/);
}

{
  const { dir, manifest } = fixture();
  delete manifest.host.processArchitecture;
  const result = validateWindowsFoundationHostEvidence(manifest, { baseDir: dir });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /architecture/);
}

const collectorScript = readFileSync(
  join(SCRIPT_DIR, "windows-port/foundation-host-uia-collector.ps1"),
  "utf8",
);
assert.doesNotMatch(
  collectorScript,
  /\.ArgumentList\b|\.Environment\[/,
  "interactive collector must remain compatible with Windows PowerShell 5.1",
);
assert.doesNotMatch(
  collectorScript,
  /\.Kill\(\$true\)/,
  "interactive collector must not use the .NET Core-only Kill(entireProcessTree) overload",
);
assert.match(
  collectorScript,
  /Wait-ForRouteSmokeResult/,
  "interactive collector must bound route-smoke waits on the emitted result file",
);
assert.match(
  collectorScript,
  /\$routeExitCode/,
  "interactive collector must trust route-smoke result JSON instead of requiring app process exit",
);
assert.match(
  collectorScript,
  /collector-error\.txt/,
  "interactive collector must leave a structured failure artifact on terminating errors",
);

const runnerScript = readFileSync(
  join(SCRIPT_DIR, "windows-port/run-foundation-host-evidence.ps1"),
  "utf8",
);
const candidateVerificationBlock = runnerScript.slice(
  runnerScript.indexOf("$candidateVerification ="),
  runnerScript.indexOf("$forbiddenEnv ="),
);
assert.match(
  candidateVerificationBlock,
  /candidateVerificationResult\.status\s+-ne\s+'passed'/,
  "candidate verification must inspect the emitted fail-closed result",
);
assert.doesNotMatch(
  candidateVerificationBlock,
  /LASTEXITCODE/,
  "PowerShell script invocation must not trust a stale native LASTEXITCODE",
);
assert.doesNotMatch(
  runnerScript,
  /\$pid\s*=/i,
  "runner must not assign PowerShell's read-only PID automatic variable",
);
assert.match(
  runnerScript,
  /Wait-ForJsonOrProcessExit/,
  "runner must fail closed when the interactive collector exits before writing its result",
);
assert.match(
  runnerScript,
  /Remove-Item[^\n]+\$interactiveProfiles[^\n]+-ErrorAction Stop/,
  "runner must remove scenario-local protected storage before publishing evidence",
);
assert.match(
  runnerScript,
  /\^obb-storage-\[0-9a-f\]\{32\}\$/,
  "secret scanner must recognize its generated storage fixture identifiers",
);
assert.match(
  runnerScript,
  /\^openburnbar-foundation-evidence-\[0-9a-f\]\{7,40\}\$/,
  "secret scanner must recognize its generated output-directory identifiers",
);

console.log("windows foundation host evidence validator tests passed");
