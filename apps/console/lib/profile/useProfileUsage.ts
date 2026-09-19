"use client";

import { useCallback, useEffect, useState } from "react";
import { doc, getDoc } from "firebase/firestore";

import { db } from "@/lib/firebaseClient";
import { useAuth } from "@/lib/useAuth";
import { rebuildUsageRollups } from "@/lib/api";
import { emptyRollup, normalizeRollup, type UsageRollup } from "@/lib/usage";
import {
  profileRollupNeedsFullRebuild,
  rebuildUsageErrorMessage,
  rebuildUsageKeepsWaiting,
} from "@/lib/profile/rollupHealth";

const IN_FLIGHT_POLL_MS = 4_000;
const IN_FLIGHT_POLL_BUDGET_MS = 540_000;

export type ProfileSource = "live" | "empty";

export interface ProfileUsageResult {
  /** The all-time rollup: totals, daily series, provider/model/device summaries. */
  rollup: UsageRollup;
  /** "live" when a rollup doc exists; "empty" when the member has never synced. */
  source: ProfileSource;
  loading: boolean;
  /** True while a server-side recompute is in flight (auto first-sync or a
   *  manual re-sync) — the page reads again as soon as it lands. */
  syncing: boolean;
  error: string | null;
  /** Re-read; pass true to force a server recompute (rebuildUsageRollups) first. */
  reload: (rebuild?: boolean) => void;
}

/**
 * Reads the member's lifetime usage for the profile page:
 *   users/{uid}/usage_rollups/all_time → totals + full-history daily series
 *
 * A missing doc almost always means the rollup pipeline has never computed for
 * this account (history predates the counters), so the first "empty" read of a
 * session automatically fires the deployed `rebuildUsageRollups` callable and
 * re-reads once — the page fills itself in instead of sitting at a lying zero.
 * Guarded by a sessionStorage marker so a failed/slow recompute never loops.
 *
 * The first Firestore read is applied *before* waiting on that callable. A
 * full rebuild can take minutes (and used to OOM/timeout on the default
 * 60s/256MiB envelope); blanking the lifetime stats for the whole wait made
 * a working heatmap look like sync was broken.
 *
 * Same fail-soft discipline as useDashboardUsage: a denied or missing doc
 * degrades to a zeroed "empty" state, never throws, never mocks.
 */
export function useProfileUsage(): ProfileUsageResult {
  const { user, loading: authLoading } = useAuth();
  const [rollup, setRollup] = useState<UsageRollup>(() => emptyRollup("all_time"));
  const [source, setSource] = useState<ProfileSource>("empty");
  const [loading, setLoading] = useState(true);
  const [syncing, setSyncing] = useState(false);
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

    const readRollup = async (): Promise<UsageRollup | null> => {
      const snap = await getDoc(doc(db(), "users", uid, "usage_rollups", "all_time"));
      return snap.exists() ? normalizeRollup(snap.data(), "all_time") : null;
    };

    const apply = (result: UsageRollup | null) => {
      if (result) {
        setRollup(result);
        setSource("live");
      } else {
        setRollup(emptyRollup("all_time"));
        setSource("empty");
      }
    };

    const run = async () => {
      // Show whatever already exists *before* a possibly-minutes-long repair
      // so lifetime numbers don't collapse to dashes for the whole wait.
      let result = await readRollup();
      if (cancelled) return;
      apply(result);
      setLoading(false);

      const needsForce =
        shouldRebuild ||
        (profileRollupNeedsFullRebuild(result) && !autoSyncDone(uid));
      if (!needsForce) return;

      if (!shouldRebuild) markAutoSync(uid);
      if (!cancelled) setSyncing(true);
      try {
        await rebuildUsageRollups(true);
      } catch (err) {
        if (!cancelled) setError(rebuildUsageErrorMessage(err));
        if (rebuildUsageKeepsWaiting(err)) {
          const deadline = Date.now() + IN_FLIGHT_POLL_BUDGET_MS;
          const previousComputedAt = result?.computedAt;
          while (!cancelled && Date.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, IN_FLIGHT_POLL_MS));
            const latest = await readRollup();
            if (cancelled) return;
            apply(latest);
            if (latest?.computedAt && latest.computedAt !== previousComputedAt) {
              if (!cancelled) setError(null);
              return;
            }
          }
        }
      }
      result = await readRollup();
      if (cancelled) return;
      apply(result);
    };

    run()
      .catch((err: unknown) => {
        if (!cancelled)
          setError(err instanceof Error ? err.message : "Could not load your usage.");
      })
      .finally(() => {
        if (!cancelled) {
          setLoading(false);
          setSyncing(false);
        }
      });

    return () => {
      cancelled = true;
    };
    // rebuildPending intentionally not a dep: reload() arms it then bumps
    // nonce, so nonce already gates the re-run.
  }, [user, authLoading, nonce]);

  return { rollup, source, loading, syncing, error, reload };
}

// ── auto first-sync marker (per session, per account) ───────────────────────

const AUTO_SYNC_PREFIX = "burnbar.profile.autoSync.";

function autoSyncDone(uid: string): boolean {
  try {
    return window.sessionStorage.getItem(AUTO_SYNC_PREFIX + uid) === "1";
  } catch {
    // sessionStorage blocked (private mode) — treat as done so a failing
    // recompute can't retry-loop every render.
    return true;
  }
}

function markAutoSync(uid: string): void {
  try {
    window.sessionStorage.setItem(AUTO_SYNC_PREFIX + uid, "1");
  } catch {
    /* non-fatal */
  }
}
