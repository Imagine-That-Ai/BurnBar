/**
 * CROSS-LANGUAGE interop: proves lib/escrow.ts is wire-compatible with the Swift
 * CloudVaultCrypto. The fixture in test/interop/swift-fixture.json is produced by
 * test/interop/seal.swift (real CryptoKit). We:
 *   - import the Swift-emitted recipient private key (PKCS#8),
 *   - unwrap the Swift-wrapped vault key with it (Swift ECDH+HKDF -> JS),
 *   - prove the unwrapped key opens the Swift-sealed blob AND sealed text,
 *   - additionally open the Swift blob/text with the raw vault key (defence in depth).
 *
 * Skips gracefully if the fixture is absent (Swift unavailable in CI), so the
 * suite never fails for a missing toolchain — but when present this is the real
 * compatibility gate.
 */
import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  openBlob,
  openText,
  unwrapVaultKey,
  importVaultKey,
  base64ToBytes,
  type CloudVaultBlobEnvelope,
  type CloudVaultSealedText,
} from "../lib/escrow";

const fixturePath = resolve(__dirname, "interop/swift-fixture.json");
const hasFixture = existsSync(fixturePath);

interface Fixture {
  vaultKeyB64: string;
  blob: CloudVaultBlobEnvelope & { expectedPlaintext: string };
  text: CloudVaultSealedText & { expectedPlaintext: string };
  recipientPrivatePKCS8B64: string;
  recipientPublicX963B64: string;
  wrappedVaultKeyB64: string;
}

/** Import a PKCS#8 P-256 private key for ECDH deriveBits (matches our device key). */
async function importPkcs8Private(pkcs8: Uint8Array): Promise<CryptoKey> {
  const buf = new ArrayBuffer(pkcs8.byteLength);
  new Uint8Array(buf).set(pkcs8);
  return globalThis.crypto.subtle.importKey(
    "pkcs8",
    buf,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
}

describe.skipIf(!hasFixture)("Swift <-> JS escrow wire compatibility", () => {
  const fx: Fixture = hasFixture
    ? (JSON.parse(readFileSync(fixturePath, "utf8")) as Fixture)
    : (null as unknown as Fixture);

  it("unwraps a Swift-wrapped vault key and opens Swift-sealed blob + text", async () => {
    const recipientPriv = await importPkcs8Private(base64ToBytes(fx.recipientPrivatePKCS8B64));
    const vaultKey = await unwrapVaultKey(base64ToBytes(fx.wrappedVaultKeyB64), recipientPriv);

    // The unwrapped (Swift-wrapped) key must open Swift-sealed blob + text.
    const blob = await openBlob(fx.blob, vaultKey);
    expect(new TextDecoder().decode(blob)).toBe(fx.blob.expectedPlaintext);

    const text = await openText(fx.text, vaultKey);
    expect(text).toBe(fx.text.expectedPlaintext);
  });

  it("opens Swift-sealed content with the raw vault key directly", async () => {
    const vaultKey = await importVaultKey(base64ToBytes(fx.vaultKeyB64));
    expect(new TextDecoder().decode(await openBlob(fx.blob, vaultKey))).toBe(
      fx.blob.expectedPlaintext,
    );
    expect(await openText(fx.text, vaultKey)).toBe(fx.text.expectedPlaintext);
  });
});
