import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  base64ToBytes,
  blobPlaintextHMAC,
  bytesToBase64,
  cloudVaultAADContext,
  importVaultKey,
  openBlob,
  sealBlob,
} from "../lib/escrow";
import {
  configureCloudVaultDomainCoreForTests,
  initializeCloudVaultDomainCoreForTests,
} from "../lib/domainCoreCloudVault";

interface DeterministicKat {
  aad: Array<{
    uid: string;
    collection: string;
    docID: string;
    field: string;
    schemaVersion: number;
    purpose: string;
    v2: string;
  }>;
  keyedHashes: Array<{
    purpose: string;
    keyHex: string;
    dataHex: string;
    hex: string;
  }>;
  aesGcm: Array<{
    keyHex: string;
    nonceHex: string;
    plaintextHex: string;
    aadHex: string;
    ciphertextHex: string;
    tagHex: string;
    combinedBase64: string;
  }>;
}

function fromHex(value: string): Uint8Array {
  return Uint8Array.from(Buffer.from(value, "hex"));
}

let fixture: DeterministicKat;

beforeAll(async () => {
  const wasmURL = new URL(
    "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core_bg.wasm",
    import.meta.url,
  );
  initializeCloudVaultDomainCoreForTests(await readFile(fileURLToPath(wasmURL)));

  const fixtureURL = new URL(
    "../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-deterministic-kat.json",
    import.meta.url,
  );
  fixture = JSON.parse(await readFile(fileURLToPath(fixtureURL), "utf8")) as DeterministicKat;
});

afterEach(() => {
  configureCloudVaultDomainCoreForTests(undefined);
  vi.restoreAllMocks();
});

describe("CloudVault domain-core browser adapter", () => {
  it("uses the canonical AAD KAT in rust mode", () => {
    configureCloudVaultDomainCoreForTests("rust", true);
    for (const vector of fixture.aad) {
      expect(
        cloudVaultAADContext({
          uid: vector.uid,
          collection: vector.collection,
          docID: vector.docID,
          field: vector.field,
          schemaVersion: vector.schemaVersion,
          purpose: vector.purpose,
        }),
      ).toBe(vector.v2);
    }
  });

  it("returns legacy output without mismatch telemetry in shadow mode", () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    configureCloudVaultDomainCoreForTests("shadow", true);

    expect(
      cloudVaultAADContext({
        uid: "user_alice",
        collection: "cloudSessions",
        docID: "doc_123",
        field: "title",
      }),
    ).toBe("OpenBurnBar-CloudVault-aad-v2|user_alice|cloudSessions|doc_123|title|2|title");
    expect(warning).not.toHaveBeenCalled();
  });

  it("does not evaluate WebCrypto HKDF in rust mode", async () => {
    const vector = fixture.keyedHashes.find(({ purpose }) => purpose === "blob-integrity");
    expect(vector).toBeDefined();
    configureCloudVaultDomainCoreForTests("rust", true);
    const legacyImport = vi.spyOn(globalThis.crypto.subtle, "importKey");

    const actual = await blobPlaintextHMAC(
      Uint8Array.from(Buffer.from(vector!.dataHex, "hex")),
      Uint8Array.from(Buffer.from(vector!.keyHex, "hex")),
    );

    expect(actual).toBe(vector!.hex);
    expect(legacyImport).not.toHaveBeenCalled();
  });

  it("uses canonical Base64 and rejects non-canonical input in rust mode", () => {
    configureCloudVaultDomainCoreForTests("rust", true);
    for (const vector of fixture.aesGcm) {
      expect(bytesToBase64(base64ToBytes(vector.combinedBase64))).toBe(vector.combinedBase64);
    }
    expect(() => base64ToBytes("AA==\n")).toThrow();
  });

  it("routes v2 AES through Wasm without exporting the browser CryptoKey", async () => {
    configureCloudVaultDomainCoreForTests("rust", true);
    const rawKey = fromHex(fixture.aesGcm[1]!.keyHex);
    const vaultKey = await importVaultKey(rawKey);
    const webEncrypt = vi.spyOn(globalThis.crypto.subtle, "encrypt");
    const webDecrypt = vi.spyOn(globalThis.crypto.subtle, "decrypt");

    const envelope = await sealBlob(new TextEncoder().encode("wasm custody proof"), vaultKey, {
      rawVaultKey: rawKey,
    });
    const plaintext = await openBlob(envelope, vaultKey, { rawVaultKey: rawKey });

    expect(new TextDecoder().decode(plaintext)).toBe("wasm custody proof");
    expect(webEncrypt).toHaveBeenCalledTimes(1);
    expect(webDecrypt).not.toHaveBeenCalled();
    expect(vaultKey.extractable).toBe(false);
  });

  it("rejects raw bytes that do not match the non-extractable browser key", async () => {
    configureCloudVaultDomainCoreForTests("rust", true);
    const rawKey = fromHex(fixture.aesGcm[1]!.keyHex);
    const vaultKey = await importVaultKey(rawKey);
    const wrongRawKey = rawKey.slice();
    wrongRawKey[0] ^= 1;

    await expect(
      sealBlob(new TextEncoder().encode("misbound"), vaultKey, { rawVaultKey: wrongRawKey }),
    ).rejects.toMatchObject({ code: "invalid_key_length" });
  });
});
