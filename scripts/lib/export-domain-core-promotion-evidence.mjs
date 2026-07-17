import {
  isValidDomainSliceConsumer,
  isValidDomainSliceOperationConsumer,
  requiredCoverageForDomain,
} from "./domain-core-evidence-contract.mjs";

const STORED_V1_KEYS = new Set([
  "schemaVersion",
  "sampleId",
  "domain",
  "consumer",
  "channel",
  "operation",
  "coreVersion",
  "observedAt",
  "outcome",
  "mismatchCategory",
  "legacyMicros",
  "rustMicros",
  "receivedAt",
  "expireAt",
]);
const STORED_V2_KEYS = new Set([...STORED_V1_KEYS, "slice"]);
const STORED_V1_PROMOTION_KEYS = new Set([
  ...STORED_V1_KEYS,
  "promotionEligible",
]);
const STORED_V2_PROMOTION_KEYS = new Set([
  ...STORED_V2_KEYS,
  "promotionEligible",
]);
const STORED_V3_KEYS = new Set([
  "schemaVersion",
  "sampleId",
  "domain",
  "slice",
  "consumer",
  "channel",
  "operation",
  "candidateCommit",
  "expectedCoreVersion",
  "expectedCoreAbiVersion",
  "expectedCoreSourceSha256",
  "loadedCoreVersion",
  "loadedCoreAbiVersion",
  "loadedCoreSourceSha256",
  "observedAt",
  "outcome",
  "mismatchCategory",
  "legacyMicros",
  "rustMicros",
  "promotionEligible",
  "receivedAt",
  "expireAt",
]);
const CHANNELS = new Set(["internal", "beta"]);
const V1_CONSUMERS = new Set(["apple", "windows"]);
const UUID_V4 =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const IDENTIFIER = /^[a-z][a-z0-9_.-]{0,63}$/u;
const DRAIN_VERSION = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/u;
const VERSION =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;
const GIT_REVISION = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const MAX_CORE_ABI_VERSION = 0xffff_ffff;
const UNAVAILABLE_CORE_VERSIONS = new Set([
  "0.0.0-unavailable",
  "0.0.0-native-unavailable",
  "0.0.0-abi-mismatch",
]);
const MISMATCH_CATEGORIES = new Set([
  "result_mismatch",
  "native_unavailable",
  "native_error",
  "invalid_result",
  "loaded_identity_mismatch",
]);
const EXPORT_OPTION_KEYS = new Set([
  "domain",
  "channel",
  "candidateCommit",
  "expectedCoreVersion",
  "expectedCoreAbiVersion",
  "expectedCoreSourceSha256",
  "startedAt",
  "endedAt",
  "generatedAt",
  "sourceUri",
]);

// This allowlist is deliberately exhaustive. A new operation must be assigned to a real
// domain/slice before its evidence can contribute to a promotion decision.
const OPERATION_IDENTITY = new Map([
  ["claude_quota", "quota/claude"],
  ["codex_quota", "quota/codex"],
  ["cursor_quota", "quota/cursor"],
  ["anthropic_quota", "quota/anthropic"],
  ["pensieve_l2_normalize", "cloudvault/pensieve-vectors"],
  ["pensieve_vector_cloak", "cloudvault/pensieve-vectors"],
  ["pensieve_deterministic_embed", "cloudvault/pensieve-vectors"],
  ["pensieve_deterministic_embed_and_cloak", "cloudvault/pensieve-vectors"],
  ...[
    "aad_v1",
    "aad_v2",
    "resolve_aad",
    "sha256",
    "sha256_hex",
    "vault_key_id",
    "expected_session_body_hash",
    "expected_session_body_hash_v0",
    "expected_session_body_hash_v1",
    "expected_session_body_hash_v2",
    "blob_integrity",
    "session_body",
    "session_chunk",
    "project_memory_content",
    "blob_integrity_hash",
    "session_body_hash",
    "session_chunk_hash",
    "project_memory_content_hash",
    "keyed_hash_blob_integrity",
    "base64_encode",
    "base64_decode",
    "base64_decode_strict",
    "p256_validate_public_key",
    "cloudvault_aad_v1",
    "cloudvault_aad_v2",
    "cloudvault_resolve_aad",
    "cloudvault_sha256",
    "cloudvault_key_id",
    "cloudvault_keyed_hash",
    "cloudvault_base64_encode",
    "cloudvault_base64_decode",
    "cloudvault_validate_p256_public_key",
    "initialize",
  ].map((operation) => [operation, "cloudvault/foundation"]),
  ...[
    "aes_gcm_seal_detached",
    "aes_gcm_seal_combined",
    "aes_gcm_open_detached",
    "aes_gcm_open_text_detached",
    "aes_gcm_open_combined",
    "aes_seal_detached",
    "aes_seal_combined",
    "aes_open_combined",
    "aes_open_text",
    "aes_open_detached",
    "cloudvault_aes_seal_detached",
    "cloudvault_aes_seal_combined",
    "cloudvault_aes_open_detached",
    "cloudvault_aes_open_text",
    "cloudvault_aes_open_combined",
  ].map((operation) => [operation, "cloudvault/aes"]),
  ...[
    "recovery_normalize",
    "recovery_wrapping_key",
    "recovery_verification_hash",
    "recovery_wrap_vault_key",
    "recovery_open_vault_key",
    "cloudvault_recovery_wrapping_key",
    "cloudvault_recovery_verification_hash",
    "cloudvault_recovery_wrap_vault_key",
    "cloudvault_recovery_open_vault_key",
  ].map((operation) => [operation, "cloudvault/recovery"]),
  ...[
    "escrow_wrapping_key",
    "escrow_assemble_wire",
    "escrow_split_wire",
    "escrow_seal",
    "escrow_open",
    "cloudvault_escrow_split_wire",
    "cloudvault_escrow_seal",
    "cloudvault_escrow_open",
  ].map((operation) => [operation, "cloudvault/escrow"]),
  ["document_rewrap", "cloudvault/document-rewrap"],
  ...["token", "index", "query", "semantic"].map((operation) => [
    operation,
    "cloudvault/search",
  ]),
  ["project_memory_doc_id", "cloudvault/opaque-identifiers"],
  ["pensieve_dedup_hash", "cloudvault/opaque-identifiers"],
  ["pensieve_provenance_hash", "cloudvault/opaque-identifiers"],
  ["pensieve_slug_hmac", "cloudvault/opaque-identifiers"],
  ["subscription_doc_id", "cloudvault/opaque-identifiers"],
  ["aad", "hermes/aad"],
  ["hpke_v3_info", "hermes/hpke-info"],
  ...[
    "seal",
    "open",
    "seal_combined",
    "open_combined",
    "safety_code",
    "key_wrap_info_v1",
    "key_wrap_info_v2",
    "hkdf",
  ].map((operation) => [operation, "hermes/payload-keywrap"]),
  ...[
    "ratchet_open",
    "ratchet_root_kdf",
    "ratchet_chain_kdf",
    "ratchet_message_kdf",
    "ratchet_aad",
    "ratchet_seal",
  ].map((operation) => [operation, "hermes/ratchet"]),
  ["calculate_token_cost", "pricing/token-cost"],
  ["price_legacy_kimi", "pricing/legacy-kimi"],
]);

function timestamp(value, label) {
  const date =
    typeof value?.toDate === "function" ? value.toDate() : new Date(value);
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) {
    throw new Error(`${label} must be a timestamp`);
  }
  return date.toISOString();
}

function exactKeys(record, allowed, label) {
  if (record === null || typeof record !== "object" || Array.isArray(record)) {
    throw new Error(`${label} must be an object`);
  }
  const keys = Object.keys(record);
  if (keys.length !== allowed.size || keys.some((key) => !allowed.has(key))) {
    throw new Error(`${label} has an invalid field set`);
  }
}

function validateLatency(record, label) {
  for (const field of ["legacyMicros", "rustMicros"]) {
    if (
      !Number.isSafeInteger(record[field]) ||
      record[field] < 0 ||
      record[field] > 600_000_000
    ) {
      throw new Error(`${label}.${field} is invalid`);
    }
  }
}

function isCanonicalVersion(value) {
  return typeof value === "string" && value.length <= 64 && VERSION.test(value);
}

function isDrainVersion(value) {
  return (
    typeof value === "string" && value.length <= 64 && DRAIN_VERSION.test(value)
  );
}

function validateOutcome(record, label) {
  if (record.outcome !== "match" && record.outcome !== "mismatch") {
    throw new Error(`${label}.outcome is invalid`);
  }
  if (
    (record.outcome === "match" && record.mismatchCategory !== null) ||
    (record.outcome === "mismatch" &&
      !MISMATCH_CATEGORIES.has(record.mismatchCategory))
  ) {
    throw new Error(`${label}.mismatchCategory is inconsistent`);
  }
}

function validateBase(record, label) {
  if (typeof record.sampleId !== "string" || !UUID_V4.test(record.sampleId)) {
    throw new Error(`${label}.sampleId is invalid`);
  }
  if (!CHANNELS.has(record.channel))
    throw new Error(`${label}.channel is invalid`);
  if (
    typeof record.operation !== "string" ||
    !IDENTIFIER.test(record.operation)
  ) {
    throw new Error(`${label}.operation is invalid`);
  }
  validateOutcome(record, label);
  validateLatency(record, label);
}

function validateOperationIdentity(record, label) {
  const expected = OPERATION_IDENTITY.get(record.operation);
  if (expected !== `${record.domain}/${record.slice}`) {
    throw new Error(`${label} has an inconsistent operation, domain, or slice`);
  }
}

function validateV3Identity(record, label) {
  if (!GIT_REVISION.test(record.candidateCommit)) {
    throw new Error(`${label}.candidateCommit is invalid`);
  }
  if (
    !isCanonicalVersion(record.expectedCoreVersion) ||
    UNAVAILABLE_CORE_VERSIONS.has(record.expectedCoreVersion) ||
    !Number.isSafeInteger(record.expectedCoreAbiVersion) ||
    record.expectedCoreAbiVersion < 1 ||
    record.expectedCoreAbiVersion > MAX_CORE_ABI_VERSION ||
    !SHA256.test(record.expectedCoreSourceSha256)
  ) {
    throw new Error(`${label} has an invalid expected core identity`);
  }
  const loaded = [
    record.loadedCoreVersion,
    record.loadedCoreAbiVersion,
    record.loadedCoreSourceSha256,
  ];
  const allNull = loaded.every((value) => value === null);
  const allPresent = loaded.every((value) => value !== null);
  if (!allNull && !allPresent)
    throw new Error(`${label} has a partial loaded core identity`);
  if (allPresent) {
    if (
      !isCanonicalVersion(record.loadedCoreVersion) ||
      UNAVAILABLE_CORE_VERSIONS.has(record.loadedCoreVersion) ||
      !Number.isSafeInteger(record.loadedCoreAbiVersion) ||
      record.loadedCoreAbiVersion < 1 ||
      record.loadedCoreAbiVersion > MAX_CORE_ABI_VERSION ||
      !SHA256.test(record.loadedCoreSourceSha256)
    ) {
      throw new Error(`${label} has an invalid loaded core identity`);
    }
    const identityDiffers =
      record.loadedCoreVersion !== record.expectedCoreVersion ||
      record.loadedCoreAbiVersion !== record.expectedCoreAbiVersion ||
      record.loadedCoreSourceSha256 !== record.expectedCoreSourceSha256;
    if (
      identityDiffers &&
      record.mismatchCategory !== "loaded_identity_mismatch"
    ) {
      throw new Error(
        `${label} loaded core identity does not match the expected candidate`,
      );
    }
    if (
      !identityDiffers &&
      record.mismatchCategory === "loaded_identity_mismatch"
    ) {
      throw new Error(
        `${label} loaded_identity_mismatch requires a different loaded core identity`,
      );
    }
  }
  if (record.outcome === "match" && !allPresent) {
    throw new Error(`${label} match is missing the loaded core identity`);
  }
  if (
    (record.mismatchCategory === "result_mismatch" ||
      record.mismatchCategory === "invalid_result") &&
    !allPresent
  ) {
    throw new Error(
      `${label} completed comparison is missing the loaded core identity`,
    );
  }
  if (record.mismatchCategory === "native_unavailable" && !allNull) {
    throw new Error(
      `${label} native_unavailable must not claim a loaded core identity`,
    );
  }
  if (record.mismatchCategory === "loaded_identity_mismatch" && !allPresent) {
    throw new Error(
      `${label} loaded_identity_mismatch requires a complete loaded core identity`,
    );
  }
}

export function parseStoredDomainCoreShadowSample(record, index = 0) {
  const label = `records[${index}]`;
  if (record?.schemaVersion === 1) {
    exactKeys(
      record,
      Object.hasOwn(record, "promotionEligible")
        ? STORED_V1_PROMOTION_KEYS
        : STORED_V1_KEYS,
      label,
    );
    if (
      Object.hasOwn(record, "promotionEligible") &&
      record.promotionEligible !== false
    ) {
      throw new Error(`${label} legacy evidence cannot be promotion eligible`);
    }
    validateBase(record, label);
    if (!isDrainVersion(record.coreVersion))
      throw new Error(`${label}.coreVersion is invalid`);
    if (
      record.domain !== "quota" ||
      !V1_CONSUMERS.has(record.consumer) ||
      OPERATION_IDENTITY.get(record.operation) !==
        `quota/${record.operation.replace(/_quota$/u, "")}`
    ) {
      throw new Error(`${label} has an unsupported V1 identity`);
    }
  } else if (record?.schemaVersion === 2) {
    exactKeys(
      record,
      Object.hasOwn(record, "promotionEligible")
        ? STORED_V2_PROMOTION_KEYS
        : STORED_V2_KEYS,
      label,
    );
    if (
      Object.hasOwn(record, "promotionEligible") &&
      record.promotionEligible !== false
    ) {
      throw new Error(`${label} drain evidence cannot be promotion eligible`);
    }
    validateBase(record, label);
    if (!isDrainVersion(record.coreVersion))
      throw new Error(`${label}.coreVersion is invalid`);
    if (
      typeof record.domain !== "string" ||
      typeof record.slice !== "string" ||
      typeof record.consumer !== "string" ||
      !isValidDomainSliceConsumer(
        record.domain,
        record.slice,
        record.consumer,
      ) ||
      (record.domain === "quota" &&
        OPERATION_IDENTITY.get(record.operation) !==
          `${record.domain}/${record.slice}`)
    ) {
      throw new Error(`${label} has an invalid V2 domain, slice, or consumer`);
    }
  } else if (record?.schemaVersion === 3) {
    exactKeys(record, STORED_V3_KEYS, label);
    validateBase(record, label);
    if (
      record.promotionEligible !== true ||
      typeof record.domain !== "string" ||
      typeof record.slice !== "string" ||
      typeof record.consumer !== "string" ||
      !isValidDomainSliceConsumer(record.domain, record.slice, record.consumer)
    ) {
      throw new Error(`${label} is not promotion-eligible V3 evidence`);
    }
    validateOperationIdentity(record, label);
    if (
      !isValidDomainSliceOperationConsumer(
        record.domain,
        record.slice,
        record.operation,
        record.consumer,
      )
    ) {
      throw new Error(`${label} has an invalid consumer for its operation`);
    }
    validateV3Identity(record, label);
  } else {
    throw new Error(`${label} has an unsupported schema version`);
  }
  return {
    ...record,
    observedAt: timestamp(record.observedAt, `${label}.observedAt`),
    receivedAt: timestamp(record.receivedAt, `${label}.receivedAt`),
    expireAt: timestamp(record.expireAt, `${label}.expireAt`),
  };
}

function nearestRankP95(values) {
  if (values.length === 0)
    throw new Error("Cannot calculate p95 for an empty sample set");
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.ceil(sorted.length * 0.95) - 1];
}

function utcDay(value) {
  return value.slice(0, 10);
}

function requiredUtcDays(startedAt, endedAt) {
  const days = [];
  let cursor = Date.parse(`${utcDay(startedAt)}T00:00:00.000Z`);
  const endMillis = Date.parse(endedAt);
  while (cursor < endMillis) {
    days.push(new Date(cursor).toISOString().slice(0, 10));
    cursor += 24 * 60 * 60 * 1_000;
  }
  return days;
}

export function validateDomainCorePromotionOptions(options) {
  exactKeys(options, EXPORT_OPTION_KEYS, "options");
  const requiredCoverage = requiredCoverageForDomain(options.domain);
  if (requiredCoverage.length === 0) {
    throw new Error(`Unsupported --domain ${options.domain ?? "<missing>"}`);
  }
  if (!CHANNELS.has(options.channel))
    throw new Error("channel must be internal or beta");
  if (!GIT_REVISION.test(options.candidateCommit)) {
    throw new Error("candidateCommit must be a full lowercase Git SHA");
  }
  if (
    !isCanonicalVersion(options.expectedCoreVersion) ||
    UNAVAILABLE_CORE_VERSIONS.has(options.expectedCoreVersion)
  ) {
    throw new Error(
      "expectedCoreVersion must be an available semantic version",
    );
  }
  if (
    !Number.isSafeInteger(options.expectedCoreAbiVersion) ||
    options.expectedCoreAbiVersion < 1 ||
    options.expectedCoreAbiVersion > MAX_CORE_ABI_VERSION
  ) {
    throw new Error(
      "expectedCoreAbiVersion must be an unsigned 32-bit integer",
    );
  }
  if (!SHA256.test(options.expectedCoreSourceSha256)) {
    throw new Error(
      "expectedCoreSourceSha256 must be a lowercase SHA-256 digest",
    );
  }
  const source = new URL(options.sourceUri);
  if (
    source.protocol !== "https:" ||
    source.username ||
    source.password ||
    source.search ||
    source.hash
  ) {
    throw new Error(
      "sourceUri must be credential-free HTTPS without query or fragment",
    );
  }
  const generatedAt = timestamp(options.generatedAt, "options.generatedAt");
  const startedAt = timestamp(options.startedAt, "options.startedAt");
  const endedAt = timestamp(options.endedAt, "options.endedAt");
  if (
    Date.parse(endedAt) <= Date.parse(startedAt) ||
    Date.parse(generatedAt) < Date.parse(endedAt)
  ) {
    throw new Error(
      "The observation window must end after it starts and no later than generatedAt",
    );
  }
  return { requiredCoverage, generatedAt, startedAt, endedAt };
}

export function buildDomainCorePromotionEvidence(records, options) {
  const { requiredCoverage, generatedAt, startedAt, endedAt } =
    validateDomainCorePromotionOptions(options);

  const parsed = records.map(parseStoredDomainCoreShadowSample);
  const ids = new Set(parsed.map((record) => record.sampleId));
  if (ids.size !== parsed.length)
    throw new Error("records contains duplicate sampleId values");
  if (
    parsed.some((record) => record.schemaVersion !== 3) &&
    !parsed.some((record) => record.schemaVersion === 3)
  ) {
    throw new Error("evidence_schema_v3_required");
  }
  const selected = parsed.filter(
    (record) =>
      record.schemaVersion === 3 &&
      record.domain === options.domain &&
      record.channel === options.channel &&
      record.candidateCommit === options.candidateCommit &&
      record.expectedCoreVersion === options.expectedCoreVersion &&
      record.expectedCoreAbiVersion === options.expectedCoreAbiVersion &&
      record.expectedCoreSourceSha256 === options.expectedCoreSourceSha256 &&
      Date.parse(record.receivedAt) >= Date.parse(startedAt) &&
      Date.parse(record.receivedAt) < Date.parse(endedAt),
  );
  if (selected.length === 0) {
    throw new Error(
      "No V3 samples matched the exact candidate tuple and server-received window",
    );
  }
  const requiredDays = requiredUtcDays(startedAt, endedAt);

  const windows = requiredCoverage.map(({ slice, consumer }) => {
    const samples = selected.filter(
      (record) => record.slice === slice && record.consumer === consumer,
    );
    if (samples.length === 0) {
      throw new Error(
        `No ${options.domain}/${slice}/${consumer} V3 samples matched the exact candidate tuple`,
      );
    }
    const dailyCounts = new Map(requiredDays.map((day) => [day, 0]));
    for (const sample of samples) {
      const day = utcDay(sample.receivedAt);
      dailyCounts.set(day, (dailyCounts.get(day) ?? 0) + 1);
    }
    const missingDays = [...dailyCounts.entries()]
      .filter(([, count]) => count === 0)
      .map(([day]) => day);
    if (missingDays.length > 0) {
      throw new Error(
        `${options.domain}/${slice}/${consumer} is missing server-received V3 samples for UTC days: ${missingDays.join(", ")}`,
      );
    }
    const mismatchCounts = new Map();
    for (const sample of samples) {
      if (sample.mismatchCategory !== null) {
        mismatchCounts.set(
          sample.mismatchCategory,
          (mismatchCounts.get(sample.mismatchCategory) ?? 0) + 1,
        );
      }
    }
    return {
      slice,
      consumer,
      channel: options.channel,
      startedAt,
      endedAt,
      sampleCount: samples.length,
      dailySampleCounts: [...dailyCounts].map(([date, sampleCount]) => ({
        date,
        sampleCount,
      })),
      mismatches: [...mismatchCounts.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([category, count]) => ({
          category,
          count,
          resolution: "unexplained",
        })),
      latency: {
        sampleCount: samples.length,
        legacyP95Micros: nearestRankP95(
          samples.map((record) => record.legacyMicros),
        ),
        rustP95Micros: nearestRankP95(
          samples.map((record) => record.rustMicros),
        ),
      },
    };
  });

  const candidate = {
    candidateCommit: options.candidateCommit,
    expectedCoreVersion: options.expectedCoreVersion,
    expectedCoreAbiVersion: options.expectedCoreAbiVersion,
    expectedCoreSourceSha256: options.expectedCoreSourceSha256,
  };
  return {
    schemaVersion: 3,
    domain: options.domain,
    ...candidate,
    generatedAt,
    provenance: {
      collector: "domain-core-shadow-exporter",
      ...candidate,
      sourceUri: options.sourceUri,
    },
    windows,
  };
}
