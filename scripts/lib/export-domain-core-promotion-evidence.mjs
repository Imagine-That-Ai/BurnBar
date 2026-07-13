const STORED_KEYS = new Set([
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
const CONSUMERS = new Set(["apple", "windows"]);
const CHANNELS = new Set(["internal", "beta"]);
const OPERATIONS = new Set([
  "claude_quota",
  "codex_quota",
  "cursor_quota",
  "anthropic_quota",
]);
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const VERSION = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/u;
const MISMATCH_CATEGORIES = new Set([
  "result_mismatch",
  "native_unavailable",
  "native_error",
  "invalid_result",
]);
const GIT_REVISION = /^[0-9a-f]{40}$/u;

function timestamp(value, label) {
  const date = typeof value?.toDate === "function" ? value.toDate() : new Date(value);
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) {
    throw new Error(`${label} must be a timestamp`);
  }
  return date.toISOString();
}

function exactKeys(record, label) {
  if (record === null || typeof record !== "object" || Array.isArray(record)) {
    throw new Error(`${label} must be an object`);
  }
  const keys = Object.keys(record);
  if (keys.length !== STORED_KEYS.size || keys.some((key) => !STORED_KEYS.has(key))) {
    throw new Error(`${label} has an invalid field set`);
  }
}

export function parseStoredDomainCoreShadowSample(record, index = 0) {
  const label = `records[${index}]`;
  exactKeys(record, label);
  if (record.schemaVersion !== 1 || record.domain !== "quota") {
    throw new Error(`${label} has an unsupported schema or domain`);
  }
  if (typeof record.sampleId !== "string" || !UUID_V4.test(record.sampleId)) {
    throw new Error(`${label}.sampleId is invalid`);
  }
  if (!CONSUMERS.has(record.consumer) || !CHANNELS.has(record.channel)) {
    throw new Error(`${label} has an invalid consumer or channel`);
  }
  if (!OPERATIONS.has(record.operation) || !VERSION.test(record.coreVersion)) {
    throw new Error(`${label} has an invalid operation or coreVersion`);
  }
  if (record.outcome !== "match" && record.outcome !== "mismatch") {
    throw new Error(`${label}.outcome is invalid`);
  }
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
  const generatedAt = timestamp(options.generatedAt, "options.generatedAt");
  const startedAt = timestamp(options.startedAt, "options.startedAt");
  const endedAt = timestamp(options.endedAt, "options.endedAt");
  if (Date.parse(endedAt) <= Date.parse(startedAt) || Date.parse(generatedAt) < Date.parse(endedAt)) {
    throw new Error("The observation window must end after it starts and no later than generatedAt");
  }
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
      record.channel === options.channel &&
      record.coreVersion === options.coreVersion &&
      Date.parse(record.observedAt) >= Date.parse(startedAt) &&
      Date.parse(record.observedAt) <= Date.parse(endedAt),
  );

  const windows = [...CONSUMERS].map((consumer) => {
    const samples = selected.filter((record) => record.consumer === consumer);
    if (samples.length === 0) throw new Error(`No ${consumer} samples matched the requested window`);
    const observedMillis = samples.map((record) => Date.parse(record.observedAt));
    const consumerStartedAt = new Date(Math.min(...observedMillis)).toISOString();
    const consumerEndedAt = new Date(Math.max(...observedMillis)).toISOString();
    if (consumerStartedAt === consumerEndedAt) {
      throw new Error(`${consumer} samples do not span a measurable observation window`);
    }
    const mismatchCounts = new Map();
    for (const sample of samples) {
      if (sample.mismatchCategory !== null) {
        mismatchCounts.set(sample.mismatchCategory, (mismatchCounts.get(sample.mismatchCategory) ?? 0) + 1);
      }
    }
    return {
      consumer,
      channel: options.channel,
      startedAt: consumerStartedAt,
      endedAt: consumerEndedAt,
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
    schemaVersion: 1,
    domain: "quota",
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
