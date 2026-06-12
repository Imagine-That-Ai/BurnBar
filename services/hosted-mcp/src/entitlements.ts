import type { Firestore } from "firebase-admin/firestore";
import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { entitlementExpiryMillis } from "@openburnbar/entitlements";
import { NEGATIVE_ENTITLEMENT_CACHE_MS, POSITIVE_ENTITLEMENT_CACHE_MS, REMOTE_MCP_LAST_USED_WRITE_INTERVAL_MS } from "./config.js";
import { HttpError } from "./errors.js";
import type { HostedMcpFirestore, RemoteMcpClientFirestore } from "./firestoreTypes.js";

export interface EntitlementState {
  active: boolean;
  source: "burnbar_ultra" | "burnbar_pro_max" | "burnbar_pro" | "hosted_quota_sync" | "none";
  /** Pensieve/MCP tier: drives Ultra-only rate buckets (e.g. search:ultra). */
  tier: "ultra" | "pro" | "none";
  expiresAt?: string;
}

export interface RemoteMcpClientState {
  allowedScopes: string[];
}

const cache = new Map<string, { state: EntitlementState; expiresAtMs: number }>();
const lastUsedWriteCache = new Map<string, number>();

export function firestore(): Firestore {
  if (getApps().length === 0) {
    const storageBucket = process.env.FIREBASE_STORAGE_BUCKET || process.env.OPENBURNBAR_STORAGE_BUCKET;
    initializeApp(storageBucket ? { storageBucket } : undefined);
  }
  return getFirestore();
}

function dateFromRaw(raw: unknown): Date | undefined {
  if (raw instanceof Timestamp) return raw.toDate();
  if (raw instanceof Date) return raw;
  if (typeof raw === "string") {
    const date = new Date(raw);
    return Number.isNaN(date.getTime()) ? undefined : date;
  }
  return undefined;
}

function isActive(data: FirebaseFirestore.DocumentData | undefined): { active: boolean; expiresAt?: Date } {
  if (!data || data.active !== true) return { active: false };
  // Shared expiry math (@openburnbar/entitlements) so functions/relay/hosted-mcp
  // resolve `expireAt`/`expiresAt` identically. Returns NaN when unparseable.
  const expiresAtMs = entitlementExpiryMillis(data);
  if (!Number.isFinite(expiresAtMs)) return { active: false };
  const expiresAt = new Date(expiresAtMs);
  if (expiresAtMs <= Date.now()) return { active: false, expiresAt };
  return { active: true, expiresAt };
}

export async function getEntitlementState(uid: string, db: RemoteMcpClientFirestore = firestore()): Promise<EntitlementState> {
  const cached = cache.get(uid);
  if (cached && cached.expiresAtMs > Date.now()) return cached.state;

  // Ultra (source) + Cloud Pro (proMax) are read alongside legacy Pro + hosted-quota
  // so Cloud-Pro/Ultra members can use the hosted MCP, and Ultra unlocks its rate tier.
  const [ultra, proMax, pro, legacy] = await Promise.all([
    db.doc(`users/${uid}/entitlements/burnbar_ultra`).get(),
    db.doc(`users/${uid}/entitlements/burnbar_pro_max`).get(),
    db.doc(`users/${uid}/entitlements/burnbar_pro`).get(),
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get()
  ]);
  const ultraState = isActive(ultra.data());
  const proMaxState = isActive(proMax.data());
  const proState = isActive(pro.data());
  const legacyState = isActive(legacy.data());
  let state: EntitlementState;
  if (ultraState.active) {
    state = { active: true, source: "burnbar_ultra", tier: "ultra", expiresAt: ultraState.expiresAt?.toISOString() };
  } else if (proMaxState.active) {
    state = { active: true, source: "burnbar_pro_max", tier: "pro", expiresAt: proMaxState.expiresAt?.toISOString() };
  } else if (proState.active) {
    state = { active: true, source: "burnbar_pro", tier: "pro", expiresAt: proState.expiresAt?.toISOString() };
  } else if (legacyState.active) {
    state = { active: true, source: "hosted_quota_sync", tier: "pro", expiresAt: legacyState.expiresAt?.toISOString() };
  } else {
    state = { active: false, source: "none", tier: "none" };
  }
  cache.set(uid, {
    state,
    expiresAtMs: Date.now() + (state.active ? POSITIVE_ENTITLEMENT_CACHE_MS : NEGATIVE_ENTITLEMENT_CACHE_MS)
  });
  return state;
}

export async function requireActiveBurnBarPro(uid: string, db: RemoteMcpClientFirestore = firestore()): Promise<EntitlementState> {
  const state = await getEntitlementState(uid, db);
  if (!state.active) {
    throw new HttpError(403, "BurnBar Pro is required for hosted remote MCP.", "burnbar_pro_required");
  }
  return state;
}

export async function requireActiveRemoteMcpClient(
  uid: string,
  clientId: string,
  db: RemoteMcpClientFirestore = firestore()
): Promise<RemoteMcpClientState> {
  const ref = db.doc(`users/${uid}/remote_mcp_clients/${clientId}`);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpError(403, "OpenBurnBar MCP client grant was not found.", "client_not_found");
  }
  const data = snap.data() ?? {};
  if (dateFromRaw(data.revokedAt)) {
    throw new HttpError(403, "OpenBurnBar MCP client has been revoked.", "client_revoked");
  }
  const allowedScopes = normalizeAllowedScopes(data.allowedScopes);
  const cacheKey = `${uid}:${clientId}`;
  const now = Date.now();
  const lastWriteAt = lastUsedWriteCache.get(cacheKey) ?? 0;
  if (now - lastWriteAt >= REMOTE_MCP_LAST_USED_WRITE_INTERVAL_MS) {
    lastUsedWriteCache.set(cacheKey, now);
    void ref.set({ lastUsedAt: Timestamp.now(), updatedAt: Timestamp.now() }, { merge: true }).catch(() => {
      lastUsedWriteCache.delete(cacheKey);
    });
  }
  return { allowedScopes };
}

function normalizeAllowedScopes(raw: unknown): string[] {
  if (!Array.isArray(raw) || !raw.every((scope): scope is string => typeof scope === "string" && scope.length > 0)) {
    throw new HttpError(403, "OpenBurnBar MCP client scope policy is missing.", "client_scope_policy_missing");
  }
  return [...new Set(raw)];
}

export function assertTokenScopesAllowedByClient(tokenScopes: readonly string[], client: RemoteMcpClientState): void {
  const allowed = new Set(client.allowedScopes);
  const disallowed = tokenScopes.filter((scope) => !allowed.has(scope));
  if (disallowed.length > 0) {
    throw new HttpError(403, "OpenBurnBar MCP token scopes exceed the registered client grant.", "client_scope_downgraded");
  }
}

export async function requireActiveRemoteMcpAccess(
  uid: string,
  clientId: string,
  tokenScopes: readonly string[],
  db: RemoteMcpClientFirestore = firestore()
): Promise<RemoteMcpClientState> {
  const client = await requireActiveRemoteMcpClient(uid, clientId, db);
  assertTokenScopesAllowedByClient(tokenScopes, client);
  return client;
}
