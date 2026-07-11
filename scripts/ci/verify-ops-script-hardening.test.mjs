#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(path, "utf8");

const hostedMcp = read("scripts/deploy-hosted-mcp.sh");
assert.match(
  hostedMcp,
  /\*\)\n\s+if \[\[ "\$SECONDS" -ge "\$deadline" \]\]; then\n\s+echo "Cloud Build timed out waiting for \$\{build_id\}; last status: \$\{status\}"/,
  "hosted MCP Cloud Build polling must time out even for unexpected statuses",
);

const cloudRunWorkflow = read(".github/workflows/deploy-cloud-run.yml");
assert.match(
  cloudRunWorkflow,
  /\*\)\n\s+if \[\[ "\$SECONDS" -ge "\$deadline" \]\]; then\n\s+echo "::error::Cloud Build timed out waiting for \$\{build_id\}; last status: \$\{status\}"/,
  "Cloud Run workflow polling must time out even for unexpected statuses",
);

const deadFlags = read("scripts/detect-dead-feature-flags.sh");
for (const include of ['--include="*.mjs"', '--include="*.js"', '--include="*.sh"']) {
  assert.ok(deadFlags.includes(include), `grep fallback must include ${include}`);
}

const versionConsistency = read("scripts/verify-version-consistency.sh");
assert.ok(
  versionConsistency.includes("OPENBURNBAR_REQUIRE_CURRENT_HOMEBREW_CASK"),
  "version consistency must expose an explicit Homebrew enforcement mode",
);
assert.match(
  versionConsistency,
  /GITHUB_REF_TYPE:-\}" == "tag"/,
  "version consistency must enforce current Homebrew cask on tag builds",
);
assert.ok(
  versionConsistency.includes("OPENBURNBAR_EXPECTED_VERSION"),
  "version consistency must reject a requested release version that differs from project.yml",
);

const windowsReleaseWorkflow = read(".github/workflows/openburnbar-release-windows.yml");
assert.match(
  windowsReleaseWorkflow,
  /OPENBURNBAR_EXPECTED_VERSION: \$\{\{ needs\.resolve-release\.outputs\.version \}\}/,
  "Windows release workflow must bind the resolved release version to the repo version gate",
);
assert.match(
  windowsReleaseWorkflow,
  /OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION: \$\{\{ github\.event_name == 'workflow_dispatch' && github\.event\.inputs\.allow_unsigned == 'true' && '0' \|\| '1' \}\}/,
  "only an explicit unsigned Windows rehearsal may defer the Windows manifest version",
);
assert.match(
  windowsReleaseWorkflow,
  /Windows Kits\\10\\bin\\\*\\x64\\makeappx\.exe/,
  "Windows release workflow must locate MakeAppx from the installed Windows SDK",
);
assert.match(
  windowsReleaseWorkflow,
  /Windows Kits\\10\\bin\\\*\\x64\\makepri\.exe/,
  "Windows release workflow must locate MakePri from the installed Windows SDK",
);
assert.match(
  windowsReleaseWorkflow,
  /windows\/packaging\/msix\/New-MsixPackage\.ps1/,
  "Windows release workflow must package the already-published app through the reviewed MSIX script",
);
assert.match(
  windowsReleaseWorkflow,
  /-MakePriPath "\$makepri"/,
  "Windows release workflow must pass the reviewed MakePri tool to the MSIX packager",
);
assert.match(
  windowsReleaseWorkflow,
  /Test-SignedMsixLifecycle\.ps1[\s\S]*-HoldSeconds 20/,
  "signed MSIX evidence must exercise a sustained application launch",
);
assert.ok(
  windowsReleaseWorkflow.includes('predicate.write_text(json.dumps(payload'),
  "Windows release attestations must generate a per-artifact Sigstore predicate",
);
assert.ok(
  windowsReleaseWorkflow.includes('--predicate "$predicate"'),
  "Windows release attestations must generate and pass a per-artifact Sigstore predicate",
);
assert.match(
  windowsReleaseWorkflow,
  /unzip -q "\$archive" -d "sbom-input\/\$\{name\}"[\s\S]*path: sbom-input/,
  "Windows SBOM generation must inventory expanded package contents",
);
assert.ok(
  windowsReleaseWorkflow.includes("SBOM contains no dependency packages after expanding Windows artifacts"),
  "Windows SBOM generation must fail closed when package dependencies are absent",
);
const updaterTestsIndex = windowsReleaseWorkflow.indexOf(
  "Run updater unit tests against committed sample pin",
);
const productionPinIndex = windowsReleaseWorkflow.indexOf(
  'printf \'%s\\n\' "$WINDOWS_UPDATE_PUBLIC_KEY" > "$pin"',
);
assert.ok(
  updaterTestsIndex >= 0 && productionPinIndex > updaterTestsIndex,
  "committed updater fixtures must run before the production key replaces their development pin",
);
assert.match(
  read("windows/packaging/updater/OpenBurnBar.Updater.Generator/Program.cs"),
  /VerifyGeneratedFeed\([\s\S]*UpdateFeedVerifier\.TryCreate\([\s\S]*VerifyArtifact\(/,
  "the Windows feed generator must parse and pin-verify its emitted release feeds",
);
const windowsMsixPackager = read("windows/packaging/msix/New-MsixPackage.ps1");
assert.match(
  windowsMsixPackager,
  /SetAttribute\("Version", "\$Version\.0"\)[\s\S]*SetAttribute\("ProcessorArchitecture", \$Architecture\)/,
  "MSIX staging must stamp the resolved version and target architecture into the package identity",
);
assert.match(
  windowsMsixPackager,
  /\$executableAttribute\.Value/,
  "MSIX staging must validate the executable attribute value, not its serialized XML form",
);
assert.match(
  windowsMsixPackager,
  /WriteAllLines\([\s\S]*pri\.resfiles[\s\S]*@\("PRI", "RESFILES"\)/,
  "MSIX staging must merge component PRI files through an explicit resfiles index",
);
assert.match(
  windowsMsixPackager,
  /MakePriPath new[\s\S]*\/in \$packageName[\s\S]*MakePriPath dump/,
  "MSIX staging must build and inspect a package-identity resources.pri",
);
assert.match(
  windowsMsixPackager,
  /NamedResource\[@name='FlyoutWindow\.xbf'\]/,
  "MSIX staging must fail closed when the packaged FlyoutWindow XBF is absent",
);

const signedMsixLifecycle = read("windows/packaging/msix/Test-SignedMsixLifecycle.ps1");
assert.match(
  signedMsixLifecycle,
  /shell:AppsFolder\\\$appUserModelId/,
  "signed MSIX lifecycle verification must launch the registered application identity",
);
assert.match(
  signedMsixLifecycle,
  /Start-Sleep -Seconds \$HoldSeconds[\s\S]*Get-Process -Name \$ProcessName/,
  "signed MSIX lifecycle verification must prove that the process survives the hold window",
);
assert.match(
  signedMsixLifecycle,
  /Application Error\|Windows Error Reporting\|\\\.NET Runtime/,
  "signed MSIX lifecycle verification must reject Windows crash events",
);
assert.match(
  signedMsixLifecycle,
  /Application\\\.UnhandledException\|XamlParseException\|fatal/,
  "signed MSIX lifecycle verification must reject fatal WinUI diagnostic entries",
);
for (const requiredEvidence of [
  "openburnbar.windows.signed-msix-lifecycle.v2",
  "clean-install-sustained-launch",
  "reinstall-sustained-launch",
]) {
  assert.ok(
    signedMsixLifecycle.includes(requiredEvidence),
    `signed MSIX lifecycle evidence must include ${requiredEvidence}`,
  );
}

const windowsDistPrWorkflow = read(".github/workflows/pr-windows-dist.yml");
assert.match(
  windowsDistPrWorkflow,
  /windows\/packaging\/msix\//,
  "Windows distribution PR detection must include the MSIX packaging surface",
);
assert.match(
  windowsDistPrWorkflow,
  /Get-ChildItem windows\/packaging\/msix[\s\S]*Language\.Parser\]::ParseFile\(/,
  "Windows distribution PR verification must parse the MSIX PowerShell scripts",
);
assert.ok(
  windowsDistPrWorkflow.includes("node scripts/ci/verify-ops-script-hardening.test.mjs"),
  "Windows distribution PR verification must execute the release wiring regressions",
);

const firebaseRules = read("scripts/ci/deploy-firebase-rules-releases.mjs");
assert.ok(
  firebaseRules.includes("rulesSourceForDeploy"),
  "Firestore rules release helper must compact deploy source before creating rulesets",
);
assert.match(
  firebaseRules,
  /method: "PATCH",[\s\S]*body: JSON\.stringify\(\{\s*release: update,\s*\}\)/,
  "Firebase Rules release PATCH must match firebase-tools' nested release payload without updateMask",
);
const firestoreWorkflow = read(".github/workflows/deploy-firestore.yml");
assert.match(
  firestoreWorkflow,
  /--only firestore:indexes,storage/,
  "Firestore deploy workflow must avoid firebase-tools' broken firestore:rules release path",
);
assert.match(
  firestoreWorkflow,
  /node scripts\/ci\/deploy-firebase-rules-releases\.mjs "\$FIREBASE_PROJECT"/,
  "Firestore deploy workflow must release rules through the hardened REST script",
);

console.log("PASS: ops script hardening regression checks");
