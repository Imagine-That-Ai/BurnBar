#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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
for (const include of [
  '--include="*.mjs"',
  '--include="*.js"',
  '--include="*.sh"',
]) {
  assert.ok(
    deadFlags.includes(include),
    `grep fallback must include ${include}`,
  );
}

const versionConsistency = read("scripts/verify-version-consistency.sh");
const homebrewUpdater = read("scripts/update-homebrew.sh");
const macosR2Uploader = read("scripts/upload-macos-downloads-r2.sh");
const macosRollbackPublisher = read(
  "scripts/publish-macos-appcast-rollback-r2.sh",
);
const macosRollback = read("scripts/ops/rollback-macos-appcast.sh");
const releaseProject = read("project.yml");
const releaseInfoPlist = read("AgentLens/Resources/OpenBurnBar-Info.plist");
const directUpdateService = read(
  "AgentLens/Services/DirectDownloadUpdateService.swift",
);
const homebrewCask = read("homebrew/burnbar.rb");
const projectVersion = read("project.yml").match(
  /^\s+MARKETING_VERSION:\s*["']?([^\s"']+)/m,
)?.[1];
assert.ok(projectVersion, "project.yml must expose a MARKETING_VERSION");
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
assert.ok(
  versionConsistency.includes("OPENBURNBAR_EXPECTED_WINDOWS_VERSION"),
  "version consistency must support an independently requested Windows release version",
);
assert.match(
  homebrewUpdater,
  /^OWNER="Imagine-That-Ai"$/m,
  "the Homebrew updater must download releases from the canonical organization repository",
);
assert.match(
  homebrewCask,
  /url "https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/releases\/download\/v#\{version\}\/OpenBurnBar-#\{version\}-macOS\.dmg"/,
  "the Homebrew cask must download the canonical organization release artifact",
);
assert.match(
  homebrewCask,
  /homepage "https:\/\/github\.com\/Imagine-That-Ai\/BurnBar"/,
  "the Homebrew cask homepage must use the canonical organization repository",
);
assert.match(
  versionConsistency,
  /canonical_repository="Imagine-That-Ai\/BurnBar"/,
  "version consistency must fail closed on Homebrew repository-owner drift",
);
assert.match(
  macosR2Uploader,
  /OPENBURNBAR_RELEASE_ASSET_DIR/,
  "the R2 uploader must consume the exact audited release asset directory",
);
assert.match(
  macosR2Uploader,
  /OPENBURNBAR_RELEASE_RECEIPT/,
  "the R2 uploader must consume the promotion-audit receipt",
);
assert.match(
  macosR2Uploader,
  /OPENBURNBAR_RELEASE_VERSION:-\$\(/,
  "the R2 uploader must accept an exact release version independent of the public website pointer",
);
assert.match(
  macosR2Uploader,
  /MARKETING_VERSION:/,
  "the R2 uploader must default to the prepared project marketing version",
);
assert.doesNotMatch(
  macosR2Uploader,
  /website\/src\/data\/site\.ts/,
  "the R2 uploader must not derive release artifacts from the previously published website version",
);
assert.match(
  macosR2Uploader,
  /macos-r2-publication\.mjs preflight[\s\S]*upload_group immutable[\s\S]*upload_group metadata[\s\S]*upload_group discovery[\s\S]*macos-r2-publication\.mjs verify-public/u,
  "the R2 uploader must preflight fully, publish immutable assets before metadata/discovery, and exactly verify public bytes",
);
assert.match(
  macosR2Uploader,
  /Use the exact asset directory and receipt emitted by promote-github-release\.mjs audit/,
  "the R2 uploader must document the authoritative producer handoff",
);
assert.match(
  macosRollbackPublisher,
  /OPENBURNBAR_EXPECTED_LIVE_VERSION[\s\S]*OPENBURNBAR_EXPECTED_LIVE_COMMIT/u,
  "the rollback publisher must compare-and-swap against the operator-declared live release",
);
assert.match(
  macosRollbackPublisher,
  /capture_snapshot[\s\S]*verify_snapshot_unchanged[\s\S]*mutation_started=true[\s\S]*upload_group metadata[\s\S]*upload_group discovery[\s\S]*verify-rollback-public/u,
  "the rollback publisher must snapshot, race-check, publish metadata/discovery in order, and exactly verify",
);
assert.match(
  macosRollbackPublisher,
  /on_exit[\s\S]*restore_snapshot/u,
  "the rollback publisher must compensate after partial publication",
);
assert.match(
  macosRollback,
  /scripts\/publish-macos-appcast-rollback-r2\.sh/u,
  "the rollback tool must hand off only to the dedicated rollback publisher",
);
assert.doesNotMatch(
  macosRollback,
  /scripts\/upload-macos-downloads-r2\.sh/u,
  "the rollback tool must never invoke the full-release uploader",
);
for (const source of [releaseProject, releaseInfoPlist, directUpdateService]) {
  assert.match(
    source,
    /https:\/\/downloads\.burnbar\.ai\/latest-macos\.json/u,
    "the shipped direct updater must poll the governed R2 pointer",
  );
}
for (const source of [releaseProject, releaseInfoPlist]) {
  assert.match(
    source,
    /https:\/\/downloads\.burnbar\.ai\/appcast\.xml/u,
    "the shipped Sparkle updater must poll the governed R2 appcast",
  );
}

const windowsManifest = read("windows/app/OpenBurnBar.App/app.manifest");
const expectedWindowsAssemblyVersion = "1.0.40.0";
const windowsVersionFull = windowsManifest.match(
  /assemblyIdentity[\s\S]*?version="(\d+\.\d+\.\d+\.\d+)"/,
)?.[1];
assert.equal(
  windowsVersionFull,
  expectedWindowsAssemblyVersion,
  `Windows app manifest must declare the next release identity ${expectedWindowsAssemblyVersion}`,
);
const windowsVersion = windowsVersionFull.split(".").slice(0, 3).join(".");
assert.ok(
  windowsVersion,
  "Windows app manifest must expose an X.Y.Z release version",
);
const windowsVersionParts = windowsVersion.split(".").map(Number);
const mismatchedWindowsVersion = `${windowsVersionParts[0]}.${windowsVersionParts[1]}.${windowsVersionParts[2] + 1}`;
const matchingWindowsGate = spawnSync(
  "bash",
  ["scripts/verify-version-consistency.sh"],
  {
    encoding: "utf8",
    env: {
      ...process.env,
      OPENBURNBAR_EXPECTED_WINDOWS_VERSION: windowsVersion,
      OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION: "1",
    },
  },
);
assert.equal(
  matchingWindowsGate.status,
  0,
  matchingWindowsGate.stderr || matchingWindowsGate.stdout,
);
const mismatchedWindowsGate = spawnSync(
  "bash",
  ["scripts/verify-version-consistency.sh"],
  {
    encoding: "utf8",
    env: {
      ...process.env,
      OPENBURNBAR_EXPECTED_WINDOWS_VERSION: mismatchedWindowsVersion,
      OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION: "1",
    },
  },
);
assert.notEqual(
  mismatchedWindowsGate.status,
  0,
  "a mismatched Windows release version must fail closed",
);
assert.match(mismatchedWindowsGate.stderr, /Windows app manifest.*expected/);
const nonWindowsTagGate = spawnSync(
  "bash",
  ["scripts/verify-version-consistency.sh"],
  {
    encoding: "utf8",
    env: {
      ...process.env,
      GITHUB_REF: `refs/tags/v${projectVersion}`,
      GITHUB_REF_NAME: `v${projectVersion}`,
      GITHUB_REF_TYPE: "tag",
      OPENBURNBAR_EXPECTED_WINDOWS_VERSION: "",
      OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION: "0",
    },
  },
);
assert.match(
  nonWindowsTagGate.stdout,
  /Windows app manifest(?: deferred)?/u,
  "ordinary v* tags must not require the independently versioned Windows manifest",
);
assert.doesNotMatch(
  nonWindowsTagGate.stderr,
  /Windows app manifest.*expected/,
  "ordinary v* tags may fail their macOS release gates, but not the independent Windows version gate",
);

const windowsReleaseWorkflow = read(
  ".github/workflows/openburnbar-release-windows.yml",
);
const windowsEngineWorkflow = read(
  ".github/workflows/openburnbar-engine-windows.yml",
);
const windowsOperationsRunbook = read(
  "docs/windows-port/WINDOWS_PORT_OPERATIONS_RUNBOOK.md",
);
assert.match(
  windowsReleaseWorkflow,
  /ensure-windows-domain-core-release\.mjs[\s\S]*--phase prepare[\s\S]*publish-domain-core-release-evidence\.mjs/u,
  "Windows release workflow must keep its public GitHub publication path visible to the operations contract",
);
assert.match(
  windowsOperationsRunbook,
  /Stop for explicit operator approval before pushing the tag\.[\s\S]*publishes a public GitHub Release[\s\S]*do not create or push the tag/u,
  "Windows operations must require explicit public GitHub release approval before a windows-v* tag is pushed",
);
for (const dryRun of ["true", "false"]) {
  assert.match(
    windowsOperationsRunbook,
    new RegExp(
      String.raw`gh workflow run deploy-staging\.yml --repo "\$REPO" --ref main \\\n\s+-f candidate_sha="\$CANDIDATE_SHA" \\\n\s+-f dry_run=${dryRun} -f deploy_functions=true`,
      "u",
    ),
    `Windows staging dry_run=${dryRun} dispatch must bind the exact candidate SHA`,
  );
}
const windowsVersionArgumentSets =
  windowsReleaseWorkflow.match(
    /-p:Version="\$VERSION" -p:AssemblyVersion="\$\{VERSION\}\.0" \\\n\s+-p:FileVersion="\$\{VERSION\}\.0" -p:InformationalVersion="\$VERSION"/g,
  ) ?? [];
assert.equal(
  windowsVersionArgumentSets.length,
  4,
  "the app, CLI, watchdog, and privileged-input publishes must all derive package, assembly, file, and informational versions from the authorized Windows release tag",
);
assert.match(
  windowsReleaseWorkflow,
  /OPENBURNBAR_EXPECTED_WINDOWS_VERSION: \$\{\{ needs\.resolve-release\.outputs\.version \}\}/,
  "Windows release workflow must bind the resolved release version to the Windows manifest gate",
);
assert.match(
  windowsReleaseWorkflow,
  /OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION: \$\{\{ github\.event_name == 'workflow_dispatch' && github\.event\.inputs\.allow_unsigned == 'true' && '0' \|\| '1' \}\}/,
  "only an explicit unsigned Windows rehearsal may defer the Windows manifest version",
);
assert.match(
  windowsReleaseWorkflow,
  /Mandatory Windows release package is missing/,
  "final checksums must fail closed when a mandatory Windows package is missing",
);
assert.match(
  windowsReleaseWorkflow,
  /CODESIGN_ENABLED[\s\S]*Signed release certification manifest is missing/,
  "signed final checksums must require both physical-certification manifests",
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
  /Build Microsoft Store MSIX packages[\s\S]*store-identity\.json[\s\S]*-DistributionChannel MicrosoftStore[\s\S]*artifacts\/store/,
  "Windows release workflow must build a distinct Store-identity package set",
);
assert.match(
  windowsReleaseWorkflow,
  /Authenticode sign the direct-download MSIX[\s\S]*files-folder-recurse: false[\s\S]*Verify Microsoft Store MSIX identity and unsigned state[\s\S]*-SignatureExpectation Unsigned/,
  "Microsoft Store packages must stay outside direct Artifact Signing and be rechecked as unsigned afterward",
);
assert.match(
  windowsReleaseWorkflow,
  /store\/OpenBurnBar-\$\{VERSION\}-store-x64\.msix[\s\S]*store\/OpenBurnBar-\$\{VERSION\}-store-arm64\.msix[\s\S]*store-submission-v\$\{VERSION\}\.json/,
  "final checksums must bind both Store packages and their submission manifest",
);
assert.match(
  windowsReleaseWorkflow,
  /archives=\(artifacts\/\*\.zip artifacts\/\*\.msix artifacts\/store\/\*\.msix\)/,
  "the Windows SBOM must inventory both direct and Store package contents",
);
assert.match(
  windowsReleaseWorkflow,
  /find artifacts -type f -print0/,
  "Sigstore provenance must recurse into the Store artifact directory",
);
assert.match(
  windowsReleaseWorkflow,
  /OpenBurnBar\.ComputerUse\.Watchdog\.csproj[\s\S]*dotnet publish "\$watchdog"[\s\S]*cp -R "\$watchdog_out\/\." "publish\/\$rid\/ComputerUseWatchdog\/"/,
  "Windows release workflow must publish and stage the independent privileged-input watchdog",
);
assert.match(
  windowsReleaseWorkflow,
  /OpenBurnBar\.PrivilegedInput\.csproj[\s\S]*dotnet publish "\$privileged_input"[\s\S]*cp -R "\$privileged_input_out\/\." "publish\/\$rid\/PrivilegedInput\/"/,
  "Windows release workflow must publish and stage the complete privileged-input broker runtime",
);
assert.match(
  windowsReleaseWorkflow,
  /OpenBurnBar\.ComputerUse\.Watchdog\.exe[\s\S]*--verify-self-publisher[\s\S]*runtime publisher gate accepted/,
  "Windows release workflow must execute the signed watchdog's runtime publisher gate",
);
assert.match(
  windowsReleaseWorkflow,
  /PrivilegedInput\/OpenBurnBar\.PrivilegedInput\.exe[\s\S]*--verify-self-publisher[\s\S]*Privileged-input runtime publisher gate accepted/,
  "Windows release workflow must execute the signed privileged-input broker publisher gate",
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
const publishedLayoutValidationIndex = windowsReleaseWorkflow.indexOf(
  "Validate published native-engine layouts",
);
const publishedParserSmokeIndex = windowsReleaseWorkflow.indexOf(
  "Run parser smoke from the published x64 layout",
);
const authenticodeSignIndex = windowsReleaseWorkflow.indexOf(
  "- name: Authenticode sign",
);
assert.ok(
  publishedLayoutValidationIndex >= 0 &&
    publishedParserSmokeIndex > publishedLayoutValidationIndex &&
    authenticodeSignIndex > publishedParserSmokeIndex,
  "the real parser must execute from the published x64 layout before Authenticode signing",
);
const publishedParserSmokeBlock = windowsReleaseWorkflow.slice(
  publishedParserSmokeIndex,
  authenticodeSignIndex,
);
assert.match(
  publishedParserSmokeBlock,
  /OPENBURNBAR_REQUIRE_NATIVE_ENGINE_INTEGRATION: "1"[\s\S]*publish\/win-x64[\s\S]*\$smokeRoot = Join-Path \$env:RUNNER_TEMP[\s\S]*\$testOutputRoot = Join-Path \$env:RUNNER_TEMP[\s\S]*Copy-Item[\s\S]*OpenBurnBarCoreCAbi\.dll/,
  "the published-layout parser smoke must load the published native engine",
);
const trustedDotnetCaptureIndex = publishedParserSmokeBlock.indexOf(
  "$dotnetExecutable = (Get-Command dotnet -CommandType Application -ErrorAction Stop).Source",
);
const testhostBuildIndex = publishedParserSmokeBlock.indexOf(
  "& $dotnetExecutable build $testProject",
);
const resourceCopyIndex = publishedParserSmokeBlock.indexOf(
  "$requiredResourceBundles = @(",
);
const nativeDllSearchPathIndex = publishedParserSmokeBlock.indexOf(
  '$env:PATH = "$smokeRoot;$env:PATH"',
);
const parserTestIndex = publishedParserSmokeBlock.indexOf(
  "& $dotnetExecutable test $testProject",
);
assert.ok(
  trustedDotnetCaptureIndex >= 0 &&
    testhostBuildIndex > trustedDotnetCaptureIndex &&
    resourceCopyIndex > testhostBuildIndex &&
    parserTestIndex > resourceCopyIndex,
  "the isolated testhost must build before resource staging and execute afterward",
);
assert.ok(
  nativeDllSearchPathIndex > trustedDotnetCaptureIndex &&
    nativeDllSearchPathIndex < parserTestIndex,
  "the isolated testhost must pin trusted dotnet before exposing copied native dependencies",
);
for (const bundleName of [
  "OpenBurnBarCore_OpenBurnBarCore.resources",
  "OpenBurnBarCore_OpenBurnBarKernel.resources",
]) {
  assert.ok(
    publishedParserSmokeBlock.includes(bundleName),
    `the parser smoke must require ${bundleName}`,
  );
}
assert.match(
  publishedParserSmokeBlock,
  /Get-ChildItem[\s\S]*OpenBurnBarCore_\*\.resources[\s\S]*Copy-Item[\s\S]*\$testOutputRoot/,
  "Swift resource bundles must be copied beside the isolated test process",
);
assert.match(
  publishedParserSmokeBlock,
  /\$forbiddenRuntimeFiles = @\("hostfxr\.dll", "hostpolicy\.dll", "coreclr\.dll"\)[\s\S]*& \$dotnetExecutable test \$testProject[\s\S]*--no-build[\s\S]*--output \$testOutputRoot[\s\S]*NativeUsageEngineIntegrationTests/,
  "the parser smoke must reject app-local runtimes and execute the prebuilt isolated testhost",
);
assert.doesNotMatch(
  publishedParserSmokeBlock,
  /--output \$smokeRoot/,
  "the .NET testhost must not be emitted into the self-contained published app layout",
);
assert.equal(
  (
    windowsEngineWorkflow.match(/OPENBURNBAR_CORE_CABI_PATH=\$stagedEngine/g) ??
    []
  ).length,
  2,
  "both native architectures must run their usage scan from the staged engine layout",
);
assert.equal(
  (
    windowsEngineWorkflow.match(
      /Copy-Item -Path \(Join-Path \$env:OPENBURNBAR_NATIVE_ENGINE_STAGE "\*"\)/g,
    ) ?? []
  ).length,
  2,
  "both native architectures must mirror the staged bundle into the parser smoke host layout",
);
assert.equal(
  (windowsEngineWorkflow.match(/--output \$smokeRoot/g) ?? []).length,
  2,
  "both native parser smoke hosts must execute beside the staged Swift resource bundles",
);
const portableSignatureIndex = windowsReleaseWorkflow.indexOf(
  "Verify portable Authenticode signatures",
);
const signedManifestRefreshIndex = windowsReleaseWorkflow.indexOf(
  "Refresh and validate signed native-engine layouts",
);
const portablePackageIndex = windowsReleaseWorkflow.indexOf(
  "Package zips + checksums",
);
assert.ok(
  portableSignatureIndex >= 0 &&
    signedManifestRefreshIndex > portableSignatureIndex &&
    portablePackageIndex > signedManifestRefreshIndex,
  "signed native-engine manifests must be refreshed after Authenticode and before packaging",
);
assert.ok(
  windowsReleaseWorkflow.includes("refresh-native-engine-manifest.mjs"),
  "Windows release packaging must refresh native-engine hashes after signing",
);
assert.ok(
  windowsReleaseWorkflow.includes("predicate.write_text(json.dumps(payload"),
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
  windowsReleaseWorkflow.includes(
    "SBOM contains no dependency packages after expanding Windows artifacts",
  ),
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
  /MicrosoftStore packaging requires a complete Partner Center identity[\s\S]*StoreProductId[\s\S]*distribution-channel\.json[\s\S]*SetAttribute\("Name", \$PackageName\)[\s\S]*SetAttribute\("Publisher", \$Publisher\)[\s\S]*PackageDisplayName[\s\S]*PublisherDisplayName/,
  "MSIX staging must fail closed on partial Store identity and stamp every Partner Center field",
);
const windowsMsixIdentityVerifier = read(
  "windows/packaging/msix/Test-MsixPackageIdentity.ps1",
);
assert.match(
  windowsMsixIdentityVerifier,
  /MakeAppxPath unpack[\s\S]*ExpectedName[\s\S]*ExpectedPublisher[\s\S]*ExpectedDisplayName[\s\S]*ExpectedPublisherDisplayName[\s\S]*ExpectedVersion[\s\S]*ExpectedArchitecture/,
  "Store package verification must inspect every required identity field from the packed MSIX",
);
assert.match(
  windowsMsixIdentityVerifier,
  /SignatureExpectation[\s\S]*AppxSignature\.p7x[\s\S]*Microsoft Store submission package must not contain AppxSignature\.p7x/,
  "Store package verification must fail closed if a submission package becomes signed",
);
assert.match(
  windowsMsixIdentityVerifier,
  /MicrosoftStore package contains forbidden direct-update metadata[\s\S]*distribution-channel\.json[\s\S]*Sideload package is missing required direct-update metadata/,
  "package verification must prove direct and Store update ownership cannot cross channels",
);
assert.match(
  windowsMsixPackager,
  /\$executableAttribute\.Value/,
  "MSIX staging must validate the executable attribute value, not its serialized XML form",
);
assert.match(
  windowsMsixPackager,
  /ComputerUseWatchdog\\OpenBurnBar\.ComputerUse\.Watchdog\.exe[\s\S]*Privileged-input watchdog is missing/,
  "MSIX staging must fail closed when the privileged-input watchdog is absent",
);
assert.match(
  windowsMsixPackager,
  /PrivilegedInput\\OpenBurnBar\.PrivilegedInput\.exe[\s\S]*Privileged-input broker is missing/,
  "MSIX staging must fail closed when the privileged-input broker is absent",
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

const signedMsixLifecycle = read(
  "windows/packaging/msix/Test-SignedMsixLifecycle.ps1",
);
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
  /on:\n\s+workflow_dispatch:/,
  "Windows distribution verification must support an exact-candidate manual run",
);
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
  windowsDistPrWorkflow.includes(
    "node scripts/ci/verify-ops-script-hardening.test.mjs",
  ),
  "Windows distribution PR verification must execute the release wiring regressions",
);
assert.match(
  windowsDistPrWorkflow,
  /msix-package-smoke:[\s\S]*runs-on: windows-latest[\s\S]*dotnet publish windows\/app\/OpenBurnBar\.App\/OpenBurnBar\.App\.csproj[\s\S]*New-MsixPackage\.ps1[\s\S]*-DistributionChannel Sideload[\s\S]*-DistributionChannel MicrosoftStore[\s\S]*Test-MsixPackageIdentity\.ps1/,
  "Windows distribution PR verification must execute MakePri/MakeAppx over real WinUI output for both package channels",
);
assert.match(
  windowsDistPrWorkflow,
  /MSIX_SMOKE_RESULT[\s\S]*The Windows MSIX package smoke failed/,
  "the required Windows distribution aggregate must fail when the real MSIX smoke fails",
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
