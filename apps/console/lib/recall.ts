import { applyCloudVaultDomainCore } from "./domainCoreCloudVault";
import type { CloudVaultAADContext } from "./escrow";
import { legacyEmbedAndCloakQuery } from "./legacy/pensieveVectorLegacy";
import { pensieveDeterministicEmbedAndCloak } from "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core.js";

const EMBEDDING_DIM = 384;
const EMBEDDING_MODEL_VERSION = "hashing-bow-v1";

// ── RR-8 path-bound AAD for sealed knowledge chunks ─────────────────────────
// Mirrors PensieveKnowledgeChunker in OpenBurnBarVectorKit: the device seals each
// chunk bound to `uid | cloud_search_knowledge | vectorId | field`, so a reader
// must rebuild the identical context or AES-GCM rejects the envelope. The doc id
// IS the chunk's vectorId (= its vault-keyed dedupHash).

/** Firestore collection sealed chunks land in: `users/{uid}/<this>/{vectorId}`. */
export const KNOWLEDGE_CHUNK_COLLECTION = "cloud_search_knowledge";
/** Field holding the sealed chunk text. */
export const KNOWLEDGE_CHUNK_CIPHERTEXT_FIELD = "sealedCiphertext";
/** Field holding the sealed chunk metadata blob. */
export const KNOWLEDGE_CHUNK_METADATA_FIELD = "sealedMetadata";

/**
 * Rebuild the AAD context the device sealed a knowledge chunk with. `purpose` is
 * set explicitly to `field`, matching Swift's `CloudVaultAADContext`, which
 * defaults `purpose` to the field name.
 *
 * Chunks sealed without a uid (the daemon queue writer has no auth session) are
 * schemaVersion-1 envelopes; `openText` ignores the AAD for those, so passing
 * this context is safe for both shapes.
 */
export function knowledgeChunkAADContext(
  uid: string,
  vectorId: string,
  field: string = KNOWLEDGE_CHUNK_CIPHERTEXT_FIELD,
): CloudVaultAADContext {
  return {
    uid,
    collection: KNOWLEDGE_CHUNK_COLLECTION,
    docID: vectorId,
    field,
    schemaVersion: 2,
    purpose: field,
  };
}

export async function embedAndCloakQuery(text: string, vaultKey: Uint8Array) {
  const queryVector = await applyCloudVaultDomainCore(
    "pensieve_deterministic_embed_and_cloak",
    () => legacyEmbedAndCloakQuery(text, vaultKey, EMBEDDING_DIM, EMBEDDING_MODEL_VERSION),
    () => Array.from(pensieveDeterministicEmbedAndCloak(
      text,
      EMBEDDING_DIM,
      true,
      vaultKey,
      EMBEDDING_MODEL_VERSION,
    )),
    (legacyValue, rustValue) =>
      legacyValue.length === rustValue.length &&
      legacyValue.every((value, index) => Math.abs(value - rustValue[index]) < 1e-12),
  );
  return { embeddingModelVersion: EMBEDDING_MODEL_VERSION, queryVector };
}
