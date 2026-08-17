/**
 * Regression cover for the Pensieve Recall decrypt path (PensieveRecallCard).
 *
 * The console opens sealed knowledge chunks the device produced in
 * PensieveKnowledgeChunker.prepareBatch. With a uid present those chunks are
 * RR-8 path-bound: sealed with AAD `uid | cloud_search_knowledge | vectorId |
 * sealedCiphertext`. openText REQUIRES the caller to rebuild that context for
 * schemaVersion-2 envelopes, so recalling without one rejected every v2 chunk.
 *
 * These tests pin both halves of the contract:
 *   1. the AAD the console derives is byte-identical to the Swift one, and it is
 *      derived from the hit's own coordinates (uid + vectorId) — not read back
 *      off the envelope, which would prove nothing;
 *   2. the binding is real: a transplanted vectorId / field / uid is refused;
 *   3. legacy uid-less chunks (the daemon queue writer) still open through the
 *      exact same call shape the card uses.
 *
 * The Swift-fixture block is the cross-language gate; the local-seal block runs
 * everywhere so the regression stays covered without a Swift toolchain.
 */
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, it, expect } from "vitest";
import {
  cloudVaultAADContext,
  importVaultKey,
  openText,
  sealText,
  EscrowError,
  base64ToBytes,
  type CloudVaultSealedText,
} from "../lib/escrow";
import {
  KNOWLEDGE_CHUNK_CIPHERTEXT_FIELD,
  KNOWLEDGE_CHUNK_COLLECTION,
  KNOWLEDGE_CHUNK_METADATA_FIELD,
  knowledgeChunkAADContext,
} from "../lib/recall";
import { initializeCloudVaultDomainCoreForTests } from "../lib/domainCoreCloudVault";

beforeAll(() => {
  const wasmURL = new URL(
    "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core_bg.wasm",
    import.meta.url,
  );
  const manifestURL = new URL(
    "../../../crates/openburnbar-domain-core/union-abi-manifest.json",
    import.meta.url,
  );
  const expected = JSON.parse(readFileSync(fileURLToPath(manifestURL), "utf8")) as {
    coreVersion: string;
    abiVersion: number;
    sourceSha256: string;
  };
  initializeCloudVaultDomainCoreForTests(readFileSync(fileURLToPath(wasmURL)), expected);
});

const randomBytes = (n: number) => globalThis.crypto.getRandomValues(new Uint8Array(n));

/**
 * The decrypt step of PensieveRecallCard.runRecall, verbatim: one sealed hit +
 * the signed-in uid + the in-memory vault key.
 */
function openRecallHit(
  ciphertext: CloudVaultSealedText,
  vaultKey: CryptoKey,
  uid: string,
  vectorId: string,
  rawVaultKey: Uint8Array,
): Promise<string> {
  return openText(ciphertext, vaultKey, {
    aadContext: knowledgeChunkAADContext(uid, vectorId),
    rawVaultKey,
  });
}

describe("Pensieve recall AAD context", () => {
  it("mirrors the Swift chunker's collection, field, and purpose-defaults-to-field", () => {
    const context = knowledgeChunkAADContext("user-1", "vec-1");
    expect(context).toEqual({
      uid: "user-1",
      collection: "cloud_search_knowledge",
      docID: "vec-1",
      field: "sealedCiphertext",
      schemaVersion: 2,
      // CloudVaultAADContext(purpose: nil) resolves purpose to the field name.
      purpose: "sealedCiphertext",
    });
    expect(KNOWLEDGE_CHUNK_COLLECTION).toBe("cloud_search_knowledge");
    expect(KNOWLEDGE_CHUNK_CIPHERTEXT_FIELD).toBe("sealedCiphertext");
    expect(KNOWLEDGE_CHUNK_METADATA_FIELD).toBe("sealedMetadata");

    expect(cloudVaultAADContext(context)).toBe(
      "OpenBurnBar-CloudVault-aad-v2|user-1|cloud_search_knowledge|vec-1|sealedCiphertext|2|sealedCiphertext",
    );
  });

  it("addresses the metadata field separately from the ciphertext field", () => {
    expect(
      cloudVaultAADContext(
        knowledgeChunkAADContext("user-1", "vec-1", KNOWLEDGE_CHUNK_METADATA_FIELD),
      ),
    ).toBe(
      "OpenBurnBar-CloudVault-aad-v2|user-1|cloud_search_knowledge|vec-1|sealedMetadata|2|sealedMetadata",
    );
  });
});

describe("Pensieve recall decrypt path", () => {
  const uid = "console-user";
  const vectorId = "b7f1c3d5e90a4c2fa1806d4e5f2b39c8";
  const plaintext = "the vault key never leaves the device";

  async function sealChunk() {
    const raw = randomBytes(32);
    const key = await importVaultKey(raw);
    const sealed = await sealText(plaintext, key, {
      aadContext: knowledgeChunkAADContext(uid, vectorId),
      rawVaultKey: raw,
    });
    return { raw, key, sealed };
  }

  it("opens a path-bound v2 chunk the way the recall card does", async () => {
    const { raw, key, sealed } = await sealChunk();
    expect(sealed.schemaVersion).toBe(2);
    await expect(openRecallHit(sealed, key, uid, vectorId, raw)).resolves.toBe(plaintext);
  });

  it("REGRESSION: opening a v2 chunk with no AAD context throws", async () => {
    // This was the recall bug — options omitted, so expectedAAD was undefined and
    // every schemaVersion-2 chunk failed with invalid_envelope.
    const { key, sealed } = await sealChunk();
    await expect(openText(sealed, key)).rejects.toMatchObject({
      name: "EscrowError",
      code: "invalid_envelope",
    });
  });

  it("refuses a chunk transplanted to another vectorId, field, or account", async () => {
    const { raw, key, sealed } = await sealChunk();
    await expect(
      openRecallHit(sealed, key, uid, "a-different-vector-id", raw),
    ).rejects.toBeInstanceOf(EscrowError);
    await expect(openRecallHit(sealed, key, "another-uid", vectorId, raw)).rejects.toBeInstanceOf(
      EscrowError,
    );
    await expect(
      openText(sealed, key, {
        aadContext: knowledgeChunkAADContext(uid, vectorId, KNOWLEDGE_CHUNK_METADATA_FIELD),
        rawVaultKey: raw,
      }),
    ).rejects.toBeInstanceOf(EscrowError);
  });

  it("still opens a legacy uid-less chunk through the same call", async () => {
    // prepareBatch(uid: nil) — the daemon queue writer — emits a schemaVersion-1
    // envelope with no AAD. openText ignores the context for v1, so the card's
    // single code path must keep reading those.
    const raw = randomBytes(32);
    const key = await importVaultKey(raw);
    const legacy = await sealText(plaintext, key);
    expect(legacy.schemaVersion).toBeUndefined();
    expect(legacy.aad).toBeUndefined();
    await expect(openRecallHit(legacy, key, uid, vectorId, raw)).resolves.toBe(plaintext);
  });
});

// ── Cross-language gate: chunks sealed by real CryptoKit ────────────────────
const fixturePath = resolve(__dirname, "interop/swift-fixture.json");
const hasFixture = existsSync(fixturePath);

interface ChunkFixture {
  knowledgeChunk: CloudVaultSealedText & {
    uid: string;
    vectorId: string;
    field: string;
    expectedPlaintext: string;
  };
  legacyKnowledgeChunk: CloudVaultSealedText & {
    uid: string;
    vectorId: string;
    expectedPlaintext: string;
  };
  vaultKeyB64: string;
}

describe.skipIf(!hasFixture)("Swift-sealed knowledge chunks open in the console", () => {
  const fx: ChunkFixture = hasFixture
    ? (JSON.parse(readFileSync(fixturePath, "utf8")) as ChunkFixture)
    : (null as unknown as ChunkFixture);

  it("derives the same AAD Swift sealed the chunk with, from the hit's coordinates", () => {
    const chunk = fx.knowledgeChunk;
    expect(chunk.field).toBe(KNOWLEDGE_CHUNK_CIPHERTEXT_FIELD);
    // Built from uid + vectorId alone; matched against the AAD CryptoKit authenticated.
    expect(cloudVaultAADContext(knowledgeChunkAADContext(chunk.uid, chunk.vectorId))).toBe(
      chunk.aad,
    );
  });

  it("opens a Swift path-bound v2 chunk, and rejects it under a foreign vectorId", async () => {
    const chunk = fx.knowledgeChunk;
    const raw = base64ToBytes(fx.vaultKeyB64);
    const key = await importVaultKey(raw);

    await expect(openRecallHit(chunk, key, chunk.uid, chunk.vectorId, raw)).resolves.toBe(
      chunk.expectedPlaintext,
    );
    await expect(openText(chunk, key)).rejects.toBeInstanceOf(EscrowError);
    await expect(
      openRecallHit(chunk, key, chunk.uid, "b7f1c3d5e90a4c2fa1806d4e5f2b39c9", raw),
    ).rejects.toBeInstanceOf(EscrowError);
  });

  it("opens a Swift legacy uid-less chunk through the same call", async () => {
    const chunk = fx.legacyKnowledgeChunk;
    const raw = base64ToBytes(fx.vaultKeyB64);
    const key = await importVaultKey(raw);

    expect(chunk.schemaVersion).toBeUndefined();
    expect(chunk.aad).toBeUndefined();
    await expect(openRecallHit(chunk, key, chunk.uid, chunk.vectorId, raw)).resolves.toBe(
      chunk.expectedPlaintext,
    );
  });
});
