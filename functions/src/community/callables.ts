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
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { onCallProduction, logInfo } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { firestoreWithResilience } from "../resilienceHelpers.js";
import { COMMUNITY_SCHEMA_VERSION, CommunityPaths } from "./consent.js";
import { deriveGeoKeys, populateGeoKeys, normalizeGeoKey } from "./geo.js";
import { assertCommunityRuntimeEnabled } from "./rollout.js";
import { optionalEnumField, optionalString, parseCallableInput } from "../validation/callableSchema.js";
import { refreshCommunityShareSnapshotForUser } from "./snapshot.js";
import type { CommunityConsentDoc, CommunityProfileDoc } from "../types/generated/community.js";
import type { ColumnSource } from "hyparquet-writer";

// ---------------------------------------------------------------------------
// Callable options
// ---------------------------------------------------------------------------

const COMMUNITY_CALLABLE_OPTS = {
  region: FUNCTIONS_REGION,
  timeoutSeconds: 60,
  memory: "256MiB" as const,
};

type HandleClaimTransaction<TRef> = {
  get(ref: TRef): Promise<unknown>;
  set(ref: TRef, data: Record<string, unknown>): unknown;
  delete(ref: TRef): unknown;
};

type HandleClaimFirestore<TRef> = {
  doc(path: string): TRef;
  runTransaction(fn: (tx: HandleClaimTransaction<TRef>) => Promise<void>): Promise<unknown>;
};

function isRecordValue(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function handleClaimExists(snapshot: unknown): boolean {
  if (!isRecordValue(snapshot)) throw new HttpsError("internal", "Invalid handle claim transaction snapshot.");
  const exists = Reflect.get(snapshot, "exists");
  if (typeof exists !== "boolean") throw new HttpsError("internal", "Invalid handle claim existence state.");
  return exists;
}

function handleClaimOwner(snapshot: unknown): unknown {
  if (!isRecordValue(snapshot)) throw new HttpsError("internal", "Invalid handle claim transaction snapshot.");
  const data = Reflect.get(snapshot, "data");
  if (typeof data !== "function") throw new HttpsError("internal", "Invalid handle claim data reader.");
  const raw = data.call(snapshot);
  return isRecordValue(raw) ? raw.uid : undefined;
}

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
  "admin",
  "root",
  "system",
  "burnbar",
  "support",
  "official",
  "moderator",
  "fuck",
  "shit",
  "dick",
  "cunt",
  "bitch",
  "nigger",
  "nazi",
  "faggot",
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
async function claimHandleTransaction<TRef>(
  db: HandleClaimFirestore<TRef>,
  uid: string,
  newHandleLower: string,
  oldHandleLower: string | null,
): Promise<void> {
  await db.runTransaction(async (tx) => {
    const claimRef = db.doc(CommunityPaths.handleClaim(newHandleLower));
    const claimSnap = await tx.get(claimRef);

    if (handleClaimExists(claimSnap)) {
      const owner = handleClaimOwner(claimSnap);
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
async function claimHandleRelease<TRef>(
  db: HandleClaimFirestore<TRef>,
  uid: string,
  handleLower: string,
): Promise<void> {
  await db.runTransaction(async (tx) => {
    const ref = db.doc(CommunityPaths.handleClaim(handleLower));
    const snap = await tx.get(ref);
    // Only delete if it belongs to this user (defensive).
    if (handleClaimExists(snap) && handleClaimOwner(snap) === uid) {
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

function validatedJoinHandle(raw: string | undefined): string | undefined {
  if (raw === undefined) return undefined;
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  if (!isValidHandle(trimmed)) {
    throw new HttpsError("invalid-argument", "Handle must be 3-24 chars, alphanumeric + _-.");
  }
  return trimmed;
}

function buildConsentDoc(data: JoinCommunityInput, now: string): CommunityConsentDoc {
  return {
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
}

function applyJoinGeo(profileDoc: CommunityProfileDoc & { handleLower?: string }, data: JoinCommunityInput): void {
  const geo = deriveGeoKeys(data.timezone ?? "", data.locale ?? "");
  populateGeoKeys(profileDoc, geo, {
    country: data.l2Country === "granted",
    region: data.l2Region === "granted",
    city: false,
  });

  if (data.l2Country === "granted") {
    const normalized = normalizeGeoKey(data.countryCode);
    if (normalized) profileDoc.countryCode = normalized;
  }
  if (data.l2Region === "granted") {
    const normalized = normalizeGeoKey(data.regionKey);
    if (normalized) profileDoc.regionKey = normalized;
  }
  if (data.l2City === "granted" && data.locationConsent === "granted") {
    const normalized = normalizeGeoKey(data.cityKey);
    if (normalized) profileDoc.cityKey = normalized;
  }
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
    assertCommunityRuntimeEnabled("join");

    const data = request.data ?? {};
    const now = new Date().toISOString();
    const requestedHandle = validatedJoinHandle(data.handle);
    const generatedAnonId = randomUUID().replace(/-/g, "").slice(0, 16);
    let anonId = generatedAnonId;

    const db = getFirestore();
    const consentDoc = buildConsentDoc(data, now);

    await firestoreWithResilience("community-join-write", () =>
      db.runTransaction(async (tx) => {
        const consentRef = db.doc(CommunityPaths.consent(uid));
        const profileRef = db.doc(CommunityPaths.profile(uid));
        const profileSnap = await tx.get(profileRef);
        const oldProfile = profileSnap.data();
        const existingAnonId = typeof oldProfile?.anonId === "string" ? oldProfile.anonId : undefined;
        const existingHandle = typeof oldProfile?.handle === "string" ? oldProfile.handle : undefined;
        const existingHandleLower = typeof oldProfile?.handleLower === "string" ? oldProfile.handleLower : null;
        anonId = existingAnonId ?? generatedAnonId;

        const finalHandle = requestedHandle ?? existingHandle;
        const finalHandleLower = finalHandle?.toLowerCase();
        if (finalHandleLower) {
          const claimRef = db.doc(CommunityPaths.handleClaim(finalHandleLower));
          const claimSnap = await tx.get(claimRef);
          if (claimSnap.exists) {
            const owner = claimSnap.data()?.uid;
            if (owner !== uid) {
              throw new HttpsError("already-exists", "That handle is taken.");
            }
          } else {
            tx.set(claimRef, { uid, createdAt: now });
          }
        }
        if (existingHandleLower && existingHandleLower !== finalHandleLower) {
          tx.delete(db.doc(CommunityPaths.handleClaim(existingHandleLower)));
        }

        const profileDoc: CommunityProfileDoc & { handleLower?: string } = {
          anonId,
          schemaVersion: COMMUNITY_SCHEMA_VERSION,
          updatedAt: now,
        };
        if (finalHandle) {
          profileDoc.handle = finalHandle;
          profileDoc.handleLower = finalHandle.toLowerCase();
        }
        applyJoinGeo(profileDoc, data);

        tx.set(consentRef, consentDoc);
        tx.set(profileRef, profileDoc);
      }),
    );

    await refreshCommunityShareSnapshotForUser(db, uid, new Date(now));

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

type CommunityTierGrants = Record<string, string>;

const UPDATE_PROFILE_INPUT = {
  handle: optionalString({ maxLength: HANDLE_MAX_LENGTH }),
  timezone: optionalString({ maxLength: 128 }),
  locale: optionalString({ maxLength: 64 }),
  countryCode: optionalString({ maxLength: 16 }),
  regionKey: optionalString({ maxLength: 96 }),
  cityKey: optionalString({ maxLength: 128 }),
} as const;

function optionalParsedString(value: unknown, fieldName: string): string | undefined {
  if (value === undefined || typeof value === "string") return value;
  throw new HttpsError("internal", `Validated community profile field ${fieldName} did not parse to a string.`);
}

function parseUpdateProfileInput(data: unknown): UpdateProfileInput {
  const parsed = parseCallableInput("updateCommunityProfile", UPDATE_PROFILE_INPUT, data);
  return {
    handle: optionalParsedString(parsed.handle, "handle"),
    timezone: optionalParsedString(parsed.timezone, "timezone"),
    locale: optionalParsedString(parsed.locale, "locale"),
    countryCode: optionalParsedString(parsed.countryCode, "countryCode"),
    regionKey: optionalParsedString(parsed.regionKey, "regionKey"),
    cityKey: optionalParsedString(parsed.cityKey, "cityKey"),
  };
}

function communityTierGrants(consent: Record<string, unknown>): CommunityTierGrants {
  if (consent.l2Rankings !== "granted") return {};
  const tiers = consent.l2Tiers;
  if (!tiers || typeof tiers !== "object" || Array.isArray(tiers)) return {};
  const out: CommunityTierGrants = {};
  for (const key of ["world", "country", "region", "city"]) {
    const value = Reflect.get(tiers, key);
    if (typeof value === "string") out[key] = value;
  }
  return out;
}

async function applyProfileHandleUpdate<TRef>(
  db: HandleClaimFirestore<TRef>,
  uid: string,
  handle: string | undefined,
  oldHandleLower: string | null,
  updates: Record<string, unknown>,
): Promise<void> {
  if (handle === undefined) return;

  const trimmed = handle.trim();
  if (!trimmed) {
    if (oldHandleLower) await claimHandleRelease(db, uid, oldHandleLower);
    updates.handle = null;
    updates.handleLower = null;
    return;
  }

  if (!isValidHandle(trimmed)) {
    throw new HttpsError("invalid-argument", "Handle must be 3-24 chars, alphanumeric + _-.");
  }

  const newLower = trimmed.toLowerCase();
  await claimHandleTransaction(db, uid, newLower, oldHandleLower);
  updates.handle = trimmed;
  updates.handleLower = newLower;
}

function setNormalizedGeoUpdate(
  updates: Record<string, unknown>,
  field: "countryCode" | "regionKey" | "cityKey",
  raw: string | undefined,
  granted: boolean,
): void {
  if (raw === undefined || raw.trim() === "" || !granted) return;
  const normalized = normalizeGeoKey(raw);
  if (normalized) updates[field] = normalized;
}

function applyProfileGeoUpdates(
  data: UpdateProfileInput,
  tiers: CommunityTierGrants,
  updates: Record<string, unknown>,
): void {
  if (data.timezone || data.locale) {
    const geo = deriveGeoKeys(data.timezone ?? "", data.locale ?? "");
    if (geo.countryCode && tiers.country === "granted") updates.countryCode = geo.countryCode;
    if (geo.regionKey && tiers.region === "granted") updates.regionKey = geo.regionKey;
  }

  setNormalizedGeoUpdate(updates, "countryCode", data.countryCode, tiers.country === "granted");
  setNormalizedGeoUpdate(updates, "regionKey", data.regionKey, tiers.region === "granted");
  setNormalizedGeoUpdate(updates, "cityKey", data.cityKey, tiers.city === "granted");
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
    assertCommunityRuntimeEnabled("profile update");

    const data = parseUpdateProfileInput(request.data);
    const db = getFirestore();
    const consentDoc = await db.doc(CommunityPaths.consent(uid)).get();
    if (!consentDoc.exists) {
      throw new HttpsError("failed-precondition", "Join the community before updating your profile.");
    }

    const profileSnap = await db.doc(CommunityPaths.profile(uid)).get();
    const oldProfile = profileSnap.data();
    const oldHandleLower = typeof oldProfile?.handleLower === "string" ? oldProfile.handleLower : null;
    const updates: Record<string, unknown> = { updatedAt: new Date().toISOString() };

    await applyProfileHandleUpdate(db, uid, data.handle, oldHandleLower, updates);
    applyProfileGeoUpdates(data, communityTierGrants(consentDoc.data() ?? {}), updates);

    await firestoreWithResilience("community-profile-update", () =>
      db.doc(CommunityPaths.profile(uid)).set(updates, { merge: true }),
    );
    await refreshCommunityShareSnapshotForUser(db, uid);

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
    const oldProfile = profileSnap.data();
    const oldHandleLower = typeof oldProfile?.handleLower === "string" ? oldProfile.handleLower : null;

    // Required audit event first — if this fails, no revocation mutation runs.
    await appendAuditEventRequired(uid, {
      actor: auditActorLabel(request),
      action: "community.revoke",
      domain: "community",
    });

    await firestoreWithResilience("community-revoke", async () => {
      const batch = db.batch();

      // Delete the server-owned share snapshot immediately; the next
      // aggregation sweep also removes public boards whose cohorts vanished.
      batch.delete(db.doc(CommunityPaths.shareSnapshot(uid)));

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
        schemaVersion: COMMUNITY_SCHEMA_VERSION,
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
type LookingGlassExportFormat = "jsonl" | "parquet";
const LOOKING_GLASS_EXPORT_INPUT = {
  format: optionalEnumField(["jsonl", "parquet"]),
} as const;

interface SerializedLookingGlassBundle {
  buffer: Buffer;
  extension: LookingGlassExportFormat;
  contentType: string;
}

function requestedLookingGlassExportFormat(raw: unknown): LookingGlassExportFormat {
  if (raw === undefined || raw === null || raw === "") return "jsonl";
  if (raw === "jsonl" || raw === "parquet") return raw;
  throw new HttpsError("invalid-argument", "Looking Glass export format must be jsonl or parquet.");
}

async function serializeLookingGlassBundle(
  rows: Array<Record<string, unknown>>,
  format: LookingGlassExportFormat,
): Promise<SerializedLookingGlassBundle> {
  if (format === "jsonl") {
    return {
      buffer: Buffer.from(rows.map((row) => JSON.stringify(row)).join("\n"), "utf-8"),
      extension: "jsonl",
      contentType: "application/x-ndjson",
    };
  }

  const jsonRows = rows.map((row) => JSON.stringify(row));
  const columnData: ColumnSource[] = [
    { name: "json", data: jsonRows, type: "STRING", nullable: false },
    {
      name: "sessionId",
      data: rows.map((row) => (typeof row.sessionId === "string" ? row.sessionId : null)),
      type: "STRING",
      nullable: true,
    },
    {
      name: "recordedAt",
      data: rows.map((row) => (typeof row.recordedAt === "string" ? row.recordedAt : null)),
      type: "STRING",
      nullable: true,
    },
  ];

  // hyparquet-writer is ESM-only while this Functions package compiles as
  // CommonJS under NodeNext; a static value import fails TS1479 at build time.
  const { parquetWriteBuffer } = await import("hyparquet-writer");
  const arrayBuffer = parquetWriteBuffer({
    columnData,
    rowGroupSize: Math.min(Math.max(rows.length, 1), 1000),
    kvMetadata: [
      { key: "openburnbar.domain", value: "looking_glass" },
      { key: "openburnbar.schema_version", value: String(COMMUNITY_SCHEMA_VERSION) },
    ],
  });

  return {
    buffer: Buffer.from(arrayBuffer),
    extension: "parquet",
    contentType: "application/vnd.apache.parquet",
  };
}

/**
 * Exports the user's Looking Glass traces as a JSONL or Parquet bundle in Cloud
 * Storage and returns a signed download URL. Requires L3 consent.
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
  assertCommunityRuntimeEnabled("Looking Glass export");

    const input = parseCallableInput("exportLookingGlassBundle", LOOKING_GLASS_EXPORT_INPUT, request.data, {
      rejectUnknownKeys: true,
    });
    const format = requestedLookingGlassExportFormat(input.format);
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

    const rows = tracesSnapshot.docs.map((doc) => ({ traceId: doc.id, ...doc.data() }));
    const bundle = await serializeLookingGlassBundle(rows, format);
    const exportId = `${Date.now()}_${randomBytes(4).toString("hex")}`;
    const storagePath = `looking_glass_exports/${uid}/${exportId}.${bundle.extension}`;

    // Required audit event before writing export bytes/metadata. If audit fails,
    // the export does not leave the process.
    await appendAuditEventRequired(uid, {
      actor: auditActorLabel(request),
      action: AUDIT_ACTIONS.dataExport,
      domain: "looking_glass",
    });

    const bucket = getStorage().bucket();
    const file = bucket.file(storagePath);
    await file.save(bundle.buffer, { contentType: bundle.contentType });

    const [signedUrl] = await file.getSignedUrl({
      action: "read",
      expires: Date.now() + SIGNED_URL_TTL_SECONDS * 1000,
    });

    // Record export metadata.
    await firestoreWithResilience("community-lg-export-write", () =>
      db.collection(CommunityPaths.lookingGlassExports(uid)).add({
        storagePath,
        format: bundle.extension,
        traceCount: tracesSnapshot.size,
        sizeBytes: bundle.buffer.length,
        createdAt: new Date().toISOString(),
        schemaVersion: COMMUNITY_SCHEMA_VERSION,
      }),
    );

    logInfo({
      event: "community_lg_export",
      uid_prefix: uid.slice(0, 8),
      traceCount: tracesSnapshot.size,
      format: bundle.extension,
    });

    return {
      signedUrl,
      downloadUrl: signedUrl,
      traceCount: tracesSnapshot.size,
      format: bundle.extension,
      expiresIn: SIGNED_URL_TTL_SECONDS,
    };
  },
);

/** Test-only bundle for unit tests (not re-exported from community barrel). */
export const __communityCallableTestExports = {
  isValidHandle,
  SIGNED_URL_TTL_SECONDS,
};
