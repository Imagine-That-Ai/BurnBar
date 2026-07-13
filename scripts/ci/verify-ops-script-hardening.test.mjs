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

const foundationUiaCollector = read(
  "scripts/windows-port/foundation-host-uia-collector.ps1",
);
assert.match(
  foundationUiaCollector,
  /\[ValidateRange\(10000, 120000\)\] \[int\] \$WindowTimeoutMilliseconds = 30000/,
  "foundation UIA collection must allow ARM64 cold starts enough time to expose a window",
);
assert.match(
  foundationUiaCollector,
  /Find-WindowForProcess -ProcessId \$process\.Id -TimeoutMs \$WindowTimeoutMilliseconds/,
  "foundation UIA scenarios must use the configured window timeout",
);
assert.match(
  foundationUiaCollector,
  /timeoutMilliseconds = \$WindowTimeoutMilliseconds[\s\S]*processExited = \$process\.HasExited/,
  "foundation UIA failures must distinguish startup timeout from early process exit",
);

// The bespoke REST rules-release helper (deploy-firebase-rules-releases.mjs)
// 400'd on every push for ~3 weeks (diligence 2026-07-12 LB-2) and was removed
// in favor of firebase-tools' proven release path. Guard the replacement so the
// supply-chain posture survives: rules ship through the pinned CLI, compacted to
// preserve the size margin, with a pre-deploy size tripwire and no predeploy.
const firestoreWorkflow = read(".github/workflows/deploy-firestore.yml");
assert.match(
  firestoreWorkflow,
  /--only firestore,storage/,
  "Firestore deploy must ship rules (and indexes + storage) through firebase-tools",
);
assert.doesNotMatch(
  firestoreWorkflow,
  /deploy-firebase-rules-releases\.mjs/,
  "the removed bespoke REST rules-release helper must not be reintroduced",
);
assert.match(
  firestoreWorkflow,
  /node scripts\/ci\/compact-firestore-rules-inplace\.mjs firestore\.rules/,
  "Firestore rules must be compacted in place before firebase-tools deploys them",
);
assert.match(
  firestoreWorkflow,
  /node scripts\/ci\/check-firestore-rules-size\.mjs/,
  "Firestore deploy must run the rules-size tripwire before deploying",
);
const compactHelper = read("scripts/ci/compact-firestore-rules-inplace.mjs");
assert.ok(
  compactHelper.includes("compactFirebaseRulesSource"),
  "the in-place compaction helper must use the shared compactor so deployed bytes match the drift check",
);

console.log("PASS: ops script hardening regression checks");
