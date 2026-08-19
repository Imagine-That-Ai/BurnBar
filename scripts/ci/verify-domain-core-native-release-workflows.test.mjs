import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const appleAndroid = readFileSync(
  new URL("../../.github/workflows/release.yml", import.meta.url),
  "utf8",
);
const domainCore = readFileSync(
  new URL("../../.github/workflows/domain-core.yml", import.meta.url),
  "utf8",
);
const windows = readFileSync(
  new URL(
    "../../.github/workflows/openburnbar-release-windows.yml",
    import.meta.url,
  ),
  "utf8",
);
const windowsEngine = readFileSync(
  new URL(
    "../../.github/workflows/openburnbar-engine-windows.yml",
    import.meta.url,
  ),
  "utf8",
);
const iosEvidence = readFileSync(
  new URL(
    "../../.github/workflows/domain-core-ios-release-evidence.yml",
    import.meta.url,
  ),
  "utf8",
);
const androidBuild = readFileSync(
  new URL("../../android/app/build.gradle.kts", import.meta.url),
  "utf8",
);
const project = readFileSync(
  new URL("../../project.yml", import.meta.url),
  "utf8",
);
const artifactVerifier = readFileSync(
  new URL("./verify-domain-core-native-release-artifact.sh", import.meta.url),
  "utf8",
);
const appleReporter = readFileSync(
  new URL(
    "../../OpenBurnBarCore/Sources/OpenBurnBarKernel/DomainCoreReleaseIdentityReporter.swift",
    import.meta.url,
  ),
  "utf8",
);
const appleApp = readFileSync(
  new URL("../../AgentLens/App/AgentLensApp.swift", import.meta.url),
  "utf8",
);

function job(source, name, nextName) {
  const start = source.indexOf(`\n  ${name}:`);
  assert.notEqual(start, -1, `missing ${name}`);
  const end = nextName ? source.indexOf(`\n  ${nextName}:`, start + 1) : -1;
  return source.slice(start, end === -1 ? source.length : end);
}

function renderArtifactName(template, { commit, runId, runAttempt }) {
  return template
    .replaceAll("${{ needs.release-preflight.outputs.release_commit }}", commit)
    .replaceAll("${{ github.run_id }}", String(runId))
    .replaceAll("${{ github.run_attempt }}", String(runAttempt));
}

test("native release profiles force stable tags and protect manual rollback", () => {
  for (const source of [appleAndroid, windows]) {
    assert.match(
      source,
      /domain_core_profile:\n[\s\S]*public-production-rollback/u,
    );
    assert.match(
      source,
      /GITHUB_EVENT_NAME[^\n]*==[^\n]*push[\s\S]*domain_core_profile=public-production/u,
    );
    assert.match(
      source,
      /authorize-domain-core-rollback:[\s\S]*environment: domain-core-promotion/u,
    );
  }
  assert.match(
    appleAndroid,
    /verify-domain-core-native-event-commit\.mjs[\s\S]*--event-commit "\$GITHUB_SHA"/u,
  );
});

test("Apple and Android signing consumes the exact protected gate first", () => {
  const gate = job(
    appleAndroid,
    "domain-core-native-release-gate",
    "build-and-release",
  );
  const build = job(appleAndroid, "build-and-release", "smoke-test");
  assert.match(gate, /attestations: read/u);
  assert.match(gate, /prepare-domain-core-native-release-gate\.mjs/u);
  assert.match(gate, /domain-core-native-release-gate-\$\{\{/u);
  assert.match(
    build,
    /needs:[\s\S]*release-preflight,[\s\S]*authorize-domain-core-rollback,[\s\S]*domain-core-native-release-gate,/u,
  );
  assert.match(build, /resolve-domain-core-build-profile\.mjs/u);
  assert.match(build, /domain-core-android-observed-identity\.json/u);
  assert.match(build, /verify-domain-core-observed-identity\.mjs/u);
  assert.doesNotMatch(build, /OpenBurnBarDomainCoreIdentityProbe/u);
  // regularFile() fail-closes on a relative path, so the policy argument must
  // stay workspace-anchored or the signing step can never run at all.
  assert.match(
    build,
    /--policy "\$GITHUB_WORKSPACE\/config\/apple-release-signing-policy\.json" --environment/u,
  );
  assert.match(build, /--binary "\$packaged_library"/u);
  assert.match(build, /verify-domain-core-android-universal-artifact\.mjs/u);
  assert.match(build, /run-domain-core-android-native-load\.sh/u);
  assert.match(build, /run-android-release-startup-smoke\.sh/u);
  assert.match(
    build,
    /\.\/gradlew :app:bundleRelease :app:assembleRelease --no-daemon/u,
  );
  assert.doesNotMatch(build, /run-as com\.openburnbar\.domaincore\.test/u);
  assert.match(build, /--candidate-aar Vendor\/openburnbar-domain-core\.aar/u);
  const checkedInAar = build.indexOf(
    "Rebuild and byte-compare checked-in Android AAR",
  );
  const candidateAar = build.indexOf(
    "Build candidate-bound four-ABI Android AAR",
  );
  const signedBundle = build.indexOf("Build signed Android release bundle");
  assert.ok(checkedInAar >= 0);
  assert.ok(checkedInAar < candidateAar);
  assert.ok(candidateAar < signedBundle);
  assert.match(
    build,
    /Rebuild and byte-compare checked-in Android AAR[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: 0{40}[\s\S]*build-domain-core-android-aar\.sh --check-artifact/u,
  );
  assert.match(
    build,
    /Build candidate-bound four-ABI Android AAR[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}[\s\S]*build-domain-core-android-aar\.sh/u,
  );
  assert.match(build, /runs-on: macos-26[\s\S]*arch: arm64-v8a/u);
  assert.match(
    androidBuild,
    /keepDebugSymbols \+= "\*\*\/libopenburnbar_domain_ffi\.so"/u,
  );
});

test("deterministic native smoke resolves candidate C and extracts Android identity before uninstall", () => {
  const appleSmoke = job(
    domainCore,
    "apple-native-smoke",
    "swift-consumer-contracts",
  );
  const android = job(domainCore, "android", "apple");
  assert.match(appleSmoke, /candidate_commit="\$\(git rev-parse HEAD\)"/u);
  assert.match(
    appleSmoke,
    /DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ steps\.candidate\.outputs\.commit \}\}/u,
  );
  assert.match(
    appleSmoke,
    /--expected-candidate-commit "\$\{\{ steps\.candidate\.outputs\.commit \}\}"/u,
  );
  assert.doesNotMatch(
    appleSmoke,
    /--expected-candidate-commit "\$GITHUB_SHA"/u,
  );
  assert.match(android, /run-domain-core-android-native-load\.sh/u);
  assert.doesNotMatch(android, /run-as com\.openburnbar\.domaincore\.test/u);
});

test("native release keeps protected candidate C distinct from activation P", () => {
  const gate = job(
    appleAndroid,
    "domain-core-native-release-gate",
    "build-and-release",
  );
  const build = job(appleAndroid, "build-and-release", "smoke-test");
  const evidence = job(
    appleAndroid,
    "domain-core-native-release-evidence",
    "verify-live-update-feed",
  );
  assert.match(
    gate,
    /resolve-domain-core-activation\.mjs[\s\S]*--release-commit "\$RELEASE_COMMIT"/u,
  );
  assert.match(gate, /CANDIDATE_COMMIT="\$\(jq -er '\.candidateCommit'/u);
  assert.match(
    gate,
    /--candidate-commit "\$CANDIDATE_COMMIT"[\s\S]*--release-commit "\$RELEASE_COMMIT"[\s\S]*--activation "\$activation"/u,
  );
  assert.doesNotMatch(gate, /--candidate-commit "\$RELEASE_COMMIT"/u);
  assert.match(
    build,
    /--expected-candidate-commit "\$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}"/u,
  );
  assert.match(
    evidence,
    /COMMIT: \$\{\{ needs\.release-preflight\.outputs\.release_commit \}\}[\s\S]*--activation "\$RUNNER_TEMP\/domain-core-native-release-gate\/domain-core-activation\.json"/u,
  );
});

test("Android release artifacts embed the preflight version", () => {
  assert.match(
    appleAndroid,
    /\.\/gradlew\s+:app:bundleRelease[^\n]*-PopenBurnBarAppVersionName="\$\{\{\s*needs\.release-preflight\.outputs\.version\s*\}\}"/u,
  );
  const projectVersion = project.match(
    /^\s+MARKETING_VERSION:\s*["']?([^\s"']+)/mu,
  )?.[1];
  assert.ok(projectVersion, "project.yml must expose a MARKETING_VERSION");
  const gradleFallbackVersion = androidBuild.match(
    /providers\s*\.\s*gradleProperty\(\s*"openBurnBarAppVersionName"\s*\)[\s\S]{0,160}?\.orElse\(\s*"([^"]+)"\s*\)/u,
  )?.[1];
  assert.equal(
    gradleFallbackVersion,
    projectVersion,
    "Android Gradle version fallback must match project.yml MARKETING_VERSION",
  );
  assert.match(
    artifactVerifier,
    /java\s+-jar\s+"\$bundletool"\s+dump\s+manifest\s+--bundle="\$artifact"\s+--xpath=\/manifest\/@android:versionName/u,
  );
  assert.match(
    artifactVerifier,
    /if\s+\[\[\s+"\$embedded_version"\s+!=\s+"\$version"\s+\]\];\s*then/u,
  );
  assert.match(artifactVerifier, /Android artifact version mismatch/u);
});

test("Apple DMG is fully verified before any release mutation", () => {
  const prepublication = job(
    appleAndroid,
    "apple-native-prepublication",
    "prepare-release-publication",
  );
  const preparation = job(
    appleAndroid,
    "prepare-release-publication",
    "domain-core-native-release-evidence",
  );
  assert.match(prepublication, /needs:[\s\S]*- smoke-test/u);
  assert.match(prepublication, /runs-on: macos-26/u);
  assert.match(
    prepublication,
    /verify-domain-core-native-release-artifact\.sh[\s\S]*apple "\$DMG_PATH"/u,
  );
  assert.doesNotMatch(prepublication, /gh release|--clobber/u);
  assert.match(preparation, /- apple-native-prepublication/u);
  assert.match(preparation, /release-publication-inputs/u);
  assert.match(preparation, /Retain exact general publication inputs/u);
  assert.match(
    preparation,
    /permissions:\n\s+actions: read\n\s+contents: read/u,
  );
  assert.doesNotMatch(
    preparation,
    /(?:contents|attestations|id-token): write/u,
  );
  assert.doesNotMatch(preparation, /gh release|--clobber/u);
});

test("failed-job reruns consume exact producer artifact names from attempt one", () => {
  const gate = job(
    appleAndroid,
    "domain-core-native-release-gate",
    "build-and-release",
  );
  const build = job(appleAndroid, "build-and-release", "smoke-test");
  const prepublication = job(
    appleAndroid,
    "apple-native-prepublication",
    "prepare-release-publication",
  );
  const preparation = job(
    appleAndroid,
    "prepare-release-publication",
    "domain-core-native-release-evidence",
  );
  const evidence = job(
    appleAndroid,
    "domain-core-native-release-evidence",
    "verify-live-update-feed",
  );
  const output = gate.match(/^\s+artifact_name: (.+)$/mu)?.[1];
  assert.ok(output);
  const attemptOne = renderArtifactName(output, {
    commit: "a".repeat(40),
    runId: 9001,
    runAttempt: 1,
  });
  const incorrectAttemptTwo = renderArtifactName(output, {
    commit: "a".repeat(40),
    runId: 9001,
    runAttempt: 2,
  });
  assert.notEqual(attemptOne, incorrectAttemptTwo);
  assert.match(
    build,
    /name: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.artifact_name \}\}/u,
  );
  assert.match(
    prepublication,
    /name: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.artifact_name \}\}/u,
  );
  for (const binding of [
    "domain-core-native-release-gate.outputs.artifact_name",
    "build-and-release.outputs.native_identity_artifact_name",
    "apple-native-prepublication.outputs.identity_artifact_name",
    "prepare-release-publication.outputs.publication_inputs_artifact_name",
  ]) {
    assert.match(
      evidence,
      new RegExp(
        `name: \\$\\{\\{ needs\\.${binding.replaceAll(".", "\\.")} \\}\\}`,
        "u",
      ),
    );
  }
  assert.doesNotMatch(
    evidence.slice(0, evidence.indexOf("Retain exact native release evidence")),
    /name: [^\n]*github\.run_attempt/u,
  );
  assert.match(preparation, /publication_inputs_artifact_name:/u);
  assert.equal(attemptOne.endsWith("-1"), true);
});

test("Apple and Android verifiers accept the same prerelease SemVer", () => {
  assert.match(artifactVerifier, /\(-\[0-9A-Za-z\]/u);
  assert.match(artifactVerifier, /invalid native release version/u);
  assert.doesNotMatch(artifactVerifier, /stable Android release version/u);
});

test("mounted shipped app executable itself emits the loaded Rust identity", () => {
  assert.match(
    artifactVerifier,
    /"\$executable" --domain-core-release-identity-report "\$observed_identity"/u,
  );
  assert.match(artifactVerifier, /verify_selected_identity "\$executable"/u);
  assert.match(artifactVerifier, /codesign -d --verbose=4 "\$artifact"/u);
  assert.match(artifactVerifier, /codesign -d --verbose=4 "\$app"/u);
  assert.doesNotMatch(
    artifactVerifier,
    /identity_probe|DOMAIN_CORE_SHIPPED_BINARY/u,
  );
  assert.match(appleApp, /runDomainCoreReleaseIdentityModeIfRequested\(\)/u);
  assert.match(appleApp, /Bundle\.main\.executableURL/u);
  assert.match(appleReporter, /domainCoreVersion\(\)/u);
  assert.match(appleReporter, /domainCoreAbiVersion\(\)/u);
  assert.match(appleReporter, /domainCoreSourceFingerprint\(\)/u);
  assert.match(appleReporter, /SHA256\.hash\(data: executableData\)/u);
  assert.match(
    appleReporter,
    /#if canImport\(CryptoKit\)[\s\S]*import CryptoKit[\s\S]*#elseif canImport\(Crypto\)[\s\S]*import Crypto[\s\S]*#error/u,
  );
});

test("all Apple and Android assets and v2 evidence publish through one draft state machine", () => {
  const publication = job(
    appleAndroid,
    "prepare-release-publication",
    "domain-core-native-release-evidence",
  );
  const evidence = job(
    appleAndroid,
    "domain-core-native-release-evidence",
    "verify-live-update-feed",
  );
  assert.match(evidence, /needs:[\s\S]*- prepare-release-publication/u);
  assert.doesNotMatch(evidence, /^    if: .*is_prerelease == 'false'/mu);
  assert.match(evidence, /verify-domain-core-native-release-artifact\.sh/u);
  assert.match(evidence, /create-domain-core-native-release-evidence\.mjs/gmu);
  assert.match(
    evidence,
    /predicate-type: https:\/\/openburnbar\.dev\/attestations\/domain-core-release-artifact\/v2/u,
  );
  assert.match(evidence, /hydrate-apple-android-release-evidence\.mjs/u);
  assert.match(evidence, /create-apple-android-release-publication\.mjs/u);
  assert.match(evidence, /publish-apple-android-release\.mjs/u);
  assert.match(evidence, /apple-final-reverify-identity\.json/u);
  assert.match(evidence, /domain-core-apple-prepublication-identity/u);
  assert.match(evidence, /android-universal-abi-manifest\.json/u);
  assert.match(evidence, /--android-abi-manifest/u);
  assert.match(
    evidence,
    /mkdir -p "\$RUNNER_TEMP\/domain-core-native-evidence"/u,
  );
  assert.match(evidence, /release_published != 'true'/u);
  assert.match(evidence, /--asset "\$asset"/u);
  assert.match(
    publication,
    /ROLLBACK_PATH=.*OpenBurnBar-\$\{VERSION\}-legacy-rollback\.zip/u,
  );
  assert.match(publication, /ASSETS=\("\$ZIP_PATH" "\$ROLLBACK_PATH"\)/u);
  assert.match(evidence, /environment: release/u);
  assert.doesNotMatch(evidence, /--clobber|14[- ]day|10,?000/iu);
  assert.doesNotMatch(evidence, /gh release (?:upload|create|edit|delete)/u);
});

test("release workflow has no replacement-capable asset mutation", () => {
  assert.doesNotMatch(appleAndroid, /--clobber/u);
  assert.doesNotMatch(
    appleAndroid,
    /gh release (?:upload|create|edit|delete)/u,
  );
  assert.match(appleAndroid, /publish-apple-android-release\.mjs/u);
  assert.match(
    appleAndroid,
    /group: release-\$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.tag \|\| github\.ref_name \}\}/u,
  );
  assert.match(appleAndroid, /VERSION_WITHOUT_BUILD="\$\{TAG_NAME%%\+\*\}"/u);
});

test("Windows signing and canonical evidence consume the exact gate", () => {
  const gate = job(windows, "domain-core-native-release-gate", "build-sign");
  const nativeEngine = job(
    windows,
    "native-engine",
    "authorize-domain-core-rollback",
  );
  const build = job(windows, "build-sign", "supply-chain");
  const supplyChain = job(
    windows,
    "supply-chain",
    "domain-core-windows-release-evidence",
  );
  const evidence = job(windows, "domain-core-windows-release-evidence");
  assert.match(
    gate,
    /resolve-domain-core-activation\.mjs[\s\S]*--release-commit "\$RELEASE_COMMIT"/u,
  );
  assert.match(gate, /CANDIDATE_COMMIT="\$\(jq -er '\.candidateCommit'/u);
  assert.match(
    gate,
    /prepare-domain-core-native-release-gate\.mjs[\s\S]*--candidate-commit "\$CANDIDATE_COMMIT"[\s\S]*--release-commit "\$RELEASE_COMMIT"[\s\S]*--activation "\$activation"/u,
  );
  assert.doesNotMatch(gate, /--candidate-commit "\$RELEASE_COMMIT"/u);
  assert.match(
    gate,
    /candidate_commit: \$\{\{ steps\.gate\.outputs\.candidate_commit \}\}/u,
  );
  assert.match(
    gate,
    /rust_active: \$\{\{ steps\.gate\.outputs\.rust_active \}\}/u,
  );
  assert.match(nativeEngine, /needs: domain-core-native-release-gate/u);
  assert.match(
    nativeEngine,
    /candidate_commit: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}/u,
  );
  assert.match(build, /- domain-core-native-release-gate/u);
  assert.match(
    build,
    /--expected-candidate-commit "\$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}"/u,
  );
  assert.match(
    build,
    /DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}/u,
  );
  assert.doesNotMatch(
    build,
    /(?:--expected-candidate-commit|DOMAIN_CORE_CANDIDATE_COMMIT:) [^\n]*needs\.resolve-release\.outputs\.release_commit/u,
  );
  assert.match(build, /Loaded_native_identity_is_observed_for_attestation/u);
  assert.match(build, /DOMAIN_CORE_NATIVE_LIBRARY_PATH/u);
  assert.match(build, /OpenBurnBar-\$\{env:VERSION\}-win-x64\.zip/u);
  assert.match(build, /--binary "\$nativeLibrary"/u);
  assert.match(evidence, /create-windows-domain-core-release-bundle\.py/u);
  assert.match(
    supplyChain,
    /expected_native_set="\$\([\s\S]*\.modes \| to_entries\[\][\s\S]*\.key == "quota" or \.key == "cloudVault"[\s\S]*\.value == "rust"[\s\S]*\| sort[\s\S]*\.schemaVersion == 2 and \.consumer == "windows" and \(\[\.domains\[\]\.domain\] \| sort\) == \$expected/u,
  );
  assert.match(
    supplyChain,
    /RUST_ACTIVE: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.rust_active \}\}/u,
  );
  assert.match(supplyChain, /protected_evidence=\(\)/u);
  assert.match(
    supplyChain,
    /if \[\[ "\$RUST_ACTIVE" == "true" \]\]; then[\s\S]*--protected-signer-run-id "\$SIGNER_RUN_ID"[\s\S]*fi/u,
  );
  assert.doesNotMatch(supplyChain, /\.domains \| length > 0/u);
  assert.match(evidence, /verify-domain-core-observed-identity\.mjs/u);
  assert.match(evidence, /create-domain-core-native-release-evidence\.mjs/u);
  assert.match(
    evidence,
    /--expected-candidate-commit "\$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}"/u,
  );
  assert.doesNotMatch(
    evidence,
    /--expected-candidate-commit "\$RELEASE_COMMIT"/u,
  );
  assert.match(
    evidence,
    /create-domain-core-native-release-evidence\.mjs[\s\S]*--commit "\$RELEASE_COMMIT"[\s\S]*--activation "\$RUNNER_TEMP\/domain-core-native-release-gate\/domain-core-activation\.json"/u,
  );
  assert.match(
    evidence,
    /RUST_ACTIVE: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.rust_active \}\}/u,
  );
  assert.match(evidence, /protected_evidence=\(\)/u);
  assert.match(evidence, /actions\/attest@[0-9a-f]{40}/u);
  assert.match(evidence, /publish-domain-core-release-evidence\.mjs/u);
  assert.match(evidence, /--phase prepare/u);
  assert.doesNotMatch(evidence, /--phase publish/u);
  assert.doesNotMatch(
    evidence,
    /(?:Stage deterministic attestation bundle names|Prepare exact stable Windows GitHub release|Publish create-only Windows evidence)\n\s+if:/u,
  );
  assert.doesNotMatch(evidence, /--clobber|14[- ]day|10,?000/iu);
});

test("Windows production engine builds embed their exact candidate commit", () => {
  const x64 = job(windowsEngine, "build", "build-arm64");
  const arm64 = job(windowsEngine, "build-arm64");
  for (const build of [x64, arm64]) {
    assert.match(
      build,
      /Build and stage production C ABI engine(?: \(ARM64\))?[\s\S]*env:[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ inputs\.candidate_commit \|\| github\.sha \}\}[\s\S]*cargo build --manifest-path crates\/openburnbar-domain-core\/Cargo\.toml -p openburnbar-domain-ffi --release/u,
    );
  }
  assert.equal(
    windowsEngine.match(
      /OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ inputs\.candidate_commit \|\| github\.sha \}\}/gu,
    )?.length,
    2,
  );
});

test("native evidence binds restored rollback profile bytes across raw and packaged workflows", () => {
  const appleAndroidEvidence = job(
    appleAndroid,
    "domain-core-native-release-evidence",
    "verify-live-update-feed",
  );
  const ios = job(iosEvidence, "attest-ios-domain-core");
  const windowsSupplyChain = job(
    windows,
    "supply-chain",
    "domain-core-windows-release-evidence",
  );
  const windowsEvidence = job(windows, "domain-core-windows-release-evidence");

  // Raw-profile workflows consume the exact verified gate rollback JSON
  // directly via --rollback-artifact and never unpack a legacy rollback
  // archive. The supply-chain job binds $gate_dir to the same gate directory
  // and references the rollback JSON through that variable, while the Apple
  // and Windows evidence jobs spell out the full $RUNNER_TEMP path.
  for (const rawProfileWorkflow of [
    appleAndroidEvidence,
    windowsSupplyChain,
    windowsEvidence,
  ]) {
    assert.match(
      rawProfileWorkflow,
      /--rollback-artifact "\$(?:RUNNER_TEMP\/domain-core-native-release-gate|gate_dir)\/source\/domain-core-public-production-rollback\.json"/u,
    );
    assert.doesNotMatch(rawProfileWorkflow, /--rollback-profile/u);
  }

  // iOS remains the only packaged rollback workflow: it downloads the legacy
  // rollback archive, extracts rollback_profile from it, and feeds both
  // --rollback-artifact and --rollback-profile to the evidence tool.
  for (const packagedWorkflow of [ios]) {
    assert.match(
      packagedWorkflow,
      /rollback_profile=.*domain-core-public-production-rollback\.json/u,
    );
    assert.match(
      packagedWorkflow,
      /--rollback-artifact "\$rollback"[\s\S]*--rollback-profile "\$rollback_profile"/u,
    );
  }
});
