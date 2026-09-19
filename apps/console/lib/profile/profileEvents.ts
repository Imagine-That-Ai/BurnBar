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
 * Query strategy (deliberately narrow server-side, wide client-side):
 * the server applies AT MOST one `==` facet plus the `startTime` range and
 * the `startTime`-desc order; every remaining facet filters client-side in
 * `matchEventFacets`. This keeps every cross-facet combo on indexes that
 * already exist (provider/model/device + startTime, plus the two new
 * executionSourceID/providerAccountID + startTime singles) instead of
 * demanding a composite index per combo — and it lets matching honor the
 * catalog rules the counters use (display-name vs canonical provider,
 * `${providerID}:unattributed` accounts, `deviceId ?? sourceDeviceId`).
 *
 * Server events carry `startTime` as a Firestore Timestamp (legacy desktop
 * shape, see `functions/src/guards.ts`); docs that only carry
 * `recordedAt`/`timestamp` strings (e.g. Elder Wand fusion rows) are fetched
 * by a second `startTime == null` pass and merged client-side.
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
 * The single server-side equality for a page, if any. Priority prefers the
 * iOS-covered indexes (provider, model, device) over the two new singles
 * (executionSourceID, providerAccountID); multi-value groups never constrain
 * server-side — they filter client-side so no selection is silently dropped.
 * Provider chips carry rollup `provider` values (canonical IDs like
 * "claude-code"); Mac-synced docs may store the display name ("Claude Code")
 * in `provider` with the canonical ID in `providerID`, so the provider group
 * NEVER constrains server-side — a `provider ==` would silently exclude the
 * display-name rows. Providers always filter client-side, where the matcher
 * below accepts either field.
 */
function serverEquality(
  facets: ProfileEventFacets,
): { field: string; value: string } | null {
  const single = (values: readonly string[]): string | null =>
    values.length === 1 ? (values[0] ?? null) : null;
  const model = single(facets.models);
  if (model) return { field: "model", value: model };
  const device = single(facets.devices);
  if (device) return { field: "deviceId", value: device };
  const harness = single(facets.harnesses);
  if (harness) return { field: "executionSourceID", value: harness };
  const account = single(facets.accounts);
  if (account && !account.endsWith(":unattributed")) {
    return { field: "providerAccountID", value: account };
  }
  return null;
}

/**
 * Build the Firestore constraints for one page of the event query: at most
 * one `==` facet plus the `startTime` range, always ordered by `startTime`
 * desc with the page-size limit and optional cursor. Everything else filters
 * client-side via `matchEventFacets`.
 */
export function buildProfileEventConstraints(
  q: ProfileEventQuery,
  cursor?: DocumentSnapshot<DocumentData>,
): QueryConstraint[] {
  const constraints: QueryConstraint[] = [];
  const eq = serverEquality(q.facets);
  if (eq) constraints.push(where(eq.field, "==", eq.value));

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

/**
 * Client-side facet matching over normalized events — the wide half of the
 * query strategy. Mirrors the counter rules in
 * `functions/src/rollupCounters.ts` so chips agree with the rollup lists
 * they came from:
 * - provider: matches display `provider`, canonical `providerID`, or either
 *   way round (Mac-synced rows store "Claude Code" + "claude-code").
 * - account: `${providerID}:unattributed` chips match events with NO
 *   `providerAccountID` (the synthetic key is rollup-only, never stored).
 * - device: `deviceId ?? sourceDeviceId`, same fallback the rollup uses.
 * Multi-value groups are ORs; groups AND across. Empty groups match all.
 */
export function matchEventFacets(
  e: ProfileUsageEvent,
  facets: ProfileEventFacets,
): boolean {
  if (
    facets.providers.length > 0 &&
    !facets.providers.some((p) => p === e.provider || p === e.providerID)
  ) {
    return false;
  }
  if (facets.models.length > 0 && (e.model == null || !facets.models.includes(e.model))) {
    return false;
  }
  if (
    facets.harnesses.length > 0 &&
    (e.harnessId == null || !facets.harnesses.includes(e.harnessId))
  ) {
    return false;
  }
  if (facets.accounts.length > 0) {
    const key = e.accountId ?? `${e.providerID ?? e.provider}:unattributed`;
    if (!facets.accounts.includes(key)) return false;
  }
  if (
    facets.devices.length > 0 &&
    (e.deviceId == null || !facets.devices.includes(e.deviceId))
  ) {
    return false;
  }
  return true;
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
 * Fetch one page of usage events for the signed-in user. The server applies
 * at most one equality + the range; remaining facets filter client-side via
 * `matchEventFacets` so cross-facet combos never hit a missing index.
 *
 * On the first page only, a second `startTime == null` pass picks up docs
 * the `orderBy("startTime")` excludes (Elder Wand fusion rows carry
 * `recordedAt` but no `startTime`); they merge client-side, range-filtered
 * by their normalized timestamp. Fail-soft: denied / index-missing reads
 * resolve to an empty page with a stable error KIND — the UI renders its own
 * recovery copy, never the raw Firebase text.
 */
export async function fetchProfileEventPage(
  firestore: Firestore,
  uid: string,
  q: ProfileEventQuery,
  cursor?: DocumentSnapshot<DocumentData>,
): Promise<{ page: ProfileEventPageResult; error: "index" | "denied" | "network" | null }> {
  try {
    const constraints = buildProfileEventConstraints(q, cursor);
    const snap = await getDocs(query(collection(firestore, "users", uid, "usage"), ...constraints));
    const matched = snap.docs
      .map((d) => normalizeProfileEvent(d.id, d.data()))
      .filter((e) => matchEventFacets(e, q.facets));
    const events = [...matched];

    // Timeless pass: docs without startTime are invisible to the ordered
    // query. Bound by the same range client-side (their normalized timestamp
    // still carries recordedAt/timestamp), capped at one page.
    if (!cursor) {
      try {
        const timeless = await getDocs(
          query(
            collection(firestore, "users", uid, "usage"),
            where("startTime", "==", null),
            limit(PROFILE_EVENTS_PAGE_SIZE),
          ),
        );
        const inRange = timeless.docs
          .map((d) => normalizeProfileEvent(d.id, d.data()))
          .filter((e) => matchEventFacets(e, q.facets))
          .filter((e) => {
            if (!e.startedAt) return false;
            const day = e.startedAt.slice(0, 10);
            if (q.range.fromDay && day < q.range.fromDay) return false;
            if (q.range.toDay && day > q.range.toDay) return false;
            return true;
          });
        const seen = new Set(events.map((e) => e.id));
        for (const e of inRange) {
          if (!seen.has(e.id)) {
            seen.add(e.id);
            events.push(e);
          }
        }
        events.sort((a, b) => (b.startedAt ?? "").localeCompare(a.startedAt ?? ""));
      } catch {
        /* timeless pass is best-effort; the ordered page still stands */
      }
    }

    const last = snap.docs[snap.docs.length - 1] ?? null;
    return {
      page: { events, cursor: last, hasMore: snap.docs.length >= PROFILE_EVENTS_PAGE_SIZE },
      error: null,
    };
  } catch (err) {
    return {
      page: { events: [], cursor: cursor ?? null, hasMore: false },
      error: classifyProfileEventError(err),
    };
  }
}

/**
 * Map a Firestore read failure onto a stable kind for member-facing copy.
 * The raw message stays in console.error — the UI shows recovery text, not
 * backend internals or project-specific console links.
 */
export function classifyProfileEventError(err: unknown): "index" | "denied" | "network" {
  const msg = err instanceof Error ? err.message : String(err ?? "");
  if (/failed-precondition|requires an index|create.*index/i.test(msg)) return "index";
  if (/permission-denied|permission denied|unauthenticated/i.test(msg)) return "denied";
  return "network";
}

/** Member-facing recovery copy per error kind. */
export function profileEventErrorCopy(kind: "index" | "denied" | "network"): string {
  switch (kind) {
    case "index":
      return "Usage search is still warming up — try again in a minute.";
    case "denied":
      return "Sign in again to reload these runs.";
    case "network":
      return "Could not load these runs — check your connection and retry.";
  }
}
