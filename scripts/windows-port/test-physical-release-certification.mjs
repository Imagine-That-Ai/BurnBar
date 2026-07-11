#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const script = readFileSync(join(root, "run-physical-release-certification.ps1"), "utf8");

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
assert.match(script, /ArtifactManifestPath/);
assert.match(script, /signatureResult/);
assert.match(script, /Refusing certification evidence for an artifact without a verified signature/);
assert.match(script, /run-ui-automation\.ps1/);
assert.match(script, /-CertificationProfile', 'all'/);
assert.match(script, /validate-release-certification-evidence\.mjs/);
assert.match(script, /overallVerdict = 'NO-GO'/);
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
assert.match(script, /SUPPLEMENTAL-LIVE-RECEIPT-MISSING/);
assert.match(script, /\$supplementalGateIds = @\('accessibility-display'\)/);
assert.match(script, /\$supplementalGateIds -notcontains/);
assert.match(script, /\$candidate\.artifact\.sha256 -ne \$artifact\.sha256/);

console.log("PASS: physical release-certification runner structural checks");
