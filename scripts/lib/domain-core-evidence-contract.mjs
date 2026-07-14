export const DOMAIN_CORE_EVIDENCE_SCHEMA_VERSION = 2;

export const DOMAIN_CORE_REQUIRED_COVERAGE = Object.freeze({
  quota: Object.freeze({
    claude: Object.freeze(["apple", "windows"]),
    codex: Object.freeze(["apple", "windows"]),
    cursor: Object.freeze(["apple", "windows"]),
    anthropic: Object.freeze(["apple", "windows"]),
  }),
  cloudvault: Object.freeze({
    foundation: Object.freeze(["apple", "android", "windows", "console"]),
    aes: Object.freeze(["apple", "android", "windows", "console"]),
    recovery: Object.freeze(["apple", "android", "windows"]),
    escrow: Object.freeze(["apple", "android", "windows", "console"]),
    "document-rewrap": Object.freeze(["apple", "android"]),
    search: Object.freeze(["apple", "android"]),
  }),
  hermes: Object.freeze({
    aad: Object.freeze(["apple", "android"]),
    "payload-keywrap": Object.freeze(["apple", "android"]),
    "hpke-info": Object.freeze(["apple", "android"]),
    ratchet: Object.freeze(["apple", "android"]),
  }),
  pricing: Object.freeze({
    "token-cost": Object.freeze(["apple", "functions"]),
    "legacy-kimi": Object.freeze(["functions"]),
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
  return DOMAIN_CORE_REQUIRED_COVERAGE[domain]?.[slice]?.includes(consumer) === true;
}
