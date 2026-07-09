/**
 * @fileoverview Community callables — join, update profile, revoke, export.
 *
 * Four production callables gated by auth + onCallProduction logging:
 *   - joinCommunity: write consent doc + create profile (auto-generated anonId + handle)
 *   - updateCommunityProfile: update handle (uniqueness + profanity guard)
 *   - revokeCommunityParticipation: tombstone share/profile, audit-log, consent→declined
 *   - exportLookingGlassBundle: signed Storage URL for L3 trace export
 *
 * Every callable enforces auth.uid ownership and never trusts client-propagated
 * consent for data egress — the aggregation sweep rechecks consent server-side.
 */

import { randomBytes, randomUUID } from "node:crypto";

import { appendAuditEventRequired, AUDIT_ACTIONS, auditActorLabel } from "../callables/auditLog.js";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { onCallProduction, logInfo } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { firestoreWithResilience } from "../resilienceHelpers.js";
import { COMMUNITY_SCHEMA_VERSION, CommunityPaths } from "./consent.js";
import { deriveGeoKeys, populateGeoKeys, normalizeGeoKey } from "./geo.js";
import type { CommunityConsentDoc, CommunityProfileDoc } from "../types/generated/community.js";

// ---------------------------------------------------------------------------
// Callable options
// ---------------------------------------------------------------------------

const COMMUNITY_CALLABLE_OPTS = {
  region: FUNCTIONS_REGION,
  timeoutSeconds: 60,
  memory: "256MiB" as const,
};

// ---------------------------------------------------------------------------
// Handle validation
// ---------------------------------------------------------------------------

const HANDLE_MIN_LENGTH = 3;
const HANDLE_MAX_LENGTH = 24;
const HANDLE_PATTERN = /^[a-zA-Z0-9_-]+$/;

/**
 * Minimal profanity blocklist for handle validation. Not exhaustive — it's a
 * first line of defense. The real moderation happens client-side with user
 * corrections and post-hoc review. Case-insensitive substring matching.
 */
const PROFANITY_BLOCKLIST = [
  "admin", "root", "system", "burnbar", "support", "official", "moderator",
  "fuck", "shit", "dick", "cunt", "bitch", "nigger", "nazi", "faggot",
] as const;

export function isValidHandle(handle: string): boolean {
  if (handle.length < HANDLE_MIN_LENGTH || handle.length > HANDLE_MAX_LENGTH) return false;
  if (!HANDLE_PATTERN.test(handle)) return false;
  const lower = handle.toLowerCase();
  return !PROFANITY_BLOCKLIST.some((word) => lower.includes(word));
}

/**
 * Atomically claim a handle via a dedicated community_handles/{handleLower}
 * document inside a Firestore transaction. The doc ID IS the lowercased
 * handle, so uniqueness is enforced by Firestore's document-ID constraint —
 * no collectionGroup scan, no index, no TOCTOU race.
 *
 * `oldHandleLower` (if any) is released in the same transaction so a handle
 * change is atomic.
 */
export async function claimHandleTransaction(
  db: Firestore,
  uid: string,
  newHandleLower: string,
  oldHandleLower: string | null,
): Promise<void> {
  await db.runTransaction(async (tx) => {
    const claimRef = db.doc(CommunityPaths.handleClaim(newHandleLower));
    const claimSnap = await tx.get(claimRef);

    if (claimSnap.exists) {
      const owner = claimSnap.data()?.uid;
      if (owner !== uid) {
        throw new HttpsError("already-exists", "That handle is taken.");
      }
      // Same owner re-claiming — no-op, allow.
    } else {
      tx.set(claimRef, { uid, createdAt: new Date().toISOString() });
    }

    // Release the old handle in the same transaction.
    if (oldHandleLower && oldHandleLower !== newHandleLower) {
      tx.delete(db.doc(CommunityPaths.handleClaim(oldHandleLower)));
    }
  });
}

/** Release a handle claim — used when clearing the handle or revoking. */
async function claimHandleRelease(db: Firestore, uid: string, handleLower: string): Promise<void> {
  await db.runTransaction(async (tx) => {
    const ref = db.doc(CommunityPaths.handleClaim(handleLower));
    const snap = await tx.get(ref);
    // Only delete if it belongs to this user (defensive).
    if (snap.exists && snap.data()?.uid === uid) {
      tx.delete(ref);
    }
  });
}

// ---------------------------------------------------------------------------
// joinCommunity
// ---------------------------------------------------------------------------

interface JoinCommunityInput {
  l1Analytics?: string;
  l2Rankings?: string;
  l2World?: string;
  l2Country?: string;
  l2Region?: string;
  l2City?: string;
  locationConsent?: string;
  l3LookingGlass?: string;
  handle?: string;
  /** IANA timezone (e.g. "America/Los_Angeles") for locale/timezone geo derivation. */
  timezone?: string;
  /** BCP 47 locale (e.g. "en-US") for locale/timezone geo derivation. */
  locale?: string;
  /** Optional manual override for geo keys (manual picker fallback). */
  countryCode?: string;
  regionKey?: string;
  cityKey?: string;
}

/**
 * Creates the consent doc + profile doc. The user opts into one or more levels.
 * Generates a stable anonId and an auto handle if none is provided.
 */
export const joinCommunity = onCallProduction(
  "joinCommunity",
  COMMUNITY_CALLABLE_OPTS,
  async (request: CallableRequest<JoinCommunityInput>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to join the community.");

    const data = request.data ?? {};
    const now = new Date().toISOString();
    const anonId = randomUUID().replace(/-/g, "").slice(0, 16);

    // Validate handle if provided.
    let handle: string | undefined;
    if (data.handle) {
      const trimmed = data.handle.trim();
      if (!isValidHandle(trimmed)) {
        throw new HttpsError("invalid-argument", "Handle must be 3-24 chars, alphanumeric + _-.");
      }
      handle = trimmed;
    }

    const db = getFirestore();

    // Atomically claim the handle if one was provided.
    if (handle) {
      await claimHandleTransaction(db, uid, handle.toLowerCase(), null);
    }

    // Write consent doc.
    const consentDoc: CommunityConsentDoc = {
      l1Analytics: data.l1Analytics === "granted" ? "granted" : "declined",
      l2Rankings: data.l2Rankings === "granted" ? "granted" : "declined",
      l2Tiers: {
        world: data.l2World === "granted" ? "granted" : "declined",
        country: data.l2Country === "granted" ? "granted" : "declined",
        region: data.l2Region === "granted" ? "granted" : "declined",
        city: data.l2City === "granted" ? "granted" : "declined",
      },
      l3LookingGlass: data.l3LookingGlass === "granted" ? "granted" : "declined",
      locationConsent: data.locationConsent === "granted" ? "granted" : "declined",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: now,
      optedInAt: now,
    };

    // Write profile doc — only include geo keys at consented tiers.
    const profileDoc: CommunityProfileDoc & { handleLower?: string } = {
      anonId,
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: now,
    };
    if (handle) {
      profileDoc.handle = handle;
      profileDoc.handleLower = handle.toLowerCase();
    }
    // Geo keys: derive from timezone/locale (no location permission needed for
    // country/region). Client may override via manual picker. City tier
    // requires OS location (passed as cityKey when locationConsent is granted).
    const geo = deriveGeoKeys(data.timezone ?? "", data.locale ?? "");
    populateGeoKeys(profileDoc, geo, {
      country: data.l2Country === "granted",
      region: data.l2Region === "granted",
      city: false, // cityKey requires OS location, not timezone/locale
    });
    // Manual override (manual picker or client-provided). Normalize ALL
    // client-provided geo keys through normalizeGeoKey before persisting —
    // defense-in-depth against path injection (a `/` in a key crashes the
    // hourly aggregation loop via db.doc() throwing).
    if (data.l2Country === "granted") {
      const normalized = normalizeGeoKey(data.countryCode);
      if (normalized) profileDoc.countryCode = normalized;
    }
    if (data.l2Region === "granted") {
      const normalized = normalizeGeoKey(data.regionKey);
      if (normalized) profileDoc.regionKey = normalized;
    }
    if (data.l2City === "granted" && data.locationConsent === "granted") {
      profileDoc.cityKey = normalizeGeoKey(data.cityKey);
    }

    await firestoreWithResilience("community-join-write", async () => {
      const batch = db.batch();
      batch.set(db.doc(CommunityPaths.consent(uid)), consentDoc);
      batch.set(db.doc(CommunityPaths.profile(uid)), profileDoc);
      await batch.commit();
    });

    logInfo({ event: "community_join", uid_prefix: uid.slice(0, 8) });

    return { ok: true, anonId };
  },
);

// ---------------------------------------------------------------------------
// updateCommunityProfile
// ---------------------------------------------------------------------------

interface UpdateProfileInput {
  handle?: string;
  /** IANA timezone for server-side geo re-derivation. */
  timezone?: string;
  /** BCP 47 locale for server-side geo re-derivation. */
  locale?: string;
  /** Manual override geo keys. */
  countryCode?: string;
  regionKey?: string;
  cityKey?: string;
}

/**
 * Updates the community profile. Handle changes go through uniqueness +
 * profanity validation. Geo key updates require the corresponding tier consent.
 */
export const updateCommunityProfile = onCallProduction(
  "updateCommunityProfile",
  COMMUNITY_CALLABLE_OPTS,
  async (request: CallableRequest<UpdateProfileInput>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to update your profile.");

    const data = request.data ?? {};
    const db = getFirestore();

    // Verify consent exists.
    const consentDoc = await db.doc(CommunityPaths.consent(uid)).get();
    if (!consentDoc.exists) {
      throw new HttpsError("failed-precondition", "Join the community before updating your profile.");
    }

    const updates: Record<string, unknown> = { updatedAt: new Date().toISOString() };

    // Read current profile to get old handle for atomic release.
    const profileSnap = await db.doc(CommunityPaths.profile(uid)).get();
    const oldProfile = profileSnap.data();
    const oldHandleLower = typeof oldProfile?.handleLower === "string" ? oldProfile.handleLower : null;

    if (data.handle !== undefined) {
      const trimmed = data.handle.trim();
      if (trimmed) {
        if (!isValidHandle(trimmed)) {
          throw new HttpsError("invalid-argument", "Handle must be 3-24 chars, alphanumeric + _-.");
        }
        const newLower = trimmed.toLowerCase();
        // Atomically claim new + release old in one transaction.
        await claimHandleTransaction(db, uid, newLower, oldHandleLower);
        updates.handle = trimmed;
        updates.handleLower = newLower;
      } else {
        // Clear handle → fully anonymous. Release the claim.
        if (oldHandleLower) {
          await claimHandleRelease(db, uid, oldHandleLower);
        }
        updates.handle = null;
        updates.handleLower = null;
      }
    }

    // Geo key updates are gated by consent — verify before allowing.
    const consent = consentDoc.data() ?? {};
    const tiers = (consent.l2Tiers ?? {}) as Record<string, string>;

    // Server-side geo re-derivation from timezone/locale when provided.
    if (data.timezone || data.locale) {
      const geo = deriveGeoKeys(data.timezone ?? "", data.locale ?? "");
      if (geo.countryCode && tiers.country === "granted") {
        updates.countryCode = geo.countryCode;
      }
      if (geo.regionKey && tiers.region === "granted") {
        updates.regionKey = geo.regionKey;
      }
    }
    if (data.countryCode !== undefined && tiers.country === "granted") {
      updates.countryCode = normalizeGeoKey(data.countryCode) ?? null;
    }
    if (data.regionKey !== undefined && tiers.region === "granted") {
      updates.regionKey = normalizeGeoKey(data.regionKey) ?? null;
    }
    if (data.cityKey !== undefined && tiers.city === "granted") {
      updates.cityKey = normalizeGeoKey(data.cityKey) ?? null;
    }

    await firestoreWithResilience("community-profile-update", () =>
      db.doc(CommunityPaths.profile(uid)).set(updates, { merge: true }),
    );

    return { ok: true };
  },
);

// ---------------------------------------------------------------------------
// revokeCommunityParticipation
// ---------------------------------------------------------------------------

/**
 * Full revocation: marks share_snapshot as revoked (tombstone for the next
 * aggregation sweep), deletes the profile doc, sets all consent levels to
 * declined, and audit-logs the action. The aggregation sweep will pick up the
 * tombstone and stop including the user in leaderboards.
 */
export const revokeCommunityParticipation = onCallProduction(
  "revokeCommunityParticipation",
  COMMUNITY_CALLABLE_OPTS,
  async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to revoke participation.");

    const db = getFirestore();
    const now = new Date().toISOString();

    // Read the profile first to get the handle for claim release.
    const profileSnap = await db.doc(CommunityPaths.profile(uid)).get();
    const oldHandleLower =
      typeof profileSnap.data()?.handleLower === "string"
        ? (profileSnap.data()!.handleLower as string)
        : null;

    // Required audit event first — if this fails, no revocation mutation runs.
    await appendAuditEventRequired(uid, {
      actor: auditActorLabel(request),
      action: "community.revoke",
      domain: "community",
    });

    await firestoreWithResilience("community-revoke", async () => {
      const batch = db.batch();

      // Tombstone the share_snapshot (aggregation sweep will delete it).
      const shareRef = db.doc(CommunityPaths.shareSnapshot(uid));
      const shareDoc = await shareRef.get();
      if (shareDoc.exists) {
        batch.set(shareRef, { revoked: true, updatedAt: now }, { merge: true });
      }

      // Delete profile doc.
      batch.delete(db.doc(CommunityPaths.profile(uid)));

      // Set all consent levels to declined.
      batch.set(db.doc(CommunityPaths.consent(uid)), {
        l1Analytics: "declined",
        l2Rankings: "declined",
        l2Tiers: {
          world: "declined",
          country: "declined",
          region: "declined",
          city: "declined",
        },
        l3LookingGlass: "declined",
        locationConsent: "declined",
        updatedAt: now,
      });

      await batch.commit();
    });

    // Release the handle claim so the handle becomes available again.
    if (oldHandleLower) {
      await claimHandleRelease(db, uid, oldHandleLower);
    }


    logInfo({ event: "community_revoke", uid_prefix: uid.slice(0, 8) });

    return { ok: true };
  },
);

// ---------------------------------------------------------------------------
// exportLookingGlassBundle
// ---------------------------------------------------------------------------

const SIGNED_URL_TTL_SECONDS = 15 * 60;
const MAX_EXPORT_TRACES = 10_000;

/**
 * Exports the user's Looking Glass traces as a JSONL bundle in Cloud Storage
 * and returns a signed download URL. Requires L3 consent.
 */
export const exportLookingGlassBundle = onCallProduction(
  "exportLookingGlassBundle",
  {
    ...COMMUNITY_CALLABLE_OPTS,
    timeoutSeconds: 120,
    memory: "512MiB" as const,
  },
  async (request: CallableRequest<{ format?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to export your data.");

    const db = getFirestore();

    // Verify L3 consent server-side.
    const consentDoc = await db.doc(CommunityPaths.consent(uid)).get();
    if (!consentDoc.exists || consentDoc.data()?.l3LookingGlass !== "granted") {
      throw new HttpsError("permission-denied", "Looking Glass Mode consent is required for export.");
    }

    // Collect traces (bounded).
    const tracesSnapshot = await firestoreWithResilience("community-lg-export-read", () =>
      db.collection(CommunityPaths.lookingGlassTraces(uid)).limit(MAX_EXPORT_TRACES).get(),
    );

    if (tracesSnapshot.empty) {
      throw new HttpsError("not-found", "No Looking Glass traces to export.");
    }

    // Build JSONL bundle.
    const lines = tracesSnapshot.docs.map((doc) => JSON.stringify(doc.data()));
    const jsonl = lines.join("\n");
    const buffer = Buffer.from(jsonl, "utf-8");
    const exportId = `${Date.now()}_${randomBytes(4).toString("hex")}`;
    const storagePath = `looking_glass_exports/${uid}/${exportId}.jsonl`;

    // Required audit event before writing export bytes/metadata. If audit fails,
    // the export does not leave the process.
    await appendAuditEventRequired(uid, {
      actor: auditActorLabel(request),
      action: AUDIT_ACTIONS.dataExport,
      domain: "looking_glass",
    });

    const bucket = getStorage().bucket();
    const file = bucket.file(storagePath);
    await file.save(buffer, { contentType: "application/x-ndjson" });

    const [signedUrl] = await file.getSignedUrl({
      action: "read",
      expires: Date.now() + SIGNED_URL_TTL_SECONDS * 1000,
    });

    // Record export metadata.
    await firestoreWithResilience("community-lg-export-write", () =>
      db.collection(CommunityPaths.lookingGlassExports(uid)).add({
        storagePath,
        format: "jsonl",
        traceCount: tracesSnapshot.size,
        sizeBytes: buffer.length,
        createdAt: new Date().toISOString(),
        schemaVersion: COMMUNITY_SCHEMA_VERSION,
      }),
    );


    logInfo({
      event: "community_lg_export",
      uid_prefix: uid.slice(0, 8),
      traceCount: tracesSnapshot.size,
    });

    return { signedUrl, traceCount: tracesSnapshot.size, expiresIn: SIGNED_URL_TTL_SECONDS };
  },
);

/** Test-only bundle for unit tests (not re-exported from community barrel). */
export const __communityCallableTestExports = {
  isValidHandle,
  claimHandleTransaction,
  SIGNED_URL_TTL_SECONDS,
};
