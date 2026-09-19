"use client";

/**
 * Event-path hook for the mineable /profile explorer: paginated
 * `users/{uid}/usage` reads with cursor pagination and the 2,000-doc
 * aggregate cap, mirroring iOS `fetchUsagePage`.
 *
 * The hook fires only when `enabled` (the caller gates on a bounded range).
 * Pages fetch SEQUENTIALLY and automatically until the server runs dry or
 * the aggregate cap hits — the hour grid, token mix, day inspector, and
 * ledger all aggregate the full loaded range, never just page one.
 * `loadMore` continues past an interruption; when everything is loaded it is
 * a no-op. Facet/range/auth changes hard-reset the cursor and re-page from
 * the top; in-flight pages from the previous generation are dropped.
 * Fail-soft: failures surface a stable error KIND (member copy lives in
 * `profileEventErrorCopy`), never raw Firebase text.
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

export type ProfileEventsError = "index" | "denied" | "network" | null;

export interface UseProfileEventsResult {
  events: ProfileUsageEvent[];
  /** True while any page is in flight. */
  loading: boolean;
  /** True when the aggregate cap stopped the pass (range is wider than 2k docs). */
  capped: boolean;
  /** Stable failure kind, or null. */
  error: ProfileEventsError;
  /** True when the server has more pages AND the cap is not hit. */
  hasMore: boolean;
  /** Continue paging (after an interruption) or retry a failed page. */
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
  const [error, setError] = React.useState<ProfileEventsError>(null);
  /** Manual continue/retry counter; reset to 0 on every generation change. */
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

    const run = async () => {
      setLoading(true);
      setError(null);
      try {
        // Sequential auto-page: every page lands in state as it arrives so
        // the ledger paints progressively; aggregates settle when the pass
        // completes or the cap hits.
        for (;;) {
          if (cancelled) return;
          if (totalRef.current >= PROFILE_EVENTS_AGGREGATE_CAP) {
            setCapped(true);
            setHasMore(false);
            return;
          }
          const { page, error: err } = await fetchProfileEventPage(
            db(),
            uid,
            q,
            cursorRef.current ?? undefined,
          );
          if (cancelled) return;
          if (err) {
            setError(err);
            // Keep what already loaded; hasMore stays true only when a
            // cursor exists to continue from.
            setHasMore(cursorRef.current != null);
            return;
          }
          setError(null);
          cursorRef.current = page.cursor;
          totalRef.current += page.events.length;
          if (page.events.length > 0) {
            setEvents((prev) => {
              const room = PROFILE_EVENTS_AGGREGATE_CAP - prev.length;
              if (room <= 0) return prev;
              return [...prev, ...page.events.slice(0, room)];
            });
          }
          if (!page.hasMore || page.events.length === 0) {
            setHasMore(false);
            return;
          }
          if (totalRef.current >= PROFILE_EVENTS_AGGREGATE_CAP) {
            setCapped(true);
            setHasMore(false);
            return;
          }
          setHasMore(true);
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };

    run().catch(() => {
      if (!cancelled) {
        setError("network");
        setLoading(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [enabled, authLoading, user, key, nonce]);

  const loadMore = React.useCallback(() => {
    if (loading) return;
    if (!hasMore && !error) return;
    setNonce((n) => n + 1);
  }, [hasMore, error, loading]);

  return { events, loading, capped, error, hasMore, loadMore };
}
