import { onAuthStateChanged } from "firebase/auth";
import { httpsCallable } from "firebase/functions";
import { auth, functions } from "./firebaseClient";
import {
  resolveDomainCoreCandidateIdentity,
  resolveDomainCoreEvidenceChannel,
  type DomainCoreCandidateIdentity,
} from "./domainCoreBuildProfile";
import type { CloudVaultShadowComparison } from "./domainCoreCloudVault";

const SAMPLE_STORAGE_KEY_PREFIX = "openburnbar.domain-core-shadow.v3.sample.";
// Legacy shared V2/V3 keys are intentionally opaque. Only their deployed writers may drain them.
const MAX_SAMPLES = 800;
const MAX_GLOBAL_SAMPLES = 3_200;
const BATCH_SIZE = 100;
const MAX_SAMPLE_AGE_MS = 31 * 24 * 60 * 60 * 1_000;
const FUTURE_SKEW_MS = 5 * 60 * 1_000;
const CANONICAL_CORE_VERSION =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const OPERATION = /^[a-z][a-z0-9_.-]{0,63}$/u;
const UUID_V4 =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const UTC_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/u;
const SAMPLE_KEYS = new Set([
  "candidateCommit",
  "channel",
  "consumer",
  "domain",
  "expectedCoreAbiVersion",
  "expectedCoreSourceSha256",
  "expectedCoreVersion",
  "legacyMicros",
  "loadedCoreAbiVersion",
  "loadedCoreSourceSha256",
  "loadedCoreVersion",
  "mismatchCategory",
  "observedAt",
  "operation",
  "outcome",
  "rustMicros",
  "sampleId",
  "schemaVersion",
  "slice",
]);
const CONSOLE_OPERATION_SLICES = new Map<
  string,
  CloudVaultShadowComparison["slice"]
>(
  Object.entries({
    foundation:
      "aad_v1 aad_v2 resolve_aad sha256 sha256_hex vault_key_id blob_integrity session_body session_chunk project_memory_content blob_integrity_hash session_body_hash session_chunk_hash project_memory_content_hash keyed_hash_blob_integrity expected_session_body_hash expected_session_body_hash_v0 expected_session_body_hash_v1 expected_session_body_hash_v2 base64_encode base64_decode base64_decode_strict p256_validate_public_key initialize cloudvault_aad_v1 cloudvault_aad_v2 cloudvault_resolve_aad cloudvault_sha256 cloudvault_key_id cloudvault_keyed_hash cloudvault_base64_encode cloudvault_base64_decode cloudvault_validate_p256_public_key",
    aes: "aes_gcm_seal_detached aes_gcm_seal_combined aes_gcm_open_detached aes_gcm_open_text_detached aes_gcm_open_combined aes_seal_detached aes_seal_combined aes_open_detached aes_open_text aes_open_combined cloudvault_aes_seal_detached cloudvault_aes_seal_combined cloudvault_aes_open_detached cloudvault_aes_open_text cloudvault_aes_open_combined",
    escrow:
      "escrow_wrapping_key escrow_assemble_wire escrow_split_wire escrow_seal escrow_open cloudvault_escrow_split_wire cloudvault_escrow_seal cloudvault_escrow_open",
    "pensieve-vectors":
      "pensieve_vector_cloak pensieve_l2_normalize pensieve_deterministic_embed pensieve_deterministic_embed_and_cloak",
  }).flatMap(([slice, operations]) =>
    operations
      .split(" ")
      .map((operation) => [
        operation,
        slice as CloudVaultShadowComparison["slice"],
      ]),
  ),
);

type ConsoleShadowMismatchCategory =
  | "result_mismatch"
  | "native_unavailable"
  | "native_error"
  | "loaded_identity_mismatch";

interface ConsoleShadowSampleV3 {
  schemaVersion: 3;
  sampleId: string;
  channel: "internal" | "beta";
  observedAt: string;
  domain: "cloudvault";
  slice: CloudVaultShadowComparison["slice"];
  consumer: "console";
  operation: string;
  candidateCommit: string;
  expectedCoreVersion: string;
  expectedCoreAbiVersion: number;
  expectedCoreSourceSha256: string;
  loadedCoreVersion: string | null;
  loadedCoreAbiVersion: number | null;
  loadedCoreSourceSha256: string | null;
  outcome: "match" | "mismatch";
  mismatchCategory: ConsoleShadowMismatchCategory | null;
  legacyMicros: number;
  rustMicros: number;
}

interface EvidenceProfile {
  channel: "internal" | "beta";
  candidateIdentity: DomainCoreCandidateIdentity;
}

let timer: ReturnType<typeof setTimeout> | undefined;
let maintenanceTimer: ReturnType<typeof setTimeout> | undefined;
const maintenanceProfiles = new Map<string, EvidenceProfile>();
let flushing = false;
let authListenerInstalled = false;
let writerID: string | undefined;

export function recordConsoleCloudVaultShadowComparison(
  comparison: CloudVaultShadowComparison,
): void {
  if (typeof window === "undefined") return;
  try {
    const profile = resolveEvidenceProfile();
    if (!profile) return;
    const sample = buildConsoleShadowSampleV3(comparison, profile);
    if (!sample) return;

    if (!writeSample(profile, sample)) return;
    scheduleMaintenance(profile);
    installAuthListener();
    scheduleFlush(5_000);
  } catch {
    // Evidence is diagnostic. Browser storage/auth failures cannot change product behavior.
  }
}

function buildConsoleShadowSampleV3(
  comparison: CloudVaultShadowComparison,
  profile: EvidenceProfile,
): ConsoleShadowSampleV3 | undefined {
  if (
    !OPERATION.test(comparison.operation) ||
    CONSOLE_OPERATION_SLICES.get(comparison.operation) !== comparison.slice ||
    !boundedMicros(comparison.legacyMicros) ||
    !boundedMicros(comparison.rustMicros)
  ) {
    return undefined;
  }
  const loadedValues = [
    comparison.loadedCoreVersion,
    comparison.loadedCoreAbiVersion,
    comparison.loadedCoreSourceSha256,
  ];
  const loadedIsNull = loadedValues.every((value) => value === null);
  const loadedIsPresent = loadedValues.every((value) => value !== null);
  if (!loadedIsNull && !loadedIsPresent) return undefined;
  if (
    loadedIsPresent &&
    (!isCanonicalCoreVersion(comparison.loadedCoreVersion) ||
      !isCoreAbiVersion(comparison.loadedCoreAbiVersion) ||
      typeof comparison.loadedCoreSourceSha256 !== "string" ||
      !SHA256.test(comparison.loadedCoreSourceSha256))
  ) {
    return undefined;
  }
  const expected = profile.candidateIdentity;
  const loadedMatchesExpected =
    comparison.loadedCoreVersion === expected.coreVersion &&
    comparison.loadedCoreAbiVersion === expected.abiVersion &&
    comparison.loadedCoreSourceSha256 === expected.sourceSha256;
  const loadedIdentityMismatch = loadedIsPresent && !loadedMatchesExpected;
  const outcome =
    loadedIsNull || loadedIdentityMismatch ? "mismatch" : comparison.outcome;
  const mismatchCategory: ConsoleShadowMismatchCategory | null = loadedIsNull
    ? "native_unavailable"
    : loadedIdentityMismatch
      ? "loaded_identity_mismatch"
      : comparison.mismatchCategory === "native_unavailable"
        ? "native_error"
        : comparison.mismatchCategory;
  if ((outcome === "match") !== (mismatchCategory === null)) return undefined;

  return {
    schemaVersion: 3,
    sampleId: crypto.randomUUID(),
    channel: profile.channel,
    observedAt: new Date().toISOString(),
    domain: comparison.domain,
    slice: comparison.slice,
    consumer: comparison.consumer,
    operation: comparison.operation,
    candidateCommit: expected.candidateCommit,
    expectedCoreVersion: expected.coreVersion,
    expectedCoreAbiVersion: expected.abiVersion,
    expectedCoreSourceSha256: expected.sourceSha256,
    loadedCoreVersion: comparison.loadedCoreVersion,
    loadedCoreAbiVersion: comparison.loadedCoreAbiVersion,
    loadedCoreSourceSha256: comparison.loadedCoreSourceSha256,
    outcome,
    mismatchCategory,
    legacyMicros: comparison.legacyMicros,
    rustMicros: comparison.rustMicros,
  };
}

function resolveEvidenceProfile(): EvidenceProfile | undefined {
  const channel = resolveDomainCoreEvidenceChannel();
  const candidateIdentity = resolveDomainCoreCandidateIdentity();
  return channel && candidateIdentity
    ? { channel, candidateIdentity }
    : undefined;
}

function isCanonicalCoreVersion(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length <= 64 &&
    CANONICAL_CORE_VERSION.test(value)
  );
}

function isCoreAbiVersion(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= 1 &&
    value <= 0xffff_ffff
  );
}

function boundedMicros(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0 && value <= 600_000_000;
}

function candidateNamespace(profile: EvidenceProfile): string {
  const candidate = profile.candidateIdentity;
  return `${profile.channel}.${candidate.candidateCommit}.${encodeURIComponent(candidate.coreVersion)}.${candidate.abiVersion}.${candidate.sourceSha256}`;
}

function candidateSamplePrefix(profile: EvidenceProfile): string {
  return `${SAMPLE_STORAGE_KEY_PREFIX}${candidateNamespace(profile)}.`;
}

function currentWriterID(): string {
  writerID ??= crypto.randomUUID();
  return writerID;
}

function sampleStorageKey(
  profile: EvidenceProfile,
  sample: ConsoleShadowSampleV3,
): string {
  return `${candidateSamplePrefix(profile)}${currentWriterID()}.${sample.sampleId}`;
}

type StoredSampleRead =
  | { state: "valid"; key: string; sample: ConsoleShadowSampleV3 }
  | { state: "invalid" }
  | { state: "unreadable" };

function readStoredSample(
  key: string,
  nowMillis = Date.now(),
): StoredSampleRead {
  let encoded: string | null;
  try {
    encoded = localStorage.getItem(key);
  } catch {
    return { state: "unreadable" };
  }
  if (encoded === null) return { state: "invalid" };
  try {
    const decoded: unknown = JSON.parse(encoded);
    return isStoredSampleKey(decoded, key, nowMillis)
      ? { state: "valid", key, sample: decoded }
      : { state: "invalid" };
  } catch {
    return { state: "invalid" };
  }
}

function writeSample(
  profile: EvidenceProfile,
  sample: ConsoleShadowSampleV3,
): boolean {
  return safeSetItem(sampleStorageKey(profile, sample), JSON.stringify(sample));
}

function installAuthListener(): void {
  if (authListenerInstalled) return;
  authListenerInstalled = true;
  onAuthStateChanged(auth(), (user) => {
    if (user) scheduleFlush(0);
  });
}

function scheduleFlush(delayMillis: number): void {
  if (timer !== undefined) return;
  timer = setTimeout(() => {
    timer = undefined;
    void flush();
  }, delayMillis);
}

function scheduleMaintenance(profile: EvidenceProfile): void {
  maintenanceProfiles.set(candidateNamespace(profile), profile);
  if (maintenanceTimer !== undefined) return;
  maintenanceTimer = setTimeout(runScheduledMaintenance, 0);
}

function runScheduledMaintenance(): void {
  if (maintenanceTimer !== undefined) clearTimeout(maintenanceTimer);
  maintenanceTimer = undefined;
  const profiles = [...maintenanceProfiles.values()];
  maintenanceProfiles.clear();
  if (profiles.length === 0) return;
  try {
    maintainStorage(profiles);
  } catch {
    // Maintenance is diagnostic and retried by the next record/read/flush.
  }
}

async function flush(): Promise<void> {
  if (flushing) return;
  const profile = resolveEvidenceProfile();
  if (!profile) return;
  if (!auth().currentUser) return;
  flushing = true;
  try {
    const entries = readSamplesForProfile(profile);
    for (let offset = 0; offset < entries.length; offset += BATCH_SIZE) {
      const batch = entries.slice(offset, offset + BATCH_SIZE);
      const callable = httpsCallable<
        { samples: ConsoleShadowSampleV3[] },
        { accepted: number; duplicates: number }
      >(functions(), "submitDomainCoreShadowSamples");
      const response = await callable({
        samples: batch.map(({ sample }) => sample),
      });
      if (!validAcknowledgement(response.data, batch.length)) {
        throw new Error("Invalid domain-core evidence acknowledgement");
      }
      if (!batch.every(({ keys }) => keys.every(safeRemoveItem))) {
        throw new Error("Could not remove acknowledged domain-core evidence");
      }
    }
  } catch {
    scheduleFlush(30_000);
  } finally {
    flushing = false;
  }
}

function readSamplesForProfile(
  profile: EvidenceProfile,
): Array<{ sample: ConsoleShadowSampleV3; keys: string[] }> {
  maintenanceProfiles.set(candidateNamespace(profile), profile);
  runScheduledMaintenance();
  const samples = new Map<
    string,
    { sample: ConsoleShadowSampleV3; keys: string[]; canonicalBytes: string }
  >();
  const conflictingSampleIDs = new Set<string>();
  for (const key of storageKeys(candidateSamplePrefix(profile))) {
    const result = readStoredSample(key);
    if (result.state !== "valid") continue;
    if (conflictingSampleIDs.has(result.sample.sampleId)) {
      safeRemoveItem(key);
      continue;
    }
    const canonicalBytes = canonicalSampleBytes(result.sample);
    const existing = samples.get(result.sample.sampleId);
    if (!existing) {
      samples.set(result.sample.sampleId, {
        sample: result.sample,
        keys: [key],
        canonicalBytes,
      });
    } else if (existing.canonicalBytes === canonicalBytes) {
      existing.keys.push(key);
    } else {
      for (const conflictingKey of [...existing.keys, key]) {
        safeRemoveItem(conflictingKey);
      }
      samples.delete(result.sample.sampleId);
      conflictingSampleIDs.add(result.sample.sampleId);
    }
  }
  return [...samples.values()].sort(compareStoredSamples);
}

function canonicalSampleBytes(sample: ConsoleShadowSampleV3): string {
  return JSON.stringify(
    Object.fromEntries(
      [...SAMPLE_KEYS]
        .sort((left, right) => left.localeCompare(right))
        .map((key) => [key, sample[key as keyof ConsoleShadowSampleV3]]),
    ),
  );
}

function validAcknowledgement(
  value: { accepted: number; duplicates: number },
  batchLength: number,
): boolean {
  return (
    Number.isSafeInteger(value.accepted) &&
    Number.isSafeInteger(value.duplicates) &&
    value.accepted >= 0 &&
    value.duplicates >= 0 &&
    value.accepted <= batchLength &&
    value.duplicates <= batchLength &&
    value.accepted + value.duplicates === batchLength
  );
}

function storageKeys(prefix: string): string[] {
  const keys: string[] = [];
  try {
    for (let index = 0; index < localStorage.length; index += 1) {
      const key = localStorage.key(index);
      if (key?.startsWith(prefix)) keys.push(key);
    }
  } catch {
    return [];
  }
  return keys;
}

function maintainStorage(profiles: EvidenceProfile[]): void {
  const nowMillis = Date.now();
  const valid: Array<{ key: string; sample: ConsoleShadowSampleV3 }> = [];
  for (const key of storageKeys(SAMPLE_STORAGE_KEY_PREFIX)) {
    const result = readStoredSample(key, nowMillis);
    if (result.state === "invalid") safeRemoveItem(key);
    else if (result.state === "valid") valid.push(result);
  }
  pruneOldest(valid, MAX_GLOBAL_SAMPLES);
  for (const profile of profiles) {
    pruneOldest(
      valid.filter(({ key }) => key.startsWith(candidateSamplePrefix(profile))),
      MAX_SAMPLES,
    );
  }
}

function pruneOldest(
  entries: Array<{ key: string; sample: ConsoleShadowSampleV3 }>,
  maximum: number,
): void {
  if (entries.length <= maximum) return;
  entries.sort(compareStoredSamples);
  for (const { key } of entries.slice(0, entries.length - maximum)) {
    safeRemoveItem(key);
  }
}

function compareStoredSamples(
  left: { key?: string; sample: ConsoleShadowSampleV3 },
  right: { key?: string; sample: ConsoleShadowSampleV3 },
): number {
  return (
    Date.parse(left.sample.observedAt) - Date.parse(right.sample.observedAt) ||
    (left.key ?? left.sample.sampleId).localeCompare(
      right.key ?? right.sample.sampleId,
    )
  );
}

function safeRemoveItem(key: string): boolean {
  try {
    localStorage.removeItem(key);
    return true;
  } catch {
    return false;
  }
}

function safeSetItem(key: string, value: string): boolean {
  try {
    localStorage.setItem(key, value);
    return true;
  } catch {
    return false;
  }
}

function isStoredSampleKey(
  value: unknown,
  key: string,
  nowMillis: number,
): value is ConsoleShadowSampleV3 {
  if (!sampleRecordBelongsToKey(value, key)) return false;
  return isStoredSampleV3(
    value,
    {
      channel: value.channel,
      candidateIdentity: {
        candidateCommit: value.candidateCommit,
        coreVersion: value.expectedCoreVersion,
        abiVersion: value.expectedCoreAbiVersion,
        sourceSha256: value.expectedCoreSourceSha256,
      },
    },
    nowMillis,
  );
}

function sampleRecordBelongsToKey(
  value: unknown,
  key: string,
): value is Record<string, unknown> & {
  channel: "internal" | "beta";
  candidateCommit: string;
  expectedCoreVersion: string;
  expectedCoreAbiVersion: number;
  expectedCoreSourceSha256: string;
  observedAt: string;
} {
  if (
    !isRecord(value) ||
    (value.channel !== "internal" && value.channel !== "beta") ||
    typeof value.candidateCommit !== "string" ||
    !/^[0-9a-f]{40}$/u.test(value.candidateCommit) ||
    !isCanonicalCoreVersion(value.expectedCoreVersion) ||
    !isCoreAbiVersion(value.expectedCoreAbiVersion) ||
    typeof value.expectedCoreSourceSha256 !== "string" ||
    !SHA256.test(value.expectedCoreSourceSha256) ||
    typeof value.observedAt !== "string" ||
    !UTC_TIMESTAMP.test(value.observedAt) ||
    !Number.isFinite(Date.parse(value.observedAt))
  ) {
    return false;
  }
  const prefix = `${SAMPLE_STORAGE_KEY_PREFIX}${value.channel}.${value.candidateCommit}.${encodeURIComponent(value.expectedCoreVersion)}.${value.expectedCoreAbiVersion}.${value.expectedCoreSourceSha256}.`;
  if (!key.startsWith(prefix)) return false;
  const [writerID, sampleID, extra] = key.slice(prefix.length).split(".");
  return (
    extra === undefined &&
    UUID_V4.test(writerID ?? "") &&
    UUID_V4.test(sampleID ?? "") &&
    sampleID === value.sampleId
  );
}

function isStoredSampleV3(
  value: unknown,
  profile: EvidenceProfile,
  nowMillis = Date.now(),
): value is ConsoleShadowSampleV3 {
  if (!isRecord(value)) return false;
  const keys = Object.keys(value);
  if (
    keys.length !== SAMPLE_KEYS.size ||
    keys.some((key) => !SAMPLE_KEYS.has(key))
  )
    return false;
  const expected = profile.candidateIdentity;
  const observedMillis =
    typeof value.observedAt === "string"
      ? Date.parse(value.observedAt)
      : Number.NaN;
  if (
    value.schemaVersion !== 3 ||
    !UUID_V4.test(value.sampleId as string) ||
    value.channel !== profile.channel ||
    value.domain !== "cloudvault" ||
    value.consumer !== "console" ||
    value.candidateCommit !== expected.candidateCommit ||
    value.expectedCoreVersion !== expected.coreVersion ||
    value.expectedCoreAbiVersion !== expected.abiVersion ||
    value.expectedCoreSourceSha256 !== expected.sourceSha256 ||
    typeof value.operation !== "string" ||
    CONSOLE_OPERATION_SLICES.get(value.operation) !== value.slice ||
    typeof value.observedAt !== "string" ||
    !UTC_TIMESTAMP.test(value.observedAt) ||
    !Number.isFinite(observedMillis) ||
    observedMillis < nowMillis - MAX_SAMPLE_AGE_MS ||
    observedMillis > nowMillis + FUTURE_SKEW_MS ||
    !boundedMicros(value.legacyMicros as number) ||
    !boundedMicros(value.rustMicros as number)
  ) {
    return false;
  }
  const loadedValues = [
    value.loadedCoreVersion,
    value.loadedCoreAbiVersion,
    value.loadedCoreSourceSha256,
  ];
  const loadedIsNull = loadedValues.every((loaded) => loaded === null);
  const loadedIsPresent = loadedValues.every((loaded) => loaded !== null);
  if (!loadedIsNull && !loadedIsPresent) return false;
  if (
    loadedIsPresent &&
    (!isCanonicalCoreVersion(value.loadedCoreVersion) ||
      !isCoreAbiVersion(value.loadedCoreAbiVersion) ||
      typeof value.loadedCoreSourceSha256 !== "string" ||
      !SHA256.test(value.loadedCoreSourceSha256))
  ) {
    return false;
  }
  const loadedMatchesExpected =
    value.loadedCoreVersion === expected.coreVersion &&
    value.loadedCoreAbiVersion === expected.abiVersion &&
    value.loadedCoreSourceSha256 === expected.sourceSha256;
  if (value.outcome === "match")
    return value.mismatchCategory === null && loadedMatchesExpected;
  if (value.outcome !== "mismatch") return false;
  if (value.mismatchCategory === "native_unavailable") return loadedIsNull;
  if (value.mismatchCategory === "loaded_identity_mismatch")
    return loadedIsPresent && !loadedMatchesExpected;
  return (
    (value.mismatchCategory === "result_mismatch" ||
      value.mismatchCategory === "native_error") &&
    loadedMatchesExpected
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function clearStorageForTests(): void {
  for (let index = localStorage.length - 1; index >= 0; index -= 1) {
    const key = localStorage.key(index);
    if (key?.startsWith(SAMPLE_STORAGE_KEY_PREFIX)) {
      localStorage.removeItem(key);
    }
  }
}

export function resetConsoleShadowEvidenceForTests(): void {
  if (timer !== undefined) clearTimeout(timer);
  if (maintenanceTimer !== undefined) clearTimeout(maintenanceTimer);
  timer = undefined;
  maintenanceTimer = undefined;
  maintenanceProfiles.clear();
  flushing = false;
  authListenerInstalled = false;
  writerID = undefined;
  if (typeof localStorage !== "undefined") {
    clearStorageForTests();
  }
}

export function startNewConsoleShadowEvidenceWriterForTests(): void {
  writerID = undefined;
}

export const flushConsoleShadowEvidenceForTests = flush;
export const runConsoleShadowEvidenceMaintenanceForTests =
  runScheduledMaintenance;
export function pendingConsoleShadowEvidenceForTests(): unknown[] {
  if (typeof localStorage === "undefined") return [];
  const profile = resolveEvidenceProfile();
  return profile
    ? readSamplesForProfile(profile).map(({ sample }) => sample)
    : [];
}
