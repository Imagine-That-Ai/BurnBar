"use client";

import { useEffect, useMemo, useState } from "react";
import { doc, getDoc } from "firebase/firestore";

import { db } from "@/lib/firebaseClient";
import { useAuth } from "@/lib/useAuth";
import type {
  CommunityLeaderboardDoc,
  CommunityProfileDoc,
  CommunityShareSnapshotDoc,
  CommunityTimeWindow,
  GeographyTier,
} from "./types";

export type CommunityLiveDataStatus = "signed-out" | "loading" | "ready" | "empty" | "error";

export interface CommunityLiveDataState {
  status: CommunityLiveDataStatus;
  profile: CommunityProfileDoc | null;
  shareSnapshot: CommunityShareSnapshotDoc | null;
  leaderboards: CommunityLeaderboardDoc[];
  errorMessage: string;
}

const EMPTY_STATE: CommunityLiveDataState = {
  status: "signed-out",
  profile: null,
  shareSnapshot: null,
  leaderboards: [],
  errorMessage: "",
};

function normalizeGeoKey(raw: string | undefined): string | undefined {
  const sanitized = raw
    ?.normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-zA-Z0-9-]/g, "")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
  return sanitized || undefined;
}

function geoKeyForTier(profile: CommunityProfileDoc | null, tier: GeographyTier): string | undefined {
  switch (tier) {
    case "world":
      return "world";
    case "country":
      return normalizeGeoKey(profile?.countryCode);
    case "region":
      return normalizeGeoKey(profile?.regionKey);
    case "city":
      return normalizeGeoKey(profile?.cityKey);
  }
}

async function readDocData<T>(path: string): Promise<T | null> {
  const snap = await getDoc(doc(db(), path));
  return snap.exists() ? (snap.data() as T) : null;
}

export function useCommunityLiveData(window: CommunityTimeWindow): CommunityLiveDataState {
  const { user, loading } = useAuth();
  const [state, setState] = useState<CommunityLiveDataState>(EMPTY_STATE);

  useEffect(() => {
    let cancelled = false;
    if (loading) {
      setState((current) => ({ ...current, status: "loading" }));
      return;
    }
    if (!user) {
      setState(EMPTY_STATE);
      return;
    }

    setState((current) => ({ ...current, status: "loading", errorMessage: "" }));
    const uid = user.uid;

    async function load() {
      try {
        const [profile, shareSnapshot] = await Promise.all([
          readDocData<CommunityProfileDoc>(`users/${uid}/community/profile`),
          readDocData<CommunityShareSnapshotDoc>(`users/${uid}/community/share_snapshot`),
        ]);
        const boardReads = (["city", "region", "country", "world"] as GeographyTier[]).map(async (tier) => {
          const geoKey = geoKeyForTier(profile, tier);
          if (!geoKey) return null;
          return readDocData<CommunityLeaderboardDoc>(`community_leaderboards/${window}_${tier}_${geoKey}`);
        });
        const leaderboards = (await Promise.all(boardReads)).filter((board): board is CommunityLeaderboardDoc => board !== null);
        if (cancelled) return;
        setState({
          status: profile || shareSnapshot || leaderboards.length > 0 ? "ready" : "empty",
          profile,
          shareSnapshot,
          leaderboards,
          errorMessage: "",
        });
      } catch (error) {
        if (cancelled) return;
        setState({
          status: "error",
          profile: null,
          shareSnapshot: null,
          leaderboards: [],
          errorMessage: error instanceof Error ? error.message : "Unable to load community data.",
        });
      }
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [loading, user, window]);

  return useMemo(() => state, [state]);
}
