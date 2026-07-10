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
import { getFirestore, type Firestore, type Transaction } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
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
  enforceAppCheck: getConfig().enforceAppCheck,
  timeoutSeconds: 60,
  memory: "256MiB" as const,
};

function isRecordValue(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function assertOptionalStringFields(data: unknown, fields: readonly string[]): void {
  if (!isRecordValue(data)) return;
  for (const field of fields) {
    const value = Reflect.get(data, field);
    if (value !== undefined && value !== null && typeof value !== "string") {
      throw new HttpsError("invalid-argument", `${field} must be a string.`);
    }
  }
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

const JOIN_COMMUNITY_INPUT = {
  l1Analytics: optionalEnumField(["granted", "declined"]),
  l2Rankings: optionalEnumField(["granted", "declined"]),
  l2World: optionalEnumField(["granted", "declined"]),
  l2Country: optionalEnumField(["granted", "declined"]),
  l2Region: optionalEnumField(["granted", "declined"]),
  l2City: optionalEnumField(["granted", "declined"]),
  locationConsent: optionalEnumField(["granted", "declined"]),
  l3LookingGlass: optionalEnumField(["granted", "declined"]),
  handle: optionalString({ maxLength: HANDLE_MAX_LENGTH }),
  timezone: optionalString({ maxLength: 128 }),
  locale: optionalString({ maxLength: 64 }),
  countryCode: optionalString({ maxLength: 16 }),
  regionKey: optionalString({ maxLength: 96 }),
  cityKey: optionalString({ maxLength: 128 }),
} as const;

function parseJoinCommunityInput(data: unknown): JoinCommunityInput {
  assertOptionalStringFields(data, Object.keys(JOIN_COMMUNITY_INPUT));
  const parsed = parseCallableInput("joinCommunity", JOIN_COMMUNITY_INPUT, data);
  return {
    l1Analytics: optionalParsedString(parsed.l1Analytics, "l1Analytics"),
    l2Rankings: optionalParsedString(parsed.l2Rankings, "l2Rankings"),
    l2World: optionalParsedString(parsed.l2World, "l2World"),
    l2Country: optionalParsedString(parsed.l2Country, "l2Country"),
    l2Region: optionalParsedString(parsed.l2Region, "l2Region"),
    l2City: optionalParsedString(parsed.l2City, "l2City"),
    locationConsent: optionalParsedString(parsed.locationConsent, "locationConsent"),
    l3LookingGlass: optionalParsedString(parsed.l3LookingGlass, "l3LookingGlass"),
    handle: optionalParsedString(parsed.handle, "handle"),
    timezone: optionalParsedString(parsed.timezone, "timezone"),
    locale: optionalParsedString(parsed.locale, "locale"),
    countryCode: optionalParsedString(parsed.countryCode, "countryCode"),
    regionKey: optionalParsedString(parsed.regionKey, "regionKey"),
    cityKey: optionalParsedString(parsed.cityKey, "cityKey"),
  };
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

function applyJoinGeo(profileDoc: Partial<CommunityProfileDoc> & Record<string, unknown>, data: JoinCommunityInput): void {
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

async function applyJoinHandleClaimInTransaction(
  tx: Transaction,
  db: Firestore,
  uid: string,
  finalHandleLower: string | undefined,
  existingHandleLower: string | null,
  now: string,
): Promise<void> {
  if (finalHandleLower) {
    const claimRef = db.doc(CommunityPaths.handleClaim(finalHandleLower));
    const claimSnap = await tx.get(claimRef);
    if (claimSnap.exists && claimSnap.data()?.uid !== uid) {
      throw new HttpsError("already-exists", "That handle is taken.");
    }
    if (!claimSnap.exists) tx.set(claimRef, { uid, createdAt: now });
  }
  if (existingHandleLower && existingHandleLower !== finalHandleLower) {
    tx.delete(db.doc(CommunityPaths.handleClaim(existingHandleLower)));
  }
}

function buildJoinProfileDoc(
  data: JoinCommunityInput,
  anonId: string,
  finalHandle: string | undefined,
  existingCityKey: string | undefined,
  now: string,
): Partial<CommunityProfileDoc> & Record<string, unknown> {
  const profileDoc: Partial<CommunityProfileDoc> & Record<string, unknown> = {
    anonId,
    schemaVersion: COMMUNITY_SCHEMA_VERSION,
    updatedAt: now,
  };
  if (finalHandle) {
    profileDoc.handle = finalHandle;
    profileDoc.handleLower = finalHandle.toLowerCase();
  }
  applyJoinGeo(profileDoc, data);
  if (data.l2City === "granted" && data.locationConsent === "granted" && !profileDoc.cityKey && existingCityKey) {
    profileDoc.cityKey = existingCityKey;
  }
  if (data.l2Country !== "granted") profileDoc.countryCode = null;
  if (data.l2Region !== "granted") profileDoc.regionKey = null;
  if (data.l2City !== "granted" || data.locationConsent !== "granted") profileDoc.cityKey = null;
  return profileDoc;
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
    enforceAuthAndAppCheck(request, uid);
    assertCommunityRuntimeEnabled("join");

    const data = parseJoinCommunityInput(request.data);
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
        await applyJoinHandleClaimInTransaction(tx, db, uid, finalHandleLower, existingHandleLower, now);
        const existingCityKey = typeof oldProfile?.cityKey === "string" ? oldProfile.cityKey : undefined;
        const profileDoc = buildJoinProfileDoc(data, anonId, finalHandle, existingCityKey, now);

        tx.set(consentRef, consentDoc);
        tx.set(profileRef, profileDoc, { merge: true });
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
  assertOptionalStringFields(data, Object.keys(UPDATE_PROFILE_INPUT));
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
  if (typeof consent.locationConsent === "string") out.location = consent.locationConsent;
  return out;
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
  setNormalizedGeoUpdate(updates, "cityKey", data.cityKey, tiers.city === "granted" && tiers.location === "granted");
}

async function applyProfileHandleUpdateInTransaction(
  tx: Transaction,
  db: Firestore,
  uid: string,
  handle: string | undefined,
  oldHandleLower: string | null,
  updates: Record<string, unknown>,
): Promise<void> {
  if (handle === undefined) return;
  const trimmed = handle.trim();
  if (!trimmed) {
    if (oldHandleLower) {
      const oldClaimRef = db.doc(CommunityPaths.handleClaim(oldHandleLower));
      const oldClaimSnap = await tx.get(oldClaimRef);
      if (handleClaimExists(oldClaimSnap) && handleClaimOwner(oldClaimSnap) === uid) tx.delete(oldClaimRef);
    }
    updates.handle = null;
    updates.handleLower = null;
    return;
  }
  if (!isValidHandle(trimmed)) {
    throw new HttpsError("invalid-argument", "Handle must be 3-24 chars, alphanumeric + _-.");
  }
  const newLower = trimmed.toLowerCase();
  const claimRef = db.doc(CommunityPaths.handleClaim(newLower));
  const claimSnap = await tx.get(claimRef);
  if (handleClaimExists(claimSnap) && handleClaimOwner(claimSnap) !== uid) {
    throw new HttpsError("already-exists", "That handle is taken.");
  }
  if (!handleClaimExists(claimSnap)) tx.set(claimRef, { uid, createdAt: new Date().toISOString() });
  if (oldHandleLower && oldHandleLower !== newLower) tx.delete(db.doc(CommunityPaths.handleClaim(oldHandleLower)));
  updates.handle = trimmed;
  updates.handleLower = newLower;
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
    enforceAuthAndAppCheck(request, uid);
    assertCommunityRuntimeEnabled("profile update");

    const data = parseUpdateProfileInput(request.data);
    const db = getFirestore();

    await firestoreWithResilience("community-profile-update", () =>
      db.runTransaction(async (tx) => {
        const consentRef = db.doc(CommunityPaths.consent(uid));
        const profileRef = db.doc(CommunityPaths.profile(uid));
        const consentDoc = await tx.get(consentRef);
        if (!consentDoc.exists) {
          throw new HttpsError("failed-precondition", "Join the community before updating your profile.");
        }

        const profileSnap = await tx.get(profileRef);
        const oldProfile = profileSnap.data();
        const oldHandleLower = typeof oldProfile?.handleLower === "string" ? oldProfile.handleLower : null;
        const updates: Record<string, unknown> = { updatedAt: new Date().toISOString() };
        await applyProfileHandleUpdateInTransaction(tx, db, uid, data.handle, oldHandleLower, updates);
        applyProfileGeoUpdates(data, communityTierGrants(consentDoc.data() ?? {}), updates);
        tx.set(profileRef, updates, { merge: true });
      }),
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
    enforceAuthAndAppCheck(request, uid);

    const db = getFirestore();
    const now = new Date().toISOString();

    // Required audit event first — if this fails, no revocation mutation runs.
    await appendAuditEventRequired(uid, {
      actor: auditActorLabel(request),
      action: "community.revoke",
      domain: "community",
    });

    await firestoreWithResilience("community-revoke", () =>
      db.runTransaction(async (tx) => {
        const profileRef = db.doc(CommunityPaths.profile(uid));
        const profileSnap = await tx.get(profileRef);
        const oldProfile = profileSnap.data();
        const oldHandleLower = typeof oldProfile?.handleLower === "string" ? oldProfile.handleLower : null;
        if (oldHandleLower) {
          const claimRef = db.doc(CommunityPaths.handleClaim(oldHandleLower));
          const claimSnap = await tx.get(claimRef);
          if (claimSnap.exists && claimSnap.data()?.uid === uid) tx.delete(claimRef);
        }

        tx.delete(db.doc(CommunityPaths.shareSnapshot(uid)));
        tx.delete(profileRef);
        tx.set(db.doc(CommunityPaths.consent(uid)), {
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
      }),
    );

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
    enforceAuthAndAppCheck(request, uid);
    assertCommunityRuntimeEnabled("Looking Glass export");

    assertOptionalStringFields(request.data, ["format"]);
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
