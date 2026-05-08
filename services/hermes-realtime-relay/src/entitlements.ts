import { getFirestore, type Firestore, type Timestamp } from "firebase-admin/firestore";
import { RelayHttpError } from "./errors.js";

export interface EntitlementCheck {
  productID: string;
  expiresAtMs: number;
  source: "firestore" | "cache";
}

export interface EntitlementVerifier {
  assertActive(uid: string): Promise<EntitlementCheck>;
}

interface EntitlementCacheEntry {
  ok: boolean;
  productID?: string;
  expiresAtMs?: number;
  reason?: string;
  cachedUntilMs: number;
}

export interface FirestoreEntitlementVerifierOptions {
  productIDs: string[];
  cacheTTLSeconds: number;
  negativeCacheTTLSeconds: number;
  firestore?: Pick<Firestore, "doc">;
}

export class FirestoreEntitlementVerifier implements EntitlementVerifier {
  private readonly productIDs: Set<string>;
  private readonly cacheTTLMillis: number;
  private readonly negativeCacheTTLMillis: number;
  private readonly cache = new Map<string, EntitlementCacheEntry>();
  private readonly firestore: Pick<Firestore, "doc">;

  constructor(options: FirestoreEntitlementVerifierOptions) {
    this.productIDs = new Set(options.productIDs);
    this.cacheTTLMillis = Math.max(1, options.cacheTTLSeconds) * 1_000;
    this.negativeCacheTTLMillis = Math.max(1, options.negativeCacheTTLSeconds) * 1_000;
    this.firestore = options.firestore ?? getFirestore();
  }

  async assertActive(uid: string): Promise<EntitlementCheck> {
    const now = Date.now();
    const cached = this.cache.get(uid);
    if (cached && cached.cachedUntilMs > now) {
      if (cached.ok && cached.productID && cached.expiresAtMs) {
        return { productID: cached.productID, expiresAtMs: cached.expiresAtMs, source: "cache" };
      }
      throw entitlementDenied(cached.reason ?? "Hosted Hermes subscription is inactive.");
    }

    const snap = await this.firestore
      .doc(`users/${uid}/entitlements/hosted_quota_sync`)
      .get();
    if (!snap.exists) {
      this.cacheDeny(uid, "Hosted Hermes subscription required.");
      throw entitlementDenied("Hosted Hermes subscription required.");
    }

    const data = snap.data() ?? {};
    const productID = typeof data.productID === "string" ? data.productID : "";
    const expiresAtMs = entitlementExpiryMillis(data);
    const active = data.active === true
      && this.productIDs.has(productID)
      && Number.isFinite(expiresAtMs)
      && expiresAtMs > now;

    if (!active) {
      this.cacheDeny(uid, "Hosted Hermes subscription is inactive.");
      throw entitlementDenied("Hosted Hermes subscription is inactive.");
    }

    const cachedUntilMs = Math.min(now + this.cacheTTLMillis, expiresAtMs);
    this.cache.set(uid, {
      ok: true,
      productID,
      expiresAtMs,
      cachedUntilMs,
    });
    return { productID, expiresAtMs, source: "firestore" };
  }

  private cacheDeny(uid: string, reason: string): void {
    this.cache.set(uid, {
      ok: false,
      reason,
      cachedUntilMs: Date.now() + this.negativeCacheTTLMillis,
    });
  }
}

function entitlementDenied(message: string): RelayHttpError {
  return new RelayHttpError(403, "entitlement_required", message);
}

function entitlementExpiryMillis(data: Record<string, unknown>): number {
  const expireAt = data.expireAt as Timestamp | undefined;
  if (expireAt && typeof expireAt.toMillis === "function") {
    return expireAt.toMillis();
  }
  if (typeof data.expiresAt === "string") {
    return Date.parse(data.expiresAt);
  }
  return Number.NaN;
}
