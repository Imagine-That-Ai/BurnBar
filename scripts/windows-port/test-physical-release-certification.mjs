#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describeLocalCertificationHost } from "./local-certification-host.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const script = readFileSync(join(root, "run-physical-release-certification.ps1"), "utf8");
const attestationGenerator = readFileSync(join(root, "new-physical-hardware-attestation.ps1"), "utf8");
const supplementalGenerator = readFileSync(
  join(root, "new-release-certification-supplemental-receipt.ps1"),
  "utf8",
);
const supplementalValidator = readFileSync(
  join(root, "validate-release-certification-receipt.mjs"),
  "utf8",
);
const protocolCatalog = JSON.parse(
  readFileSync(join(root, "release-certification-protocols.json"), "utf8"),
);
const performanceBudgetBytes = readFileSync(join(root, "release-performance-budgets.json"));
const performanceBudget = JSON.parse(performanceBudgetBytes.toString("utf8"));
const physicalRunbook = readFileSync(
  join(root, "../../docs/windows-port/evidence/windows-v1.0.35-release/PHYSICAL_X64_RUNBOOK.md"),
  "utf8",
);
const localRunner = readFileSync(join(root, "run-local-certification-checks.mjs"), "utf8");

assert.match(script, /\$PhysicalHardware/);
assert.match(script, /-HardwareAttestationPath/);
assert.match(script, /physical-hardware-attestation\.v1/);
assert.match(script, /PhysicalHardware requires -HardwareAttestationPath/);
assert.match(script, /Get-CimInstance Win32_OperatingSystem/);
assert.match(script, /Get-CimInstance Win32_SystemEnclosure/);
assert.match(script, /Get-CimInstance Win32_ComputerSystemProduct/);
assert.match(script, /placeholder chassis tag/);
assert.match(script, /systemProduct\.IdentifyingNumber/);
assert.match(script, /assetTagSource/);
assert.match(script, /Hardware attestation assetTagSource is required for physical certification/);
assert.match(script, /Hardware attestation assetTagSource does not match/);
assert.match(script, /Amazon EC2\|Google Compute Engine\|HVM domU\|\\bXen\\b/);
assert.match(script, /\$script:AllowedAssetTagSources -notcontains \$candidateAssetTagSource/);
assert.match(script, /validate-release-certification-receipt\.mjs/);
assert.match(script, /Supplemental PASS receipt failed schema validation/);
assert.match(script, /\$candidateDeviceIdentity -match \$script:VirtualHostIdentityPattern/);
assert.match(script, /Normalize-Architecture \(\[string\]\$candidate\.device\.architecture\)/);
assert.match(script, /\$candidateEvidencePathMap\[\$sourceFileKey\] = \$destinationRelative/);
assert.match(script, /\$assertion\.evidence = \$rewrittenEvidence/);
assert.match(
  script,
  /system asset tag\|chassis asset tag/,
  "generic chassis asset tags must fall back to the system-product identifier",
);
assert.match(
  script,
  /Hardware attestation \$field does not match the current device/,
);
assert.match(script, /Physical hardware architecture mismatch/);
assert.match(script, /Get-Tpm/);

assert.match(attestationGenerator, /openburnbar\.windows\.physical-hardware-attestation\.v1/);
assert.match(attestationGenerator, /Get-CimInstance Win32_SystemEnclosure/);
assert.match(attestationGenerator, /Get-CimInstance Win32_ComputerSystemProduct/);
assert.match(attestationGenerator, /Win32_SystemEnclosure\.SMBIOSAssetTag/);
assert.match(attestationGenerator, /Win32_ComputerSystemProduct\.IdentifyingNumber/);
assert.match(attestationGenerator, /system asset tag\|chassis asset tag/);
assert.match(attestationGenerator, /assetTagSource/);
assert.match(attestationGenerator, /Refusing physical hardware attestation for a virtualized host identity/);
assert.match(attestationGenerator, /Amazon EC2\|Google Compute Engine\|HVM domU\|\\bXen\\b/);
assert.match(attestationGenerator, /Refusing to overwrite existing hardware attestation without -Force/);
assert.match(attestationGenerator, /\.tmp-/);
assert.equal(
  protocolCatalog.schema,
  "openburnbar.windows.release-certification-protocols.v1",
);
assert.deepEqual(
  Object.keys(protocolCatalog.gates).sort(),
  [
    "accessibility-display",
    "media-computer-use-safety",
    "physical-performance-arm64",
    "physical-performance-x64",
    "staging-cloud",
    "store-update-lifecycle",
  ],
);
for (const [gate, gateConfig] of Object.entries(protocolCatalog.gates)) {
  const profile = protocolCatalog.profiles[gateConfig.profile];
  assert.ok(profile, `${gate} profile must exist`);
  assert.ok(profile.assertions.length > 0, `${gate} must require assertions`);
  assert.equal(
    new Set(profile.assertions.map((assertion) => assertion.id)).size,
    profile.assertions.length,
    `${gate} assertion ids must be unique`,
  );
}
assert.equal(performanceBudget.status, "ACTIVE_RELEASE_GATE");
assert.equal(performanceBudget.profile, "physical-performance");
assert.equal(
  createHash("sha256").update(performanceBudgetBytes).digest("hex"),
  "e74d889051244901f1bac929999d9b276feb89cdd8d9ea61a74ca275de3ab832",
);
assert.equal(
  protocolCatalog.profiles["physical-performance"].performanceBudgetSchema,
  performanceBudget.schema,
);
assert.ok(performanceBudget.measurements.length >= 15);
const performanceAssertionIds = new Set(
  protocolCatalog.profiles["physical-performance"].assertions.map((assertion) => assertion.id),
);
for (const measurement of performanceBudget.measurements) {
  assert.ok(performanceAssertionIds.has(measurement.assertionId));
  assert.ok(measurement.minimumSamples >= 1);
  assert.ok(measurement.minimumDurationSeconds >= 0);
}
assert.match(supplementalGenerator, /ParameterSetName = 'Initialize'/);
assert.match(supplementalGenerator, /status = 'NOT_RUN'/);
assert.match(supplementalGenerator, /validate-release-certification-evidence\.mjs/);
assert.match(supplementalGenerator, /validate-release-certification-receipt\.mjs/);
assert.match(supplementalGenerator, /Refusing a supplemental receipt from a dirty source checkout/);
assert.match(supplementalGenerator, /dirty certification harness checkout/);
assert.match(supplementalGenerator, /baseline receipt is not bound to the clean current certification harness/);
assert.match(supplementalGenerator, /--expected-harness-commit/);
assert.match(supplementalGenerator, /Get-CimInstance Win32_ComputerSystem/);
assert.match(supplementalGenerator, /Get-CimInstance Win32_SystemEnclosure/);
assert.match(supplementalGenerator, /Get-CimInstance Win32_ComputerSystemProduct/);
assert.match(supplementalGenerator, /Get-CimInstance Win32_OperatingSystem/);
assert.match(supplementalGenerator, /Get-Tpm/);
assert.match(supplementalGenerator, /The current host identity looks virtualized/);
assert.match(supplementalGenerator, /The live device .* does not match the physical baseline/);
assert.match(supplementalGenerator, /Required protocol assertion is missing/);
assert.match(supplementalGenerator, /Unknown protocol assertion/);
assert.match(supplementalGenerator, /did not PASS/);
assert.match(supplementalGenerator, /has no raw evidence file/);
assert.match(supplementalGenerator, /evidence is missing or escapes the result directory/);
assert.match(supplementalGenerator, /contains secret-like material/);
assert.match(supplementalGenerator, /The signed artifact architecture does not match/);
assert.match(supplementalGenerator, /invalid, stale, or future time interval/);
assert.match(supplementalGenerator, /release-performance-budgets\.json/);
assert.match(supplementalGenerator, /ACTIVE_RELEASE_GATE/);
assert.match(supplementalGenerator, /performanceMeasurements/);
assert.match(supplementalGenerator, /performanceContext/);
assert.match(supplementalGenerator, /requires an explicit numeric value/);
assert.match(supplementalGenerator, /sampleCount does not match samples/);
assert.match(supplementalGenerator, /has no raw evidence file/);
assert.match(supplementalValidator, /validateReceipt/);
assert.match(supplementalValidator, /Windows release-certification receipt is valid/);
assert.match(physicalRunbook, /Do not hand-author PASS receipts/);
assert.match(physicalRunbook, /new-release-certification-supplemental-receipt\.ps1/);
assert.match(physicalRunbook, /-Initialize/);
assert.match(physicalRunbook, /-BaselineBundle \$Evidence/);
assert.match(physicalRunbook, /\$Repo = Join-Path \$Root 'candidate'/);
assert.match(physicalRunbook, /\$Harness = Join-Path \$Root 'harness'/);
assert.match(
  physicalRunbook,
  /\$ExpectedHarnessCommit = 'f7d95fabecc6964f7b2cec895eb1c14dc8178bb1'/,
);
assert.match(
  physicalRunbook,
  /\$ExpectedPerformanceBudgetHash = 'e74d889051244901f1bac929999d9b276feb89cdd8d9ea61a74ca275de3ab832'/,
);
assert.match(physicalRunbook, /Active release performance budget mismatch/);
assert.match(physicalRunbook, /git -C \$Repo checkout --detach windows-v1\.0\.35/);
assert.match(physicalRunbook, /git -C \$Harness checkout --detach \$ExpectedHarnessCommit/);
assert.match(
  physicalRunbook,
  /Join-Path \$Harness 'scripts\\windows-port\\run-physical-release-certification\.ps1'/,
);
assert.match(
  physicalRunbook,
  /Join-Path \$Harness 'scripts\\windows-port\\validate-release-certification-evidence\.mjs'/,
);
assert.match(physicalRunbook, /--expected-commit \$ExpectedCommit/);
assert.match(physicalRunbook, /--expected-harness-commit \$ExpectedHarnessCommit/);
const windowsFastWorkflow = readFileSync(join(root, "../../.github/workflows/pr-windows-fast.yml"), "utf8");
const windowsReleaseWorkflow = readFileSync(
  join(root, "../../.github/workflows/openburnbar-release-windows.yml"),
  "utf8",
);
assert.match(windowsFastWorkflow, /new-physical-hardware-attestation\.ps1/);
assert.match(windowsFastWorkflow, /new-release-certification-supplemental-receipt\.ps1/);
assert.match(windowsFastWorkflow, /Smoke supplemental certification templates/);
assert.match(windowsFastWorkflow, /Supplemental template OK/);
assert.match(windowsFastWorkflow, /run-physical-release-certification\.ps1/);
assert.match(windowsFastWorkflow, /Language\.Parser\]::ParseFile/);
assert.match(windowsReleaseWorkflow, /Write physical-certification artifact manifests/);
assert.match(windowsReleaseWorkflow, /write-signed-artifact-manifest\.mjs/);
assert.match(windowsReleaseWorkflow, /RELEASE_COMMIT: \$\{\{ needs\.resolve-release\.outputs\.release_commit \}\}/);
assert.match(windowsReleaseWorkflow, /signed-artifact-\$\{file_arch\}\.json/);
assert.match(windowsReleaseWorkflow, /"signed-artifact-x64\.json"[\s\S]*"signed-artifact-arm64\.json"/);
assert.ok(
  windowsReleaseWorkflow.indexOf("Verify MSIX Authenticode signatures") <
    windowsReleaseWorkflow.indexOf("Write physical-certification artifact manifests"),
  "the workflow must emit certification manifests only after signature verification",
);

assert.match(script, /IsPathRooted\(\$Path\)/);
assert.match(script, /function ConvertTo-WindowsProcessArgument/);
assert.match(script, /function Normalize-Architecture/);
assert.match(script, /'x64', 'amd64', 'x8664'/);
assert.match(script, /'arm64', 'aarch64'/);
assert.match(script, /if \(\$null -ne \$startInfo\.PSObject\.Properties\['ArgumentList'\]\)/);
assert.doesNotMatch(script, /if \(\$null -ne \$startInfo\.ArgumentList\)/);
assert.match(script, /\$startInfo\.Arguments =/);
assert.match(script, /ConvertTo-WindowsProcessArgument \$_/);
assert.match(script, /'dotnet-build'[\s\S]*'-m:1'/);
assert.match(script, /'dotnet-test'[\s\S]*'-m:1'/);
assert.match(script, /\$script:SourceIdentity = \[ordered\]@\{/);
assert.match(script, /harness = \[ordered\]@\{/);
assert.match(script, /Refusing certification evidence from a dirty certification harness checkout/);
assert.match(script, /Refusing certification evidence for a candidate that was dirty before execution/);
// The pre-execution cleanliness snapshot must happen before the runner writes
// its own output directories, and an in-repo OutputDir must be excluded from
// the dirty-tree probe.
assert.ok(
  script.indexOf("Refusing certification evidence for a candidate that was dirty before execution") <
    script.indexOf("New-Item -ItemType Directory -Force -Path $OutputDir, (Join-Path $OutputDir 'receipts')"),
  "dirty-tree refusal must precede OutputDir creation",
);
assert.match(script, /\$script:RepoRelativeOutputDir/);
assert.match(script, /:\(exclude\)/);
assert.match(script, /\$HarnessRoot = Resolve-FullPath \(Join-Path \$PSScriptRoot '\.\.\\\.\.'\)/);
assert.match(script, /Join-Path \$HarnessRoot 'scripts\\windows-port\\run-ui-automation\.ps1'/);
assert.match(script, /Join-Path \$HarnessRoot 'scripts\\windows-port\\validate-release-certification-evidence\.mjs'/);
assert.match(script, /--expected-harness-commit \$script:SourceIdentity\.harness\.commitSha/);
// The artifact manifest must bind the signed artifact to its source commit.
assert.match(script, /'sourceCommit',/);
assert.match(script, /Artifact manifest sourceCommit must be a full 40-character Git SHA/);
assert.match(script, /Artifact manifest source commit mismatch/);
assert.match(script, /source = \$script:SourceIdentity/);
assert.match(script, /artifact = \$artifact/);
assert.doesNotMatch(script, /source = \[ordered\]@\{ commitSha = Get-CommitSha; dirtyTree = Test-DirtyTree \}/);
assert.match(script, /\$script:HardwareAttestationSha256 = Get-Sha256 \$attestationEvidencePath/);
assert.match(script, /evidence\/hardware-attestation\.json/);
assert.match(script, /Copy-Item -LiteralPath \$attestationPath -Destination \$attestationEvidencePath/);
assert.match(script, /evidencePath = \[string\]\$script:HardwareAttestationEvidencePath/);
assert.match(script, /\$receiptEvidenceFiles \+= \[ordered\]@\{/);
assert.doesNotMatch(script, /\$script:HardwareAttestation\.sha256\s*=/);
assert.match(script, /ArtifactManifestPath/);
assert.match(script, /signatureResult/);
assert.match(script, /Refusing certification evidence for an artifact without a verified signature/);
assert.match(script, /run-ui-automation\.ps1/);
assert.match(script, /-CertificationProfile', 'all'/);
assert.match(script, /validate-release-certification-evidence\.mjs/);
assert.match(
  script,
  /\$overallVerdict = if \(\$nonPassingRequiredGates\.Count -eq 0\) \{ 'GO' \} else \{ 'NO-GO' \}/,
);
assert.match(script, /overallVerdict = \$overallVerdict/);
for (const gate of [
  "physical-performance-x64",
  "physical-performance-arm64",
  "accessibility-display",
  "staging-cloud",
  "media-computer-use-safety",
  "store-update-lifecycle",
]) {
  assert.match(script, new RegExp(gate));
}
assert.doesNotMatch(script, /allow_unsigned/i);
assert.doesNotMatch(script, /\$pid\s*=/i);
assert.match(script, /Sanitize-Text/);
assert.match(script, /\[ValidateRange\(1, 7200\)\] \[int\] \$TimeoutSeconds = 1800/);
assert.match(script, /WaitForExit\(\$TimeoutSeconds \* 1000\)/);
assert.match(script, /\$process\.Kill\(\$true\)/);
assert.match(script, /timedOut = \$timedOut/);
assert.match(script, /SUPPLEMENTAL-LIVE-RECEIPT-MISSING/);
assert.match(script, /\$supplementalGateIds = @\('accessibility-display'\)/);
assert.match(script, /\$supplementalGateIds -notcontains/);
assert.match(script, /\$performanceArchitectureByGate\.ContainsKey\(\$candidateGate\)/);
assert.match(
  script,
  /\$expectedPerformanceArchitecture -eq \(Normalize-Architecture \$Platform\)[\s\S]*\$candidate\.artifact\.sha256 -ne \$artifact\.sha256/,
);
assert.match(script, /\$candidate\.artifact\.sha256 -ne \$artifact\.sha256/);
assert.match(script, /Supplemental evidence hash mismatch/);
assert.match(script, /\$candidate\.device\.hardwareAttestation/);
assert.match(script, /Supplemental hardware attestation hash mismatch/);
assert.match(script, /\$candidateAttestation\.physicalHardware -ne \$true/);
assert.match(script, /\$candidateAttestation\.assetTagSource/);
assert.match(script, /\$attestationCapturedAt -lt \$receiptStartedAt\.AddHours\(-24\)/);
assert.match(script, /\$candidate\.device\.hardwareAttestation\.evidencePath = \$candidateAttestationDestinationRelative/);
assert.match(
  script,
  /Get-Sha256 \$sourcePath[\s\S]*Supplemental evidence hash mismatch[\s\S]*Copy-Item -LiteralPath \$sourcePath/,
);
assert.match(localRunner, /const runtimePlatform = platform\(\)/);
assert.match(localRunner, /const windowsNativeColdSpike = runtimePlatform === "win32"/);
assert.match(localRunner, /name: "domain-core-native-build"[\s\S]*file: "cargo"/);
assert.ok(
  localRunner.indexOf('name: "domain-core-native-build"') <
    localRunner.indexOf('name: "windows-solution-aggregate"'),
  "the local certification runner must build the native domain core before running Windows tests",
);
assert.match(localRunner, /OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE: "1"/);
assert.match(localRunner, /isColdNativeSpike \? \(windowsNativeColdSpike \? "600s" : "180s"\) : "60s"/);
assert.match(localRunner, /isColdNativeSpike \? \(windowsNativeColdSpike \? 900000 : 360000\) : 180000/);
assert.match(
  localRunner,
  /windows\/OpenBurnBar\.sln[\s\S]*--blame-hang-timeout",[\s\S]*runtimePlatform === "win32" \? "600s" : "60s"[\s\S]*timeoutMs: 900000/,
);
assert.match(localRunner, /PYTHONUTF8: process\.env\.PYTHONUTF8 \?\? "1"/);
assert.match(localRunner, /\.\.\.\(spec\.env \?\? \{\}\)/);

const windowsHost = describeLocalCertificationHost({
  platform: "win32",
  release: "10.0.26200",
  architecture: "x64",
  cpuModel: "Virtual CPU",
  ramBytes: 8 * 1024 ** 3,
});
assert.equal(windowsHost.label, "Windows native host (physicality not attested)");
assert.equal(windowsHost.evidenceScope, "Windows-native automated evidence");
assert.deepEqual(windowsHost.device, {
  kind: "windows-native-unattested",
  manufacturer: "unattested",
  model: "Virtual CPU",
  architecture: "x64",
  osBuild: "win32 10.0.26200",
  tpm: "not-inspected",
  cpu: "Virtual CPU",
  ramBytes: 8 * 1024 ** 3,
});

const macHost = describeLocalCertificationHost({
  platform: "darwin",
  release: "25.5.0",
  architecture: "arm64",
  cpuModel: "Apple M3",
  ramBytes: 16 * 1024 ** 3,
});
assert.equal(macHost.label, "macOS authoring host");
assert.equal(macHost.device.kind, "macos-authoring-host");

const linuxHost = describeLocalCertificationHost({
  platform: "linux",
  release: "6.8.0",
  architecture: "x64",
  cpuModel: "Test CPU",
  ramBytes: 4 * 1024 ** 3,
});
assert.equal(linuxHost.label, "linux authoring host");
assert.equal(linuxHost.device.kind, "linux-authoring-host");
assert.equal(linuxHost.device.manufacturer, "unattested");

console.log("PASS: physical release-certification runner structural checks");
