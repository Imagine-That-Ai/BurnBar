/**
 * Crypto unit tests for lib/escrow.ts — the browser half of BurnBar's zero-knowledge
 * model. We verify:
 *   1. AES-GCM blob round-trip (seal -> open) + hash binding.
 *   2. AES-GCM sealed-text round-trip with the Swift facet layout (nonce/ct/tag).
 *   3. ECDH agreement: two key pairs derive the SAME shared secret (the property
 *      the whole wrap/unwrap depends on).
 *   4. Vault-key wrap -> unwrap across two parties, proving the Swift wire layout
 *      (ephemeralPub.x963 ‖ nonce ‖ ciphertext ‖ tag) is honoured by HKDF-Escrow.
 *   5. Tamper detection (auth-tag / hash mismatches throw, never silently pass).
 *
 * Runs on Node's WebCrypto (globalThis.crypto.subtle) — no jsdom required for the
 * crypto itself; IndexedDB-backed key persistence is exercised separately under
 * the jsdom-ish path is skipped here (covered by build-time type checks).
 */
import { describe, it, expect } from "vitest";
import {
  sealBlob,
  openBlob,
  sealText,
  openText,
  wrapVaultKey,
  unwrapVaultKey,
  importVaultKey,
  bytesToBase64,
  base64ToBytes,
  EscrowError,
  AESGCM_ALGORITHM,
} from "../lib/escrow";

const subtle = globalThis.crypto.subtle;

function randomBytes(n: number): Uint8Array {
  return globalThis.crypto.getRandomValues(new Uint8Array(n));
}

/** Generate a P-256 key pair and export the public key as raw X9.63 (65 bytes). */
async function genP256() {
  const pair = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ]);
  const x963 = new Uint8Array(await subtle.exportKey("raw", pair.publicKey));
  return { pair, x963 };
}

describe("escrow base64 helpers", () => {
  it("round-trips arbitrary bytes", () => {
    const bytes = randomBytes(129);
    expect(base64ToBytes(bytesToBase64(bytes))).toEqual(bytes);
  });
});

describe("AES-256-GCM blob envelope", () => {
  it("seals and opens, preserving plaintext and hash", async () => {
    const key = await importVaultKey(randomBytes(32));
    const plaintext = new TextEncoder().encode("the basin holds your mercury");
    const env = await sealBlob(plaintext, key);

    expect(env.algorithm).toBe(AESGCM_ALGORITHM);
    expect(env.keyVersion).toBe(1);
    expect(env.plaintextSHA256).toHaveLength(64);

    const opened = await openBlob(env, key);
    expect(new TextDecoder().decode(opened)).toBe("the basin holds your mercury");
  });

  it("rejects a tampered ciphertext", async () => {
    const key = await importVaultKey(randomBytes(32));
    const env = await sealBlob(new TextEncoder().encode("seal me"), key);
    const raw = base64ToBytes(env.sealedBoxBase64);
    raw[raw.length - 1] ^= 0xff; // flip a tag byte
    env.sealedBoxBase64 = bytesToBase64(raw);
    await expect(openBlob(env, key)).rejects.toBeInstanceOf(EscrowError);
  });

  it("rejects a hash mismatch even with a valid tag", async () => {
    const key = await importVaultKey(randomBytes(32));
    const env = await sealBlob(new TextEncoder().encode("seal me"), key);
    env.plaintextSHA256 = "0".repeat(64);
    await expect(openBlob(env, key)).rejects.toMatchObject({ code: "hash_mismatch" });
  });

  it("fails to open with the wrong key", async () => {
    const key = await importVaultKey(randomBytes(32));
    const wrong = await importVaultKey(randomBytes(32));
    const env = await sealBlob(new TextEncoder().encode("secret"), key);
    await expect(openBlob(env, wrong)).rejects.toBeInstanceOf(EscrowError);
  });
});

describe("AES-256-GCM sealed text (Swift facet layout)", () => {
  it("seals to nonce/ciphertext/tag facets and opens", async () => {
    const key = await importVaultKey(randomBytes(32));
    const env = await sealText("conversation body", key);

    expect(env.algorithm).toBe(AESGCM_ALGORITHM);
    // Nonce is 12 bytes; tag is 16 bytes (matching CryptoKit AES.GCM).
    expect(base64ToBytes(env.nonce)).toHaveLength(12);
    expect(base64ToBytes(env.tag)).toHaveLength(16);

    expect(await openText(env, key)).toBe("conversation body");
  });

  it("rejects a tampered tag", async () => {
    const key = await importVaultKey(randomBytes(32));
    const env = await sealText("hi", key);
    const tag = base64ToBytes(env.tag);
    tag[0] ^= 0x01;
    env.tag = bytesToBase64(tag);
    await expect(openText(env, key)).rejects.toBeInstanceOf(EscrowError);
  });

  it("rejects an unsupported algorithm", async () => {
    const key = await importVaultKey(randomBytes(32));
    const env = await sealText("hi", key);
    env.algorithm = "ROT13";
    await expect(openText(env, key)).rejects.toBeInstanceOf(EscrowError);
  });
});

describe("P-256 ECDH agreement", () => {
  it("both parties derive the same shared secret", async () => {
    const a = await genP256();
    const b = await genP256();

    const aImportsB = await subtle.importKey(
      "raw",
      b.x963.buffer as ArrayBuffer,
      { name: "ECDH", namedCurve: "P-256" },
      false,
      [],
    );
    const bImportsA = await subtle.importKey(
      "raw",
      a.x963.buffer as ArrayBuffer,
      { name: "ECDH", namedCurve: "P-256" },
      false,
      [],
    );

    const ssA = new Uint8Array(
      await subtle.deriveBits({ name: "ECDH", public: aImportsB }, a.pair.privateKey, 256),
    );
    const ssB = new Uint8Array(
      await subtle.deriveBits({ name: "ECDH", public: bImportsA }, b.pair.privateKey, 256),
    );

    expect(ssA).toHaveLength(32); // P-256 X coordinate
    expect(ssA).toEqual(ssB);
  });
});

describe("vault-key wrap -> unwrap (Swift wire format)", () => {
  it("wraps to a recipient public key and unwraps with its private key", async () => {
    const recipient = await genP256();
    const vaultKeyRaw = randomBytes(32);

    const wrapped = await wrapVaultKey(vaultKeyRaw, recipient.x963);

    // Layout: ephemeralPub.x963 (65, leading 0x04) ‖ nonce(12) ‖ ct ‖ tag(16).
    expect(wrapped[0]).toBe(0x04);
    expect(wrapped.length).toBeGreaterThan(65 + 12 + 16);

    const vaultKey = await unwrapVaultKey(wrapped, recipient.pair.privateKey);

    // Prove the unwrapped key actually decrypts content the raw key sealed: we
    // can't export the non-extractable key, so seal with the unwrapped key and
    // open with a key imported from the original raw bytes.
    const fromRaw = await importVaultKey(vaultKeyRaw);
    const env = await sealBlob(new TextEncoder().encode("vaulted"), vaultKey);
    expect(new TextDecoder().decode(await openBlob(env, fromRaw))).toBe("vaulted");
  });

  it("rejects unwrapping with the wrong private key", async () => {
    const recipient = await genP256();
    const attacker = await genP256();
    const wrapped = await wrapVaultKey(randomBytes(32), recipient.x963);
    await expect(unwrapVaultKey(wrapped, attacker.pair.privateKey)).rejects.toBeInstanceOf(
      EscrowError,
    );
  });

  it("rejects a non-32-byte vault key", async () => {
    const recipient = await genP256();
    await expect(wrapVaultKey(randomBytes(31), recipient.x963)).rejects.toMatchObject({
      code: "invalid_key_length",
    });
  });

  it("rejects a too-short wrapped blob", async () => {
    const recipient = await genP256();
    await expect(unwrapVaultKey(randomBytes(40), recipient.pair.privateKey)).rejects.toBeInstanceOf(
      EscrowError,
    );
  });
});
