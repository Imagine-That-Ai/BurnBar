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
const appleProbe = readFileSync(
  new URL(
    "../../OpenBurnBarCore/Sources/OpenBurnBarDomainCoreIdentityProbe/main.swift",
    import.meta.url,
  ),
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
  assert.match(build, /OpenBurnBarDomainCoreIdentityProbe/u);
  assert.match(
    build,
    /--policy config\/apple-release-signing-policy\.json --environment/u,
  );
  assert.match(build, /--binary "\$packaged_library"/u);
  assert.match(build, /runs-on: macos-26[\s\S]*arch: arm64-v8a/u);
  assert.match(
    androidBuild,
    /keepDebugSymbols \+= "\*\*\/libopenburnbar_domain_ffi\.so"/u,
  );
});

test("Apple DMG is fully verified and uploaded create-only before public exposure", () => {
  const prepublication = job(
    appleAndroid,
    "apple-native-prepublication",
    "publish",
  );
  const publish = job(
    appleAndroid,
    "publish",
    "domain-core-native-release-evidence",
  );
  assert.match(prepublication, /needs:[\s\S]*- smoke-test/u);
  assert.match(prepublication, /runs-on: macos-26/u);
  assert.match(
    prepublication,
    /verify-domain-core-native-release-artifact\.sh[\s\S]*apple "\$DMG_PATH"/u,
  );
  assert.match(prepublication, /ensure-apple-domain-core-release\.mjs/u);
  assert.match(prepublication, /--phase preflight/u);
  assert.match(prepublication, /--phase publish/u);
  assert.match(prepublication, /expected-prerelease "\$PRERELEASE"/u);
  assert.doesNotMatch(prepublication, /--clobber/u);
  assert.match(publish, /- apple-native-prepublication/u);
  assert.doesNotMatch(publish, /gh release create/u);

  const verifyIndex = prepublication.indexOf(
    "verify-domain-core-native-release-artifact.sh",
  );
  const createIndex = prepublication.indexOf(
    "ensure-apple-domain-core-release.mjs",
  );
  const uploadIndex = prepublication.lastIndexOf("--phase publish");
  assert.ok(verifyIndex >= 0 && verifyIndex < createIndex);
  assert.ok(createIndex < uploadIndex);

  const uploadOtherAssetsIndex = publish.indexOf("gh release upload");
  const exposeIndex = publish.indexOf("gh release edit");
  assert.ok(
    uploadOtherAssetsIndex >= 0 && uploadOtherAssetsIndex < exposeIndex,
  );
});

test("Apple verifier accepts prerelease SemVer while Android remains stable-only", () => {
  assert.match(
    artifactVerifier,
    /consumer" == "apple"[\s\S]*\(-\[0-9A-Za-z\]/u,
  );
  assert.match(artifactVerifier, /invalid stable Android release version/u);
  assert.doesNotMatch(
    artifactVerifier,
    /android"[\s\S]{0,300}invalid Apple release version/u,
  );
});

test("mounted Apple probe exercises Rust but binds identity to the shipped app executable", () => {
  assert.match(artifactVerifier, /DOMAIN_CORE_SHIPPED_BINARY="\$executable"/u);
  assert.match(artifactVerifier, /verify_selected_identity "\$executable"/u);
  assert.match(artifactVerifier, /codesign -d --verbose=4 "\$artifact"/u);
  assert.match(artifactVerifier, /codesign -d --verbose=4 "\$app"/u);
  assert.match(artifactVerifier, /codesign -d --verbose=4 "\$identity_probe"/u);
  assert.match(appleProbe, /DOMAIN_CORE_SHIPPED_BINARY/u);
  assert.match(appleProbe, /domainCoreVersion\(\)/u);
  assert.match(appleProbe, /domainCoreAbiVersion\(\)/u);
  assert.match(appleProbe, /domainCoreSourceFingerprint\(\)/u);
  assert.doesNotMatch(appleProbe, /CommandLine\.arguments\[0\]/u);
});

test("stable Apple and Android evidence is v2, create-only, and byte-observed", () => {
  const evidence = job(
    appleAndroid,
    "domain-core-native-release-evidence",
    "verify-live-update-feed",
  );
  assert.match(evidence, /needs:[\s\S]*- publish/u);
  assert.match(evidence, /is_prerelease == 'false'/u);
  assert.match(evidence, /verify-domain-core-native-release-artifact\.sh/u);
  assert.match(evidence, /create-domain-core-native-release-evidence\.mjs/gmu);
  assert.match(
    evidence,
    /predicate-type: https:\/\/openburnbar\.dev\/attestations\/domain-core-release-artifact\/v2/u,
  );
  assert.match(evidence, /publish-domain-core-release-evidence\.mjs/u);
  assert.match(evidence, /apple-stable-reverify-identity\.json/u);
  assert.match(evidence, /domain-core-apple-prepublication-identity/u);
  assert.match(
    evidence,
    /mkdir -p "\$RUNNER_TEMP\/domain-core-native-evidence"/u,
  );
  assert.doesNotMatch(
    evidence,
    /Publish create-only (?:Apple|Android) evidence\n\s+if:/u,
  );
  assert.doesNotMatch(evidence, /--clobber|14[- ]day|10,?000/iu);
});

test("general macOS publisher never clobbers the canonical DMG", () => {
  const publish = job(
    appleAndroid,
    "publish",
    "domain-core-native-release-evidence",
  );
  assert.doesNotMatch(publish, /ASSETS=\("\$DMG_PATH"/u);
  assert.match(publish, /publish-create-only-release-asset\.mjs/u);
  assert.match(publish, /--phase preflight/u);
  assert.doesNotMatch(publish, /--phase publish/u);
  assert.doesNotMatch(publish, /gh release create/u);
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
