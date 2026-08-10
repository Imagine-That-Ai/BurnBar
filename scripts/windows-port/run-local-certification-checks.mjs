#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { cpus, platform, release, totalmem } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUNDLE_SCHEMA,
  RECEIPT_SCHEMA,
  REQUIRED_GATE_IDS,
  validateReleaseCertificationBundle,
  writeSha256Sums,
} from "./validate-release-certification-evidence.mjs";
import { sanitizeCertificationLog } from "./certification-log-sanitizer.mjs";
import { describeLocalCertificationHost } from "./local-certification-host.mjs";
import { nativeLibraryFileName } from "./stage-local-rust-cdylib.mjs";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const defaultOutput = join(
  repoRoot,
  "docs/windows-port/evidence/physical-release-certification-2026-07-11",
);
const outputDir = resolve(process.argv[2] ?? defaultOutput);
const logsDir = join(outputDir, "logs");
const receiptsDir = join(outputDir, "receipts");
const blockersDir = join(outputDir, "blockers");
mkdirSync(logsDir, { recursive: true });
mkdirSync(receiptsDir, { recursive: true });
mkdirSync(blockersDir, { recursive: true });

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function commandText(file, args) {
  return [file, ...args].join(" ");
}

function sanitize(text) {
  return sanitizeCertificationLog(text);
}

function git(args) {
  return execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: "utf8",
  }).trim();
}

const source = {
  commitSha: git(["rev-parse", "HEAD"]),
  dirtyTree: git(["status", "--porcelain"]).length > 0,
};
const runtimePlatform = platform();
const nativeStageDir = join(
  repoRoot,
  "crates/openburnbar-domain-core/target/debug",
);
const domainCoreNativePath = join(
  nativeStageDir,
  nativeLibraryFileName("openburnbar_domain_ffi", runtimePlatform),
);
const burnBarRemoteNativePath = join(
  nativeStageDir,
  nativeLibraryFileName("burnbar_remote", runtimePlatform),
);
const irohNativePath = join(
  nativeStageDir,
  nativeLibraryFileName("openburnbar_iroh", runtimePlatform),
);
const domainCoreObservedIdentityPath = join(
  logsDir,
  "domain-core-observed-identity.json",
);
rmSync(domainCoreObservedIdentityPath, { force: true });
const nativeTestEnvironment = {
  OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE: "1",
  OPENBURNBAR_REQUIRE_NATIVE_SHIMS: "1",
  OPENBURNBAR_NATIVE_DIR: nativeStageDir,
  DOMAIN_CORE_NATIVE_LIBRARY_PATH: domainCoreNativePath,
  DOMAIN_CORE_CANDIDATE_COMMIT: source.commitSha,
  DOMAIN_CORE_OBSERVED_IDENTITY_REPORT: domainCoreObservedIdentityPath,
};
const host = describeLocalCertificationHost({
  platform: runtimePlatform,
  release: release(),
  architecture: process.arch,
  cpuModel: cpus()[0]?.model ?? "unknown",
  ramBytes: totalmem(),
});
const device = host.device;
const artifact = {
  name: "source-checkout",
  architecture: `${runtimePlatform}-${process.arch}`,
  availability: "not-applicable",
  sha256: null,
  workflowRunId: "not-applicable-local",
  workflowRunUrl: "not-applicable",
  signature: { result: "not-applicable", identity: "not-applicable" },
};

const commands = [
  {
    name: "evidence-validator-tests",
    file: "node",
    args: [
      "scripts/windows-port/test-validate-release-certification-evidence.mjs",
    ],
    timeoutMs: 120000,
  },
  {
    name: "runner-structural-tests",
    file: "node",
    args: ["scripts/windows-port/test-physical-release-certification.mjs"],
    timeoutMs: 120000,
  },
  {
    name: "domain-core-local-identity-verifier-tests",
    file: "node",
    args: [
      "--test",
      "scripts/windows-port/verify-local-domain-core-identity.test.mjs",
    ],
    timeoutMs: 120000,
  },
  {
    name: "domain-core-local-staging-tests",
    file: "node",
    args: [
      "--test",
      "scripts/windows-port/stage-local-domain-core-native.test.mjs",
    ],
    timeoutMs: 120000,
  },
  {
    name: "rust-cdylib-local-staging-tests",
    file: "node",
    args: ["--test", "scripts/windows-port/stage-local-rust-cdylib.test.mjs"],
    timeoutMs: 120000,
  },
  {
    name: "windows-trx-evidence-verifier-tests",
    file: "node",
    args: ["--test", "scripts/windows-port/verify-trx-results.test.mjs"],
    timeoutMs: 120000,
  },
  {
    name: "foundation-evidence-validator-tests",
    file: "node",
    args: ["scripts/test-windows-foundation-host-evidence.mjs"],
    timeoutMs: 120000,
  },
  {
    name: "windows-storage-architecture",
    file: "bash",
    args: ["scripts/ci/verify-windows-storage-architecture.sh"],
    timeoutMs: 120000,
  },
  {
    name: "windows-packaging-verify",
    file: "bash",
    args: ["windows/packaging/scripts/verify.sh"],
    timeoutMs: 120000,
  },
  {
    name: "windows-parity-ledger",
    file: "bash",
    args: ["scripts/ci/verify-windows-parity-ledger.sh"],
    timeoutMs: 120000,
  },
  {
    name: "windows-release-workflow-lint",
    file: "actionlint",
    args: [
      ".github/workflows/openburnbar-release-windows.yml",
      ".github/workflows/openburnbar-pr-harness.yml",
      ".github/workflows/pr-windows-full.yml",
      ".github/workflows/pr-windows-fast.yml",
      ".github/workflows/pr-windows-dist.yml",
      ".github/workflows/windows-candidate-evidence.yml",
    ],
    timeoutMs: 120000,
  },
  {
    name: "no-suppressions",
    file: "bash",
    args: ["scripts/ci/check-no-suppressions.sh"],
    timeoutMs: 120000,
  },
  {
    name: "domain-core-native-build",
    file: "rustup",
    args: [
      "run",
      "1.96.0",
      "cargo",
      "build",
      "--locked",
      "--manifest-path",
      "crates/openburnbar-domain-core/Cargo.toml",
      "-p",
      "openburnbar-domain-ffi",
    ],
    timeoutMs: 900000,
    env: { OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: source.commitSha },
  },
  {
    name: "domain-core-native-stage",
    file: "node",
    args: [
      "scripts/windows-port/stage-local-rust-cdylib.mjs",
      "--manifest-path",
      "crates/openburnbar-domain-core/Cargo.toml",
      "--toolchain",
      "1.96.0",
      "--logical-name",
      "openburnbar_domain_ffi",
      "--destination",
      domainCoreNativePath,
    ],
    timeoutMs: 120000,
  },
  {
    name: "burnbar-remote-native-build",
    file: "rustup",
    args: [
      "run",
      "1.94.0",
      "cargo",
      "build",
      "--locked",
      "--manifest-path",
      "crates/burnbar-remote/Cargo.toml",
      "-p",
      "burnbar-remote-ffi",
    ],
    timeoutMs: 900000,
  },
  {
    name: "burnbar-remote-native-stage",
    file: "node",
    args: [
      "scripts/windows-port/stage-local-rust-cdylib.mjs",
      "--manifest-path",
      "crates/burnbar-remote/Cargo.toml",
      "--toolchain",
      "1.94.0",
      "--logical-name",
      "burnbar_remote",
      "--destination",
      burnBarRemoteNativePath,
    ],
    timeoutMs: 120000,
  },
  {
    name: "iroh-native-build",
    file: "rustup",
    args: [
      "run",
      "1.96.0",
      "cargo",
      "build",
      "--locked",
      "--manifest-path",
      "crates/openburnbar-iroh/Cargo.toml",
    ],
    timeoutMs: 900000,
  },
  {
    name: "iroh-native-stage",
    file: "node",
    args: [
      "scripts/windows-port/stage-local-rust-cdylib.mjs",
      "--manifest-path",
      "crates/openburnbar-iroh/Cargo.toml",
      "--toolchain",
      "1.96.0",
      "--logical-name",
      "openburnbar_iroh",
      "--destination",
      irohNativePath,
    ],
    timeoutMs: 120000,
  },
  {
    name: "windows-solution-aggregate",
    file: "dotnet",
    args: [
      "test",
      "windows/OpenBurnBar.sln",
      "--configuration",
      "Release",
      "--nologo",
      "-p:EnableWindowsTargeting=true",
      "--blame-hang-timeout",
      runtimePlatform === "win32" ? "600s" : "60s",
    ],
    timeoutMs: 900000,
    env: nativeTestEnvironment,
  },
];

function walk(root) {
  const result = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (["bin", "obj", ".git"].includes(entry.name)) continue;
    const path = join(root, entry.name);
    if (entry.isDirectory()) result.push(...walk(path));
    else if (entry.isFile() && entry.name.endsWith(".Tests.csproj"))
      result.push(path);
  }
  return result;
}

const testProjects = walk(join(repoRoot, "windows"))
  .map((path) => relative(repoRoot, path).replaceAll("\\", "/"))
  .filter(
    (path) =>
      !path.includes(
        "/ui-automation-harness/OpenBurnBar.UiAutomationHarness.csproj",
      ),
  )
  .sort();
const windowsNativeColdSpike = runtimePlatform === "win32";
for (const project of testProjects) {
  const isColdNativeSpike =
    project === "windows/tests/b0-spike/OpenBurnBar.B0Spike.Tests.csproj";
  commands.push({
    name: `dotnet-${project.replaceAll("/", "-").replaceAll(".csproj", "")}`,
    file: "dotnet",
    args: [
      "test",
      project,
      "--configuration",
      "Release",
      "--nologo",
      "-p:EnableWindowsTargeting=true",
      "--blame-hang-timeout",
      isColdNativeSpike ? (windowsNativeColdSpike ? "600s" : "180s") : "60s",
    ],
    timeoutMs: isColdNativeSpike
      ? windowsNativeColdSpike
        ? 900000
        : 360000
      : 180000,
    env: nativeTestEnvironment,
  });
}
commands.push({
  name: "domain-core-local-identity",
  file: "node",
  args: [
    "scripts/windows-port/verify-local-domain-core-identity.mjs",
    "--expected-commit",
    source.commitSha,
    "--observed-identity",
    domainCoreObservedIdentityPath,
    "--binary",
    domainCoreNativePath,
  ],
  timeoutMs: 120000,
});

function runCommand(spec) {
  const startedAt = new Date();
  const result = spawnSync(spec.file, spec.args, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: spec.timeoutMs,
    maxBuffer: 32 * 1024 * 1024,
    env: {
      ...process.env,
      PYTHONUTF8: process.env.PYTHONUTF8 ?? "1",
      ...(spec.env ?? {}),
    },
  });
  const endedAt = new Date();
  const timedOut =
    result.error?.code === "ETIMEDOUT" || result.signal === "SIGTERM";
  const exitCode = timedOut ? null : (result.status ?? 1);
  const logPath = join(logsDir, `${spec.name}.log`);
  const output = sanitize(
    `${result.stdout ?? ""}${result.stderr ?? ""}${result.error ? `\n${result.error.message}` : ""}`,
  );
  writeFileSync(logPath, output);
  return {
    name: spec.name,
    command: commandText(spec.file, spec.args),
    exitCode,
    timedOut,
    log: `logs/${spec.name}.log`,
    logSha256: sha256(logPath),
    startedAtUtc: startedAt.toISOString(),
    endedAtUtc: endedAt.toISOString(),
    durationSeconds: (endedAt.getTime() - startedAt.getTime()) / 1000,
  };
}

const startedAt = new Date();
const results = [];
for (const spec of commands) {
  const result = runCommand(spec);
  results.push(result);
  const status =
    result.exitCode === 0 ? "PASS" : result.timedOut ? "TIMEOUT" : "FAIL";
  console.log(`${status} ${result.name}`);
}
const endedAt = new Date();
const summaryPath = join(logsDir, "command-summary.json");
writeJson(summaryPath, {
  schema: "openburnbar.windows.release-certification-command-summary.v1",
  startedAtUtc: startedAt.toISOString(),
  endedAtUtc: endedAt.toISOString(),
  commands: results,
  counts: {
    total: results.length,
    passed: results.filter((result) => result.exitCode === 0).length,
    failed: results.filter(
      (result) => result.exitCode !== 0 && !result.timedOut,
    ).length,
    timedOut: results.filter((result) => result.timedOut).length,
  },
});

function blockerFile(gate, id, missing, recovery) {
  const path = join(blockersDir, `${gate}.md`);
  writeFileSync(
    path,
    `# ${gate} blocker\n\n- id: ${id}\n- status: BLOCKED\n- owner: Alberto\n- missing: ${missing}\n- recovery: ${recovery}\n- capturedAtUtc: ${new Date().toISOString()}\n`,
  );
  return { path: `blockers/${gate}.md`, sha256: sha256(path) };
}

function baseReceipt(
  gate,
  status,
  expected,
  observed,
  exitCode,
  protocol,
  evidenceFiles,
  blocker,
) {
  return {
    schema: RECEIPT_SCHEMA,
    status,
    gate,
    target:
      gate === "local-automated-checks"
        ? `portable Windows cores and CI/meta harnesses on ${host.label}`
        : gate,
    source,
    artifact,
    device,
    protocol,
    time: {
      startedAtUtc: startedAt.toISOString(),
      endedAtUtc: endedAt.toISOString(),
      durationSeconds: (endedAt.getTime() - startedAt.getTime()) / 1000,
    },
    expected,
    observed,
    exitCode,
    evidence: { files: evidenceFiles },
    blocker,
  };
}

const evidenceFiles = [
  ...results.map((result) => ({ path: result.log, sha256: result.logSha256 })),
  { path: "logs/command-summary.json", sha256: sha256(summaryPath) },
];
const failedResults = results.filter((result) => result.exitCode !== 0);
const localReceipt = baseReceipt(
  "local-automated-checks",
  failedResults.length === 0 ? "PASS" : "FAIL",
  `Every portable Windows, packaging, ledger, workflow, and test-project command reachable on ${host.label} exits 0.`,
  failedResults.length === 0
    ? `All ${results.length} commands exited 0.`
    : `${failedResults.length} command(s) failed or timed out: ${failedResults.map((result) => result.name).join(", ")}. Full output is retained in logs.`,
  failedResults.length === 0 ? 0 : 1,
  {
    commands: results.map((result) => result.command),
    manualSteps: [
      "This receipt is supporting evidence only and cannot certify physical Windows behavior.",
    ],
  },
  evidenceFiles,
  null,
);
writeJson(join(receiptsDir, "local-automated-checks.json"), localReceipt);

const blockers = {
  "physical-performance-x64": [
    "EXT-PHYSICAL-WINDOWS-X64",
    "A named physical Windows 11 x64 device with GPU, display, power, TPM, and signed exact-candidate artifact is not attached to this macOS session.",
    "Run run-physical-release-certification.ps1 on the physical x64 device with the signed artifact manifest and hardware attestation; capture WPR/ETW, counters, frame pacing, lifecycle, and soak evidence.",
  ],
  "physical-performance-arm64": [
    "EXT-PHYSICAL-WINDOWS-ARM64",
    "A named physical Windows 11 ARM64 device with GPU, display, power, TPM, and signed exact-candidate artifact is not attached to this macOS session; the UTM VM is not physical certification.",
    "Run run-physical-release-certification.ps1 on the physical ARM64 device with the signed artifact manifest and hardware attestation; capture WPR/ETW, counters, frame pacing, lifecycle, and soak evidence.",
  ],
  "accessibility-display": [
    "EXT-WINDOWS-ACCESSIBILITY-OPERATOR",
    "No signed-in physical Windows desktop session with Narrator operator, UIA inspection, 150%/200% DPI, OS high contrast, reduced motion/transparency, and mixed-DPI monitors is available here.",
    "Run the accessibility profile plus the manual receipt protocol on both physical architectures; attach machine-readable UIA trees, screenshots, focus/live-region results, and Narrator/keyboard observations.",
  ],
  "staging-cloud": [
    "EXT-STAGING-OAUTH-APPCHECK-TPM",
    "No configured staging OAuth/App Check credential names, interactive staging account, Firebase enforcement permission, or physical TPM claim endpoint is available in this session.",
    "Use staging only with configured OS/CI secret names, complete OAuth PKCE and expiry/revocation/offline/sign-out flows, prove valid/invalid App Check and physical TPM enforcement, run CloudVault/queue/cross-device/leak scans, and attach sanitized receipts.",
  ],
  "media-computer-use-safety": [
    "EXT-WINDOWS-MEDIA-COMPUTER-USE-PEERS",
    "No physical Windows host plus paired Mac/mobile staging peers and capture/camera/microphone permissions are available for end-to-end Mercury, transfer, or Computer Use safety proof.",
    "Run harmless fixtures on physical Windows with paired Mac/mobile devices; capture permission, reconnect/cancel/quarantine/MOTW, protected-target/secure-desktop denial, approval/kill/watchdog, audit-chain, and phone replay evidence.",
  ],
  "store-update-lifecycle": [
    "EXT-STORE-PRIVATE-FLIGHT-APPROVAL",
    "No Microsoft Partner Center reservation/private-flight approval and no authorized physical Store/update test device is available; public release advancement is not authorized.",
    "After PR #1541's exact signed sustained-launch artifact is recorded, validate private flight and direct-download lifecycle on x64 and ARM64, then record Store/winget/update/rollback receipts without publishing broadly.",
  ],
};

const receiptEntries = [
  {
    path: "receipts/local-automated-checks.json",
    status: localReceipt.status,
    gate: localReceipt.gate,
  },
];
for (const gate of REQUIRED_GATE_IDS.slice(1)) {
  const [id, missing, recovery] = blockers[gate];
  const evidence = blockerFile(gate, id, missing, recovery);
  const receipt = baseReceipt(
    gate,
    "BLOCKED",
    "The complete physical/live/private-flight protocol passes with exact signed artifact and raw evidence.",
    "The required external device, account, permission, or approval is unavailable in this session; no pass is claimed.",
    null,
    { commands: [], manualSteps: [missing, recovery] },
    [evidence],
    { id, owner: "Alberto", missing, recovery },
  );
  const path = join(receiptsDir, `${gate}.json`);
  writeJson(path, receipt);
  receiptEntries.push({
    path: `receipts/${gate}.json`,
    status: "BLOCKED",
    gate,
  });
}

const manifest = {
  schema: BUNDLE_SCHEMA,
  generatedAtUtc: endedAt.toISOString(),
  source,
  runner: {
    script: "scripts/windows-port/run-local-certification-checks.mjs",
    host: host.label,
    note: `This bundle records ${host.evidenceScope} and external blockers; it does not attest physical Windows hardware or satisfy physical/live gates.`,
  },
  overallVerdict: "NO-GO",
  receipts: receiptEntries.map((entry) => ({
    path: entry.path,
    sha256: sha256(join(outputDir, entry.path)),
  })),
  gates: receiptEntries.map((entry) => ({
    id: entry.gate,
    status: entry.status,
    receipts: [entry.path],
  })),
  notes: [
    "Physical PASS is reserved for physical-windows device receipts with recorded signed artifacts.",
    "VM, hosted runner, source review, unit tests, and successful package registration do not satisfy physical certification.",
  ],
};
writeJson(join(outputDir, "certification-manifest.json"), manifest);
writeSha256Sums(outputDir);
const validation = validateReleaseCertificationBundle(outputDir, {
  expectedCommit: source.commitSha,
});
if (!validation.ok) {
  console.error("FAIL: generated local certification bundle did not validate.");
  for (const error of validation.errors) console.error(`- ${error}`);
  process.exit(1);
}
if (failedResults.length > 0) {
  console.error(
    `FAIL: ${failedResults.length} local certification command(s) failed or timed out. ` +
      `The NO-GO evidence bundle was retained at ${outputDir}.`,
  );
  process.exit(1);
}
console.log(
  `PASS: generated and validated ${receiptEntries.length} certification receipts at ${outputDir}`,
);
