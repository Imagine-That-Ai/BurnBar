"use client";

import { useCallback, useEffect, useState } from "react";
import { doc, getDoc } from "firebase/firestore";

import { db } from "@/lib/firebaseClient";
import { useAuth } from "@/lib/useAuth";
import { rebuildUsageRollups } from "@/lib/api";
import { emptyRollup, normalizeRollup, type UsageRollup } from "@/lib/usage";

export type ProfileSource = "live" | "empty";

export interface ProfileUsageResult {
  /** The all-time rollup: totals, daily series, provider/model/device summaries. */
  rollup: UsageRollup;
  /** "live" when a rollup doc exists; "empty" when the member has never synced. */
  source: ProfileSource;
  loading: boolean;
  error: string | null;
  /** Re-read; pass true to force a server recompute (rebuildUsageRollups) first. */
  reload: (rebuild?: boolean) => void;
}

/**
 * Reads the member's lifetime usage for the profile page:
 *   users/{uid}/usage_rollups/all_time → totals + full-history daily series
 *
 * Same fail-soft discipline as useDashboardUsage: a denied or missing doc
 * degrades to a zeroed "empty" state, never throws, never mocks.
 */
export function useProfileUsage(): ProfileUsageResult {
  const { user, loading: authLoading } = useAuth();
  const [rollup, setRollup] = useState<UsageRollup>(() => emptyRollup("all_time"));
  const [source, setSource] = useState<ProfileSource>("empty");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const [rebuildPending, setRebuildPending] = useState(false);

  const reload = useCallback((rebuild = false) => {
    if (rebuild) setRebuildPending(true);
    setNonce((n) => n + 1);
  }, []);

  useEffect(() => {
    if (authLoading) return;
    if (!user) {
      setRollup(emptyRollup("all_time"));
      setSource("empty");
      setLoading(false);
      return;
    }
    const uid = user.uid;
    let cancelled = false;
    setLoading(true);
    setError(null);

    // One-shot rebuild intent, consumed before the read (same contract as
    // useDashboardUsage): a cancelled run can't leave it armed for the next.
    const shouldRebuild = rebuildPending;
    if (shouldRebuild) setRebuildPending(false);

    const run = async () => {
      if (shouldRebuild) {
        try {
          await rebuildUsageRollups(true);
        } catch {
          // Recompute is best-effort; fall through to read whatever exists.
        }
      }
      const snap = await getDoc(doc(db(), "users", uid, "usage_rollups", "all_time"));
      if (cancelled) return;
      if (snap.exists()) {
        setRollup(normalizeRollup(snap.data(), "all_time"));
        setSource("live");
      } else {
        setRollup(emptyRollup("all_time"));
        setSource("empty");
      }
    };

    run()
      .catch((err: unknown) => {
        if (!cancelled)
          setError(err instanceof Error ? err.message : "Could not load your usage.");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
    // rebuildPending intentionally not a dep: reload() arms it then bumps
    // nonce, so nonce already gates the re-run.
  }, [user, authLoading, nonce]);

  return { rollup, source, loading, error, reload };
}
