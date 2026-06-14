/**
 * @fileoverview Provider-quota refresh sweep (crosscut-010).
 *
 * Extracted core of the `refreshAllProviderQuotas` scheduled job so the
 * selection/budget/concurrency/backfill logic is unit-testable with an
 * in-memory Firestore model.
 *
 * Design notes (corrected from the originally-filed sketch):
 *
 * - Legacy account docs that predate `lastRefreshAt` have the field MISSING,
 *   not explicit-null. Firestore's `== null` filter matches only explicit
 *   nulls and `orderBy` excludes missing-field docs entirely, so neither the
 *   stale-first ordered query nor a `where("lastRefreshAt", "==", null)`
 *   filter can ever see them — the originally proposed filter would have
 *   returned zero rows and permanently orphaned legacy docs. Instead, a
 *   cursor-resumable backfill stamps `lastRefreshAt: null` onto missing-field
 *   docs (cheap writes, no provider HTTP). Explicit null sorts FIRST in the
 *   ordered pass's asc `orderBy`, so backfilled docs are refreshed with
 *   stale-first priority by the very next ordered query, covered by the
 *   existing composite index (status asc, storageScope asc, lastRefreshAt
 *   asc) — no new index needed.
 *
 * - The backfill terminates: each (status, storageScope) stream pages in
 *   implicit `__name__` order with a persisted cursor, and once every stream
 *   returns a short page the marker doc is stamped `complete` and cached
 *   in-process. After that the sweep costs one marker read per cold start and
 *   zero extra collection-group queries — replacing the old "compatibility
 *   pass" that re-read up to a full batch of already-refreshed docs every 15
 *   minutes forever (and that starved permanently once the ordered pass
 *   filled the batch budget).
 *
 * - Refreshes run through a bounded concurrency pool instead of strictly
 *   serial awaits: each refresh is an outbound provider HTTP call (1-3 s), so
 *   a serial batch of 20 approached the default 60 s function timeout. Note
 *   the underlying adapters share one process-global `externalApiPolicy`
 *   circuit breaker (not per-provider), so a dead provider failing in
 *   parallel can open the shared breaker for the remainder of the run; that
 *   self-heals on the next run.
 *
 * All Firestore access goes through narrow structural types so the real
 * admin-SDK objects satisfy them directly (zero casts, production and tests).
 */

/** Subset of `DocumentReference` the sweep touches on account docs. */
type SweepAccountDocRef = {
  readonly path: string;
  update(data: Record<string, unknown>): Promise<unknown>;
};

/** Subset of `QueryDocumentSnapshot` the sweep reads. */
export type SweepAccountDoc = {
  readonly ref: SweepAccountDocRef;
  get(field: string): unknown;
};

export type SweepQuerySnapshot<Doc> = { readonly docs: readonly Doc[] };

/** Subset of `Query` used for both the ordered pass and the backfill scan. */
export type SweepQuery<Doc> = {
  where(field: string, op: "==" | "in", value: unknown): SweepQuery<Doc>;
  orderBy(field: string, direction?: "asc" | "desc"): SweepQuery<Doc>;
  limit(count: number): SweepQuery<Doc>;
  startAfter(cursor: unknown): SweepQuery<Doc>;
  get(): Promise<SweepQuerySnapshot<Doc>>;
};

/** Subset of `DocumentSnapshot` used for marker and cursor docs. */
export type SweepMarkerSnapshot = {
  readonly exists: boolean;
  /** Cursor resume position — real snapshots expose their location here. */
  readonly ref: { readonly path: string };
  data(): Record<string, unknown> | undefined;
};

/** Subset of `DocumentReference` used for marker and cursor docs. */
export type SweepDocRef = {
  get(): Promise<SweepMarkerSnapshot>;
  set(data: Record<string, unknown>): Promise<unknown>;
};

/** Subset of `Firestore` the sweep needs. */
export type SweepDb<Doc extends SweepAccountDoc> = {
  collectionGroup(collectionId: string): SweepQuery<Doc>;
  doc(path: string): SweepDocRef;
};

type QuotaBackfillResult = {
  /** True when the backfill is already complete and no scan was issued. */
  skipped: boolean;
  /** True once every (status, storageScope) stream has been drained. */
  complete: boolean;
  /** Docs examined by this run's scan pages. */
  examined: number;
  /** Missing-field docs stamped `lastRefreshAt: null` by this run. */
  backfilled: number;
};

type QuotaRefreshSweepOptions<Doc extends SweepAccountDoc> = {
  /** Maximum account + legacy-connection refreshes per run. */
  batchSize: number;
  /** Parallel refresh width (default 5). */
  concurrency?: number;
  /** Backfill scan page size per stream per run (default 200). */
  backfillScanPageSize?: number;
  /** Refresh one provider account doc. Expected to handle its own errors. */
  refreshAccountDoc(doc: Doc): Promise<void>;
  /** `${uid}/${providerID}` key used to dedupe the legacy connection pass. */
  legacyKeyForAccountDoc(doc: Doc): string | undefined;
  /** Refresh one legacy provider_connections doc. */
  refreshLegacyConnectionDoc(doc: Doc): Promise<void>;
  /** Dedupe key for a legacy connection doc; undefined skips the doc. */
  legacyKeyForConnectionDoc(doc: Doc): string | undefined;
};

type QuotaRefreshSweepResult = {
  backfill: QuotaBackfillResult;
  refreshedAccountPaths: string[];
  refreshedLegacyPaths: string[];
};

const REFRESHABLE_STATUSES = ["connected", "stale", "error"] as const;
const REFRESHABLE_SCOPES = ["cloud_refreshable", "server_private"] as const;
const DEFAULT_CONCURRENCY = 5;
const DEFAULT_BACKFILL_SCAN_PAGE_SIZE = 200;

/**
 * Server-only migration marker (clients are denied by default — the path is
 * matched by no firestore.rules allow). While incomplete it stores one resume
 * cursor per (status, storageScope) stream; on completion the cursors are
 * dropped so no account-doc paths are retained.
 */
export const LAST_REFRESH_AT_BACKFILL_MARKER_PATH = "ops_migrations/provider_accounts_last_refresh_at_backfill";

/**
 * Process-global memo of backfill completion: warm instances skip even the
 * marker read. Safe because completion is monotonic — new account docs are
 * always created with `lastRefreshAt` populated.
 */
let backfillCompleteCache = false;

export function resetQuotaRefreshSweepCachesForTests(): void {
  backfillCompleteCache = false;
}

/**
 * Runs `fn` over `items` with at most `limit` invocations in flight. Always
 * settles every item (a rejection does not starve the rest of the batch),
 * then rethrows the first failure so callers still observe it.
 */
export async function mapWithConcurrency<T>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<void>,
): Promise<void> {
  if (items.length === 0) return;
  const width = Math.max(1, Math.min(limit, items.length));
  let nextIndex = 0;
  const failures: unknown[] = [];

  const workers = Array.from({ length: width }, async () => {
    for (;;) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= items.length) return;
      try {
        await fn(items[index]);
      } catch (err) {
        failures.push(err);
      }
    }
  });

  await Promise.all(workers);
  if (failures.length > 0) {
    throw failures[0];
  }
}

type BackfillStreamState = {
  cursorPath?: string;
  done?: boolean;
};

function parseBackfillStreamState(value: unknown): BackfillStreamState {
  if (typeof value !== "object" || value === null) return {};
  const record: Record<string, unknown> = { ...value };
  return {
    cursorPath: typeof record.cursorPath === "string" ? record.cursorPath : undefined,
    done: record.done === true ? true : undefined,
  };
}

function backfillStreamKeys(): string[] {
  const keys: string[] = [];
  for (const status of REFRESHABLE_STATUSES) {
    for (const scope of REFRESHABLE_SCOPES) {
      keys.push(`${status}|${scope}`);
    }
  }
  return keys;
}

/**
 * One bounded slice of the one-time `lastRefreshAt` backfill. Missing-field
 * docs are stamped explicit null so the ordered refresh pass can see them;
 * docs that already carry the field (including explicit null) are untouched.
 */
async function runLastRefreshAtBackfill<Doc extends SweepAccountDoc>(
  db: SweepDb<Doc>,
  pageSize: number,
): Promise<QuotaBackfillResult> {
  if (backfillCompleteCache) {
    return { skipped: true, complete: true, examined: 0, backfilled: 0 };
  }

  const markerRef = db.doc(LAST_REFRESH_AT_BACKFILL_MARKER_PATH);
  const markerSnap = await markerRef.get();
  const marker = markerSnap.exists ? (markerSnap.data() ?? {}) : {};
  if (marker.complete === true) {
    backfillCompleteCache = true;
    return { skipped: true, complete: true, examined: 0, backfilled: 0 };
  }

  const priorStreamsValue = marker.streams;
  const priorStreams: Record<string, unknown> =
    typeof priorStreamsValue === "object" && priorStreamsValue !== null ? { ...priorStreamsValue } : {};

  const effectivePageSize = Math.max(1, pageSize);
  const nextStreams: Record<string, BackfillStreamState> = {};
  let examined = 0;
  let backfilled = 0;
  let allDone = true;

  for (const streamKey of backfillStreamKeys()) {
    const [status, scope] = streamKey.split("|");
    const prior = parseBackfillStreamState(priorStreams[streamKey]);
    if (prior.done === true) {
      nextStreams[streamKey] = { done: true };
      continue;
    }

    let query = db
      .collectionGroup("provider_accounts")
      .where("status", "==", status)
      .where("storageScope", "==", scope)
      .limit(effectivePageSize);

    if (prior.cursorPath !== undefined) {
      const cursorSnap = await db.doc(prior.cursorPath).get();
      if (cursorSnap.exists) {
        query = query.startAfter(cursorSnap);
      }
      // A vanished cursor doc restarts the stream from the beginning; the
      // null stamp is idempotent so a re-scan only costs reads.
    }

    const snapshot = await query.get();
    examined += snapshot.docs.length;

    for (const doc of snapshot.docs) {
      if (doc.get("lastRefreshAt") !== undefined) continue;
      try {
        await doc.ref.update({ lastRefreshAt: null });
        backfilled += 1;
      } catch {
        // Doc deleted between scan and stamp — nothing left to migrate.
      }
    }

    if (snapshot.docs.length >= effectivePageSize) {
      allDone = false;
      const lastDoc = snapshot.docs[snapshot.docs.length - 1];
      nextStreams[streamKey] = { cursorPath: lastDoc.ref.path };
    } else {
      nextStreams[streamKey] = { done: true };
    }
  }

  const now = new Date().toISOString();
  if (allDone) {
    backfillCompleteCache = true;
    // Full set (no merge): drops the per-stream cursors so no account-doc
    // paths are retained once the migration is over.
    await markerRef.set({ complete: true, completedAt: now });
  } else {
    const streams: Record<string, unknown> = {};
    for (const [key, state] of Object.entries(nextStreams)) {
      streams[key] = state.done === true ? { done: true } : { cursorPath: state.cursorPath };
    }
    await markerRef.set({ complete: false, streams, updatedAt: now });
  }

  return { skipped: false, complete: allDone, examined, backfilled };
}

/**
 * Full provider-quota sweep:
 *   1. Backfill slice (until the one-time migration completes).
 *   2. Stale-first ordered refresh of provider_accounts across the
 *      refreshable statuses, bounded by `batchSize`, refreshed through the
 *      concurrency pool. Selection (and the budget math) happens serially
 *      BEFORE any refresh runs, so pooling cannot skew the limit accounting.
 *   3. Legacy provider_connections fallback for installs that predate
 *      account docs, deduped against the accounts already refreshed.
 */
export async function runQuotaRefreshSweep<Doc extends SweepAccountDoc>(
  db: SweepDb<Doc>,
  options: QuotaRefreshSweepOptions<Doc>,
): Promise<QuotaRefreshSweepResult> {
  const concurrency = options.concurrency ?? DEFAULT_CONCURRENCY;
  const backfill = await runLastRefreshAtBackfill(db, options.backfillScanPageSize ?? DEFAULT_BACKFILL_SCAN_PAGE_SIZE);

  // Selection pass: materialize the batch before any refresh starts.
  const selectedAccounts: Doc[] = [];
  const selectedAccountPaths = new Set<string>();
  const legacyKeys = new Set<string>();

  for (const status of REFRESHABLE_STATUSES) {
    if (selectedAccounts.length >= options.batchSize) break;
    const snapshot = await db
      .collectionGroup("provider_accounts")
      .where("status", "==", status)
      .where("storageScope", "in", [...REFRESHABLE_SCOPES])
      .orderBy("lastRefreshAt", "asc")
      .limit(options.batchSize - selectedAccounts.length)
      .get();

    for (const doc of snapshot.docs) {
      if (selectedAccountPaths.has(doc.ref.path)) continue;
      selectedAccountPaths.add(doc.ref.path);
      const legacyKey = options.legacyKeyForAccountDoc(doc);
      if (legacyKey !== undefined) legacyKeys.add(legacyKey);
      selectedAccounts.push(doc);
    }
  }

  await mapWithConcurrency(selectedAccounts, concurrency, (doc) => options.refreshAccountDoc(doc));

  const refreshedLegacyPaths: string[] = [];
  const legacyRemaining = Math.max(0, options.batchSize - selectedAccounts.length);
  if (legacyRemaining > 0) {
    const connectionSnapshot = await db
      .collectionGroup("provider_connections")
      .where("status", "==", "connected")
      .orderBy("lastRefreshAt", "asc")
      .limit(legacyRemaining)
      .get();

    const selectedConnections: Doc[] = [];
    for (const doc of connectionSnapshot.docs) {
      const legacyKey = options.legacyKeyForConnectionDoc(doc);
      if (legacyKey === undefined || legacyKeys.has(legacyKey)) continue;
      selectedConnections.push(doc);
      refreshedLegacyPaths.push(doc.ref.path);
    }

    await mapWithConcurrency(selectedConnections, concurrency, (doc) => options.refreshLegacyConnectionDoc(doc));
  }

  return {
    backfill,
    refreshedAccountPaths: [...selectedAccountPaths],
    refreshedLegacyPaths,
  };
}
