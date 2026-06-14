/**
 * @fileoverview Pure query-shaping helpers for the `queryConversations` cockpit callable.
 *
 * This module is intentionally free of Firebase Admin side effects (it imports only the
 * `Timestamp` value, the `HttpsError` type, and the pure `stripUndefinedObject` guard) so the
 * faceted-query contract — sort resolution, facet-combination limits, Firestore clause shaping,
 * and manifest row projection — can be unit-tested without initializing the Admin SDK. The
 * `queryConversations` callable in `encryptedSearch.ts` composes these helpers; keeping them here
 * means the index-shaping decisions that gate latency and cost are covered by fast, hermetic tests.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import type { Query } from "firebase-admin/firestore";
import { stripUndefinedObject } from "../guards.js";

/** Sort fields the cockpit may order by; each is a plaintext facet stored on the manifest. */
export const QUERY_CONVERSATION_SORT_FIELDS = ["updatedAt", "startTime", "endTime", "costUSD", "totalTokens"] as const;
export type QueryConversationSortField = (typeof QUERY_CONVERSATION_SORT_FIELDS)[number];

function isQueryConversationSortField(value: string): value is QueryConversationSortField {
  for (const field of QUERY_CONVERSATION_SORT_FIELDS) {
    if (field === value) return true;
  }
  return false;
}

/** Normalizes a Firestore Timestamp or stored ISO string to an ISO string for transport. */
export function manifestFieldToISO(value: unknown): string | undefined {
  if (value == null) return undefined;
  if (value instanceof Timestamp) return value.toDate().toISOString();
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? new Date(parsed).toISOString() : undefined;
  }
  return undefined;
}

export interface ConversationSortPlan {
  sortField: QueryConversationSortField;
  direction: "asc" | "desc";
}

/**
 * Resolves the validated sort field and direction. Unknown sort requests fall back to
 * `updatedAt`, and any date-range filter forces a `startTime` sort because Firestore requires the
 * range field to lead the order-by. Direction defaults to `desc` unless `asc` is explicitly asked.
 */
export function resolveConversationSort(
  requestedSort: string | undefined,
  hasDateRange: boolean,
  requestedDirection: unknown,
): ConversationSortPlan {
  let sortField: QueryConversationSortField =
    requestedSort != null && isQueryConversationSortField(requestedSort) ? requestedSort : "updatedAt";
  if (hasDateRange) sortField = "startTime";
  const direction: "asc" | "desc" = requestedDirection === "asc" ? "asc" : "desc";
  return { sortField, direction };
}

export interface ConversationFacetInClauseFlags {
  providerInClause: boolean;
  modelInClause: boolean;
}

/**
 * Firestore allows at most one `in` clause per query, so a request that asks for multiple
 * providers *and* multiple models is rejected with actionable guidance. Single-value or
 * single-multi combinations are allowed.
 */
export function assertConversationFacetCombination(
  providers: readonly string[],
  models: readonly string[],
): ConversationFacetInClauseFlags {
  const providerInClause = providers.length > 1;
  const modelInClause = models.length > 1;
  if (providerInClause && modelInClause) {
    throw new HttpsError("invalid-argument", "Filter by multiple providers or multiple models, but not both at once.");
  }
  return { providerInClause, modelInClause };
}

export interface ConversationFacetFilters extends ConversationFacetInClauseFlags {
  providers: readonly string[];
  models: readonly string[];
  deviceId?: string;
  sourceType?: string;
  dateFrom?: string;
  dateTo?: string;
}

/** Firestore caps a single `in`/`array-contains-any` disjunction at 30 comparison values. */
export const CONVERSATION_IN_CLAUSE_LIMIT = 30;

/**
 * Applies the cockpit facet filters to a `session_logs` query. Equality facets use `==`; a
 * multi-valued provider/model selection uses an `in` capped at Firestore's 30-value disjunction
 * limit; and a date window adds `startTime` range bounds (which is why {@link resolveConversationSort}
 * pins the sort to `startTime` whenever a window is present). The handler validates the incoming
 * arrays to at most 20 entries, so this cap is a defensive ceiling rather than a lossy truncation.
 */
export function applyConversationFacetFilters(query: Query, filters: ConversationFacetFilters): Query {
  let filtered = query;
  if (filters.providerInClause) {
    filtered = filtered.where("provider", "in", filters.providers.slice(0, CONVERSATION_IN_CLAUSE_LIMIT));
  } else if (filters.providers.length === 1) {
    filtered = filtered.where("provider", "==", filters.providers[0]);
  }
  if (filters.modelInClause) {
    filtered = filtered.where("model", "in", filters.models.slice(0, CONVERSATION_IN_CLAUSE_LIMIT));
  } else if (filters.models.length === 1) {
    filtered = filtered.where("model", "==", filters.models[0]);
  }
  if (filters.deviceId) filtered = filtered.where("deviceId", "==", filters.deviceId);
  if (filters.sourceType) filtered = filtered.where("sourceType", "==", filters.sourceType);
  if (filters.dateFrom) filtered = filtered.where("startTime", ">=", Timestamp.fromDate(new Date(filters.dateFrom)));
  if (filters.dateTo) filtered = filtered.where("startTime", "<=", Timestamp.fromDate(new Date(filters.dateTo)));
  return filtered;
}

/**
 * Builds the page query: a single order on the requested sort field. Firestore *implicitly*
 * appends a `__name__` (document id) tiebreaker to every ordered query, so a snapshot-based
 * `startAfter` cursor never skips or repeats a row even when the sort value is non-unique (e.g.
 * many conversations share a `costUSD` of 0). We deliberately do *not* add an explicit second
 * order key: doing so would change every required composite index from `(facet, sortField)` to
 * `(facet, sortField, tiebreaker)`, which would silently break the documented cockpit indexes and
 * force the handler into its `failed-precondition` fallback for the common "filter by provider,
 * sort by cost" path. Relying on the implicit `__name__` order keeps the index set minimal and
 * lets single-field sorts (no facet) ride Firestore's automatic single-field indexes for free.
 */
export function buildConversationPageQuery(filtered: Query, sort: ConversationSortPlan): Query {
  return filtered.orderBy(sort.sortField, sort.direction);
}

/**
 * Projects a stored `session_logs` manifest into the cockpit row shape. Only plaintext facets and
 * the sealed (encrypted) title/preview envelopes ride along; conversation bodies stay in Storage
 * and never appear here. Timestamps are normalized to ISO strings for transport.
 */
export function mapSessionLogManifestRow(id: string, docData: Record<string, unknown>): Record<string, unknown> {
  return stripUndefinedObject({
    id,
    provider: docData.provider,
    sourceType: docData.sourceType,
    deviceId: docData.deviceId,
    model: docData.model,
    facetSchemaVersion: docData.facetSchemaVersion,
    messageCount: docData.messageCount,
    userWordCount: docData.userWordCount,
    assistantWordCount: docData.assistantWordCount,
    inputTokens: docData.inputTokens,
    outputTokens: docData.outputTokens,
    cacheCreationTokens: docData.cacheCreationTokens,
    cacheReadTokens: docData.cacheReadTokens,
    totalTokens: docData.totalTokens,
    costUSD: docData.costUSD,
    toolTags: docData.toolTags,
    durationSeconds: docData.durationSeconds,
    sealedTitle: docData.sealedTitle,
    sealedBodyPreview: docData.sealedBodyPreview,
    storagePath: docData.storagePath,
    bodyHash: docData.bodyHash,
    startTime: manifestFieldToISO(docData.startTime),
    endTime: manifestFieldToISO(docData.endTime),
    updatedAt: manifestFieldToISO(docData.updatedAt),
  });
}
