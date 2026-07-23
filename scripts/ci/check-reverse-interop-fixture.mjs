#!/usr/bin/env node
/**
 * Phase 2.5 — structural + byte-identity gate for the committed cross-device Signal fixtures.
 *
 * Covers two families:
 *   G1  the reverse-direction interop fixture (android-alice-to-swift-bob.json) — 4 copies
 *       (TS root, Kotlin, Swift, + the Windows KAT copy — VAL-P0-HARNESS-026),
 *       structurally validated (the Swift + Android suites decrypt it);
 *   G6  the transport-binding AAD vector (transport-binding-aad-vectors.json) — 2 copies that the
 *       harness [A2]/[D] + the Swift/Android parity tests consume.
 *
 * The native cross-language OPEN runs in the platform suites; this Linux leg pins every committed
 * copy present AND byte-identical so a silent drift OR a deleted copy fails CI (the harness [D]
 * sha-pins drift but skips on deletion — this closes that gap fail-closed). Exits non-zero on any
 * failure.
 */
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

let failures = 0;
const fail = (msg) => {
  console.error(`  FAIL ${msg}`);
  failures += 1;
};

/**
 * Require every listed copy to exist and be byte-identical. Returns the parsed first copy (for
 * downstream structural checks) or null if any copy is missing/divergent.
 */
function requireByteIdenticalCopies(label, copies) {
  const shas = new Set();
  let missing = false;
  for (const rel of copies) {
    const abs = resolve(REPO, rel);
    if (!existsSync(abs)) {
      fail(`${label}: missing committed copy ${rel}`);
      missing = true;
      continue;
    }
    shas.add(createHash("sha256").update(readFileSync(abs)).digest("hex"));
  }
  if (missing) return null;
  if (shas.size !== 1) {
    fail(`${label}: ${copies.length} copies are not byte-identical (sha256 set: ${[...shas].join(", ")})`);
    return null;
  }
  console.log(`  ok   ${label}: ${copies.length} byte-identical copies present`);
  return JSON.parse(readFileSync(resolve(REPO, copies[0]), "utf8"));
}

// ---- G1: reverse-direction interop fixture (4 copies + structure) -----------
const REVERSE_REQUIRED_KEYS = [
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
// Four byte-identical copies: the shared/TS root, the Kotlin (Android) test
// resource, the Swift (OpenBurnBarCore) test resource, and the Windows KAT copy
// (VAL-P0-HARNESS-026). The Windows libsignal-interop lane consumes the 4th copy;
// pinning byte-identity across ALL FOUR here keeps the Windows port's KAT from
// silently drifting from the three shipped platforms.
const reverse = requireByteIdenticalCopies("reverse interop fixture", [
  "tests/fixtures/signal-interop/android-alice-to-swift-bob.json",
  "android/app/src/test/resources/signal-interop/android-alice-to-swift-bob.json",
  "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/Fixtures/android-alice-to-swift-bob.json",
  "windows/tests/signal-interop/android-alice-to-swift-bob.json",
]);
if (reverse) {
  for (const key of REVERSE_REQUIRED_KEYS) {
    if (!(key in reverse)) fail(`reverse interop fixture missing key "${key}"`);
  }
  if (reverse.direction !== "android-alice-to-swift-bob") {
    fail(`reverse interop fixture direction must be "android-alice-to-swift-bob", got "${reverse.direction}"`);
  }
  if (reverse.schema !== "obb-signal-interop-v1") {
    fail(`reverse interop fixture schema must be "obb-signal-interop-v1", got "${reverse.schema}"`);
  }
  // 3 == CiphertextMessage.PREKEY_TYPE; both legs are PreKey-typed.
  if (reverse.ciphertextType !== 3) fail(`reverse interop fixture ciphertextType must be 3 (PreKey), got ${reverse.ciphertextType}`);
  if (reverse.secondCiphertextType !== 3) {
    fail(`reverse interop fixture secondCiphertextType must be 3 (PreKey), got ${reverse.secondCiphertextType}`);
  }
}

// ---- G6: transport-binding AAD vector (2 copies + shape) --------------------
const transport = requireByteIdenticalCopies("transport-binding AAD fixture", [
  "packages/signal-envelope-contracts/fixtures/transport-binding-aad-vectors.json",
  "OpenBurnBarCore/Tests/OpenBurnBarKernelCryptoTests/Fixtures/SignalTransportBindingAADVectors.json",
]);
if (transport) {
  if (transport.prefix !== "OpenBurnBar-Signal-AAD-v1|") {
    fail(`transport AAD fixture prefix must be "OpenBurnBar-Signal-AAD-v1|", got "${transport.prefix}"`);
  }
  if (!Array.isArray(transport.vectors) || transport.vectors.length < 4) {
    fail(`transport AAD fixture must carry >= 4 vectors, got ${transport.vectors?.length}`);
  } else {
    for (const v of transport.vectors) {
      if (v.binding?.mode !== "transport" || v.binding?.scope !== "gateway") {
        fail(`transport AAD vector "${v.name}" must be a transport/gateway binding`);
      }
      if (typeof v.expectedAAD !== "string" || !v.expectedAAD.startsWith(transport.prefix)) {
        fail(`transport AAD vector "${v.name}" expectedAAD missing/!prefixed`);
      }
    }
  }
}

if (failures > 0) {
  console.error(`cross-device fixture check: ${failures} failure(s).`);
  process.exit(1);
}
console.log("  ok   cross-device fixtures present, byte-identical across copies, and structurally valid");
