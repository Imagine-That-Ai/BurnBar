#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describeLocalCertificationHost } from "./local-certification-host.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const script = readFileSync(join(root, "run-physical-release-certification.ps1"), "utf8");
const attestationGenerator = readFileSync(join(root, "new-physical-hardware-attestation.ps1"), "utf8");
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
assert.match(script, /\$candidateDeviceIdentity -match \$script:VirtualHostIdentityPattern/);
assert.match(script, /Normalize-Architecture \(\[string\]\$candidate\.device\.architecture\)/);
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
const windowsFastWorkflow = readFileSync(join(root, "../../.github/workflows/pr-windows-fast.yml"), "utf8");
const windowsReleaseWorkflow = readFileSync(
  join(root, "../../.github/workflows/openburnbar-release-windows.yml"),
  "utf8",
);
assert.match(windowsFastWorkflow, /new-physical-hardware-attestation\.ps1/);
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
// The artifact manifest must bind the signed artifact to its source commit.
assert.match(script, /'sourceCommit',/);
assert.match(script, /Artifact manifest sourceCommit must be a full 40-character Git SHA/);
assert.match(script, /Artifact manifest source commit mismatch/);
assert.match(script, /source = \$script:SourceIdentity/);
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
