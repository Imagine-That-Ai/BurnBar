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
    /needs: \[release-preflight, authorize-domain-core-rollback, domain-core-native-release-gate\]/u,
  );
  assert.match(build, /resolve-domain-core-build-profile\.mjs/u);
  assert.match(build, /domain-core-android-observed-identity\.json/u);
  assert.match(build, /verify-domain-core-observed-identity\.mjs/u);
  assert.match(build, /OpenBurnBarDomainCoreIdentityProbe/u);
  assert.match(build, /domain-core-apple-signing-policy\.json/u);
  assert.match(build, /--binary "\$packaged_library"/u);
  assert.match(build, /runs-on: macos-26[\s\S]*arch: arm64-v8a/u);
  assert.match(
    androidBuild,
    /keepDebugSymbols \+= "\*\*\/libopenburnbar_domain_ffi\.so"/u,
  );
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
  assert.match(
    evidence,
    /verify-domain-core-apple-signing-identity\.mjs|verify-domain-core-native-release-artifact\.sh/u,
  );
  assert.match(evidence, /domain-core-apple-signing-policy\.json/u);
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
  assert.match(publish, /--phase publish/u);
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
