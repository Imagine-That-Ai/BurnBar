import { HttpsError } from "firebase-functions/v2/https";
import { Timestamp, type Firestore } from "firebase-admin/firestore";

import { isRecord } from "./guards.js";

const DOMAIN_CORE_SHADOW_SAMPLE_SCHEMA_VERSION = 1;
const DOMAIN_CORE_SHADOW_MAX_BATCH = 100;
export const DOMAIN_CORE_SHADOW_RETENTION_MS = 60 * 24 * 60 * 60 * 1000;
const DOMAIN_CORE_SHADOW_MAX_AGE_MS = 31 * 24 * 60 * 60 * 1000;
const DOMAIN_CORE_SHADOW_FUTURE_SKEW_MS = 5 * 60 * 1000;
const DOMAIN_CORE_SHADOW_COLLECTION = "domain_core_shadow_samples";

const SAMPLE_KEYS = [
  "channel",
  "consumer",
  "coreVersion",
  "domain",
  "legacyMicros",
  "mismatchCategory",
  "observedAt",
  "operation",
  "outcome",
  "rustMicros",
  "sampleId",
  "schemaVersion",
] as const;
const REQUEST_KEYS = ["samples"] as const;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const CORE_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/u;
const UTC_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/u;

type DomainCoreShadowConsumer = "apple" | "windows";
type DomainCoreShadowChannel = "internal" | "beta";
type DomainCoreShadowOperation = "claude_quota" | "codex_quota" | "cursor_quota" | "anthropic_quota";
type DomainCoreShadowOutcome = "match" | "mismatch";
type DomainCoreShadowMismatchCategory = "result_mismatch" | "native_unavailable" | "native_error" | "invalid_result";

interface DomainCoreShadowSampleV1 {
  schemaVersion: 1;
  sampleId: string;
  domain: "quota";
  consumer: DomainCoreShadowConsumer;
  channel: DomainCoreShadowChannel;
  operation: DomainCoreShadowOperation;
  coreVersion: string;
  observedAt: string;
  outcome: DomainCoreShadowOutcome;
  mismatchCategory: DomainCoreShadowMismatchCategory | null;
  legacyMicros: number;
  rustMicros: number;
}

interface DomainCoreShadowDocumentReference {
  path: string;
}

interface DomainCoreShadowDocumentSnapshot {
  exists: boolean;
  data(): unknown;
}

interface DomainCoreShadowTransaction {
  get(reference: DomainCoreShadowDocumentReference): Promise<DomainCoreShadowDocumentSnapshot>;
  create(reference: DomainCoreShadowDocumentReference, data: ReturnType<typeof storedDomainCoreShadowSample>): void;
}

interface DomainCoreShadowStore {
  doc(path: string): DomainCoreShadowDocumentReference;
  runTransaction<T>(update: (transaction: DomainCoreShadowTransaction) => Promise<T>): Promise<T>;
}

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
): { outcome: DomainCoreShadowOutcome; mismatchCategory: DomainCoreShadowMismatchCategory | null } {
  if (outcome !== "match" && outcome !== "mismatch") {
    throw new HttpsError("invalid-argument", `samples[${index}].outcome is invalid.`);
  }
  if (outcome === "match" && mismatchCategory === null) {
    return { outcome, mismatchCategory };
  }
  if (outcome === "mismatch" && isMismatchCategory(mismatchCategory)) {
    return { outcome, mismatchCategory };
  }
  throw new HttpsError("invalid-argument", `samples[${index}].mismatchCategory is inconsistent.`);
}

function parseSample(raw: unknown, nowMillis: number, index: number): DomainCoreShadowSampleV1 {
  if (!isRecord(raw)) throw new HttpsError("invalid-argument", `samples[${index}] must be an object.`);
  exactKeys(raw, SAMPLE_KEYS, `samples[${index}]`);
  if (raw.schemaVersion !== DOMAIN_CORE_SHADOW_SAMPLE_SCHEMA_VERSION || raw.domain !== "quota") {
    throw new HttpsError("invalid-argument", `samples[${index}] has an unsupported schema or domain.`);
  }
  if (typeof raw.sampleId !== "string" || !UUID_V4.test(raw.sampleId)) {
    throw new HttpsError("invalid-argument", `samples[${index}].sampleId is invalid.`);
  }
  if (!isConsumer(raw.consumer)) {
    throw new HttpsError("invalid-argument", `samples[${index}].consumer is invalid.`);
  }
  if (!isChannel(raw.channel)) {
    throw new HttpsError("permission-denied", "Shadow evidence is accepted only from internal or beta channels.");
  }
  if (!isOperation(raw.operation)) {
    throw new HttpsError("invalid-argument", `samples[${index}].operation is invalid.`);
  }
  if (typeof raw.coreVersion !== "string" || raw.coreVersion.length > 64 || !CORE_VERSION.test(raw.coreVersion)) {
    throw new HttpsError("invalid-argument", `samples[${index}].coreVersion is invalid.`);
  }
  const observedAt = parseObservedAt(raw.observedAt, nowMillis, index);
  const outcome = parseOutcome(raw.outcome, raw.mismatchCategory, index);

  return {
    schemaVersion: 1,
    sampleId: raw.sampleId,
    domain: "quota",
    consumer: raw.consumer,
    channel: raw.channel,
    operation: raw.operation,
    coreVersion: raw.coreVersion,
    observedAt: observedAt.iso,
    outcome: outcome.outcome,
    mismatchCategory: outcome.mismatchCategory,
    legacyMicros: boundedMicros(raw.legacyMicros, `samples[${index}].legacyMicros`),
    rustMicros: boundedMicros(raw.rustMicros, `samples[${index}].rustMicros`),
  };
}

export function parseDomainCoreShadowSampleRequest(raw: unknown, nowMillis = Date.now()): DomainCoreShadowSampleV1[] {
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
  samples: DomainCoreShadowSampleV1[],
): void {
  const claimedChannel = token.domainCoreShadowChannel;
  if (
    (claimedChannel !== "internal" && claimedChannel !== "beta") ||
    samples.some((sample) => sample.channel !== claimedChannel)
  ) {
    throw new HttpsError(
      "permission-denied",
      "This account is not enrolled for the submitted shadow-evidence channel.",
    );
  }
}

export function storedDomainCoreShadowSample(sample: DomainCoreShadowSampleV1, nowMillis: number) {
  return {
    schemaVersion: sample.schemaVersion,
    sampleId: sample.sampleId,
    domain: sample.domain,
    consumer: sample.consumer,
    channel: sample.channel,
    operation: sample.operation,
    coreVersion: sample.coreVersion,
    observedAt: Timestamp.fromDate(new Date(sample.observedAt)),
    outcome: sample.outcome,
    mismatchCategory: sample.mismatchCategory,
    legacyMicros: sample.legacyMicros,
    rustMicros: sample.rustMicros,
    receivedAt: Timestamp.fromMillis(nowMillis),
    expireAt: Timestamp.fromMillis(nowMillis + DOMAIN_CORE_SHADOW_RETENTION_MS),
  };
}

export function storedDomainCoreShadowSampleMatches(stored: unknown, sample: DomainCoreShadowSampleV1): boolean {
  if (!isRecord(stored) || !(stored.observedAt instanceof Timestamp)) return false;
  return (
    stored.schemaVersion === sample.schemaVersion &&
    stored.sampleId === sample.sampleId &&
    stored.domain === sample.domain &&
    stored.consumer === sample.consumer &&
    stored.channel === sample.channel &&
    stored.operation === sample.operation &&
    stored.coreVersion === sample.coreVersion &&
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
  samples: DomainCoreShadowSampleV1[],
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
