function operationSlices(groups: Readonly<Record<string, string>>): Readonly<Record<string, string>> {
  return Object.fromEntries(
    Object.entries(groups).flatMap(([slice, operations]) =>
      operations.split(" ").map((operation) => [operation, slice] as const),
    ),
  );
}

export const DOMAIN_CORE_SHADOW_OPERATION_SLICES: Readonly<Record<string, Readonly<Record<string, string>>>> = {
  quota: operationSlices({
    claude: "claude_quota",
    codex: "codex_quota",
    cursor: "cursor_quota",
    anthropic: "anthropic_quota",
  }),
  cloudvault: operationSlices({
    foundation:
      "aad_v1 aad_v2 resolve_aad sha256 sha256_hex vault_key_id blob_integrity session_body session_chunk project_memory_content blob_integrity_hash session_body_hash session_chunk_hash project_memory_content_hash keyed_hash_blob_integrity expected_session_body_hash expected_session_body_hash_v0 expected_session_body_hash_v1 expected_session_body_hash_v2 base64_encode base64_decode base64_decode_strict p256_validate_public_key initialize cloudvault_aad_v1 cloudvault_aad_v2 cloudvault_resolve_aad cloudvault_sha256 cloudvault_key_id cloudvault_keyed_hash cloudvault_base64_encode cloudvault_base64_decode cloudvault_validate_p256_public_key",
    aes: "aes_gcm_seal_detached aes_gcm_seal_combined aes_gcm_open_detached aes_gcm_open_text_detached aes_gcm_open_combined aes_seal_detached aes_seal_combined aes_open_detached aes_open_text aes_open_combined cloudvault_aes_seal_detached cloudvault_aes_seal_combined cloudvault_aes_open_detached cloudvault_aes_open_text cloudvault_aes_open_combined",
    recovery:
      "recovery_normalize recovery_wrapping_key recovery_verification_hash recovery_wrap_vault_key recovery_open_vault_key cloudvault_recovery_wrapping_key cloudvault_recovery_verification_hash cloudvault_recovery_wrap_vault_key cloudvault_recovery_open_vault_key",
    escrow:
      "escrow_wrapping_key escrow_assemble_wire escrow_split_wire escrow_seal escrow_open cloudvault_escrow_split_wire cloudvault_escrow_seal cloudvault_escrow_open",
    "document-rewrap": "document_rewrap",
    search: "token index query semantic",
    "opaque-identifiers":
      "project_memory_doc_id pensieve_dedup_hash pensieve_provenance_hash pensieve_slug_hmac subscription_doc_id",
    "pensieve-vectors":
      "pensieve_l2_normalize pensieve_vector_cloak pensieve_deterministic_embed pensieve_deterministic_embed_and_cloak",
  }),
  hermes: operationSlices({
    aad: "aad",
    "payload-keywrap": "key_wrap_info_v1 key_wrap_info_v2 seal open seal_combined open_combined safety_code hkdf",
    "hpke-info": "hpke_v3_info",
    ratchet: "ratchet_aad ratchet_root_kdf ratchet_chain_kdf ratchet_message_kdf ratchet_seal ratchet_open",
  }),
  pricing: operationSlices({
    "token-cost": "calculate_token_cost",
    "legacy-kimi": "price_legacy_kimi",
  }),
};

const DOMAIN_CORE_SHADOW_REQUIRED_COVERAGE: Readonly<Record<string, Readonly<Record<string, readonly string[]>>>> = {
  quota: {
    claude: ["apple", "windows"],
    codex: ["apple", "windows"],
    cursor: ["apple", "windows"],
    anthropic: ["apple", "windows"],
  },
  cloudvault: {
    foundation: ["apple", "android", "windows", "console", "local-mcp", "remote-mcp"],
    aes: ["apple", "android", "windows", "console", "local-mcp", "remote-mcp"],
    recovery: ["apple", "android", "windows"],
    escrow: ["apple", "android", "windows", "console"],
    "document-rewrap": ["apple", "android"],
    search: ["apple", "android", "local-mcp", "remote-mcp"],
    "opaque-identifiers": ["apple", "android", "windows", "local-mcp", "remote-mcp"],
    "pensieve-vectors": ["apple", "windows", "console", "remote-mcp"],
  },
  hermes: {
    aad: ["apple", "android"],
    "payload-keywrap": ["apple", "android"],
    "hpke-info": ["apple", "android"],
    ratchet: ["apple", "android"],
  },
  pricing: {
    "token-cost": ["apple", "functions"],
    "legacy-kimi": ["functions"],
  },
};

const DOMAIN_CORE_SHADOW_OPERATION_CONSUMERS: Readonly<Record<string, Readonly<Record<string, readonly string[]>>>> = {
  cloudvault: {
    project_memory_doc_id: ["apple", "local-mcp"],
    pensieve_dedup_hash: ["apple", "windows", "remote-mcp"],
    pensieve_provenance_hash: ["remote-mcp"],
    pensieve_slug_hmac: ["apple", "windows", "remote-mcp"],
    subscription_doc_id: ["apple", "android"],
    pensieve_l2_normalize: ["apple"],
  },
};

export function domainCoreShadowOperationConsumers(
  domain: string,
  slice: string,
  operation: string,
): readonly string[] {
  return (
    DOMAIN_CORE_SHADOW_OPERATION_CONSUMERS[domain]?.[operation] ??
    DOMAIN_CORE_SHADOW_REQUIRED_COVERAGE[domain]?.[slice] ??
    []
  );
}
