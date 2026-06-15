#!/usr/bin/env node
/**
 * Phase 2.5 G1 — structural + byte-identity gate for the reverse-direction cross-language Signal
 * interop fixture (android-alice-to-swift-bob.json).
 *
 * The native cross-language OPEN runs in the platform suites (Swift `OBBSignalInteropKatTests`
 * decrypts the Android-produced bytes; Android `AndroidSignalReverseInteropKatTest` guards it).
 * This Linux leg pins the three committed copies byte-identical and structurally valid so a silent
 * drift or a partial re-emit fails CI before it can break either native lane. Exits non-zero on any
 * failure.
 */
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const copies = [
  "tests/fixtures/signal-interop/android-alice-to-swift-bob.json",
  "android/app/src/test/resources/signal-interop/android-alice-to-swift-bob.json",
  "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/Fixtures/android-alice-to-swift-bob.json",
];

const REQUIRED_KEYS = [
  "schema",
  "direction",
  "aliceAddressName",
  "bobAddressName",
  "deviceId",
  "bobRegistrationId",
  "bobIdentityKeyPairB64",
  "bobPreKeyId",
  "bobPreKeyRecordB64",
  "bobSignedPreKeyId",
  "bobSignedPreKeyRecordB64",
  "bobKyberPreKeyId",
  "bobKyberPreKeyRecordB64",
  "ciphertextType",
  "ciphertextB64",
  "expectedPlaintext",
  "secondCiphertextType",
  "secondCiphertextB64",
  "secondExpectedPlaintext",
];

let failures = 0;
const fail = (msg) => {
  console.error(`  FAIL ${msg}`);
  failures += 1;
};

const shas = new Set();
for (const rel of copies) {
  const abs = resolve(REPO, rel);
  if (!existsSync(abs)) {
    fail(`missing reverse interop fixture copy: ${rel}`);
    continue;
  }
  shas.add(createHash("sha256").update(readFileSync(abs)).digest("hex"));
}
if (failures === 0 && shas.size !== 1) {
  fail(`reverse interop fixture copies are not byte-identical (sha256 set: ${[...shas].join(", ")})`);
}

if (failures === 0) {
  const fixture = JSON.parse(readFileSync(resolve(REPO, copies[0]), "utf8"));
  for (const key of REQUIRED_KEYS) {
    if (!(key in fixture)) fail(`reverse interop fixture missing key "${key}"`);
  }
  if (fixture.direction !== "android-alice-to-swift-bob") {
    fail(`reverse interop fixture direction must be "android-alice-to-swift-bob", got "${fixture.direction}"`);
  }
  if (fixture.schema !== "obb-signal-interop-v1") {
    fail(`reverse interop fixture schema must be "obb-signal-interop-v1", got "${fixture.schema}"`);
  }
  // 3 == PreKey message type (CiphertextMessage.PREKEY_TYPE); both legs are PreKey-typed.
  if (fixture.ciphertextType !== 3) fail(`reverse interop fixture ciphertextType must be 3 (PreKey), got ${fixture.ciphertextType}`);
  if (fixture.secondCiphertextType !== 3) {
    fail(`reverse interop fixture secondCiphertextType must be 3 (PreKey), got ${fixture.secondCiphertextType}`);
  }
}

if (failures > 0) {
  console.error(`reverse interop fixture check: ${failures} failure(s).`);
  process.exit(1);
}
console.log(`  ok   reverse interop fixture present in ${copies.length} byte-identical copies with all ${REQUIRED_KEYS.length} keys`);
