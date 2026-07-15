import { randomUUID } from "node:crypto";
import { HttpsError } from "firebase-functions/v2/https";
import { Timestamp, type Firestore } from "firebase-admin/firestore";

import { isRecord } from "./guards.js";

const DOMAIN_CORE_SHADOW_SAMPLE_SCHEMA_VERSION = 3;
const DOMAIN_CORE_SHADOW_SAMPLE_DRAIN_SCHEMA_VERSION = 2;
const DOMAIN_CORE_SHADOW_SAMPLE_LEGACY_SCHEMA_VERSION = 1;
const DOMAIN_CORE_SHADOW_MAX_BATCH = 100;
export const DOMAIN_CORE_SHADOW_RETENTION_MS = 60 * 24 * 60 * 60 * 1000;
const DOMAIN_CORE_SHADOW_MAX_AGE_MS = 31 * 24 * 60 * 60 * 1000;
const DOMAIN_CORE_SHADOW_FUTURE_SKEW_MS = 5 * 60 * 1000;
const DOMAIN_CORE_SHADOW_COLLECTION = "domain_core_shadow_samples";
const DOMAIN_CORE_SHADOW_CLAIM_CONSUMERS = new Set(["apple", "windows", "android", "console", "functions"]);

const SAMPLE_V1_KEYS =
  "channel consumer coreVersion domain legacyMicros mismatchCategory observedAt operation outcome rustMicros sampleId schemaVersion".split(
    " ",
  );
const SAMPLE_V2_KEYS = [...SAMPLE_V1_KEYS, "slice"] as const;
const SAMPLE_V3_KEYS =
  "candidateCommit channel consumer domain expectedCoreAbiVersion expectedCoreSourceSha256 expectedCoreVersion legacyMicros loadedCoreAbiVersion loadedCoreSourceSha256 loadedCoreVersion mismatchCategory observedAt operation outcome rustMicros sampleId schemaVersion slice".split(
    " ",
  );
const REQUEST_KEYS = ["samples"] as const;
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
  }),
  hermes: operationSlices({
    aad: "aad",
    "payload-keywrap": "key_wrap_info_v1 key_wrap_info_v2 seal open safety_code hkdf",
    "hpke-info": "hpke_v3_info",
    ratchet: "ratchet_aad ratchet_root_kdf ratchet_chain_kdf ratchet_message_kdf ratchet_seal ratchet_open",
  }),
  pricing: operationSlices({
    "token-cost": "calculate_token_cost",
    "legacy-kimi": "price_legacy_kimi",
  }),
};
export const DOMAIN_CORE_SHADOW_REQUIRED_COVERAGE: Readonly<
  Record<string, Readonly<Record<string, readonly string[]>>>
> = {
  quota: {
    claude: ["apple", "windows"],
    codex: ["apple", "windows"],
    cursor: ["apple", "windows"],
    anthropic: ["apple", "windows"],
  },
  cloudvault: {
    foundation: ["apple", "android", "windows", "console"],
    aes: ["apple", "android", "windows", "console"],
    recovery: ["apple", "android", "windows"],
    escrow: ["apple", "android", "windows", "console"],
    "document-rewrap": ["apple", "android"],
    search: ["apple", "android"],
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
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const CORE_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/u;
const CANONICAL_CORE_VERSION =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;
const GIT_COMMIT = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const UTC_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/u;

type DomainCoreShadowConsumer = "apple" | "windows";
type DomainCoreShadowConsumerV2 = "apple" | "android" | "windows" | "console" | "functions";
type DomainCoreShadowChannel = "internal" | "beta";
type DomainCoreShadowOperation = "claude_quota" | "codex_quota" | "cursor_quota" | "anthropic_quota";
type DomainCoreShadowOutcome = "match" | "mismatch";
type DomainCoreShadowMismatchCategory = "result_mismatch" | "native_unavailable" | "native_error" | "invalid_result";
type DomainCoreShadowMismatchCategoryV3 = DomainCoreShadowMismatchCategory | "loaded_identity_mismatch";

interface DomainCoreShadowSampleCommon {
  sampleId: string;
  channel: DomainCoreShadowChannel;
  observedAt: string;
  outcome: DomainCoreShadowOutcome;
  legacyMicros: number;
  rustMicros: number;
}

interface DomainCoreShadowSampleV1 extends DomainCoreShadowSampleCommon {
  schemaVersion: 1;
  domain: "quota";
  consumer: DomainCoreShadowConsumer;
  operation: DomainCoreShadowOperation;
  coreVersion: string;
  mismatchCategory: DomainCoreShadowMismatchCategory | null;
}

type DomainCoreShadowDocumentReference = { path: string };
type DomainCoreShadowDocumentSnapshot = { exists: boolean; data(): unknown };

interface DomainCoreShadowTransaction {
  get(reference: DomainCoreShadowDocumentReference): Promise<DomainCoreShadowDocumentSnapshot>;
  create(reference: DomainCoreShadowDocumentReference, data: ReturnType<typeof storedDomainCoreShadowSample>): void;
}

interface DomainCoreShadowStore {
  doc(path: string): DomainCoreShadowDocumentReference;
  runTransaction<T>(update: (transaction: DomainCoreShadowTransaction) => Promise<T>): Promise<T>;
}

interface DomainCoreShadowSampleV2 extends DomainCoreShadowSampleCommon {
  schemaVersion: 2;
  domain: "quota" | "cloudvault" | "hermes" | "pricing";
  slice: string;
  consumer: DomainCoreShadowConsumerV2;
  operation: string;
  coreVersion: string;
  mismatchCategory: DomainCoreShadowMismatchCategory | null;
}

export interface DomainCoreShadowSampleV3 extends DomainCoreShadowSampleCommon {
  schemaVersion: 3;
  domain: DomainCoreShadowSampleV2["domain"];
  slice: string;
  consumer: DomainCoreShadowConsumerV2;
  operation: string;
  candidateCommit: string;
  expectedCoreVersion: string;
  expectedCoreAbiVersion: number;
  expectedCoreSourceSha256: string;
  loadedCoreVersion: string | null;
  loadedCoreAbiVersion: number | null;
  loadedCoreSourceSha256: string | null;
  mismatchCategory: DomainCoreShadowMismatchCategoryV3 | null;
}

type DomainCoreShadowSample = DomainCoreShadowSampleV1 | DomainCoreShadowSampleV2 | DomainCoreShadowSampleV3;

type DomainCoreShadowComparisonV2 = Omit<DomainCoreShadowSampleV2, "schemaVersion" | "sampleId" | "observedAt">;

function exactKeys(record: Record<string, unknown>, expected: readonly string[], label: string): void {
  const actual = Object.keys(record).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new HttpsError("invalid-argument", `${label} has an invalid field set.`);
  }
}

function boundedMicros(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > 600_000_000) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

function coreAbiVersion(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1 || value > 0xffff_ffff) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

function coreVersion(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length > 64 || !CORE_VERSION.test(value)) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

function canonicalCoreVersion(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length > 64 || !CANONICAL_CORE_VERSION.test(value)) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

function sourceSha256(value: unknown, label: string): string {
  if (typeof value !== "string" || !SHA256.test(value)) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

function isConsumer(value: unknown): value is DomainCoreShadowConsumer {
  return value === "apple" || value === "windows";
}

function isChannel(value: unknown): value is DomainCoreShadowChannel {
  return value === "internal" || value === "beta";
}

function isOperation(value: unknown): value is DomainCoreShadowOperation {
  return value === "claude_quota" || value === "codex_quota" || value === "cursor_quota" || value === "anthropic_quota";
}

function isMismatchCategory(value: unknown): value is DomainCoreShadowMismatchCategory {
  return (
    value === "result_mismatch" ||
    value === "native_unavailable" ||
    value === "native_error" ||
    value === "invalid_result"
  );
}

function parseObservedAt(value: unknown, nowMillis: number, index: number): { iso: string; millis: number } {
  if (typeof value !== "string" || !UTC_TIMESTAMP.test(value)) {
    throw new HttpsError("invalid-argument", `samples[${index}].observedAt is invalid.`);
  }
  const millis = Date.parse(value);
  if (
    !Number.isFinite(millis) ||
    millis < nowMillis - DOMAIN_CORE_SHADOW_MAX_AGE_MS ||
    millis > nowMillis + DOMAIN_CORE_SHADOW_FUTURE_SKEW_MS
  ) {
    throw new HttpsError("invalid-argument", `samples[${index}].observedAt is outside the accepted window.`);
  }
  return { iso: new Date(millis).toISOString(), millis };
}

function parseOutcome(
  outcome: unknown,
  mismatchCategory: unknown,
  index: number,
  allowLoadedIdentityMismatch: boolean,
): { outcome: DomainCoreShadowOutcome; mismatchCategory: DomainCoreShadowMismatchCategoryV3 | null } {
  if (outcome !== "match" && outcome !== "mismatch") {
    throw new HttpsError("invalid-argument", `samples[${index}].outcome is invalid.`);
  }
  if (outcome === "match" && mismatchCategory === null) {
    return { outcome, mismatchCategory };
  }
  if (
    outcome === "mismatch" &&
    (isMismatchCategory(mismatchCategory) ||
      (allowLoadedIdentityMismatch && mismatchCategory === "loaded_identity_mismatch"))
  ) {
    return { outcome, mismatchCategory };
  }
  throw new HttpsError("invalid-argument", `samples[${index}].mismatchCategory is inconsistent.`);
}

function isV2Domain(value: unknown): value is DomainCoreShadowSampleV2["domain"] {
  return value === "quota" || value === "cloudvault" || value === "hermes" || value === "pricing";
}

function isV2Consumer(value: unknown): value is DomainCoreShadowConsumerV2 {
  return typeof value === "string" && DOMAIN_CORE_SHADOW_CLAIM_CONSUMERS.has(value);
}

function parseV3Identity(
  raw: Record<string, unknown>,
  index: number,
  outcome: { outcome: DomainCoreShadowOutcome; mismatchCategory: DomainCoreShadowMismatchCategoryV3 | null },
): Pick<
  DomainCoreShadowSampleV3,
  | "candidateCommit"
  | "expectedCoreVersion"
  | "expectedCoreAbiVersion"
  | "expectedCoreSourceSha256"
  | "loadedCoreVersion"
  | "loadedCoreAbiVersion"
  | "loadedCoreSourceSha256"
> {
  if (typeof raw.candidateCommit !== "string" || !GIT_COMMIT.test(raw.candidateCommit)) {
    throw new HttpsError("invalid-argument", `samples[${index}].candidateCommit is invalid.`);
  }
  const expectedCoreVersion = canonicalCoreVersion(raw.expectedCoreVersion, `samples[${index}].expectedCoreVersion`);
  const expectedCoreAbiVersion = coreAbiVersion(raw.expectedCoreAbiVersion, `samples[${index}].expectedCoreAbiVersion`);
  const expectedCoreSourceSha256 = sourceSha256(
    raw.expectedCoreSourceSha256,
    `samples[${index}].expectedCoreSourceSha256`,
  );
  const loadedValues = [raw.loadedCoreVersion, raw.loadedCoreAbiVersion, raw.loadedCoreSourceSha256];
  const loadedIsNull = loadedValues.every((value) => value === null);
  const loadedIsPresent = loadedValues.every((value) => value !== null);
  if (!loadedIsNull && !loadedIsPresent) {
    throw new HttpsError("invalid-argument", `samples[${index}] has a partial loaded core identity.`);
  }
  const loadedCoreVersion = loadedIsNull
    ? null
    : canonicalCoreVersion(raw.loadedCoreVersion, `samples[${index}].loadedCoreVersion`);
  const loadedCoreAbiVersion = loadedIsNull
    ? null
    : coreAbiVersion(raw.loadedCoreAbiVersion, `samples[${index}].loadedCoreAbiVersion`);
  const loadedCoreSourceSha256 = loadedIsNull
    ? null
    : sourceSha256(raw.loadedCoreSourceSha256, `samples[${index}].loadedCoreSourceSha256`);
  const loadedMatchesExpected =
    loadedCoreVersion !== null &&
    loadedCoreVersion === expectedCoreVersion &&
    loadedCoreAbiVersion === expectedCoreAbiVersion &&
    loadedCoreSourceSha256 === expectedCoreSourceSha256;
  const requiresLoadedIdentity =
    outcome.outcome === "match" ||
    outcome.mismatchCategory === "result_mismatch" ||
    outcome.mismatchCategory === "invalid_result";
  if (requiresLoadedIdentity && !loadedMatchesExpected) {
    throw new HttpsError("invalid-argument", `samples[${index}] comparison did not load its expected core identity.`);
  }
  if (outcome.mismatchCategory === "native_unavailable" && loadedCoreVersion !== null) {
    throw new HttpsError("invalid-argument", `samples[${index}] native-unavailable evidence has a loaded identity.`);
  }
  if (outcome.mismatchCategory === "native_error" && loadedCoreVersion !== null && !loadedMatchesExpected) {
    throw new HttpsError("invalid-argument", `samples[${index}] native-error evidence loaded an unexpected core.`);
  }
  if (
    outcome.mismatchCategory === "loaded_identity_mismatch" &&
    (loadedCoreVersion === null || loadedMatchesExpected)
  ) {
    throw new HttpsError("invalid-argument", `samples[${index}] loaded core identity is not mismatched.`);
  }
  return {
    candidateCommit: raw.candidateCommit,
    expectedCoreVersion,
    expectedCoreAbiVersion,
    expectedCoreSourceSha256,
    loadedCoreVersion,
    loadedCoreAbiVersion,
    loadedCoreSourceSha256,
  };
}

function parseCoveredIdentity(
  raw: Record<string, unknown>,
  index: number,
): Pick<DomainCoreShadowSampleV2, "domain" | "slice" | "consumer" | "operation"> {
  if (
    !isV2Domain(raw.domain) ||
    typeof raw.slice !== "string" ||
    !isV2Consumer(raw.consumer) ||
    typeof raw.operation !== "string" ||
    DOMAIN_CORE_SHADOW_REQUIRED_COVERAGE[raw.domain]?.[raw.slice]?.includes(raw.consumer) !== true
  ) {
    throw new HttpsError("invalid-argument", `samples[${index}] has an invalid domain, slice, or consumer.`);
  }
  const expectedSlice = DOMAIN_CORE_SHADOW_OPERATION_SLICES[raw.domain]?.[raw.operation];
  const mustValidateOperation = raw.schemaVersion === 3 || (raw.schemaVersion === 2 && raw.domain === "quota");
  if (mustValidateOperation && expectedSlice !== raw.slice) {
    throw new HttpsError("invalid-argument", `samples[${index}] has an inconsistent operation and slice.`);
  }
  return { domain: raw.domain, slice: raw.slice, consumer: raw.consumer, operation: raw.operation };
}

function parseSample(raw: unknown, nowMillis: number, index: number): DomainCoreShadowSample {
  if (!isRecord(raw)) throw new HttpsError("invalid-argument", `samples[${index}] must be an object.`);
  if (raw.schemaVersion === DOMAIN_CORE_SHADOW_SAMPLE_LEGACY_SCHEMA_VERSION) {
    exactKeys(raw, SAMPLE_V1_KEYS, `samples[${index}]`);
  } else if (raw.schemaVersion === DOMAIN_CORE_SHADOW_SAMPLE_DRAIN_SCHEMA_VERSION) {
    exactKeys(raw, SAMPLE_V2_KEYS, `samples[${index}]`);
  } else if (raw.schemaVersion === DOMAIN_CORE_SHADOW_SAMPLE_SCHEMA_VERSION) {
    exactKeys(raw, SAMPLE_V3_KEYS, `samples[${index}]`);
  } else {
    throw new HttpsError("invalid-argument", `samples[${index}] has an unsupported schema or domain.`);
  }
  if (typeof raw.sampleId !== "string" || !UUID_V4.test(raw.sampleId)) {
    throw new HttpsError("invalid-argument", `samples[${index}].sampleId is invalid.`);
  }
  if (!isChannel(raw.channel)) {
    throw new HttpsError("permission-denied", "Shadow evidence is accepted only from internal or beta channels.");
  }
  if (typeof raw.operation !== "string" || !/^[a-z][a-z0-9_.-]{0,63}$/u.test(raw.operation)) {
    throw new HttpsError("invalid-argument", `samples[${index}].operation is invalid.`);
  }
  const parsedCoreVersion =
    raw.schemaVersion === DOMAIN_CORE_SHADOW_SAMPLE_SCHEMA_VERSION
      ? undefined
      : coreVersion(raw.coreVersion, `samples[${index}].coreVersion`);
  const observedAt = parseObservedAt(raw.observedAt, nowMillis, index);
  const outcome = parseOutcome(
    raw.outcome,
    raw.mismatchCategory,
    index,
    raw.schemaVersion === DOMAIN_CORE_SHADOW_SAMPLE_SCHEMA_VERSION,
  );

  const common = {
    sampleId: raw.sampleId,
    channel: raw.channel,
    observedAt: observedAt.iso,
    outcome: outcome.outcome,
    mismatchCategory: outcome.mismatchCategory,
    legacyMicros: boundedMicros(raw.legacyMicros, `samples[${index}].legacyMicros`),
    rustMicros: boundedMicros(raw.rustMicros, `samples[${index}].rustMicros`),
  };
  if (raw.schemaVersion === DOMAIN_CORE_SHADOW_SAMPLE_LEGACY_SCHEMA_VERSION) {
    if (parsedCoreVersion === undefined) throw new Error("V1 shadow sample lost its core version.");
    if (raw.domain !== "quota" || !isConsumer(raw.consumer) || !isOperation(raw.operation)) {
      throw new HttpsError("invalid-argument", `samples[${index}] has an unsupported v1 identity.`);
    }
    return {
      schemaVersion: 1,
      domain: "quota",
      consumer: raw.consumer,
      operation: raw.operation,
      ...common,
      coreVersion: parsedCoreVersion,
      mismatchCategory: common.mismatchCategory as DomainCoreShadowMismatchCategory | null,
    };
  }
  const covered = parseCoveredIdentity(raw, index);
  if (raw.schemaVersion === DOMAIN_CORE_SHADOW_SAMPLE_SCHEMA_VERSION) {
    const identity = parseV3Identity(raw, index, outcome);
    return {
      schemaVersion: 3,
      ...covered,
      ...identity,
      sampleId: common.sampleId,
      channel: common.channel,
      observedAt: common.observedAt,
      outcome: common.outcome,
      mismatchCategory: common.mismatchCategory,
      legacyMicros: common.legacyMicros,
      rustMicros: common.rustMicros,
    };
  }
  if (parsedCoreVersion === undefined) throw new Error("V2 shadow sample lost its core version.");
  return {
    schemaVersion: 2,
    ...covered,
    ...common,
    coreVersion: parsedCoreVersion,
    mismatchCategory: common.mismatchCategory as DomainCoreShadowMismatchCategory | null,
  };
}

export function buildDomainCoreShadowSampleV2(
  comparison: DomainCoreShadowComparisonV2,
  options: { nowMillis?: number; sampleId?: string } = {},
): DomainCoreShadowSampleV2 {
  const nowMillis = options.nowMillis ?? Date.now();
  const parsed = parseSample(
    {
      schemaVersion: 2,
      sampleId: options.sampleId ?? randomUUID(),
      observedAt: new Date(nowMillis).toISOString(),
      ...comparison,
    },
    nowMillis,
    0,
  );
  if (parsed.schemaVersion !== 2) throw new Error("V2 shadow sample builder returned an unexpected schema.");
  return parsed;
}

export function parseDomainCoreShadowSampleRequest(raw: unknown, nowMillis = Date.now()): DomainCoreShadowSample[] {
  if (!isRecord(raw)) throw new HttpsError("invalid-argument", "Request data must be an object.");
  exactKeys(raw, REQUEST_KEYS, "request data");
  if (!Array.isArray(raw.samples) || raw.samples.length === 0 || raw.samples.length > DOMAIN_CORE_SHADOW_MAX_BATCH) {
    throw new HttpsError("invalid-argument", `samples must contain 1-${DOMAIN_CORE_SHADOW_MAX_BATCH} items.`);
  }
  const samples = raw.samples.map((sample, index) => parseSample(sample, nowMillis, index));
  if (new Set(samples.map((sample) => sample.sampleId)).size !== samples.length) {
    throw new HttpsError("invalid-argument", "samples contains duplicate sampleId values.");
  }
  return samples;
}

export function enforceDomainCoreShadowChannelClaim(
  token: Record<string, unknown>,
  samples: DomainCoreShadowSample[],
): void {
  const claimedChannel = token.domainCoreShadowChannel;
  const claimedConsumers = token.domainCoreShadowConsumers;
  if (
    (claimedChannel !== "internal" && claimedChannel !== "beta") ||
    !Array.isArray(claimedConsumers) ||
    claimedConsumers.some(
      (consumer) => typeof consumer !== "string" || !DOMAIN_CORE_SHADOW_CLAIM_CONSUMERS.has(consumer),
    ) ||
    samples.some((sample) => sample.channel !== claimedChannel || !claimedConsumers.includes(sample.consumer))
  ) {
    throw new HttpsError(
      "permission-denied",
      "This account is not enrolled for the submitted shadow-evidence channel and consumer.",
    );
  }
  const v3Samples = samples.filter((sample): sample is DomainCoreShadowSampleV3 => sample.schemaVersion === 3);
  if (v3Samples.length === 0) return;
  const candidateCommit = token.domainCoreShadowCandidateCommit;
  const expectedCoreVersion = token.domainCoreShadowCoreVersion;
  const expectedCoreAbiVersion = token.domainCoreShadowCoreAbiVersion;
  const expectedCoreSourceSha256 = token.domainCoreShadowCoreSourceSha256;
  if (
    typeof candidateCommit !== "string" ||
    !GIT_COMMIT.test(candidateCommit) ||
    typeof expectedCoreVersion !== "string" ||
    !CANONICAL_CORE_VERSION.test(expectedCoreVersion) ||
    typeof expectedCoreAbiVersion !== "number" ||
    !Number.isSafeInteger(expectedCoreAbiVersion) ||
    expectedCoreAbiVersion < 1 ||
    expectedCoreAbiVersion > 0xffff_ffff ||
    typeof expectedCoreSourceSha256 !== "string" ||
    !SHA256.test(expectedCoreSourceSha256) ||
    v3Samples.some(
      (sample) =>
        sample.candidateCommit !== candidateCommit ||
        sample.expectedCoreVersion !== expectedCoreVersion ||
        sample.expectedCoreAbiVersion !== expectedCoreAbiVersion ||
        sample.expectedCoreSourceSha256 !== expectedCoreSourceSha256,
    )
  ) {
    throw new HttpsError("permission-denied", "This account is not enrolled for the submitted domain-core candidate.");
  }
}

export function storedDomainCoreShadowSample(sample: DomainCoreShadowSample, nowMillis: number) {
  return {
    schemaVersion: sample.schemaVersion,
    sampleId: sample.sampleId,
    domain: sample.domain,
    ...(sample.schemaVersion !== 1 ? { slice: sample.slice } : {}),
    consumer: sample.consumer,
    channel: sample.channel,
    operation: sample.operation,
    ...(sample.schemaVersion === 3
      ? {
          candidateCommit: sample.candidateCommit,
          expectedCoreVersion: sample.expectedCoreVersion,
          expectedCoreAbiVersion: sample.expectedCoreAbiVersion,
          expectedCoreSourceSha256: sample.expectedCoreSourceSha256,
          loadedCoreVersion: sample.loadedCoreVersion,
          loadedCoreAbiVersion: sample.loadedCoreAbiVersion,
          loadedCoreSourceSha256: sample.loadedCoreSourceSha256,
        }
      : { coreVersion: sample.coreVersion }),
    observedAt: Timestamp.fromDate(new Date(sample.observedAt)),
    outcome: sample.outcome,
    mismatchCategory: sample.mismatchCategory,
    legacyMicros: sample.legacyMicros,
    rustMicros: sample.rustMicros,
    promotionEligible: sample.schemaVersion === 3,
    receivedAt: Timestamp.fromMillis(nowMillis),
    expireAt: Timestamp.fromMillis(nowMillis + DOMAIN_CORE_SHADOW_RETENTION_MS),
  };
}

export function storedDomainCoreShadowSampleMatches(stored: unknown, sample: DomainCoreShadowSample): boolean {
  if (!isRecord(stored) || !(stored.observedAt instanceof Timestamp)) return false;
  return (
    stored.schemaVersion === sample.schemaVersion &&
    stored.sampleId === sample.sampleId &&
    stored.domain === sample.domain &&
    (sample.schemaVersion === 1 || stored.slice === sample.slice) &&
    stored.consumer === sample.consumer &&
    stored.channel === sample.channel &&
    stored.operation === sample.operation &&
    (sample.schemaVersion === 3
      ? stored.candidateCommit === sample.candidateCommit &&
        stored.expectedCoreVersion === sample.expectedCoreVersion &&
        stored.expectedCoreAbiVersion === sample.expectedCoreAbiVersion &&
        stored.expectedCoreSourceSha256 === sample.expectedCoreSourceSha256 &&
        stored.loadedCoreVersion === sample.loadedCoreVersion &&
        stored.loadedCoreAbiVersion === sample.loadedCoreAbiVersion &&
        stored.loadedCoreSourceSha256 === sample.loadedCoreSourceSha256
      : stored.coreVersion === sample.coreVersion) &&
    stored.observedAt.toMillis() === Date.parse(sample.observedAt) &&
    stored.outcome === sample.outcome &&
    stored.mismatchCategory === sample.mismatchCategory &&
    stored.legacyMicros === sample.legacyMicros &&
    stored.rustMicros === sample.rustMicros
  );
}

export function domainCoreShadowStore(firestore: Firestore): DomainCoreShadowStore {
  return {
    doc: (path) => ({ path }),
    runTransaction: (update) =>
      firestore.runTransaction((transaction) =>
        update({
          get: async (reference) => {
            const snapshot = await transaction.get(firestore.doc(reference.path));
            return { exists: snapshot.exists, data: () => snapshot.data() };
          },
          create: (reference, data) => {
            transaction.create(firestore.doc(reference.path), data);
          },
        }),
      ),
  };
}

export async function persistDomainCoreShadowSamples(
  firestore: DomainCoreShadowStore,
  samples: DomainCoreShadowSample[],
  nowMillis: number,
): Promise<{ accepted: number; duplicates: number }> {
  return firestore.runTransaction(async (transaction) => {
    const refs = samples.map((sample) => firestore.doc(`${DOMAIN_CORE_SHADOW_COLLECTION}/${sample.sampleId}`));
    const snapshots = await Promise.all(refs.map((ref) => transaction.get(ref)));
    let accepted = 0;
    let duplicates = 0;
    for (const [index, ref] of refs.entries()) {
      const sample = samples[index];
      const snapshot = snapshots[index];
      if (!sample || !snapshot) throw new Error("Shadow evidence transaction lost batch alignment.");
      if (snapshot.exists) {
        if (!storedDomainCoreShadowSampleMatches(snapshot.data(), sample)) {
          throw new HttpsError(
            "already-exists",
            `sampleId ${sample.sampleId} conflicts with immutable stored evidence.`,
          );
        }
        duplicates += 1;
      } else {
        transaction.create(ref, storedDomainCoreShadowSample(sample, nowMillis));
        accepted += 1;
      }
    }
    return { accepted, duplicates };
  });
}
