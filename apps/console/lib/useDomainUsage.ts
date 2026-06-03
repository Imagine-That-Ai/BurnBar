"use client";

import { useCallback, useEffect, useState } from "react";
import { getDataDomainUsage, type DataDomainUsageResponse } from "./api";
import { useAuth } from "./useAuth";

interface UsageState {
  data: DataDomainUsageResponse | null;
  loading: boolean;
  error: string | null;
  reload: () => void;
}

/**
 * Loads the member's data footprint via getDataDomainUsage once authenticated.
 * Fail-soft: an error leaves the Basin/inventory rendering at zero usage so the
 * privacy surface is never blank.
 */
export function useDomainUsage(): UsageState {
  const { user, loading: authLoading } = useAuth();
  const [data, setData] = useState<DataDomainUsageResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    if (authLoading) return;
    if (!user) {
      setData(null);
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    getDataDomainUsage()
      .then((res) => {
        if (!cancelled) setData(res);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : "Could not load your data usage.");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [user, authLoading, nonce]);

  return { data, loading, error, reload };
}

/** Index domain usage by id for O(1) lookup against the registry list. */
export function usageById(data: DataDomainUsageResponse | null): Record<string, { count: number; bytes: number }> {
  const map: Record<string, { count: number; bytes: number }> = {};
  for (const d of data?.domains ?? []) map[d.id] = { count: d.count, bytes: d.bytes };
  return map;
}
