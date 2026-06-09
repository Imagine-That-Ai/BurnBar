#!/usr/bin/env node
/**
 * generate-cryptokit-interop-vector.mjs — the committed cross-implementation
 * at-rest seal proof (ADR-001 §7.2).
 *
 * The claim "iPhone reads the same sealed envelopes through Apple's CryptoKit,
 * interoperable with the Signal library's seal" must be locked by a COMMITTED
 * vector exercised in BOTH directions by two independent implementations:
 *
 *   case 1: official libsignal (Node @signalapp/libsignal-client,
 *           PublicKey.seal — Rust core) seals → CryptoKit opens
 *   case 2: Apple CryptoKit (HPKE.Sender via scripts/ci/cryptokit-hpke-cli.swift,
 *           zero libsignal) seals → libsignal opens
 *
 * Fixture: OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/Fixtures/
 * CryptoKitAtRestInteropVector.json — opened by BOTH implementations in CI:
 *   * this script's default CHECK mode (Node libsignal opens both cases +
 *     tamper fails closed) runs in fast-feedback on Linux;
 *   * CryptoKitAtRestInteropTests.swift opens both cases (CryptoKit side)
 *     in the macOS PR harness.
 *
 * Modes:
 *   node scripts/ci/generate-cryptokit-interop-vector.mjs            # check (CI)
 *   node scripts/ci/generate-cryptokit-interop-vector.mjs --emit     # regenerate (macOS;
 *     needs `swift` + CryptoKit; re-verifies both directions live before writing)
 *
 * The recipient private key is a fixed, clamped, PUBLICLY COMMITTED test key
 * (derived from a label hash) — test material only, never a real key. Sealed
 * bytes are not deterministic (HPKE uses ephemeral keys), so --emit rewrites
 * them; check mode never regenerates, it verifies the committed bytes.
 */

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..", "..");
const FIXTURE = join(
  ROOT,
  "OpenBurnBarCore",
  "Tests",
  "OpenBurnBarSignalCoreTests",
  "Fixtures",
  "CryptoKitAtRestInteropVector.json"
);
const SWIFT_CLI = join(HERE, "cryptokit-hpke-cli.swift");

const require = createRequire(pathToFileURL(join(ROOT, "packages", "libsignal-bridge", "package.json")));
const libsignal = require("@signalapp/libsignal-client");

const INFO = Buffer.from("OpenBurnBar-AtRest-Interop-KAT-v1", "utf8");
const AAD = Buffer.from("binding|interop-kat|cryptokit-libsignal", "utf8");

const CASE_LIBSIGNAL_SEALS = "libsignal-seals-cryptokit-opens";
const CASE_CRYPTOKIT_SEALS = "cryptokit-seals-libsignal-opens";

function fail(message) {
  console.error(`[cryptokit-interop] FAIL: ${message}`);
  process.exit(1);
}

function fixedRecipientKey() {
  // Deterministic, clamped X25519 test key — committed on purpose (KAT key).
  const seed = createHash("sha256")
    .update("OpenBurnBar CryptoKit-AtRest interop vector v1 recipient test key")
    .digest();
  seed[0] &= 248;
  seed[31] &= 127;
  seed[31] |= 64;
  return libsignal.PrivateKey.deserialize(seed);
}

function swiftCli(request) {
  const result = spawnSync("swift", [SWIFT_CLI], {
    input: JSON.stringify(request),
    encoding: "utf8",
    timeout: 120_000
  });
  if (result.error) fail(`could not run swift: ${result.error.message}`);
  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    fail(`swift CLI emitted non-JSON (status ${result.status}): ${result.stdout} ${result.stderr}`);
  }
  if (result.status !== 0 || parsed.error) fail(`swift CLI: ${parsed.error ?? result.stderr}`);
  return parsed;
}

function nodeOpen(priv, sealedB64) {
  return priv.open(Buffer.from(sealedB64, "base64"), INFO, AAD);
}

// ---------------------------------------------------------------------------

const priv = fixedRecipientKey();
const pub = priv.getPublicKey();
const pubRaw = Buffer.from(pub.serialize()).subarray(1); // strip the 0x05 type byte → 32 raw bytes

if (process.argv.includes("--emit")) {
  const plaintextA = Buffer.from(
    "OpenBurnBar at-rest interop KAT: sealed by official libsignal, opened by Apple CryptoKit.",
    "utf8"
  );
  const plaintextB = Buffer.from(
    "OpenBurnBar at-rest interop KAT: sealed by Apple CryptoKit, opened by official libsignal.",
    "utf8"
  );

  // case 1: libsignal seals …
  const sealedA = pub.seal(plaintextA, INFO, AAD);
  if (sealedA[0] !== 0x01) fail(`unexpected libsignal seal type byte 0x${sealedA[0].toString(16)}`);
  // … CryptoKit opens (live cross-implementation proof, direction 1).
  const ckOpened = swiftCli({
    mode: "open",
    recipientPrivRawB64: Buffer.from(priv.serialize()).toString("base64"),
    sealedB64: Buffer.from(sealedA).toString("base64"),
    infoB64: INFO.toString("base64"),
    aadB64: AAD.toString("base64")
  });
  if (Buffer.from(ckOpened.plaintextB64, "base64").compare(plaintextA) !== 0) {
    fail("CryptoKit opened the libsignal seal to DIFFERENT plaintext");
  }
  console.log("[cryptokit-interop] live proof 1/2: libsignal sealed → CryptoKit opened ✓");

  // case 2: CryptoKit seals …
  const ckSealed = swiftCli({
    mode: "seal",
    recipientPubRawB64: pubRaw.toString("base64"),
    plaintextB64: plaintextB.toString("base64"),
    infoB64: INFO.toString("base64"),
    aadB64: AAD.toString("base64")
  });
  // … libsignal opens (live cross-implementation proof, direction 2).
  const lsOpened = nodeOpen(priv, ckSealed.sealedB64);
  if (Buffer.from(lsOpened).compare(plaintextB) !== 0) {
    fail("libsignal opened the CryptoKit seal to DIFFERENT plaintext");
  }
  console.log("[cryptokit-interop] live proof 2/2: CryptoKit sealed → libsignal opened ✓");

  const vector = {
    name: "CryptoKitAtRestInteropVector",
    version: 1,
    description:
      "Committed cross-implementation at-rest seal vectors (ADR-001 §7.2): official libsignal " +
      "(Rust core via Node bindings) and Apple CryptoKit must open each other's seals. " +
      "Suite: HPKE Base mode, X25519-HKDF-SHA256 / HKDF-SHA256 / AES-256-GCM " +
      "(libsignal Base_X25519_HkdfSha256_Aes256Gcm == CryptoKit Curve25519_HKDF_SHA256 + AES_GCM_256). " +
      "Framing: 0x01 type byte || 32-byte X25519 encapsulated key || AES-256-GCM ciphertext. " +
      "The recipient private key is a fixed PUBLIC test key (KAT material only).",
    recipientPrivateKeyB64: Buffer.from(priv.serialize()).toString("base64"),
    recipientPublicKeyB64: Buffer.from(pub.serialize()).toString("base64"),
    infoB64: INFO.toString("base64"),
    aadB64: AAD.toString("base64"),
    cases: [
      {
        id: CASE_LIBSIGNAL_SEALS,
        sealer: "official libsignal v0.94.4 (@signalapp/libsignal-client PublicKey.seal)",
        opener: "Apple CryptoKit HPKE.Recipient (CryptoKitAtRestInteropTests.swift) + libsignal (this script)",
        plaintextB64: plaintextA.toString("base64"),
        sealedB64: Buffer.from(sealedA).toString("base64")
      },
      {
        id: CASE_CRYPTOKIT_SEALS,
        sealer: "Apple CryptoKit HPKE.Sender (scripts/ci/cryptokit-hpke-cli.swift, zero libsignal)",
        opener: "official libsignal PrivateKey.open (this script + CryptoKitAtRestInteropTests.swift)",
        plaintextB64: plaintextB.toString("base64"),
        sealedB64: ckSealed.sealedB64
      }
    ],
    provenance: {
      generator: "scripts/ci/generate-cryptokit-interop-vector.mjs --emit",
      verifiedAtEmit: [
        "libsignal sealed case 1; pure CryptoKit opened it (live)",
        "pure CryptoKit sealed case 2; libsignal opened it (live)"
      ]
    }
  };
  writeFileSync(FIXTURE, `${JSON.stringify(vector, null, 2)}\n`);
  console.log(`[cryptokit-interop] wrote ${FIXTURE}`);
}

// ---------------------------------------------------------------------------
// CHECK mode (always runs; CI entry point — pure Node, no Swift required):
// official libsignal must open BOTH committed cases byte-for-byte, and a
// tampered ciphertext must fail closed.
// ---------------------------------------------------------------------------

let vectorRaw;
try {
  vectorRaw = readFileSync(FIXTURE, "utf8");
} catch {
  fail(`missing committed vector ${FIXTURE} — run with --emit on macOS`);
}
const vector = JSON.parse(vectorRaw);
if (vector.version !== 1) fail(`unexpected vector version ${vector.version}`);
if (vector.recipientPrivateKeyB64 !== Buffer.from(priv.serialize()).toString("base64")) {
  fail("committed recipient key drifted from the fixed KAT derivation");
}
const ids = vector.cases.map((c) => c.id).sort();
if (JSON.stringify(ids) !== JSON.stringify([CASE_CRYPTOKIT_SEALS, CASE_LIBSIGNAL_SEALS].sort())) {
  fail(`vector cases drifted: ${ids.join(", ")}`);
}

for (const testCase of vector.cases) {
  const opened = nodeOpen(priv, testCase.sealedB64);
  const expected = Buffer.from(testCase.plaintextB64, "base64");
  if (Buffer.from(opened).compare(expected) !== 0) {
    fail(`libsignal opened ${testCase.id} to different plaintext`);
  }
  console.log(`[cryptokit-interop] libsignal opens committed ${testCase.id} ✓`);

  const tampered = Buffer.from(testCase.sealedB64, "base64");
  tampered[tampered.length - 1] ^= 0x01;
  let threw = false;
  try {
    priv.open(tampered, INFO, AAD);
  } catch {
    threw = true;
  }
  if (!threw) fail(`tampered ${testCase.id} did NOT fail closed`);
  console.log(`[cryptokit-interop] tampered ${testCase.id} fails closed ✓`);
}

console.log(
  "[cryptokit-interop] PASS: committed cross-implementation at-rest vectors verified " +
    "(libsignal side; the CryptoKit side runs in CryptoKitAtRestInteropTests.swift)."
);
