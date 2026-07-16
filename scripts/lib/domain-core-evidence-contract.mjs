export const DOMAIN_CORE_EVIDENCE_SCHEMA_VERSION = 2;

export const DOMAIN_CORE_REQUIRED_COVERAGE = Object.freeze({
  quota: Object.freeze({
    claude: Object.freeze(["apple", "windows"]),
    codex: Object.freeze(["apple", "windows"]),
    cursor: Object.freeze(["apple", "windows"]),
    anthropic: Object.freeze(["apple", "windows"]),
  }),
  cloudvault: Object.freeze({
    foundation: Object.freeze([
      "apple",
      "android",
      "windows",
      "console",
      "remote-mcp",
      "local-mcp",
    ]),
    aes: Object.freeze([
      "apple",
      "android",
      "windows",
      "console",
      "remote-mcp",
      "local-mcp",
    ]),
    recovery: Object.freeze(["apple", "android", "windows"]),
    escrow: Object.freeze(["apple", "android", "windows", "console"]),
    "document-rewrap": Object.freeze(["apple", "android"]),
    search: Object.freeze(["apple", "android", "remote-mcp", "local-mcp"]),
    "opaque-identifiers": Object.freeze([
      "apple",
      "android",
      "remote-mcp",
      "local-mcp",
    ]),
    "pensieve-vectors": Object.freeze([
      "apple",
      "windows",
      "console",
      "remote-mcp",
    ]),
  }),
  hermes: Object.freeze({
    aad: Object.freeze(["apple", "android"]),
    "payload-keywrap": Object.freeze(["apple", "android"]),
    "hpke-info": Object.freeze(["apple", "android"]),
    ratchet: Object.freeze(["apple", "android", "hermes-python"]),
  }),
  pricing: Object.freeze({
    "token-cost": Object.freeze(["apple", "functions"]),
    "legacy-kimi": Object.freeze(["functions"]),
  }),
});

export const DOMAIN_CORE_OPERATION_CONSUMERS = Object.freeze({
  cloudvault: Object.freeze({
    project_memory_doc_id: Object.freeze(["apple", "local-mcp"]),
    pensieve_dedup_hash: Object.freeze(["apple", "remote-mcp"]),
    pensieve_provenance_hash: Object.freeze(["remote-mcp"]),
    pensieve_slug_hmac: Object.freeze(["apple", "remote-mcp"]),
    subscription_doc_id: Object.freeze(["apple", "android"]),
    pensieve_l2_normalize: Object.freeze(["apple"]),
  }),
});

export const DOMAIN_CORE_QUOTA_OPERATION_SLICE = Object.freeze({
  claude_quota: "claude",
  codex_quota: "codex",
  cursor_quota: "cursor",
  anthropic_quota: "anthropic",
});

export function coverageKey(slice, consumer) {
  return `${slice}:${consumer}`;
}

export function requiredCoverageForDomain(domain) {
  const slices = DOMAIN_CORE_REQUIRED_COVERAGE[domain];
  if (!slices) return [];
  return Object.entries(slices).flatMap(([slice, consumers]) =>
    consumers.map((consumer) => ({ slice, consumer })),
  );
}

export function isValidDomainSliceConsumer(domain, slice, consumer) {
  return (
    DOMAIN_CORE_REQUIRED_COVERAGE[domain]?.[slice]?.includes(consumer) === true
  );
}

export function isValidDomainSliceOperationConsumer(
  domain,
  slice,
  operation,
  consumer,
) {
  if (!isValidDomainSliceConsumer(domain, slice, consumer)) return false;
  const operationConsumers =
    DOMAIN_CORE_OPERATION_CONSUMERS[domain]?.[operation];
  return operationConsumers?.includes(consumer) ?? true;
}
