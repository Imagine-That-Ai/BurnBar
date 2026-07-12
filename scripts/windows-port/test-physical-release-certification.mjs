#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describeLocalCertificationHost } from "./local-certification-host.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const script = readFileSync(join(root, "run-physical-release-certification.ps1"), "utf8");
const localRunner = readFileSync(join(root, "run-local-certification-checks.mjs"), "utf8");

assert.match(script, /\$PhysicalHardware/);
assert.match(script, /-HardwareAttestationPath/);
assert.match(script, /physical-hardware-attestation\.v1/);
assert.match(script, /PhysicalHardware requires -HardwareAttestationPath/);
assert.match(script, /Get-CimInstance Win32_OperatingSystem/);
assert.match(script, /Get-CimInstance Win32_SystemEnclosure/);
assert.match(script, /Get-CimInstance Win32_ComputerSystemProduct/);
assert.match(
  script,
  /Hardware attestation \$field does not match the current device/,
);
assert.match(script, /Physical hardware architecture mismatch/);
assert.match(script, /Get-Tpm/);
assert.match(script, /\$script:HardwareAttestationSha256 = Get-Sha256 \$attestationPath/);
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
assert.match(script, /\$candidate\.artifact\.sha256 -ne \$artifact\.sha256/);
assert.match(script, /Supplemental evidence hash mismatch/);
assert.match(
  script,
  /Get-Sha256 \$sourcePath[\s\S]*Supplemental evidence hash mismatch[\s\S]*Copy-Item -LiteralPath \$sourcePath/,
);
assert.match(localRunner, /const runtimePlatform = platform\(\)/);
assert.match(localRunner, /const windowsNativeColdSpike = runtimePlatform === "win32"/);
assert.match(localRunner, /isColdNativeSpike \? \(windowsNativeColdSpike \? "600s" : "180s"\) : "60s"/);
assert.match(localRunner, /isColdNativeSpike \? \(windowsNativeColdSpike \? 900000 : 360000\) : 180000/);
assert.match(
  localRunner,
  /windows\/OpenBurnBar\.sln[\s\S]*--blame-hang-timeout",[\s\S]*runtimePlatform === "win32" \? "600s" : "60s"[\s\S]*timeoutMs: 900000/,
);
assert.match(localRunner, /PYTHONUTF8: process\.env\.PYTHONUTF8 \?\? "1"/);

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
