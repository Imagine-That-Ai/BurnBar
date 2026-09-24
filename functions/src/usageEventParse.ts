/**
 * @fileoverview Usage-event Firestore parser.
 *
 * Split out of `guards.ts` so that file stays under the eslint max-lines cap.
 * Uploaders write a display name in `provider` ("Claude Code") and a
 * canonical or catalog-only token in `providerID`. The rebuild must resolve
 * the AgentProvider slot without rewriting catalog-only IDs (anthropic, grok)
 * onto the display harness, or daily/account splits drift.
 */

import { SUPPORTED_PROVIDERS } from "./types.js";
import type { Provider, UsageEventDoc } from "./types.js";
import { coerceFirestoreDate, isProviderAccountStorageScope, isRecord } from "./guards.js";

const PROVIDER_VALUES: ReadonlySet<string> = new Set(SUPPORTED_PROVIDERS);

function isProvider(value: unknown): value is Provider {
  return typeof value === "string" && PROVIDER_VALUES.has(value);
}

/**
 * Uploader display names whose canonical ID keeps a dash after the spaces are
 * stripped. Everything else in the `AgentProvider` catalog normalizes
 * directly: lowercase + strip spaces/underscores/dashes (Swift
 * `persistedToken`), e.g. "Pi Agent" → "piagent", "xAI" → "xai".
 */
const DASHED_PROVIDER_ALIASES: Readonly<Record<string, Provider>> = {
  claudecode: "claude-code",
  cursoragent: "cursor-agent",
  primeagent: "prime-agent",
};

/**
 * Model-vendor / catalog IDs that are valid `providerID` values but are not
 * AgentProvider cases. A rebuild must not rewrite these onto the display
 * provider ("anthropic" → "claude-code") or daily/account splits drift.
 */
const CATALOG_ONLY_PROVIDER_IDS: ReadonlySet<string> = new Set([
  "amazon",
  "anthropic",
  "bedrock",
  "cohere",
  "google",
  "grok",
  "mistral",
  "moonshot",
  "openrouter",
  "perplexity",
  "qwen",
]);

/**
 * Normalizes a provider token the way Swift `ProviderID` does: trim,
 * lowercase, spaces/underscores/dashes collapsed so display names
 * ("Claude Code"), tokens ("claudecode"), and canonical IDs ("claude-code")
 * all resolve alike.
 */
function normalizeProviderToken(value: string): string {
  return value.trim().toLowerCase().replace(/[\s_\-]+/g, "");
}

/** Resolves one raw token (canonical ID or display name) onto the catalog. */
function resolveProviderToken(value: unknown): Provider | undefined {
  if (typeof value !== "string" || !value.trim()) return undefined;
  if (isProvider(value)) return value;
  const normalized = normalizeProviderToken(value);
  const aliased = DASHED_PROVIDER_ALIASES[normalized];
  if (aliased) return aliased;
  for (const candidate of SUPPORTED_PROVIDERS) {
    if (normalizeProviderToken(candidate) === normalized) return candidate;
  }
  return undefined;
}

/**
 * Resolves the canonical provider for a raw usage event.
 *
 * Uploaders write BOTH `provider` (display name, e.g. "Claude Code") and
 * `providerID` (canonical ID, e.g. "claude-code"). An AgentProvider
 * `providerID` wins; a catalog-only ID ("anthropic") does not steal the
 * display/harness slot. Returns undefined only when neither field is an
 * AgentProvider.
 */
function resolveUsageEventProvider(raw: Record<string, unknown>): Provider | undefined {
  // AgentProvider ID wins when it is one; a catalog-only providerID must not
  // steal the display/harness slot (or reject the event when the display name
  // is a real AgentProvider).
  return resolveProviderToken(raw.providerID) ?? resolveProviderToken(raw.provider);
}

function preservedProviderID(raw: Record<string, unknown>, fallback: Provider): string {
  if (typeof raw.providerID !== "string" || !raw.providerID.trim()) return fallback;
  const token = raw.providerID.trim();
  return resolveProviderToken(token) ?? (CATALOG_ONLY_PROVIDER_IDS.has(normalizeProviderToken(token)) ? token : fallback);
}

/** Mirrors rollup `eventDate()` precedence so legacy Firestore shapes keep parsing. */
function synthesizeRecordedAt(raw: Record<string, unknown>): string | undefined {
  if (typeof raw.recordedAt === "string" && raw.recordedAt.trim()) {
    return raw.recordedAt;
  }
  const date =
    coerceFirestoreDate(raw.timestamp) ??
    coerceFirestoreDate(raw.startTime) ??
    coerceFirestoreDate(raw.endTime) ??
    coerceFirestoreDate(raw.createdAt) ??
    coerceFirestoreDate(raw.updatedAt);
  return date?.toISOString();
}

function assignUsageEventStringFields(doc: UsageEventDoc, raw: Record<string, unknown>): void {
  if (typeof raw.providerID === "string") doc.providerID = raw.providerID;
  if (typeof raw.providerAccountID === "string") doc.providerAccountID = raw.providerAccountID;
  if (typeof raw.providerAccountLabel === "string") doc.providerAccountLabel = raw.providerAccountLabel;
  if (isProviderAccountStorageScope(raw.providerAccountSource)) {
    doc.providerAccountSource = raw.providerAccountSource;
  }
  if (typeof raw.model === "string") doc.model = raw.model;
  if (typeof raw.sessionId === "string") doc.sessionId = raw.sessionId;
  if (typeof raw.deviceId === "string") doc.deviceId = raw.deviceId;
  if (typeof raw.sourceDeviceId === "string") doc.sourceDeviceId = raw.sourceDeviceId;
  if (typeof raw.executionSourceID === "string") doc.executionSourceID = raw.executionSourceID;
  if (typeof raw.executionSourceName === "string") doc.executionSourceName = raw.executionSourceName;
  if (typeof raw.executionSourceKind === "string") doc.executionSourceKind = raw.executionSourceKind;
  if (typeof raw.executionSourceConfidence === "string") doc.executionSourceConfidence = raw.executionSourceConfidence;
}

function assignUsageEventNumberFields(doc: UsageEventDoc, raw: Record<string, unknown>): void {
  if (typeof raw.inputTokens === "number") doc.inputTokens = raw.inputTokens;
  if (typeof raw.outputTokens === "number") doc.outputTokens = raw.outputTokens;
  if (typeof raw.cacheCreationTokens === "number") doc.cacheCreationTokens = raw.cacheCreationTokens;
  if (typeof raw.cacheReadTokens === "number") doc.cacheReadTokens = raw.cacheReadTokens;
  if (typeof raw.reasoningTokens === "number") doc.reasoningTokens = raw.reasoningTokens;
  if (typeof raw.totalTokens === "number") doc.totalTokens = raw.totalTokens;
  if (typeof raw.costUSD === "number") doc.costUSD = raw.costUSD;
  if (typeof raw.costUsd === "number") doc.costUsd = raw.costUsd;
  if (typeof raw.cost === "number") doc.cost = raw.cost;
  if (typeof raw.provenanceConfidence === "string") doc.provenanceConfidence = raw.provenanceConfidence;
}

function assignUsageEventRawTimeFields(doc: UsageEventDoc, raw: Record<string, unknown>): void {
  if (raw.timestamp !== undefined) doc.timestamp = raw.timestamp;
  if (raw.startTime !== undefined) doc.startTime = raw.startTime;
  if (raw.endTime !== undefined) doc.endTime = raw.endTime;
  if (raw.createdAt !== undefined) doc.createdAt = raw.createdAt;
  if (raw.updatedAt !== undefined) doc.updatedAt = raw.updatedAt;
}

export function parseUsageEventDoc(raw: unknown): UsageEventDoc | undefined {
  if (!isRecord(raw)) {
    return undefined;
  }
  // Uploaders store the display name in `provider` ("Claude Code") and the
  // canonical ID in `providerID` ("claude-code"). Resolve to the canonical ID
  // so counter buckets, daily splits, and console breakdowns all key alike.
  const provider = resolveUsageEventProvider(raw);
  if (!provider) return undefined;
  const schemaVersion = typeof raw.schemaVersion === "number" ? raw.schemaVersion : 1;
  const recordedAt = synthesizeRecordedAt(raw);
  if (!recordedAt) return undefined;
  const doc: UsageEventDoc = {
    provider,
    recordedAt,
    schemaVersion,
  };
  assignUsageEventStringFields(doc, raw);
  assignUsageEventNumberFields(doc, raw);
  assignUsageEventRawTimeFields(doc, raw);
  // Keep a valid catalog-only ID (anthropic, grok, …). Garbage tokens still
  // fall back to the resolved AgentProvider so they cannot shadow splits.
  doc.providerID = preservedProviderID(raw, provider);
  return doc;
}
