import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, type Firestore, Timestamp } from "firebase-admin/firestore";
import { NEGATIVE_ENTITLEMENT_CACHE_MS, POSITIVE_ENTITLEMENT_CACHE_MS, REMOTE_MCP_LAST_USED_WRITE_INTERVAL_MS } from "./config.js";
import { HttpError } from "./errors.js";

export interface EntitlementState {
  active: boolean;
  source: "burnbar_pro" | "hosted_quota_sync" | "none";
  expiresAt?: string;
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
  const expiresAt = dateFromRaw(data.expireAt ?? data.expiresAt);
  if (!expiresAt || expiresAt.getTime() <= Date.now()) return { active: false, expiresAt };
  return { active: true, expiresAt };
}

export async function getEntitlementState(uid: string, db: Firestore = firestore()): Promise<EntitlementState> {
  const cached = cache.get(uid);
  if (cached && cached.expiresAtMs > Date.now()) return cached.state;

  const [pro, legacy] = await Promise.all([
    db.doc(`users/${uid}/entitlements/burnbar_pro`).get(),
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get()
  ]);
  const proState = isActive(pro.data());
  const legacyState = isActive(legacy.data());
  const state: EntitlementState = proState.active
    ? { active: true, source: "burnbar_pro", expiresAt: proState.expiresAt?.toISOString() }
    : legacyState.active
      ? { active: true, source: "hosted_quota_sync", expiresAt: legacyState.expiresAt?.toISOString() }
      : { active: false, source: "none" };
  cache.set(uid, {
    state,
    expiresAtMs: Date.now() + (state.active ? POSITIVE_ENTITLEMENT_CACHE_MS : NEGATIVE_ENTITLEMENT_CACHE_MS)
  });
  return state;
}

export async function requireActiveBurnBarPro(uid: string, db?: Firestore): Promise<EntitlementState> {
  const state = await getEntitlementState(uid, db);
  if (!state.active) {
    throw new HttpError(403, "BurnBar Pro is required for hosted remote MCP.", "burnbar_pro_required");
  }
  return state;
}

export async function requireActiveRemoteMcpClient(
  uid: string,
  clientId: string,
  db: Firestore = firestore()
): Promise<void> {
  const ref = db.doc(`users/${uid}/remote_mcp_clients/${clientId}`);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpError(403, "OpenBurnBar MCP client grant was not found.", "client_not_found");
  }
  const data = snap.data() ?? {};
  if (dateFromRaw(data.revokedAt)) {
    throw new HttpError(403, "OpenBurnBar MCP client has been revoked.", "client_revoked");
  }
  const cacheKey = `${uid}:${clientId}`;
  const now = Date.now();
  const lastWriteAt = lastUsedWriteCache.get(cacheKey) ?? 0;
  if (now - lastWriteAt >= REMOTE_MCP_LAST_USED_WRITE_INTERVAL_MS) {
    lastUsedWriteCache.set(cacheKey, now);
    void ref.set({ lastUsedAt: Timestamp.now(), updatedAt: Timestamp.now() }, { merge: true }).catch(() => {
      lastUsedWriteCache.delete(cacheKey);
    });
  }
}
