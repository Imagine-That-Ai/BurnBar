/**
 * @fileoverview Bounded-memory paging for the daily ops rollup scans.
 *
 * The daily rollups (`rollupMediaSessionDaily`, `rollupIrohTransportDaily`,
 * `rollupComputerUseDaily`) range over a full UTC day of cross-tenant
 * `collectionGroup` events. A single `.get()` materializes the entire day in
 * memory, so a high-volume day can silently OOM the function and drop that
 * day's data. `forEachInPages` streams the same result set in fixed-size pages
 * using an orderBy + startAfter cursor, so peak memory is bounded by the page
 * size rather than the day's event count.
 */

/** Documents per page for daily-rollup collectionGroup scans. */
export const ROLLUP_PAGE_SIZE = 2000;

/**
 * The minimal paging surface `forEachInPages` needs. A Firestore
 * `Query<DocumentData>` satisfies it structurally (with `Doc` =
 * `QueryDocumentSnapshot<DocumentData>`), and a unit-test fake can implement it
 * directly — so neither production nor tests need an `as`-cast.
 */
export interface PageableQuery<Doc> {
  orderBy(field: string): PageableQuery<Doc>;
  startAfter(cursor: Doc): PageableQuery<Doc>;
  limit(limit: number): PageableQuery<Doc>;
  get(): Promise<{ readonly empty: boolean; readonly size: number; readonly docs: readonly Doc[] }>;
}

/**
 * Streams every document matching `query` in bounded pages, invoking `onDoc`
 * for each document in order.
 *
 * `query` should already carry the day-range `where()` filters; this function
 * adds the `orderBy`/`limit`/`startAfter` cursor. `orderByField` MUST be the
 * field the range filter uses (Firestore requires the first `orderBy` to match
 * the inequality field), e.g. `startedAt` / `observedAt` / `recordedAt`.
 *
 * @returns the total number of documents processed.
 */
export async function forEachInPages<Doc>(
  query: PageableQuery<Doc>,
  orderByField: string,
  onDoc: (doc: Doc) => void,
  pageSize: number = ROLLUP_PAGE_SIZE,
): Promise<number> {
  const ordered = query.orderBy(orderByField);
  let cursor: Doc | undefined;
  let processed = 0;

  for (;;) {
    const page = cursor ? ordered.startAfter(cursor).limit(pageSize) : ordered.limit(pageSize);
    const snap = await page.get();
    if (snap.empty) {
      break;
    }
    for (const doc of snap.docs) {
      onDoc(doc);
    }
    processed += snap.size;
    if (snap.size < pageSize) {
      break;
    }
    cursor = snap.docs[snap.size - 1];
  }

  return processed;
}
