#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describeLocalCertificationHost } from "./local-certification-host.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(root, "../..");
const script = readFileSync(
  join(root, "run-physical-release-certification.ps1"),
  "utf8",
);
const uiAutomationRunner = readFileSync(
  join(root, "run-ui-automation.ps1"),
  "utf8",
);
const attestationGenerator = readFileSync(
  join(root, "new-physical-hardware-attestation.ps1"),
  "utf8",
);
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
const performanceBudgetBytes = readFileSync(
  join(root, "release-performance-budgets.json"),
);
const performanceBudget = JSON.parse(performanceBudgetBytes.toString("utf8"));
const remoteConfigPublisher = readFileSync(
  join(root, "publish-staging-remote-config-fixture.ps1"),
  "utf8",
);
const remoteConfigHttp = readFileSync(
  join(root, "remote-config-http.psm1"),
  "utf8",
);
const remoteConfigSafetyObserver = readFileSync(
  join(root, "test-staging-runtime-safety-fixture.ps1"),
  "utf8",
);
const remoteConfigFixtureCatalog = JSON.parse(
  readFileSync(join(root, "remote-config-certification-fixtures.json"), "utf8"),
);
const packageManifest = readFileSync(
  join(root, "../../windows/packaging/msix/Package.appxmanifest"),
  "utf8",
);
const physicalRunbook = readFileSync(
  join(
    root,
    "../../docs/windows-port/evidence/windows-v1.0.37-release/PHYSICAL_X64_RUNBOOK.md",
  ),
  "utf8",
);
const storeRunbook = readFileSync(
  join(
    root,
    "../../docs/windows-port/evidence/windows-v1.0.37-release/STORE_PRIVATE_SUBMISSION_RUNBOOK.md",
  ),
  "utf8",
);
const localRunner = readFileSync(
  join(root, "run-local-certification-checks.mjs"),
  "utf8",
);
const nativeLibraryStaging = readFileSync(
  join(root, "native-library-staging.mjs"),
  "utf8",
);
const rustCdylibStager = readFileSync(
  join(root, "stage-local-rust-cdylib.mjs"),
  "utf8",
);

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
assert.match(
  script,
  /Hardware attestation assetTagSource is required for physical certification/,
);
assert.match(script, /Hardware attestation assetTagSource does not match/);
assert.match(script, /Amazon EC2\|Google Compute Engine\|HVM domU\|\\bXen\\b/);
assert.match(
  script,
  /\$script:AllowedAssetTagSources -notcontains \$candidateAssetTagSource/,
);
assert.match(script, /validate-release-certification-receipt\.mjs/);
assert.match(script, /Supplemental PASS receipt failed schema validation/);
assert.match(
  script,
  /\$candidateDeviceIdentity -match \$script:VirtualHostIdentityPattern/,
);
assert.match(
  script,
  /Normalize-Architecture \(\[string\]\$candidate\.device\.architecture\)/,
);
assert.match(
  script,
  /\$candidateEvidencePathMap\[\$sourceFileKey\] = \$destinationRelative/,
);
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

assert.match(
  attestationGenerator,
  /openburnbar\.windows\.physical-hardware-attestation\.v1/,
);
assert.match(attestationGenerator, /Get-CimInstance Win32_SystemEnclosure/);
assert.match(
  attestationGenerator,
  /Get-CimInstance Win32_ComputerSystemProduct/,
);
assert.match(attestationGenerator, /Win32_SystemEnclosure\.SMBIOSAssetTag/);
assert.match(
  attestationGenerator,
  /Win32_ComputerSystemProduct\.IdentifyingNumber/,
);
assert.match(attestationGenerator, /system asset tag\|chassis asset tag/);
assert.match(attestationGenerator, /assetTagSource/);
assert.match(
  attestationGenerator,
  /Refusing physical hardware attestation for a virtualized host identity/,
);
assert.match(
  attestationGenerator,
  /Amazon EC2\|Google Compute Engine\|HVM domU\|\\bXen\\b/,
);
assert.match(
  attestationGenerator,
  /Refusing to overwrite existing hardware attestation without -Force/,
);
assert.match(attestationGenerator, /\.tmp-/);
assert.equal(
  protocolCatalog.schema,
  "openburnbar.windows.release-certification-protocols.v1",
);
assert.deepEqual(Object.keys(protocolCatalog.gates).sort(), [
  "accessibility-display",
  "media-computer-use-safety",
  "physical-performance-arm64",
  "physical-performance-x64",
  "staging-cloud",
  "store-update-lifecycle",
]);
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
  "0824f341d0a7dea318a831e6ce67de016c9589d909e6982a678102130078fa92",
);
assert.equal(
  protocolCatalog.profiles["physical-performance"].performanceBudgetSchema,
  performanceBudget.schema,
);
assert.ok(performanceBudget.measurements.length >= 15);
const performanceAssertionIds = new Set(
  protocolCatalog.profiles["physical-performance"].assertions.map(
    (assertion) => assertion.id,
  ),
);
for (const measurement of performanceBudget.measurements) {
  assert.ok(performanceAssertionIds.has(measurement.assertionId));
  assert.ok(measurement.minimumSamples >= 1);
  assert.ok(measurement.minimumDurationSeconds >= 0);
}
assert.equal(
  remoteConfigFixtureCatalog.schema,
  "openburnbar.windows.remote-config-certification-fixtures.v1",
);
assert.equal(remoteConfigFixtureCatalog.projectId, "burnbar-staging");
assert.deepEqual(Object.keys(remoteConfigFixtureCatalog.fixtures).sort(), [
  "Baseline",
  "ComputerKill",
  "MalformedSystem",
  "MediaKill",
]);
assert.equal(
  remoteConfigFixtureCatalog.baseline.parameters.computer_use_kill_switch
    .defaultValue.value,
  "false",
);
assert.equal(
  remoteConfigFixtureCatalog.baseline.parameters.media_kill_switch.defaultValue
    .value,
  "false",
);
assert.equal(
  remoteConfigFixtureCatalog.fixtures.ComputerKill.overrides
    .computer_use_kill_switch,
  "true",
);
assert.equal(
  remoteConfigFixtureCatalog.fixtures.MediaKill.overrides.media_kill_switch,
  "true",
);
assert.equal(
  remoteConfigFixtureCatalog.fixtures.MalformedSystem.overrides
    .computer_use_system_enabled,
  "invalid-certification-value",
);
assert.equal(
  remoteConfigFixtureCatalog.fixtures.MalformedSystem.valueTypeOverrides
    .computer_use_system_enabled,
  "STRING",
);
for (const fixture of Object.values(remoteConfigFixtureCatalog.fixtures)) {
  for (const parameter of Object.keys(fixture.overrides)) {
    assert.ok(
      remoteConfigFixtureCatalog.baseline.parameters[parameter],
      `Remote Config fixture overrides an unknown parameter: ${parameter}`,
    );
  }
  for (const parameter of Object.keys(fixture.valueTypeOverrides ?? {})) {
    assert.ok(
      remoteConfigFixtureCatalog.baseline.parameters[parameter],
      `Remote Config fixture changes the type of an unknown parameter: ${parameter}`,
    );
  }
}
assert.match(remoteConfigPublisher, /ValidateSet\('burnbar-staging'\)/);
assert.match(
  remoteConfigPublisher,
  /hard-bound to burnbar-staging and refuses every other project/,
);
assert.doesNotMatch(remoteConfigPublisher, /\[string\] \$CatalogPath/);
assert.match(remoteConfigPublisher, /config get-value project/);
assert.match(
  remoteConfigPublisher,
  /Join-Path \$PSScriptRoot 'remote-config-http\.psm1'/,
);
assert.match(remoteConfigPublisher, /Import-Module -Name \$httpModulePath/);
assert.match(remoteConfigPublisher, /New-RemoteConfigHttpClient/);
assert.ok(remoteConfigHttp.includes("[System.Net.Http.HttpClient]"));
assert.match(remoteConfigHttp, /System\.Net\.DecompressionMethods]::GZip/);
assert.match(remoteConfigHttp, /ResponseHeadersRead/);
assert.match(
  remoteConfigHttp,
  /TryAddWithoutValidation\('Accept-Encoding', 'gzip'\)/,
);
assert.match(
  remoteConfigHttp,
  /TryAddWithoutValidation\('x-goog-user-project'/,
);
assert.match(remoteConfigHttp, /Response\.Headers\.ETag/);
assert.match(remoteConfigHttp, /Response\.Headers\.NonValidated/);
assert.match(remoteConfigHttp, /Get-RemoteConfigETag \$response/);
assert.match(
  remoteConfigHttp,
  /TryAddWithoutValidation\('If-Match', \$IfMatch\)/,
);
assert.match(remoteConfigPublisher, /-IfMatch \$etag/);
assert.doesNotMatch(remoteConfigPublisher, /Invoke-WebRequest/);
assert.doesNotMatch(remoteConfigHttp, /Invoke-WebRequest/);
assert.doesNotMatch(remoteConfigHttp, /'If-Match' = '\*'/);
assert.doesNotMatch(
  remoteConfigHttp,
  /TryAddWithoutValidation\('If-Match', '\*'/,
);
assert.match(
  remoteConfigPublisher,
  /parameters do not match the selected fixture/,
);
assert.match(
  remoteConfigPublisher,
  /restoreRequired = \(\$Fixture -ne 'Baseline'\)/,
);
assert.match(remoteConfigPublisher, /read failed\. No mutation was attempted/);
assert.match(
  remoteConfigPublisher,
  /publish failed\. Verify and restore Baseline/,
);
assert.match(remoteConfigPublisher, /valueTypeOverrides/);
assert.match(remoteConfigPublisher, /unsupported Remote Config valueType/);
assert.match(remoteConfigPublisher, /\[switch\] \$ValidateOnly/);
assert.match(remoteConfigPublisher, /payloadValidated = \$true/);
assert.match(remoteConfigPublisher, /mutationAttempted = \$false/);
assert.doesNotMatch(
  remoteConfigPublisher,
  /\$fixtureProperty\.Value\.overrides\.PSObject\.Properties\.Name/,
);
assert.doesNotMatch(remoteConfigPublisher, /Write-(Host|Output).*\$token/i);
assert.match(
  remoteConfigSafetyObserver,
  /ValidateSet\('ComputerKill', 'MalformedSystem'\)/,
);
assert.match(remoteConfigSafetyObserver, /ValidateSet\('burnbar-staging'\)/);
assert.match(
  remoteConfigSafetyObserver,
  /privileged-input-remote-safety\.flag/,
);
assert.match(remoteConfigSafetyObserver, /privileged-input-kill\.flag/);
assert.match(
  remoteConfigSafetyObserver,
  /openburnbar-remote-safety-v1:allow-until:/,
);
assert.match(
  remoteConfigSafetyObserver,
  /openburnbar-remote-safety-v1:blocked:remote_system_disabled/,
);
assert.match(remoteConfigSafetyObserver, /computer-use\\\.panic/);
assert.match(remoteConfigSafetyObserver, /runtime-safety/);
assert.match(
  remoteConfigSafetyObserver,
  /Get-Process -Name 'OpenBurnBar\.App'/,
);
assert.match(packageManifest, /Executable="OpenBurnBar\.App\.exe"/);
assert.match(remoteConfigSafetyObserver, /computer-use\\\.panic-cleared/);
assert.match(remoteConfigSafetyObserver, /operatorSessionStartedAt/);
assert.match(
  remoteConfigSafetyObserver,
  /mainAppTerminationExpected = \$false/,
);
assert.match(remoteConfigSafetyObserver, /finally \{/);
assert.match(remoteConfigSafetyObserver, /-Fixture Baseline/);
assert.match(remoteConfigSafetyObserver, /parametersVerified/);
assert.doesNotMatch(
  remoteConfigSafetyObserver,
  /Remove-Item.*privileged-input-kill/i,
);
assert.match(supplementalGenerator, /ParameterSetName = 'Initialize'/);
assert.match(supplementalGenerator, /status = 'NOT_RUN'/);
assert.match(
  supplementalGenerator,
  /validate-release-certification-evidence\.mjs/,
);
assert.match(
  supplementalGenerator,
  /validate-release-certification-receipt\.mjs/,
);
assert.match(
  supplementalGenerator,
  /Refusing a supplemental receipt from a dirty source checkout/,
);
assert.match(supplementalGenerator, /dirty certification harness checkout/);
assert.match(
  supplementalGenerator,
  /baseline receipt is not bound to the clean current certification harness/,
);
assert.match(supplementalGenerator, /--expected-harness-commit/);
assert.match(supplementalGenerator, /Get-CimInstance Win32_ComputerSystem/);
assert.match(supplementalGenerator, /Get-CimInstance Win32_SystemEnclosure/);
assert.match(
  supplementalGenerator,
  /Get-CimInstance Win32_ComputerSystemProduct/,
);
assert.match(supplementalGenerator, /Get-CimInstance Win32_OperatingSystem/);
assert.match(supplementalGenerator, /Get-Tpm/);
assert.match(
  supplementalGenerator,
  /The current host identity looks virtualized/,
);
assert.match(
  supplementalGenerator,
  /The live device .* does not match the physical baseline/,
);
assert.match(supplementalGenerator, /Required protocol assertion is missing/);
assert.match(supplementalGenerator, /Unknown protocol assertion/);
assert.match(supplementalGenerator, /did not PASS/);
assert.match(supplementalGenerator, /has no raw evidence file/);
assert.match(
  supplementalGenerator,
  /evidence is missing or escapes the result directory/,
);
assert.match(supplementalGenerator, /contains secret-like material/);
assert.match(
  supplementalGenerator,
  /The signed artifact architecture does not match/,
);
assert.match(supplementalGenerator, /invalid, stale, or future time interval/);
assert.match(supplementalGenerator, /release-performance-budgets\.json/);
assert.match(supplementalGenerator, /ACTIVE_RELEASE_GATE/);
assert.match(supplementalGenerator, /performanceMeasurements/);
assert.match(supplementalGenerator, /performanceContext/);
assert.match(supplementalGenerator, /requires an explicit numeric value/);
assert.match(supplementalGenerator, /sampleCount does not match samples/);
assert.match(supplementalGenerator, /has no raw evidence file/);
assert.match(supplementalValidator, /validateReceipt/);
assert.match(
  supplementalValidator,
  /Windows release-certification receipt is valid/,
);
assert.match(physicalRunbook, /Do not hand-author PASS receipts/);
assert.match(
  physicalRunbook,
  /new-release-certification-supplemental-receipt\.ps1/,
);
assert.match(physicalRunbook, /-Initialize/);
assert.match(physicalRunbook, /-BaselineBundle \$Evidence/);
assert.match(physicalRunbook, /\$Repo = Join-Path \$Root 'candidate'/);
assert.match(physicalRunbook, /\$Harness = Join-Path \$Root 'harness'/);
assert.match(
  physicalRunbook,
  /\$ExpectedHarnessCommit = '00d0751f1c671d99fe7ef8f4059e91d689a30f44'/,
);
assert.match(
  physicalRunbook,
  /\$ExpectedPerformanceBudgetHash = '0824f341d0a7dea318a831e6ce67de016c9589d909e6982a678102130078fa92'/,
);
assert.match(physicalRunbook, /Active release performance budget mismatch/);
assert.match(
  physicalRunbook,
  /git -C \$Repo checkout --detach windows-v1\.0\.37/,
);
assert.match(
  physicalRunbook,
  /\$ExpectedMsixHash = '63a9c374bb8d817f4642ddbcbc1c4847d5bcc0388d40fdac4c45b202e7e64bd9'/,
);
assert.match(
  physicalRunbook,
  /git -C \$Harness checkout --detach \$ExpectedHarnessCommit/,
);
assert.match(storeRunbook, /HARD STOP.*v1\.0\.37.*NO-GO/s);
assert.match(storeRunbook, /Do not create a[\s\S]*Partner Center draft/);
assert.doesNotMatch(
  storeRunbook,
  /Upload only these intentionally unsigned Store packages/,
);
assert.match(
  physicalRunbook,
  /Join-Path \$Harness 'scripts\\windows-port\\run-physical-release-certification\.ps1'/,
);
assert.match(
  physicalRunbook,
  /Join-Path \$Harness 'scripts\\windows-port\\validate-release-certification-evidence\.mjs'/,
);
assert.match(physicalRunbook, /--expected-commit \$ExpectedCommit/);
assert.match(
  physicalRunbook,
  /--expected-harness-commit \$ExpectedHarnessCommit/,
);
const windowsFastWorkflow = readFileSync(
  join(root, "../../.github/workflows/pr-windows-fast.yml"),
  "utf8",
);
const windowsFullWorkflow = readFileSync(
  join(root, "../../.github/workflows/pr-windows-full.yml"),
  "utf8",
);
const fullHarnessWorkflow = readFileSync(
  join(root, "../../.github/workflows/openburnbar-pr-harness.yml"),
  "utf8",
);
const windowsReleaseWorkflow = readFileSync(
  join(root, "../../.github/workflows/openburnbar-release-windows.yml"),
  "utf8",
);
function workflowStepBodies(workflow, stepName) {
  const marker = `      - name: ${stepName}\n`;
  const bodies = [];
  let cursor = 0;
  while (true) {
    const markerIndex = workflow.indexOf(marker, cursor);
    if (markerIndex === -1) break;
    const bodyStart = markerIndex + marker.length;
    const nextStep = workflow.indexOf("\n      - name:", bodyStart);
    bodies.push(
      workflow.slice(bodyStart, nextStep === -1 ? workflow.length : nextStep),
    );
    cursor = bodyStart;
  }
  return bodies;
}
const windowsFullPushTrigger = windowsFullWorkflow.slice(
  windowsFullWorkflow.indexOf("  push:"),
  windowsFullWorkflow.indexOf("  pull_request:"),
);
for (const evidenceDependency of [
  "scripts/lib/atomic-regular-file.mjs",
  "scripts/lib/domain-core-release-evidence.mjs",
  "scripts/ci/verify-domain-core-observed-identity.mjs",
  "scripts/windows-port/allowed-not-executed-full.json",
  "scripts/windows-port/native-library-staging.mjs",
  "scripts/windows-port/native-library-staging.test.mjs",
  "scripts/windows-port/stage-local-rust-cdylib.mjs",
  "scripts/windows-port/stage-local-rust-cdylib.test.mjs",
  "scripts/windows-port/verify-local-domain-core-identity.mjs",
  "scripts/windows-port/verify-local-domain-core-identity.test.mjs",
  "scripts/windows-port/verify-trx-results.mjs",
  "scripts/windows-port/verify-trx-results.test.mjs",
]) {
  assert.ok(
    windowsFullPushTrigger.includes(`- "${evidenceDependency}"`),
    `${evidenceDependency} must trigger the full Windows workflow on main`,
  );
}
const windowsFullDetector = windowsFullWorkflow.slice(
  windowsFullWorkflow.indexOf(
    "name: Determine whether full Windows paths changed",
  ),
  windowsFullWorkflow.indexOf("# x64 leg"),
);
for (const detectorDependency of [
  "scripts/lib/(atomic-regular-file|domain-core-release-evidence)\\.mjs",
  "scripts/ci/verify-domain-core-observed-identity\\.mjs",
  "allowed-not-executed-full\\.json",
  "(native-library-staging|stage-local-rust-cdylib)",
  "verify-(local-domain-core-identity|trx-results)",
]) {
  assert.ok(
    windowsFullDetector.includes(detectorDependency),
    `${detectorDependency} must rerun the full Windows workflow for pull requests`,
  );
}
assert.ok(
  windowsFastWorkflow.includes("scripts/lib/atomic-regular-file\\.mjs"),
  "atomic regular-file reader changes must rerun the fast Windows gate",
);
assert.match(windowsFastWorkflow, /new-physical-hardware-attestation\.ps1/);
assert.match(
  windowsFastWorkflow,
  /new-release-certification-supplemental-receipt\.ps1/,
);
assert.match(windowsFastWorkflow, /Smoke supplemental certification templates/);
assert.match(windowsFastWorkflow, /Supplemental template OK/);
assert.match(windowsFastWorkflow, /run-physical-release-certification\.ps1/);
assert.match(windowsFastWorkflow, /Language\.Parser\]::ParseFile/);
const windowsFastNativeHelperSteps = workflowStepBodies(
  windowsFastWorkflow,
  "Verify native candidate helpers on Windows",
);
assert.equal(windowsFastNativeHelperSteps.length, 1);
assert.equal(
  (windowsFastNativeHelperSteps[0].match(/\bnode --test\b/gu) ?? []).length,
  1,
  "the Windows helper tests must share one fail-closed node invocation",
);
for (const helperTest of [
  "native-library-staging.test.mjs",
  "stage-local-rust-cdylib.test.mjs",
  "verify-local-domain-core-identity.test.mjs",
]) {
  assert.ok(
    windowsFastNativeHelperSteps[0].includes(helperTest),
    `${helperTest} must run in the fast Windows helper step`,
  );
}
const windowsFullNativeHelperSteps = workflowStepBodies(
  windowsFullWorkflow,
  "Verify native candidate helpers",
);
assert.equal(windowsFullNativeHelperSteps.length, 2);
for (const helperStep of windowsFullNativeHelperSteps) {
  assert.equal(
    (helperStep.match(/\bnode --test\b/gu) ?? []).length,
    1,
    "each full Windows helper step must use one fail-closed node invocation",
  );
  for (const helperTest of [
    "native-library-staging.test.mjs",
    "stage-local-rust-cdylib.test.mjs",
    "verify-local-domain-core-identity.test.mjs",
    "verify-trx-results.test.mjs",
  ]) {
    assert.ok(
      helperStep.includes(helperTest),
      `${helperTest} must run in each full Windows helper step`,
    );
  }
}
for (const nativeStepName of [
  "Build exact-candidate native libraries",
  "Stage exact native libraries",
]) {
  const nativeSteps = workflowStepBodies(windowsFullWorkflow, nativeStepName);
  assert.equal(nativeSteps.length, 2);
  for (const nativeStep of nativeSteps) {
    assert.match(nativeStep, /\$ErrorActionPreference = "Stop"/u);
    assert.match(
      nativeStep,
      /\$PSNativeCommandUseErrorActionPreference = \$true/u,
      `${nativeStepName} must stop after the first failed native command`,
    );
  }
}
for (const stageStep of workflowStepBodies(
  windowsFullWorkflow,
  "Stage exact native libraries",
)) {
  assert.match(
    stageStep,
    /OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ github\.sha \}\}/u,
    "artifact-discovery rebuilds must preserve the exact candidate identity",
  );
}
const livePlaywrightSteps = workflowStepBodies(
  windowsFullWorkflow,
  "Live Windows Playwright bridge lifecycle",
);
assert.equal(livePlaywrightSteps.length, 1);
assert.match(
  livePlaywrightSteps[0],
  /\$PSNativeCommandUseErrorActionPreference = \$true/u,
  "live Playwright setup must stop after the first failed native command",
);
assert.match(
  windowsFastWorkflow,
  /--logger trx --results-directory TestResults-x64[\s\S]*verify-trx-results\.mjs --results-directory TestResults-x64 --minimum-files 40 --minimum-tests 4082 --maximum-not-executed 15/,
);
assert.match(
  windowsFullWorkflow,
  /OPENBURNBAR_REQUIRE_NATIVE_SHIMS: "1"[\s\S]*--logger trx --results-directory TestResults-x64[\s\S]*--logger trx `[\s\S]*--results-directory TestResults-x64[\s\S]*verify-trx-results\.mjs --results-directory TestResults-x64 --minimum-files 41 --minimum-tests 4084 --maximum-not-executed 2 --allowed-not-executed-file scripts\/windows-port\/allowed-not-executed-full\.json/,
);
assert.match(
  windowsFullWorkflow,
  /OPENBURNBAR_REQUIRE_NATIVE_SHIMS: "1"[\s\S]*--logger trx --results-directory TestResults-arm64[\s\S]*verify-trx-results\.mjs --results-directory TestResults-arm64 --minimum-files 40 --minimum-tests 4083 --maximum-not-executed 2 --allowed-not-executed-file scripts\/windows-port\/allowed-not-executed-full\.json/,
);
assert.match(
  windowsFullWorkflow,
  /rustup run 1\.94\.0 cargo build --locked --manifest-path crates\/burnbar-remote\/Cargo\.toml -p burnbar-remote-ffi --target x86_64-pc-windows-msvc/,
);
assert.match(
  windowsFullWorkflow,
  /rustup run 1\.96\.0 cargo build --locked --manifest-path crates\/openburnbar-iroh\/Cargo\.toml --target aarch64-pc-windows-msvc/,
);
assert.match(
  windowsFullWorkflow,
  /verify-local-domain-core-identity\.mjs --expected-commit \$\{\{ github\.sha \}\}/,
);
assert.match(
  fullHarnessWorkflow,
  /--logger trx --results-directory TestResults-x64[\s\S]*verify-trx-results\.mjs --results-directory TestResults-x64 --minimum-files 40 --minimum-tests 4082 --maximum-not-executed 15/,
);
for (const workflow of [
  windowsFastWorkflow,
  windowsFullWorkflow,
  fullHarnessWorkflow,
]) {
  assert.doesNotMatch(
    workflow,
    /trx;LogFileName=windows-(?:pr|full)-/,
    "solution-level Windows test evidence must use unique TRX filenames",
  );
}
assert.match(
  windowsReleaseWorkflow,
  /Write physical-certification artifact manifests/,
);
assert.match(windowsReleaseWorkflow, /write-signed-artifact-manifest\.mjs/);
assert.match(
  windowsReleaseWorkflow,
  /RELEASE_COMMIT: \$\{\{ needs\.resolve-release\.outputs\.release_commit \}\}/,
);
assert.match(windowsReleaseWorkflow, /signed-artifact-\$\{file_arch\}\.json/);
assert.match(
  windowsReleaseWorkflow,
  /"signed-artifact-x64\.json"[\s\S]*"signed-artifact-arm64\.json"/,
);
assert.ok(
  windowsReleaseWorkflow.indexOf("Verify MSIX Authenticode signatures") <
    windowsReleaseWorkflow.indexOf(
      "Write physical-certification artifact manifests",
    ),
  "the workflow must emit certification manifests only after signature verification",
);

assert.match(script, /IsPathRooted\(\$Path\)/);
assert.match(script, /function ConvertTo-WindowsProcessArgument/);
assert.match(script, /function Normalize-Architecture/);
assert.match(script, /'x64', 'amd64', 'x8664'/);
assert.match(script, /'arm64', 'aarch64'/);
assert.match(
  script,
  /if \(\$null -ne \$startInfo\.PSObject\.Properties\['ArgumentList'\]\)/,
);
assert.doesNotMatch(script, /if \(\$null -ne \$startInfo\.ArgumentList\)/);
assert.match(script, /\$startInfo\.Arguments =/);
assert.match(script, /ConvertTo-WindowsProcessArgument \$_/);
assert.match(script, /'dotnet-build'[\s\S]*'-m:1'/);
assert.match(script, /'dotnet-test'[\s\S]*'-m:1'/);
assert.match(script, /\$script:SourceIdentity = \[ordered\]@\{/);
assert.match(script, /harness = \[ordered\]@\{/);
assert.match(
  script,
  /Refusing certification evidence from a dirty certification harness checkout/,
);
assert.match(
  script,
  /Refusing certification evidence for a candidate that was dirty before execution/,
);
// The pre-execution cleanliness snapshot must happen before the runner writes
// its own output directories, and an in-repo OutputDir must be excluded from
// the dirty-tree probe.
assert.ok(
  script.indexOf(
    "Refusing certification evidence for a candidate that was dirty before execution",
  ) <
    script.indexOf(
      "New-Item -ItemType Directory -Force -Path $OutputDir, (Join-Path $OutputDir 'receipts')",
    ),
  "dirty-tree refusal must precede OutputDir creation",
);
assert.match(script, /\$script:RepoRelativeOutputDir/);
assert.match(script, /:\(exclude\)/);
assert.match(
  script,
  /\$HarnessRoot = Resolve-FullPath \(Join-Path \$PSScriptRoot '\.\.\\\.\.'\)/,
);
assert.match(
  script,
  /Join-Path \$HarnessRoot 'scripts\\windows-port\\run-ui-automation\.ps1'/,
);
assert.match(script, /'-HarnessRoot', \$HarnessRoot/);
assert.match(uiAutomationRunner, /\[string\]\$HarnessRoot = ""/);
assert.match(
  uiAutomationRunner,
  /\$harnessProject = Join-Path \$HarnessRoot "windows\\tests\\ui-automation-harness/,
);
assert.match(
  uiAutomationRunner,
  /\$appProject = Join-Path \$RepoRoot "windows\\app/,
);
assert.match(
  script,
  /Join-Path \$HarnessRoot 'scripts\\windows-port\\validate-release-certification-evidence\.mjs'/,
);
for (const trustedHelper of [
  "stage-local-rust-cdylib.mjs",
  "verify-trx-results.mjs",
  "allowed-not-executed-full.json",
  "verify-local-domain-core-identity.mjs",
]) {
  assert.ok(
    script.includes(
      `Join-Path $HarnessRoot 'scripts\\windows-port\\${trustedHelper}'`,
    ),
    `${trustedHelper} must come from the independent harness checkout`,
  );
}
assert.doesNotMatch(
  script,
  /Join-Path \$RepoRoot 'scripts\\windows-port\\(?:stage-local-rust-cdylib|verify-trx-results|verify-local-domain-core-identity)\.mjs'/,
);
assert.doesNotMatch(
  script,
  /Join-Path \$RepoRoot 'scripts\\windows-port\\allowed-not-executed-full\.json'/,
);
assert.match(
  script,
  /--expected-harness-commit \$script:SourceIdentity\.harness\.commitSha/,
);
assert.match(script, /operator-evidence\\validator-final\.log/);
assert.ok(
  script.match(/--write-sums/g)?.length >= 2,
  "the runner must regenerate SHA256SUMS after recording validator-final.log",
);
assert.match(script, /Final evidence bundle validation failed/);
// The artifact manifest must bind the signed artifact to its source commit.
assert.match(script, /'sourceCommit',/);
assert.match(
  script,
  /Artifact manifest sourceCommit must be a full 40-character Git SHA/,
);
assert.match(script, /Artifact manifest source commit mismatch/);
assert.match(script, /source = \$script:SourceIdentity/);
assert.match(script, /artifact = \$artifact/);
assert.doesNotMatch(
  script,
  /source = \[ordered\]@\{ commitSha = Get-CommitSha; dirtyTree = Test-DirtyTree \}/,
);
assert.match(
  script,
  /\$script:HardwareAttestationSha256 = Get-Sha256 \$attestationEvidencePath/,
);
assert.match(script, /evidence\/hardware-attestation\.json/);
assert.match(
  script,
  /Copy-Item -LiteralPath \$attestationPath -Destination \$attestationEvidencePath/,
);
assert.match(
  script,
  /evidencePath = \[string\]\$script:HardwareAttestationEvidencePath/,
);
assert.match(script, /\$receiptEvidenceFiles \+= \[ordered\]@\{/);
assert.doesNotMatch(script, /\$script:HardwareAttestation\.sha256\s*=/);
assert.match(script, /ArtifactManifestPath/);
assert.match(script, /signatureResult/);
assert.match(
  script,
  /Refusing certification evidence for an artifact without a verified signature/,
);
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
assert.match(
  script,
  /\[ValidateRange\(1, 7200\)\] \[int\] \$TimeoutSeconds = 1800/,
);
assert.match(script, /WaitForExit\(\$TimeoutSeconds \* 1000\)/);
assert.match(script, /\$process\.Kill\(\$true\)/);
assert.match(script, /timedOut = \$timedOut/);
assert.match(script, /\[hashtable\] \$Environment = @\{\}/);
assert.match(
  script,
  /\$startInfo\.EnvironmentVariables\[\[string\]\$entry\.Key\]/,
);
assert.match(
  script,
  /\$rustTargetTriple = if \(\$Platform -eq 'ARM64'\) \{ 'aarch64-pc-windows-msvc' \} else \{ 'x86_64-pc-windows-msvc' \}/,
);
assert.match(
  script,
  /'domain-core-native-build' 'rustup' @\('run', '1\.96\.0', 'cargo', 'build', '--locked', '--manifest-path', 'crates\\openburnbar-domain-core\\Cargo\.toml', '-p', 'openburnbar-domain-ffi', '--target', \$rustTargetTriple\) -Environment @\{ OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT = \$script:SourceIdentity\.commitSha \}/,
);
assert.match(
  script,
  /'domain-core-native-stage' 'node' @\(\$nativeStager,[\s\S]*'--logical-name', 'openburnbar_domain_ffi'[\s\S]*'--target', \$rustTargetTriple[\s\S]*'--destination', \$domainCoreNativePath\) -Environment @\{ OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT = \$script:SourceIdentity\.commitSha \}/,
);
assert.match(
  script,
  /'burnbar-remote-native-build' 'rustup' @\('run', '1\.94\.0', 'cargo', 'build', '--locked', '--manifest-path', 'crates\\burnbar-remote\\Cargo\.toml', '-p', 'burnbar-remote-ffi', '--target', \$rustTargetTriple\)/,
);
assert.match(
  script,
  /'iroh-native-build' 'rustup' @\('run', '1\.96\.0', 'cargo', 'build', '--locked', '--manifest-path', 'crates\\openburnbar-iroh\\Cargo\.toml', '--target', \$rustTargetTriple\)/,
);
assert.ok(
  script.indexOf("'domain-core-native-build'") <
    script.indexOf("'dotnet-build'"),
  "the physical certification runner must build the native domain core before dotnet build",
);
assert.ok(
  script.indexOf("'domain-core-native-build'") <
    script.indexOf("'domain-core-native-stage'") &&
    script.indexOf("'domain-core-native-stage'") <
      script.indexOf("'dotnet-build'"),
  "the physical certification runner must stage the platform-targeted native DLL before dotnet build",
);
for (const nativeStep of [
  "'burnbar-remote-native-build'",
  "'burnbar-remote-native-stage'",
  "'iroh-native-build'",
  "'iroh-native-stage'",
]) {
  assert.ok(
    script.indexOf(nativeStep) < script.indexOf("'dotnet-build'"),
    `${nativeStep} must finish before the physical certification managed build`,
  );
}
assert.match(
  script,
  /\$nativeTestEnvironment = @\{[\s\S]*OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE = '1'[\s\S]*OPENBURNBAR_REQUIRE_NATIVE_SHIMS = '1'[\s\S]*OPENBURNBAR_NATIVE_DIR = \$nativeStageDir[\s\S]*DOMAIN_CORE_NATIVE_LIBRARY_PATH = \$domainCoreNativePath[\s\S]*DOMAIN_CORE_CANDIDATE_COMMIT = \$script:SourceIdentity\.commitSha[\s\S]*DOMAIN_CORE_OBSERVED_IDENTITY_REPORT = \$domainCoreObservedIdentityPath[\s\S]*\}/,
);
assert.match(
  script,
  /'dotnet-test'[\s\S]*'--logger', 'trx', '--results-directory', \$testResultsDir\) -Environment \$nativeTestEnvironment/,
);
assert.match(
  script,
  /'complete-trx-evidence'[\s\S]*'--minimum-files', '40'[\s\S]*'--minimum-tests', '4083'[\s\S]*'--maximum-not-executed', '2'[\s\S]*'--allowed-not-executed-file', \$allowedNotExecuted/,
);
assert.match(
  script,
  /'domain-core-native-identity'[\s\S]*'--expected-commit', \$script:SourceIdentity\.commitSha[\s\S]*'--observed-identity', \$domainCoreObservedIdentityPath[\s\S]*'--binary', \$domainCoreNativePath/,
);
assert.match(script, /SUPPLEMENTAL-LIVE-RECEIPT-MISSING/);
assert.match(script, /\$supplementalGateIds = @\('accessibility-display'\)/);
assert.match(script, /\$supplementalGateIds -notcontains/);
assert.match(
  script,
  /\$performanceArchitectureByGate\.ContainsKey\(\$candidateGate\)/,
);
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
assert.match(
  script,
  /\$attestationCapturedAt -lt \$receiptStartedAt\.AddHours\(-24\)/,
);
assert.match(
  script,
  /\$candidate\.device\.hardwareAttestation\.evidencePath = \$candidateAttestationDestinationRelative/,
);
assert.match(
  script,
  /Get-Sha256 \$sourcePath[\s\S]*Supplemental evidence hash mismatch[\s\S]*Copy-Item -LiteralPath \$sourcePath/,
);
assert.match(localRunner, /const runtimePlatform = platform\(\)/);
assert.match(
  localRunner,
  /const windowsNativeColdSpike = runtimePlatform === "win32"/,
);
assert.match(
  localRunner,
  /name: "domain-core-native-build"[\s\S]*file: "rustup"[\s\S]*"run"[\s\S]*"1\.96\.0"[\s\S]*"cargo"/,
);
assert.ok(
  localRunner.indexOf('name: "domain-core-native-build"') <
    localRunner.indexOf('name: "windows-solution-aggregate"'),
  "the local certification runner must build the native domain core before running Windows tests",
);
assert.match(
  localRunner,
  /name: "domain-core-native-build"[\s\S]*"--locked"[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: source\.commitSha/,
);
assert.match(
  localRunner,
  /name: "domain-core-native-stage"[\s\S]*stage-local-rust-cdylib\.mjs[\s\S]*"--toolchain"[\s\S]*"1\.96\.0"[\s\S]*"--logical-name"[\s\S]*"openburnbar_domain_ffi"[\s\S]*"--destination"[\s\S]*domainCoreNativePath[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: source\.commitSha/,
);
assert.ok(
  localRunner.indexOf('name: "domain-core-native-build"') <
    localRunner.indexOf('name: "domain-core-native-stage"') &&
    localRunner.indexOf('name: "domain-core-native-stage"') <
      localRunner.indexOf('name: "windows-solution-aggregate"'),
  "the local certification runner must stage the native domain core after Cargo and before Windows tests",
);
assert.match(localRunner, /OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE: "1"/);
assert.match(localRunner, /OPENBURNBAR_REQUIRE_NATIVE_SHIMS: "1"/);
assert.match(localRunner, /OPENBURNBAR_NATIVE_DIR: nativeStageDir/);
assert.match(
  localRunner,
  /DOMAIN_CORE_NATIVE_LIBRARY_PATH: domainCoreNativePath/,
);
assert.match(localRunner, /DOMAIN_CORE_CANDIDATE_COMMIT: source\.commitSha/);
assert.match(
  localRunner,
  /DOMAIN_CORE_OBSERVED_IDENTITY_REPORT: domainCoreObservedIdentityPath/,
);
assert.match(
  localRunner,
  /name: "domain-core-local-identity"[\s\S]*verify-local-domain-core-identity\.mjs[\s\S]*"--expected-commit"[\s\S]*source\.commitSha[\s\S]*"--observed-identity"[\s\S]*domainCoreObservedIdentityPath[\s\S]*"--binary"[\s\S]*domainCoreNativePath/,
);
assert.ok(
  localRunner.indexOf('name: "domain-core-local-identity"') >
    localRunner.indexOf("for (const project of testProjects)"),
  "the local certification runner must verify the loaded native identity after all Windows tests",
);
assert.match(
  localRunner,
  /name: "burnbar-remote-native-build"[\s\S]*"1\.94\.0"[\s\S]*"burnbar-remote-ffi"/,
);
assert.match(
  localRunner,
  /name: "burnbar-remote-native-stage"[\s\S]*"burnbar_remote"[\s\S]*burnBarRemoteNativePath/,
);
assert.match(
  localRunner,
  /name: "iroh-native-build"[\s\S]*"1\.96\.0"[\s\S]*"crates\/openburnbar-iroh\/Cargo\.toml"/,
);
assert.match(
  localRunner,
  /name: "iroh-native-stage"[\s\S]*"openburnbar_iroh"[\s\S]*irohNativePath/,
);
assert.match(
  localRunner,
  /isColdNativeSpike \? \(windowsNativeColdSpike \? "600s" : "180s"\) : "60s"/,
);
assert.match(
  localRunner,
  /timeoutMs: isColdNativeSpike[\s\S]*\? windowsNativeColdSpike[\s\S]*\? 900000[\s\S]*: 360000[\s\S]*: 180000/,
);
assert.match(
  localRunner,
  /const windowsSolutionAggregateHangTimeout = "600s"/,
);
assert.match(
  localRunner,
  /windows\/OpenBurnBar\.sln[\s\S]*--blame-hang-timeout",[\s\S]*windowsSolutionAggregateHangTimeout[\s\S]*timeoutMs: 900000/,
);
assert.match(localRunner, /PYTHONUTF8: process\.env\.PYTHONUTF8 \?\? "1"/);
assert.match(localRunner, /\.\.\.\(spec\.env \?\? \{\}\)/);
const cleanSourceGuard = localRunner.indexOf("if (source.dirtyTree)");
assert.ok(cleanSourceGuard > localRunner.indexOf("const source ="));
assert.ok(
  cleanSourceGuard < localRunner.indexOf("mkdirSync(logsDir"),
  "the local certification runner must reject a dirty candidate before writing evidence or building native code",
);
assert.match(
  localRunner,
  /if \(source\.dirtyTree\)[\s\S]*exact-candidate certification requires a clean source tree[\s\S]*process\.exit\(1\)/,
);
assert.match(
  localRunner,
  /if \(failedResults\.length > 0\)[\s\S]*NO-GO evidence bundle was retained[\s\S]*process\.exit\(1\)/,
);
assert.doesNotMatch(
  nativeLibraryStaging,
  /rmSync\(destination/,
  "native staging must not create a delete-before-rename gap",
);
assert.ok(
  nativeLibraryStaging.indexOf("copyFileSync(source, temporary)") <
    nativeLibraryStaging.indexOf("renameSync(temporary, destination)"),
  "native staging must verify a temporary copy before atomically replacing the destination",
);
assert.match(rustCdylibStager, /rustup/);
assert.match(rustCdylibStager, /cargo[\s\S]*metadata[\s\S]*--locked/);
assert.match(rustCdylibStager, /targetTriple/);
assert.match(
  rustCdylibStager,
  /--message-format=json-render-diagnostics/,
);
assert.match(rustCdylibStager, /cargoCdylibArtifactPathFromMessages/);
assert.match(
  rustCdylibStager,
  /stageNativeLibrary\(source, options\.destination\)/,
);

function gitIndexMode(relativePath) {
  const entry = execFileSync(
    "git",
    ["-C", repoRoot, "ls-files", "--stage", "--", relativePath],
    { encoding: "utf8" },
  ).trim();
  return entry.split(/\s+/u)[0] ?? "";
}
for (const executableScript of [
  "scripts/windows-port/run-local-certification-checks.mjs",
  "scripts/windows-port/stage-local-rust-cdylib.mjs",
  "scripts/windows-port/test-physical-release-certification.mjs",
  "scripts/windows-port/verify-local-domain-core-identity.mjs",
  "scripts/windows-port/verify-trx-results.mjs",
]) {
  assert.equal(
    gitIndexMode(executableScript),
    "100755",
    `${executableScript} must be committed as executable`,
  );
}

const windowsHost = describeLocalCertificationHost({
  platform: "win32",
  release: "10.0.26200",
  architecture: "x64",
  cpuModel: "Virtual CPU",
  ramBytes: 8 * 1024 ** 3,
});
assert.equal(
  windowsHost.label,
  "Windows native host (physicality not attested)",
);
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
