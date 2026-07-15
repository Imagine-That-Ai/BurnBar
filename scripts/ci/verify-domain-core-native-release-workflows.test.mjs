import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const appleAndroid = readFileSync(
  new URL("../../.github/workflows/release.yml", import.meta.url),
  "utf8",
);
const windows = readFileSync(
  new URL(
    "../../.github/workflows/openburnbar-release-windows.yml",
    import.meta.url,
  ),
  "utf8",
);
const androidBuild = readFileSync(
  new URL("../../android/app/build.gradle.kts", import.meta.url),
  "utf8",
);
const artifactVerifier = readFileSync(
  new URL("./verify-domain-core-native-release-artifact.sh", import.meta.url),
  "utf8",
);
const appleReporter = readFileSync(
  new URL(
    "../../OpenBurnBarCore/Sources/OpenBurnBarCore/DomainCoreReleaseIdentityReporter.swift",
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
  assert.match(
    build,
    /--policy config\/apple-release-signing-policy\.json --environment/u,
  );
  assert.match(build, /--binary "\$packaged_library"/u);
  assert.match(build, /verify-domain-core-android-universal-artifact\.mjs/u);
  assert.match(build, /--candidate-aar Vendor\/openburnbar-domain-core\.aar/u);
  assert.match(build, /runs-on: macos-26[\s\S]*arch: arm64-v8a/u);
  assert.match(
    androidBuild,
    /keepDebugSymbols \+= "\*\*\/libopenburnbar_domain_ffi\.so"/u,
  );
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
  assert.doesNotMatch(preparation, /gh release|--clobber/u);
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
});

test("all Apple and Android assets and v2 evidence publish through one draft state machine", () => {
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
});

test("Windows signing and canonical evidence consume the exact gate", () => {
  const gate = job(windows, "domain-core-native-release-gate", "build-sign");
  const build = job(windows, "build-sign", "supply-chain");
  const evidence = job(windows, "domain-core-windows-release-evidence");
  assert.match(gate, /prepare-domain-core-native-release-gate\.mjs/u);
  assert.match(build, /- domain-core-native-release-gate/u);
  assert.match(build, /Loaded_native_identity_is_observed_for_attestation/u);
  assert.match(build, /DOMAIN_CORE_NATIVE_LIBRARY_PATH/u);
  assert.match(build, /OpenBurnBar-\$\{env:VERSION\}-win-x64\.zip/u);
  assert.match(build, /--binary "\$nativeLibrary"/u);
  assert.match(evidence, /create-windows-domain-core-release-bundle\.py/u);
  assert.match(evidence, /verify-domain-core-observed-identity\.mjs/u);
  assert.match(evidence, /create-domain-core-native-release-evidence\.mjs/u);
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
