import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  blobPlaintextHMAC,
  cloudVaultAADContext,
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
});
