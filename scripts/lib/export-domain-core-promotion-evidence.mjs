import {
  DOMAIN_CORE_QUOTA_OPERATION_SLICE,
  isValidDomainSliceConsumer,
  requiredCoverageForDomain,
} from "./domain-core-evidence-contract.mjs";

const STORED_V1_KEYS = new Set([
  "schemaVersion", "sampleId", "domain", "consumer", "channel", "operation", "coreVersion",
  "observedAt", "outcome", "mismatchCategory", "legacyMicros", "rustMicros", "receivedAt", "expireAt",
]);
const STORED_V2_KEYS = new Set([...STORED_V1_KEYS, "slice"]);
const CHANNELS = new Set(["internal", "beta"]);
const V1_CONSUMERS = new Set(["apple", "windows"]);
const V1_OPERATIONS = new Set(Object.keys(DOMAIN_CORE_QUOTA_OPERATION_SLICE));
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const IDENTIFIER = /^[a-z][a-z0-9_.-]{0,63}$/u;
const VERSION = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/u;
const MISMATCH_CATEGORIES = new Set(["result_mismatch", "native_unavailable", "native_error", "invalid_result"]);
const GIT_REVISION = /^[0-9a-f]{40}$/u;

function timestamp(value, label) {
  const date = typeof value?.toDate === "function" ? value.toDate() : new Date(value);
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) throw new Error(`${label} must be a timestamp`);
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

function validateCommon(record, label) {
  if (typeof record.sampleId !== "string" || !UUID_V4.test(record.sampleId)) {
    throw new Error(`${label}.sampleId is invalid`);
  }
  if (!CHANNELS.has(record.channel)) throw new Error(`${label}.channel is invalid`);
  if (typeof record.operation !== "string" || !IDENTIFIER.test(record.operation) || !VERSION.test(record.coreVersion)) {
    throw new Error(`${label} has an invalid operation or coreVersion`);
  }
  if (record.outcome !== "match" && record.outcome !== "mismatch") throw new Error(`${label}.outcome is invalid`);
  if (
    (record.outcome === "match" && record.mismatchCategory !== null) ||
    (record.outcome === "mismatch" && !MISMATCH_CATEGORIES.has(record.mismatchCategory))
  ) {
    throw new Error(`${label}.mismatchCategory is inconsistent`);
  }
  for (const field of ["legacyMicros", "rustMicros"]) {
    if (!Number.isSafeInteger(record[field]) || record[field] < 0 || record[field] > 600_000_000) {
      throw new Error(`${label}.${field} is invalid`);
    }
  }
}

export function parseStoredDomainCoreShadowSample(record, index = 0) {
  const label = `records[${index}]`;
  if (record?.schemaVersion === 1) {
    exactKeys(record, STORED_V1_KEYS, label);
    validateCommon(record, label);
    if (record.domain !== "quota" || !V1_CONSUMERS.has(record.consumer) || !V1_OPERATIONS.has(record.operation)) {
      throw new Error(`${label} has an unsupported v1 identity`);
    }
  } else if (record?.schemaVersion === 2) {
    exactKeys(record, STORED_V2_KEYS, label);
    validateCommon(record, label);
    if (
      typeof record.domain !== "string" ||
      typeof record.slice !== "string" ||
      typeof record.consumer !== "string" ||
      !isValidDomainSliceConsumer(record.domain, record.slice, record.consumer)
    ) {
      throw new Error(`${label} has an invalid domain, slice, or consumer`);
    }
    if (record.domain === "quota" && DOMAIN_CORE_QUOTA_OPERATION_SLICE[record.operation] !== record.slice) {
      throw new Error(`${label} has an inconsistent quota operation and slice`);
    }
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
  if (values.length === 0) throw new Error("Cannot calculate p95 for an empty sample set");
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.ceil(sorted.length * 0.95) - 1];
}

export function buildDomainCorePromotionEvidence(records, options) {
  const domain = options.domain;
  const requiredCoverage = requiredCoverageForDomain(domain);
  if (requiredCoverage.length === 0) throw new Error(`Unsupported --domain ${domain ?? "<missing>"}`);
  const generatedAt = timestamp(options.generatedAt, "options.generatedAt");
  const startedAt = timestamp(options.startedAt, "options.startedAt");
  const endedAt = timestamp(options.endedAt, "options.endedAt");
  if (Date.parse(endedAt) <= Date.parse(startedAt) || Date.parse(generatedAt) < Date.parse(endedAt)) {
    throw new Error("The observation window must end after it starts and no later than generatedAt");
  }
  if (!CHANNELS.has(options.channel)) throw new Error("channel must be internal or beta");
  if (!VERSION.test(options.coreVersion)) throw new Error("coreVersion must be a semantic version");
  if (!GIT_REVISION.test(options.queryRevision)) throw new Error("queryRevision must be a full lowercase Git SHA");
  const source = new URL(options.sourceUri);
  if (source.protocol !== "https:" || source.username || source.password || source.search || source.hash) {
    throw new Error("sourceUri must be credential-free HTTPS without query or fragment");
  }
  const parsed = records.map(parseStoredDomainCoreShadowSample);
  const ids = new Set(parsed.map((record) => record.sampleId));
  if (ids.size !== parsed.length) throw new Error("records contains duplicate sampleId values");
  const selected = parsed.filter(
    (record) =>
      record.schemaVersion === 2 &&
      record.domain === domain &&
      record.channel === options.channel &&
      record.coreVersion === options.coreVersion &&
      Date.parse(record.observedAt) >= Date.parse(startedAt) &&
      Date.parse(record.observedAt) <= Date.parse(endedAt),
  );

  const windows = requiredCoverage.map(({ slice, consumer }) => {
    const samples = selected.filter((record) => record.slice === slice && record.consumer === consumer);
    if (samples.length === 0) throw new Error(`No ${domain}/${slice}/${consumer} V2 samples matched the requested window`);
    const observedMillis = samples.map((record) => Date.parse(record.observedAt));
    const coverageStartedAt = new Date(Math.min(...observedMillis)).toISOString();
    const coverageEndedAt = new Date(Math.max(...observedMillis)).toISOString();
    if (coverageStartedAt === coverageEndedAt) {
      throw new Error(`${domain}/${slice}/${consumer} samples do not span a measurable observation window`);
    }
    const mismatchCounts = new Map();
    for (const sample of samples) {
      if (sample.mismatchCategory !== null) {
        mismatchCounts.set(sample.mismatchCategory, (mismatchCounts.get(sample.mismatchCategory) ?? 0) + 1);
      }
    }
    return {
      slice,
      consumer,
      channel: options.channel,
      startedAt: coverageStartedAt,
      endedAt: coverageEndedAt,
      sampleCount: samples.length,
      mismatches: [...mismatchCounts.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([category, count]) => ({ category, count, resolution: "unexplained" })),
      latency: {
        sampleCount: samples.length,
        legacyP95Micros: nearestRankP95(samples.map((record) => record.legacyMicros)),
        rustP95Micros: nearestRankP95(samples.map((record) => record.rustMicros)),
      },
    };
  });

  return {
    schemaVersion: 2,
    domain,
    coreVersion: options.coreVersion,
    generatedAt,
    provenance: {
      collector: "domain-core-shadow-exporter",
      queryRevision: options.queryRevision,
      sourceUri: options.sourceUri,
    },
    windows,
  };
}
