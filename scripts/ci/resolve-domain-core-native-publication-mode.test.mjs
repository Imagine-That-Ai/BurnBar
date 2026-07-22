import assert from "node:assert/strict";
import test from "node:test";

import { resolveNativePublicationMode } from "./resolve-domain-core-native-publication-mode.mjs";

function manifest(consumer, domains) {
  const version = "1.2.3";
  return {
    schemaVersion: 1,
    consumer,
    artifactKind: consumer === "apple" ? "macos-dmg" : "android-aab",
    target: consumer === "apple" ? "macos-arm64" : "android-universal",
    artifact: {
      fileName:
        consumer === "apple"
          ? `OpenBurnBar-${version}-macOS.dmg`
          : `OpenBurnBar-${version}-Android.aab`,
      sha256: "a".repeat(64),
    },
    release: { version, tag: `v${version}`, commit: "b".repeat(40) },
    domains,
  };
}

const enabledDomain = {
  domain: "hermes",
  publicProfileSha256: "c".repeat(64),
  predicateFileName: "android-hermes.predicate.json",
  bundleFileName:
    "OpenBurnBar-1.2.3-Android-hermes-domain-core-attestation.sigstore.json",
};

test("all-legacy native manifests use generic release publication", () => {
  assert.equal(
    resolveNativePublicationMode(manifest("apple", []), "apple"),
    "legacy",
  );
  assert.equal(
    resolveNativePublicationMode(manifest("android", []), "android"),
    "legacy",
  );
});

test("Rust-authoritative manifests use immutable evidence publication", () => {
  assert.equal(
    resolveNativePublicationMode(
      manifest("android", [enabledDomain]),
      "android",
    ),
    "shared-rust",
  );
});

test("malformed or cross-consumer manifests fail closed", () => {
  assert.throws(
    () => resolveNativePublicationMode(manifest("android", []), "apple"),
    /consumer mismatch/,
  );
  assert.throws(
    () =>
      resolveNativePublicationMode(
        { ...manifest("apple", []), domains: "none" },
        "apple",
      ),
    /domains must be an array/,
  );
  assert.throws(
    () =>
      resolveNativePublicationMode(
        { ...manifest("apple", []), unexpected: true },
        "apple",
      ),
    /must contain exactly/,
  );
  assert.throws(
    () =>
      resolveNativePublicationMode(
        {
          ...manifest("android", []),
          artifact: { fileName: "substitute.aab", sha256: "a".repeat(64) },
        },
        "android",
      ),
    /artifact identity is invalid/,
  );
  assert.throws(
    () =>
      resolveNativePublicationMode(
        {
          ...manifest("android", [enabledDomain]),
          domains: [enabledDomain, enabledDomain],
        },
        "android",
      ),
    /identity is invalid/,
  );
});
