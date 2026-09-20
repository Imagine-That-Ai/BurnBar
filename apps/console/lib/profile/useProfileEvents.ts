"use client";

/**
 * Event-path hook for the mineable /profile explorer: paginated
 * `users/{uid}/usage` reads with cursor pagination and the 2,000-doc
 * aggregate cap, mirroring iOS `fetchUsagePage`.
 *
 * The hook fires only when `enabled` (the caller gates on `needsEventPath`
 * + a bounded range). Facet/range/auth changes hard-reset the cursor and
 * re-page from the top; in-flight pages from the previous generation are
 * dropped. Fail-soft: a denied / index-missing read surfaces `error` (the
 * page renders the index-build hint) instead of throwing.
 */

import * as React from "react";
import type { DocumentData, DocumentSnapshot } from "firebase/firestore";

import { db } from "@/lib/firebaseClient";
import { useAuth } from "@/lib/useAuth";
import {
  PROFILE_EVENTS_AGGREGATE_CAP,
  fetchProfileEventPage,
  type ProfileEventFacets,
  type ProfileEventRange,
  type ProfileUsageEvent,
} from "./profileEvents";

export interface UseProfileEventsResult {
  events: ProfileUsageEvent[];
  /** True while any page is in flight. */
  loading: boolean;
  /** True when the aggregate cap stopped the pass (range is wider than 2k docs). */
  capped: boolean;
  /** Raw Firestore error text (missing index, denied) or null. */
  error: string | null;
  /** Whether more pages exist beyond what was fetched. */
  hasMore: boolean;
  /** Fetch the next page (ledger "load more"). No-op when !hasMore/loading. */
  loadMore: () => void;
}

export function useProfileEvents(
  facets: ProfileEventFacets,
  range: ProfileEventRange,
  enabled: boolean,
): UseProfileEventsResult {
  const { user, loading: authLoading } = useAuth();
  const [events, setEvents] = React.useState<ProfileUsageEvent[]>([]);
  const [hasMore, setHasMore] = React.useState(false);
  const [loading, setLoading] = React.useState(false);
  const [capped, setCapped] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  /** Load-more counter; reset to 0 on every generation change (page one). */
  const [nonce, setNonce] = React.useState(0);

  // The query spec as a stable string: facet/range object identity churns
  // every render, so the generation key (not the objects) drives resets.
  const key = JSON.stringify({
    p: [...facets.providers].sort(),
    m: [...facets.models].sort(),
    d: [...facets.devices].sort(),
    h: [...facets.harnesses].sort(),
    a: [...facets.accounts].sort(),
    f: range.fromDay,
    t: range.toDay,
    u: user?.uid ?? null,
    e: enabled,
  });

  // Running pagination state lives in refs so a filter change can't strand a
  // stale cursor or counter inside an in-flight fetch closure.
  const cursorRef = React.useRef<DocumentSnapshot<DocumentData> | null>(null);
  const totalRef = React.useRef(0);

  React.useEffect(() => {
    cursorRef.current = null;
    totalRef.current = 0;
    setEvents([]);
    setHasMore(false);
    setCapped(false);
    setError(null);
    setLoading(false);
    setNonce(0);
  }, [key, authLoading]);

  React.useEffect(() => {
    if (!enabled || authLoading || !user) return;
    const uid = user.uid;
    let cancelled = false;
    setLoading(true);
    setError(null);

    // key already serializes facets/range, so parsing it back keeps this
    // effect on a single stable dep instead of churning object identities.
    const spec = JSON.parse(key) as {
      p: string[];
      m: string[];
      d: string[];
      h: string[];
      a: string[];
      f: string | null;
      t: string | null;
    };
    const q = {
      facets: {
        providers: spec.p,
        models: spec.m,
        devices: spec.d,
        harnesses: spec.h,
        accounts: spec.a,
      },
      range: { fromDay: spec.f, toDay: spec.t },
    };
    const cursor = nonce === 0 ? undefined : (cursorRef.current ?? undefined);
    fetchProfileEventPage(db(), uid, q, cursor)
      .then(({ page, error: err }) => {
        if (cancelled) return;
        if (err) {
          setError(err);
          setHasMore(false);
          return;
        }
        setError(null);
        cursorRef.current = page.cursor;
        const prior = nonce === 0 ? 0 : totalRef.current;
        totalRef.current = prior + page.events.length;
        const remaining = PROFILE_EVENTS_AGGREGATE_CAP - prior;
        if (remaining <= 0) {
          setCapped(true);
          setHasMore(false);
          return;
        }
        const keep = page.events.slice(0, remaining);
        if (
          keep.length < page.events.length ||
          totalRef.current > PROFILE_EVENTS_AGGREGATE_CAP
        ) {
          setCapped(true);
          setHasMore(false);
        } else {
          setHasMore(page.hasMore);
        }
        setEvents((prev) => (nonce === 0 ? keep : [...prev, ...keep]));
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : "Could not load usage events.");
          setHasMore(false);
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [enabled, authLoading, user, key, nonce]);

  const loadMore = React.useCallback(() => {
    if (!hasMore || loading) return;
    setNonce((n) => n + 1);
  }, [hasMore, loading]);

  return { events, loading, capped, error, hasMore, loadMore };
}
