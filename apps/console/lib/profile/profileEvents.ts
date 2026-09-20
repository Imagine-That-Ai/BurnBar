/**
 * Paginated `users/{uid}/usage` event queries for the mineable /profile
 * explorer — the console twin of iOS `fetchUsagePage`
 * (`OpenBurnBarMobile/Services/FirestoreRepository.swift`).
 *
 * Rollup answers the instant scoreboard. Events answer the inspector, the
 * ledger, and bounded-range cross-filters (model / harness / account / hour /
 * token mix). Page size is 100 with cursor pagination and a hard 2,000-doc
 * cap per aggregate pass — the same ceiling as iOS Pulse.
 *
 * Query shape: `orderBy("startTime", "desc")` with equality filters and a
 * `startTime` range. Server events carry `startTime` as a Firestore Timestamp
 * (legacy desktop shape, see `functions/src/guards.ts`); the few docs that
 * only carry `recordedAt`/`timestamp` strings sort by their Firestore doc id
 * and are merged client-side at worst — the bounded range still applies.
 */

import {
  collection,
  getDocs,
  limit,
  orderBy,
  query,
  startAfter,
  where,
  type DocumentData,
  type DocumentSnapshot,
  type Firestore,
  type QueryConstraint,
} from "firebase/firestore";

export const PROFILE_EVENTS_PAGE_SIZE = 100;
export const PROFILE_EVENTS_AGGREGATE_CAP = 2_000;

export interface ProfileEventFacets {
  /** Display `provider` values (e.g. "Claude Code") — matches iOS exactly. */
  providers: readonly string[];
  models: readonly string[];
  devices: readonly string[];
  harnesses: readonly string[];
  accounts: readonly string[];
}

/** Inclusive day-key range ("YYYY-MM-DD") for the event query. */
export interface ProfileEventRange {
  fromDay: string | null;
  toDay: string | null;
}

export interface ProfileEventQuery {
  facets: ProfileEventFacets;
  range: ProfileEventRange;
}

/** A normalized usage event for the inspector + ledger. */
export interface ProfileUsageEvent {
  id: string;
  provider: string;
  providerID?: string;
  model?: string;
  harnessId?: string;
  harnessName?: string;
  accountId?: string;
  accountLabel?: string;
  deviceId?: string;
  sessionId?: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  reasoningTokens: number;
  totalTokens: number;
  costUsd: number;
  /** ISO timestamp (best of startTime / recordedAt / timestamp / createdAt). */
  startedAt: string | null;
  /** UTC hour (0–23) derived from startedAt, for the hour × weekday grid. */
  hourUtc: number | null;
  durationSeconds: number | null;
}

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() ? v : undefined;
}

/** Firestore Timestamp | Date | ISO string | millis → ISO string | null. */
export function eventTimeToIso(v: unknown): string | null {
  if (v == null) return null;
  if (v instanceof Date) {
    return Number.isNaN(v.getTime()) ? null : v.toISOString();
  }
  if (typeof v === "string" || typeof v === "number") {
    const d = new Date(v);
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }
  if (typeof v === "object") {
    const rec = v as Record<string, unknown>;
    try {
      if (typeof rec.toDate === "function") {
        const d = (rec as { toDate: () => Date }).toDate();
        return d instanceof Date && !Number.isNaN(d.getTime()) ? d.toISOString() : null;
      }
      if (typeof rec.toMillis === "function") {
        const d = new Date((rec as { toMillis: () => number }).toMillis());
        return Number.isNaN(d.getTime()) ? null : d.toISOString();
      }
      if (typeof rec.seconds === "number") {
        const d = new Date(rec.seconds * 1000);
        return Number.isNaN(d.getTime()) ? null : d.toISOString();
      }
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Build the Firestore constraints for one page of the event query, mirroring
 * iOS `fetchUsagePage`: equality filters + startTime range + startTime-desc
 * order + page-size limit + optional cursor. Single-value lists use `==`;
 * multi-value lists use `in` (max 10 per Firestore; callers slice).
 *
 * Field notes:
 * - `provider` carries the DISPLAY name on server docs (canonical ID lives in
 *   `providerID`), so provider chips filter `provider`, matching iOS.
 * - `executionSourceID` / `providerAccountID` have dedicated single-field +
 *   startTime composite indexes (added with this feature); iOS-covered
 *   provider/model/device combos reuse the existing indexes.
 */
export function buildProfileEventConstraints(
  q: ProfileEventQuery,
  cursor?: DocumentSnapshot<DocumentData>,
): QueryConstraint[] {
  const constraints: QueryConstraint[] = [];
  const take = (values: readonly string[]): string[] => values.slice(0, 10);

  if (q.facets.providers.length === 1) {
    constraints.push(where("provider", "==", q.facets.providers[0]));
  } else if (q.facets.providers.length > 1) {
    constraints.push(where("provider", "in", take(q.facets.providers)));
  }
  if (q.facets.models.length === 1) {
    constraints.push(where("model", "==", q.facets.models[0]));
  } else if (q.facets.models.length > 1) {
    constraints.push(where("model", "in", take(q.facets.models)));
  }
  if (q.facets.devices.length === 1) {
    constraints.push(where("deviceId", "==", q.facets.devices[0]));
  } else if (q.facets.devices.length > 1) {
    constraints.push(where("deviceId", "in", take(q.facets.devices)));
  }
  if (q.facets.harnesses.length === 1) {
    constraints.push(where("executionSourceID", "==", q.facets.harnesses[0]));
  } else if (q.facets.harnesses.length > 1) {
    constraints.push(where("executionSourceID", "in", take(q.facets.harnesses)));
  }
  if (q.facets.accounts.length === 1) {
    constraints.push(where("providerAccountID", "==", q.facets.accounts[0]));
  } else if (q.facets.accounts.length > 1) {
    constraints.push(where("providerAccountID", "in", take(q.facets.accounts)));
  }

  if (q.range.fromDay) {
    constraints.push(where("startTime", ">=", new Date(`${q.range.fromDay}T00:00:00Z`)));
  }
  if (q.range.toDay) {
    constraints.push(where("startTime", "<=", new Date(`${q.range.toDay}T23:59:59.999Z`)));
  }

  constraints.push(orderBy("startTime", "desc"));
  if (cursor) constraints.push(startAfter(cursor));
  constraints.push(limit(PROFILE_EVENTS_PAGE_SIZE));
  return constraints;
}

/** Normalize one raw `usage` doc into a ledger-ready event. Never throws. */
export function normalizeProfileEvent(id: string, raw: unknown): ProfileUsageEvent {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const inputTokens = num(r.inputTokens);
  const outputTokens = num(r.outputTokens);
  const cacheReadTokens = num(r.cacheReadTokens);
  const cacheWriteTokens = num(r.cacheCreationTokens ?? r.cacheWriteTokens);
  const reasoningTokens = num(r.reasoningTokens);
  const summed = inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens;
  const total = num(r.totalTokens) || summed;
  const startedAt =
    eventTimeToIso(r.startTime) ??
    eventTimeToIso(r.recordedAt) ??
    eventTimeToIso(r.timestamp) ??
    eventTimeToIso(r.createdAt) ??
    eventTimeToIso(r.endTime);
  let hourUtc: number | null = null;
  if (startedAt) {
    const d = new Date(startedAt);
    if (!Number.isNaN(d.getTime())) hourUtc = d.getUTCHours();
  }
  const start = eventTimeToIso(r.startTime);
  const end = eventTimeToIso(r.endTime);
  let durationSeconds: number | null = null;
  if (start && end) {
    const secs = Math.round((Date.parse(end) - Date.parse(start)) / 1000);
    if (Number.isFinite(secs) && secs >= 0) durationSeconds = secs;
  }
  const harnessId = str(r.executionSourceID);
  return {
    id,
    provider: str(r.provider) ?? "unknown",
    providerID: str(r.providerID),
    model: str(r.model),
    harnessId,
    harnessName: str(r.executionSourceName) ?? harnessId,
    accountId: str(r.providerAccountID),
    accountLabel: str(r.providerAccountLabel) ?? str(r.providerAccountID),
    deviceId: str(r.deviceId) ?? str(r.sourceDeviceId),
    sessionId: str(r.sessionId),
    inputTokens,
    outputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    reasoningTokens,
    totalTokens: total,
    costUsd: num(r.costUsd ?? r.cost),
    startedAt,
    hourUtc,
    durationSeconds,
  };
}

export interface ProfileEventPageResult {
  events: ProfileUsageEvent[];
  cursor: DocumentSnapshot<DocumentData> | null;
  /** True when another page exists (page came back full). */
  hasMore: boolean;
}

/**
 * Fetch one page of usage events for the signed-in user. Fail-soft: denied /
 * missing / index-missing reads resolve to an empty page with the raw error
 * message — the caller renders the index-build hint, never throws.
 */
export async function fetchProfileEventPage(
  firestore: Firestore,
  uid: string,
  q: ProfileEventQuery,
  cursor?: DocumentSnapshot<DocumentData>,
): Promise<{ page: ProfileEventPageResult; error: string | null }> {
  try {
    const constraints = buildProfileEventConstraints(q, cursor);
    const snap = await getDocs(query(collection(firestore, "users", uid, "usage"), ...constraints));
    const events = snap.docs.map((d) => normalizeProfileEvent(d.id, d.data()));
    const last = snap.docs[snap.docs.length - 1] ?? null;
    return {
      page: { events, cursor: last, hasMore: snap.docs.length >= PROFILE_EVENTS_PAGE_SIZE },
      error: null,
    };
  } catch (err) {
    return {
      page: { events: [], cursor: cursor ?? null, hasMore: false },
      error: err instanceof Error ? err.message : "Could not load usage events.",
    };
  }
}
