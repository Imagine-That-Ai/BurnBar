import { applyCloudVaultDomainCore } from "./domainCoreCloudVault";
import { legacyEmbedAndCloakQuery } from "./legacy/pensieveVectorLegacy";
import { pensieveDeterministicEmbedAndCloak } from "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core.js";

const EMBEDDING_DIM = 384;
const EMBEDDING_MODEL_VERSION = "hashing-bow-v1";

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
