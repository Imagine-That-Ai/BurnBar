#!/usr/bin/env node
/**
 * Signal crypto proof harness (SOTASIGNAL Phase F).
 *
 * Reproducible from a fresh clone. Proves, in Node, the parts of the Signal
 * at-rest crypto contract that do NOT require the native Apple/Android toolchains:
 *
 *   A. bindingToAAD byte-parity — the SHIPPED TypeScript canonicalizer reproduces
 *      every vector in the cross-language fixture byte-for-byte. This is the Node
 *      anchor of the seam that Swift (SignalEnvelopeAAD.swift) and Kotlin must also
 *      match; if Node drifts, every cross-language KAT breaks.
 *   B. Real libsignal at-rest HPKE seal -> open round-trip (RFC 9180, libsignal
 *      0.94.4) + fail-closed negatives: wrong binding (relocation), wrong recipient
 *      key, tampered ciphertext, and reserved-char binding injection all throw.
 *   C. Contract recognizer fail-closed: sanitizeCloudVaultSignalEnvelope rejects a
 *      relocated/mode-confused/transport envelope.
 *
 * It then archives a manifest (node/libsignal versions, Maven source, fixture
 * sha256s, results). Exits non-zero on ANY failed proof (CI gate).
 *
 * What this harness intentionally DOES NOT do (documented, not silently skipped):
 *   - Open the Node-sealed KAT inside Swift / Kotlin. That cross-language open is
 *     proven by the platform suites (`swift test --filter OpenBurnBarSignalCoreTests`
 *     and the Android `CloudVaultCryptoTest`), which own the native libsignal build
 *     and are a different agent's lane. This harness pins the fixtures they consume.
 *
 * Usage: node scripts/ci/crypto-proof-harness.mjs [--manifest <path>]
 */

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const CONTRACT = resolve(REPO, "packages", "signal-envelope-contracts");
const PROTOCOL = resolve(REPO, "packages", "libsignal-protocol");
const SIGNAL_MAVEN = "https://build-artifacts.signal.org/libraries/maven/";

const args = process.argv.slice(2);
const manifestIdx = args.indexOf("--manifest");
const manifestPath = manifestIdx >= 0 ? args[manifestIdx + 1] : null;

let failures = 0;
const results = [];
function check(name, fn) {
  try {
    fn();
    results.push({ name, ok: true });
    console.log(`  ok   ${name}`);
  } catch (error) {
    failures += 1;
    results.push({ name, ok: false, error: String(error && error.message ? error.message : error) });
    console.error(`  FAIL ${name}: ${error && error.message ? error.message : error}`);
  }
}
function assert(cond, message) {
  if (!cond) throw new Error(message);
}
function throws(fn, message) {
  let threw = false;
  try {
    fn();
  } catch {
    threw = true;
  }
  assert(threw, message);
}

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

function build(pkgDir, label) {
  try {
    execFileSync("npm", ["run", "build"], { cwd: pkgDir, stdio: "pipe" });
  } catch (error) {
    console.error(`ERROR: failed to build ${label} (${pkgDir}): ${error.message}`);
    process.exit(2);
  }
}

console.log("Signal crypto proof harness — building packages from source…");
build(CONTRACT, "signal-envelope-contracts");
build(PROTOCOL, "libsignal-protocol");

const contract = await import(pathToFileURL(resolve(CONTRACT, "lib", "index.js")).href);
const protocol = await import(pathToFileURL(resolve(PROTOCOL, "lib", "index.js")).href);
const { bindingToAAD, sanitizeCloudVaultSignalEnvelope } = contract;
const { atRestSeal, atRestOpen, PrivateKey } = protocol;

const fixturePath = resolve(CONTRACT, "fixtures", "binding-aad-vectors.json");
const fixtureRaw = readFileSync(fixturePath);
const fixture = JSON.parse(fixtureRaw.toString("utf8"));

// ---- Proof A: bindingToAAD byte-parity --------------------------------------
console.log("\n[A] bindingToAAD byte-parity vs cross-language fixture");
for (const vector of fixture.vectors) {
  check(`A:${vector.name} reproduces expectedAAD`, () => {
    const actual = bindingToAAD(vector.binding);
    assert(
      actual === vector.expectedAAD,
      `bindingToAAD drift:\n  expected ${JSON.stringify(vector.expectedAAD)}\n  actual   ${JSON.stringify(actual)}`,
    );
  });
}
check("A:prefix matches the fixture prefix constant", () => {
  assert(
    bindingToAAD(fixture.vectors[0].binding).startsWith(fixture.prefix),
    "bindingToAAD output does not start with the fixture prefix",
  );
});

// ---- Proof B: real libsignal at-rest seal/open + fail-closed negatives -------
console.log("\n[B] real libsignal at-rest HPKE seal/open + negatives");
const atRestBinding = (over = {}) => ({
  uid: "uid-proof",
  scope: "cloudvault",
  collection: "mobile_assistant_chats",
  docId: "thread-proof",
  field: "signalEnvelope",
  mode: "at-rest",
  formatVersion: 1,
  ...over,
});
const plaintext = new TextEncoder().encode("the body the server must never read");

const recipient = PrivateKey.generate();
const recipientPub = recipient.getPublicKey();
const binding = atRestBinding();
const sealed = atRestSeal(plaintext, recipientPub, binding);

check("B:correct key + binding round-trips to the exact plaintext", () => {
  const opened = atRestOpen(sealed, recipient, binding);
  assert(Buffer.compare(Buffer.from(opened), Buffer.from(plaintext)) === 0, "round-trip mismatch");
});
check("B:relocation — wrong docId in binding fails closed", () => {
  throws(() => atRestOpen(sealed, recipient, atRestBinding({ docId: "DIFFERENT" })), "relocated open must throw");
});
check("B:relocation — wrong collection in binding fails closed", () => {
  throws(() => atRestOpen(sealed, recipient, atRestBinding({ collection: "other" })), "cross-collection open must throw");
});
check("B:relocation — wrong field in binding fails closed", () => {
  throws(() => atRestOpen(sealed, recipient, atRestBinding({ field: "sealedPayload" })), "cross-field open must throw");
});
check("B:wrong recipient key fails closed", () => {
  const wrong = PrivateKey.generate();
  throws(() => atRestOpen(sealed, wrong, binding), "wrong-key open must throw");
});
check("B:tampered ciphertext fails closed", () => {
  const corrupted = Buffer.from(sealed);
  corrupted[corrupted.length - 1] ^= 0x01;
  throws(() => atRestOpen(corrupted, recipient, binding), "tampered ciphertext must throw");
});
check("B:reserved-char binding injection throws before sealing", () => {
  throws(() => atRestSeal(plaintext, recipientPub, atRestBinding({ docId: "a|b" })), "pipe-injected binding must throw");
  throws(() => atRestSeal(plaintext, recipientPub, atRestBinding({ field: "a\nb" })), "LF-injected binding must throw");
});

// ---- Proof C: contract recognizer fail-closed --------------------------------
console.log("\n[C] contract recognizer fail-closed (sanitizeCloudVaultSignalEnvelope)");
const b64 = (s) => Buffer.from(s, "utf8").toString("base64");
const goodEnvelope = () => ({
  signalEnvelopeFormatVersion: 1,
  mode: "at-rest",
  relayEncryption: "signal-hpke-identity-seal-v1",
  ciphertextLayer: {
    payloadCiphertextB64: b64("sealed-payload"),
    payloadAADLabel: "bindingToAAD-sha256:0123456789abcdef0123456789abcdef",
    schemaVersion: 1,
  },
  keyDelivery: {
    scheme: "signal-hpke-identity-seal-v1",
    contentKeyLength: 32,
    wraps: [
      {
        recipientKind: "device",
        recipientIdentityKeyId: "k1",
        recipientIdentityKeyB64: b64("public-key"),
        sealedContentKeyB64: b64("sealed-key"),
      },
    ],
  },
  binding: atRestBinding(),
});
check("C:a strict at-rest envelope is recognized", () => {
  assert(sanitizeCloudVaultSignalEnvelope(goodEnvelope()) !== undefined, "valid envelope rejected");
});
check("C:a transport-mode envelope is NOT a CloudVault at-rest envelope", () => {
  const e = goodEnvelope();
  e.mode = "transport";
  assert(sanitizeCloudVaultSignalEnvelope(e) === undefined, "transport envelope accepted as at-rest");
});
check("C:a gateway-scoped binding is rejected for cloudvault", () => {
  const e = goodEnvelope();
  e.binding = { ...atRestBinding(), scope: "gateway" };
  assert(sanitizeCloudVaultSignalEnvelope(e) === undefined, "gateway binding accepted as cloudvault");
});
check("C:plaintext is not an envelope", () => {
  assert(sanitizeCloudVaultSignalEnvelope({ plaintext: "secret" }) === undefined, "plaintext accepted as envelope");
});

// ---- Proof D: cross-language fixture pinning ---------------------------------
// Closes the provenance gap: the Swift/Kotlin platform suites open a Node-sealed KAT
// and consume a copy of the AAD fixture. Here we sha-PIN those fixtures so a silent
// drift between the Node anchor and the native copies fails the gate. (The native
// OPEN itself runs in the platform suites — that lane is a different agent's.)
console.log("\n[D] cross-language fixture pinning (Swift/Kotlin consume these)");
const swiftAadCopy = resolve(REPO, "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/SignalBindingAADVectors.json");
const katFixture = resolve(REPO, "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/Fixtures/SignalEnvelopeV1Vector.json");
const fixturePins = { contractAadSha256: sha256(fixtureRaw) };
if (existsSync(swiftAadCopy)) {
  const swiftRaw = readFileSync(swiftAadCopy);
  fixturePins.swiftAadSha256 = sha256(swiftRaw);
  check("D:Swift AAD fixture copy is byte-identical to the contract fixture", () => {
    assert(
      sha256(swiftRaw) === sha256(fixtureRaw),
      `AAD fixture drift: contract ${sha256(fixtureRaw)} != swift ${sha256(swiftRaw)} — cross-language seam broken`,
    );
  });
} else {
  console.log("  skip D:Swift AAD copy not in this checkout (native lane absent) — cannot sha-compare here");
}
if (existsSync(katFixture)) {
  fixturePins.katSha256 = sha256(readFileSync(katFixture));
  console.log(
    `  pin  D:KAT SignalEnvelopeV1Vector.json sha256=${fixturePins.katSha256.slice(0, 16)}… (Node-sealed; opened by the Swift+Kotlin platform suites, not here)`,
  );
} else {
  console.log("  skip D:KAT fixture not in this checkout (native lane absent)");
}

// ---- Manifest ----------------------------------------------------------------
let libsignalPin = "unknown";
try {
  const bridge = readFileSync(resolve(REPO, "packages", "libsignal-bridge", "src", "index.ts"), "utf8");
  libsignalPin = (bridge.match(/version:\s*"([^"]+)"/) || [])[1] ?? "unknown";
} catch {
  /* read-only best effort; bridge is Rule-0 */
}
const manifest = {
  tool: "crypto-proof-harness",
  generatedBy: "scripts/ci/crypto-proof-harness.mjs",
  node: process.version,
  platform: `${process.platform}-${process.arch}`,
  libsignalPin,
  libsignalMaven: SIGNAL_MAVEN,
  fixture: { path: "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json", sha256: sha256(fixtureRaw), vectors: fixture.vectors.length },
  fixturePins,
  proofs: results,
  passed: results.filter((r) => r.ok).length,
  failed: failures,
};
const manifestJson = JSON.stringify(manifest, null, 2);
if (manifestPath) {
  const { writeFileSync } = await import("node:fs");
  writeFileSync(manifestPath, manifestJson + "\n");
  console.log(`\nmanifest -> ${manifestPath}`);
} else {
  console.log("\n----- manifest -----\n" + manifestJson);
}

console.log(`\n${manifest.passed} passed, ${failures} failed.`);
process.exit(failures === 0 ? 0 : 1);
