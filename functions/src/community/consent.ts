/**
 * @fileoverview Server-side consent recheck for the Community subsystem.
 *
 * The server NEVER trusts the client's propagated consent state as the sole
 * gate for data egress. Instead, every aggregation sweep re-reads the
 * persisted consent document from Firestore and applies a strict dark-before-
 * opt-in policy. This mirrors the pattern established by
 * `AnalyticsConsentStore.swift` / `consent.ts`: unset and declined are
 * identical dark states (fail closed), and only an explicit "granted" permits
 * processing.
 *
 * The `recheckConsent` function is the single server-side gate. It:
 *   1. Reads `users/{uid}/community/consent`.
 *   2. Returns a snapshot with per-level and per-tier booleans.
 *   3. Treats any malformed / missing document as fully dark.
 */

import type { Firestore } from "firebase-admin/firestore";
import { firestoreWithResilience } from "../resilienceHelpers.js";
import { normalizeGeoKey } from "./geo.js";

/** K-anonymity threshold: a cohort needs >= K members to publish a board. */
export const COMMUNITY_K_THRESHOLD = 10;

/** Schema version for community documents. */
export const COMMUNITY_SCHEMA_VERSION = 1;

/**
 * Normalized consent snapshot after server-side recheck. Every boolean is
 * false unless the persisted doc explicitly grants at that level / tier.
 */
interface CommunityConsentSnapshot {
  /** L1 — local-only analytics (never read server-side, but tracked). */
  l1Analytics: boolean;
  /** L2 — any geography tier opted in. */
  l2Rankings: boolean;
  /** L2 per-tier granularity. */
  l2World: boolean;
  l2Country: boolean;
  l2Region: boolean;
  l2City: boolean;
  /** L3 — Looking Glass traces. */
  l3LookingGlass: boolean;
  /** Separate coarse-location consent (city tier prerequisite). */
  locationConsent: boolean;
}

const FULLY_DARK: CommunityConsentSnapshot = {
  l1Analytics: false,
  l2Rankings: false,
  l2World: false,
  l2Country: false,
  l2Region: false,
  l2City: false,
  l3LookingGlass: false,
  locationConsent: false,
};

function isGranted(raw: unknown): boolean {
  return raw === "granted";
}

/**
 * Re-read the persisted consent document and return a normalized snapshot.
 * Missing or malformed doc → fully dark. City tier additionally requires
 * locationConsent (per the spec's separate location consent gate).
 */
export async function recheckConsent(db: Firestore, uid: string): Promise<CommunityConsentSnapshot> {
  const snapshot = await firestoreWithResilience("community-consent-read", () =>
    db.doc(`users/${uid}/community/consent`).get(),
  );

  if (!snapshot.exists) return { ...FULLY_DARK };

  const data = snapshot.data();
  if (!data || typeof data !== "object") return { ...FULLY_DARK };

  const tiers = data.l2Tiers;
  const tierData = tiers && typeof tiers === "object" ? tiers : {};

  const l2World = isGranted(tierData.world);
  const l2Country = isGranted(tierData.country);
  const l2Region = isGranted(tierData.region);
  const l2City = isGranted(tierData.city) && isGranted(data.locationConsent);

  return {
    l1Analytics: isGranted(data.l1Analytics),
    l2Rankings: l2World || l2Country || l2Region || l2City,
    l2World,
    l2Country,
    l2Region,
    l2City,
    l3LookingGlass: isGranted(data.l3LookingGlass),
    locationConsent: isGranted(data.locationConsent),
  };
}

/**
 * Collection-path helpers — kept here so callables + aggregation share one
 * definition of the document layout.
 */
export const CommunityPaths = {
  consent: (uid: string) => `users/${uid}/community/consent`,
  profile: (uid: string) => `users/${uid}/community/profile`,
  shareSnapshot: (uid: string) => `users/${uid}/community/share_snapshot`,
  leaderboard: (window: string, tier: string, geoKey: string) => {
    // Defense-in-depth: normalize the geoKey before embedding it in the doc ID.
    // Even though callables normalize before persisting, the aggregation reads
    // from share_snapshot docs that may contain legacy or malformed keys.
    const safe = normalizeGeoKey(geoKey) ?? "unknown";
    return `community_leaderboards/${window}_${tier}_${safe}`;
  },
  lookingGlassTraces: (uid: string) => `users/${uid}/looking_glass_traces`,
  lookingGlassExports: (uid: string) => `users/${uid}/looking_glass_exports`,
  /** Rules-facing rollout envelope for public leaderboard reads. */
  publicReadStatus: () => "ops/community_status/state/current",
  /** Global uniqueness claim — doc ID IS the lowercased handle. */
  handleClaim: (handleLower: string) => `community_handles/${handleLower}`,
} as const;
