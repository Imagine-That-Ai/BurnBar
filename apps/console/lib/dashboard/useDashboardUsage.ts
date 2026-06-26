"use client";

import { useMemo } from "react";
import { buildMockWindow } from "./mockUsage";
import type {
  DashboardRange,
  DashboardUsageResult,
  DashboardWindow,
} from "./types";

/**
 * LIVE SEAM.
 *
 * When a Firebase / Cloud-Functions usage feed is available, implement this to
 * return a real window (or null while it is still loading / absent). Today no
 * aggregate burn feed reaches the static console: it is served from
 * app.burnbar.ai and its CSP `connect-src` excludes localhost, so the local
 * daemon is unreachable, and no Cloud Function exposes aggregate usage yet.
 * Until that backend lands (see components/dashboard/README.md → Follow-ups),
 * this returns null and the dashboard renders clearly-labeled demo data.
 *
 * Flipping a card from demo to live then requires NO card changes — only this
 * function.
 */
export function loadLiveDashboardWindow(
  _range: DashboardRange,
): DashboardWindow | null {
  return null;
}

/** Resolve the usage window for a range, preferring live data over the mock. */
export function useDashboardUsage(
  range: DashboardRange = "7d",
): DashboardUsageResult {
  return useMemo<DashboardUsageResult>(() => {
    const live = loadLiveDashboardWindow(range);
    if (live) return { data: live, source: "live", loading: false };
    return { data: buildMockWindow(range), source: "mock", loading: false };
  }, [range]);
}
