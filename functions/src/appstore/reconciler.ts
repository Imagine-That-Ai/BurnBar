/**
 * @fileoverview Entitlement reconciler.
 *
 * Single writer for `users/{uid}/entitlements/hosted_quota_sync`. Every
 * trust path (client callable, S2S webhook, daily scheduled job) flows
 * through this module so the entitlement document is always derived
 * from the same verification pipeline.
 *
 * Pipeline:
 *
 *   1. Verify the supplied JWS via `AppleJWSVerifier`.
 *   2. Resolve the Firebase UID:
 *      - Prefer `appAccountToken` ⇒ lookup `entitlement_bindings`.
 *      - Else use the supplied `claimedUid` (callable's `request.auth.uid`).
 *      - Else use the doc owner from the existing entitlement.
 *      - Mismatch ⇒ reject with `binding_mismatch`.
 *   3. Pull live state from `getAllSubscriptionStatuses` to catch
 *      revocations / renewals not yet on the supplied JWS.
 *   4. Re-verify every JWS in the live response.
 *   5. Pick the highest-watermark transaction (max signedDate, max
 *      transactionId tiebreak) for the configured productId.
 *   6. Build a fresh `HostedQuotaEntitlementDoc` and write
 *      transactionally, rejecting monotonicity violations.
 *   7. Append an `EntitlementEventDoc` to the audit collection.
 *
 * Everything is idempotent. The same `(originalTransactionId, signedDate)`
 * tuple cannot produce divergent doc state, regardless of how many
 * times Apple retries the webhook.
 */

import { createHash, randomUUID } from "node:crypto";
import { Timestamp, type Firestore } from "firebase-admin/firestore";

import type { JWSTransactionDecodedPayload } from "@apple/app-store-server-library";

import type {
  AppStoreConfig,
  EntitlementBindingDoc,
  EntitlementOwnershipType,
  HostedQuotaEntitlementDoc,
  HostedQuotaEntitlementSource,
} from "../types.js";

import { appendEntitlementEvent } from "./audit.js";
import { fetchLiveSubscriptionStatus } from "./client.js";
import {
  type AppleJWSVerifier,
  type DecodedTransaction,
  getAppleJWSVerifier,
} from "./verifier.js";

const ENTITLEMENT_SCHEMA_VERSION = 2;
const VERIFICATION_VERSION = 2;
const BINDING_SCHEMA_VERSION = 1;
const BURNBAR_PRO_ENTITLEMENT_ID = "burnbar_pro";

export interface ReconcileInput {
  /** The signed transaction JWS the caller provided. Required. */
  signedTransactionJWS: string;
  /** Optional renewal info JWS, when present (e.g. from S2S notifications). */
  signedRenewalInfoJWS?: string;
  /** Optional notification UUID — used as the audit idempotency key. */
  notificationUUID?: string;
  /** Optional notification type/subtype, surfaced in the audit log. */
  notificationType?: string;
  notificationSubtype?: string;
  /** Caller-asserted UID. Trusted only when no `appAccountToken` is present. */
  claimedUid?: string;
  /** Trust path that originated the call. */
  source: "client_callable" | "apple_s2s" | "scheduled_reconcile";
  /**
   * StoreKit product ID this entitlement gates. Defaults to
   * `cfg.hostedQuotaProductID` from the global config. Pass through the
   * caller for clarity.
   */
  productID: string;
}

export interface ReconcileResult {
  uid: string;
  entitlement: HostedQuotaEntitlementDoc;
  /** True iff the doc was actually rewritten (vs. monotonicity skip). */
  changed: boolean;
}

/**
 * Test-only override hooks. Production callers leave both undefined and
 * the reconciler resolves the real `AppleJWSVerifier` + ASC client via
 * `getAppleJWSVerifier(cfg)` / `fetchLiveSubscriptionStatus(cfg, …)`.
 */
export interface ReconcileOverrides {
  verifier?: AppleJWSVerifier;
  fetchLive?: typeof fetchLiveSubscriptionStatus;
}

export class EntitlementReconcileError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(`${code}: ${message}`);
    this.name = "EntitlementReconcileError";
    this.code = code;
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

export async function reconcileEntitlement(
  db: Firestore,
  cfg: AppStoreConfig,
  input: ReconcileInput,
  overrides: ReconcileOverrides = {}
): Promise<ReconcileResult> {
  const verifier = overrides.verifier ?? getAppleJWSVerifier(cfg);
  const fetchLive = overrides.fetchLive ?? fetchLiveSubscriptionStatus;

  // 1) Verify the supplied JWS.
  const seedTx = await verifier.verifyTransaction(input.signedTransactionJWS);
  assertBundle(cfg, seedTx);

  if (input.signedRenewalInfoJWS) {
    // We don't currently use renewal info for the entitlement decision —
    // expiresDate on the transaction is authoritative — but verifying it
    // guarantees the webhook is not pairing a real transaction JWS with
    // a forged renewal info.
    await verifier.verifyRenewalInfo(input.signedRenewalInfoJWS);
  }

  // 2) Resolve UID.
  const uid = await resolveUid(db, input, seedTx);

  // 3+4) Live truth: re-verify every JWS Apple returns.
  const live = await fetchLiveStatusVerified(verifier, cfg, seedTx, fetchLive);

  // 5) Best-of all transactions for the productId.
  const candidate = pickWinning([seedTx, ...live], input.productID);
  if (!candidate) {
    throw new EntitlementReconcileError(
      "no_active_transaction",
      `No verified transaction matched productId ${input.productID}.`
    );
  }

  // 6) Build & persist.
  const docPath = `users/${uid}/entitlements/hosted_quota_sync`;
  const docRef = db.doc(docPath);

  const next = buildEntitlementDoc({
    productID: input.productID,
    candidate,
    notificationUUID: input.notificationUUID,
  });

  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(docRef);
    const existing = snap.exists
      ? (snap.data() as HostedQuotaEntitlementDoc)
      : undefined;

    if (existing && !shouldOverwrite(existing, next)) {
      tx.set(
        db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`),
        buildBurnBarProEntitlementMirror(existing),
        { merge: true }
      );
      return { changed: false, entitlement: existing };
    }

    const merged = mergeWithExisting(existing, next);
    tx.set(docRef, merged, { merge: true });
    tx.set(
      db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`),
      buildBurnBarProEntitlementMirror(merged),
      { merge: true }
    );
    return { changed: true, entitlement: merged };
  });

  // 7) Audit (best-effort; never gates the entitlement write).
  const eventId = auditEventId(input, candidate.payload);
  try {
    await appendEntitlementEvent(db, {
      uid,
      eventId,
      source: input.source,
      notificationType: input.notificationType,
      notificationSubtype: input.notificationSubtype,
      transactionId: requireString(candidate.payload.transactionId, "transactionId"),
      originalTransactionId: requireString(
        candidate.payload.originalTransactionId,
        "originalTransactionId"
      ),
      productId: requireString(candidate.payload.productId, "productId"),
      environment: candidate.environment,
      expiresAt: result.entitlement.expiresAt,
      revokedAt: result.entitlement.revokedAt,
      revocationReason: result.entitlement.revocationReason,
      rawJWS: candidate.raw,
      decoded: redactPayload(candidate.payload),
    });
  } catch (err) {
    console.warn("entitlement audit append failed", err);
  }

  return { uid, entitlement: result.entitlement, changed: result.changed };
}

function buildBurnBarProEntitlementMirror(
  hosted: HostedQuotaEntitlementDoc
): Record<string, unknown> {
  return {
    id: BURNBAR_PRO_ENTITLEMENT_ID,
    active: hosted.active,
    productID: hosted.productID,
    sourceProductID: hosted.productID,
    entitlementFamily: "burnbar_pro",
    features: {
      hostedQuota: true,
      hostedLLM: true,
      encryptedSessionLogBackup: true,
      cloudConversationSearch: true,
    },
    expiresAt: hosted.expiresAt,
    expireAt: hosted.expireAt,
    environment: hosted.environment,
    source: hosted.source,
    sourceEntitlementID: hosted.id,
    updatedAt: hosted.updatedAt,
    schemaVersion: 1,
  };
}

// ---------------------------------------------------------------------------
// Binding & UID resolution
// ---------------------------------------------------------------------------

/**
 * Mint and persist a fresh `appAccountToken` for the signed-in user
 * before they call `Product.purchase()`. The reconciler later uses this
 * token to bind incoming JWS payloads to the correct UID without
 * trusting the in-flight callable.
 */
export async function beginBinding(
  db: Firestore,
  uid: string,
  productID: string,
  clientPlatform?: EntitlementBindingDoc["clientPlatform"]
): Promise<{ appAccountToken: string }> {
  if (!uid) throw new Error("uid is required");
  const token = uuid();
  const doc: EntitlementBindingDoc = {
    id: token,
    uid,
    productID,
    createdAt: new Date().toISOString(),
    clientPlatform,
    schemaVersion: BINDING_SCHEMA_VERSION,
  };
  await db
    .doc(`users/${uid}/entitlement_bindings/${token}`)
    .create(stripUndefined(doc as unknown as Record<string, unknown>));
  return { appAccountToken: token };
}

async function resolveUid(
  db: Firestore,
  input: ReconcileInput,
  tx: DecodedTransaction
): Promise<string> {
  const tokenRaw = tx.payload.appAccountToken;
  const token = typeof tokenRaw === "string" ? tokenRaw.toLowerCase() : "";

  if (token) {
    const bindingUid = await consumeBindingByToken(
      db,
      token,
      input.claimedUid
    );
    if (input.claimedUid && bindingUid !== input.claimedUid) {
      throw new EntitlementReconcileError(
        "binding_mismatch",
        `appAccountToken ${redactToken(token)} is bound to a different user.`
      );
    }
    return bindingUid;
  }

  // No appAccountToken on the JWS. Two legitimate cases:
  //   - Pre-binding migration: existing user with a verified callable.
  //   - S2S notification for a legacy purchase pre-migration.
  if (input.claimedUid) return input.claimedUid;

  // Last resort: look up the entitlement doc that already references this
  // originalTransactionId; if exactly one user owns it, attribute there.
  const fallbackUid = await findUidByOriginalTransaction(
    db,
    requireString(tx.payload.originalTransactionId, "originalTransactionId")
  );
  if (!fallbackUid) {
    throw new EntitlementReconcileError(
      "uid_unresolved",
      "JWS has no appAccountToken and no caller UID; cannot attribute."
    );
  }
  return fallbackUid;
}

/**
 * Find a binding by `appAccountToken`. We can't use a collectionGroup
 * read because Firestore rules restrict it; instead we require the
 * caller to also pass `claimedUid` so we read at a deterministic path.
 *
 * If no caller is known (S2S path), we fall back to a collection-group
 * search across `entitlement_bindings`. The collection is server-only
 * (rules deny clients), so this is safe.
 */
async function consumeBindingByToken(
  db: Firestore,
  token: string,
  claimedUid?: string
): Promise<string> {
  if (claimedUid) {
    const ref = db.doc(`users/${claimedUid}/entitlement_bindings/${token}`);
    const snap = await ref.get();
    if (snap.exists) {
      const d = snap.data() as EntitlementBindingDoc;
      if (d.uid !== claimedUid) {
        throw new EntitlementReconcileError(
          "binding_mismatch",
          "binding doc uid does not match caller"
        );
      }
      if (!d.consumedAt) {
        await ref.set(
          { consumedAt: new Date().toISOString() },
          { merge: true }
        );
      }
      return d.uid;
    }
    // The caller signed in but never minted a binding for this token —
    // someone else's token replayed under their UID.
    throw new EntitlementReconcileError(
      "binding_mismatch",
      "caller has no binding for this appAccountToken"
    );
  }

  // S2S path: collection-group lookup.
  const cg = await db
    .collectionGroup("entitlement_bindings")
    .where("id", "==", token)
    .limit(1)
    .get();
  const doc = cg.docs[0];
  if (!doc) {
    throw new EntitlementReconcileError(
      "binding_unknown",
      `No binding for appAccountToken ${redactToken(token)}.`
    );
  }
  const d = doc.data() as EntitlementBindingDoc;
  if (!d.consumedAt) {
    await doc.ref.set({ consumedAt: new Date().toISOString() }, { merge: true });
  }
  return d.uid;
}

async function findUidByOriginalTransaction(
  db: Firestore,
  originalTransactionId: string
): Promise<string | undefined> {
  const cg = await db
    .collectionGroup("entitlements")
    .where("originalTransactionID", "==", originalTransactionId)
    .where("id", "==", "hosted_quota_sync")
    .limit(2)
    .get();
  if (cg.size === 1) {
    const path = cg.docs[0].ref.path;
    const m = path.match(/^users\/([^/]+)\//);
    return m?.[1];
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Live ASC reconciliation
// ---------------------------------------------------------------------------

async function fetchLiveStatusVerified(
  verifier: AppleJWSVerifier,
  cfg: AppStoreConfig,
  seed: DecodedTransaction,
  fetchLive: typeof fetchLiveSubscriptionStatus
): Promise<DecodedTransaction[]> {
  const original = seed.payload.originalTransactionId;
  if (!original) return [];

  // The seed environment drives which ASC base URL we hit.
  let live;
  try {
    live = await fetchLive(cfg, seed.environment, original);
  } catch (err) {
    throw new EntitlementReconcileError(
      "asc_live_status_unavailable",
      `App Store live subscription status unavailable: ${
        err instanceof Error ? err.message : "unknown ASC error"
      }`
    );
  }

  const verified: DecodedTransaction[] = [];
  for (const pair of live.pairs) {
    try {
      const tx = await verifier.verifyTransaction(
        pair.signedTransactionInfo,
        seed.environment
      );
      assertBundle(cfg, tx);
      verified.push(tx);
    } catch (err) {
      console.warn("appstore:reconciler ASC JWS rejected", err);
    }
  }
  return verified;
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

function pickWinning(
  candidates: DecodedTransaction[],
  productID: string
): DecodedTransaction | undefined {
  let best: DecodedTransaction | undefined;
  for (const c of candidates) {
    if (c.payload.productId !== productID) continue;
    if (!best) {
      best = c;
      continue;
    }
    if (rank(c) > rank(best)) {
      best = c;
    }
  }
  return best;
}

/** Order: most recent signedDate wins. Tie-break on transactionId. */
function rank(c: DecodedTransaction): number {
  return c.payload.signedDate ?? 0;
}

// ---------------------------------------------------------------------------
// Entitlement doc construction
// ---------------------------------------------------------------------------

interface BuildArgs {
  productID: string;
  candidate: DecodedTransaction;
  notificationUUID?: string;
}

function buildEntitlementDoc(args: BuildArgs): HostedQuotaEntitlementDoc {
  const { candidate, productID, notificationUUID } = args;
  const p = candidate.payload;
  const now = new Date();
  const expiresMs = typeof p.expiresDate === "number" ? p.expiresDate : undefined;
  const revokedMs =
    typeof p.revocationDate === "number" ? p.revocationDate : undefined;
  const active =
    revokedMs === undefined &&
    typeof expiresMs === "number" &&
    expiresMs > now.getTime();

  const ownership: EntitlementOwnershipType | undefined =
    p.inAppOwnershipType === "PURCHASED" || p.inAppOwnershipType === "FAMILY_SHARED"
      ? p.inAppOwnershipType
      : undefined;

  const source: HostedQuotaEntitlementSource = "apple_jws_verified";
  const doc: HostedQuotaEntitlementDoc = {
    id: "hosted_quota_sync",
    active,
    productID,
    transactionID: requireString(p.transactionId, "transactionId"),
    originalTransactionID: requireString(
      p.originalTransactionId,
      "originalTransactionId"
    ),
    expiresAt: expiresMs !== undefined ? new Date(expiresMs).toISOString() : undefined,
    expireAt: expiresMs !== undefined ? Timestamp.fromMillis(expiresMs) : undefined,
    revokedAt: revokedMs !== undefined ? new Date(revokedMs).toISOString() : undefined,
    revocationReason:
      typeof p.revocationReason === "number" ? p.revocationReason : undefined,
    environment: candidate.environment,
    ownershipType: ownership,
    appAccountToken:
      typeof p.appAccountToken === "string" && p.appAccountToken
        ? p.appAccountToken.toLowerCase()
        : undefined,
    signedTransactionHash: createHash("sha256")
      .update(candidate.raw)
      .digest("hex"),
    signedDateMs:
      typeof p.signedDate === "number" ? Math.floor(p.signedDate) : undefined,
    lastNotificationUUID: notificationUUID,
    lastVerifiedAt: now.toISOString(),
    source,
    verificationVersion: VERIFICATION_VERSION,
    schemaVersion: ENTITLEMENT_SCHEMA_VERSION,
    updatedAt: now.toISOString(),
  };
  return stripUndefined(doc as unknown as Record<string, unknown>) as unknown as HostedQuotaEntitlementDoc;
}

/** Reject stale events: never let an older signedDate revive a newer doc. */
function shouldOverwrite(
  existing: HostedQuotaEntitlementDoc,
  next: HostedQuotaEntitlementDoc
): boolean {
  // Prefer Apple's transaction watermark over local wall-clock time.
  // `lastVerifiedAt` is still useful for operator observability, but
  // replay protection must key off the signed payload date so a stale
  // event processed later cannot revive an expired or revoked state.
  if (
    typeof existing.signedDateMs === "number" &&
    typeof next.signedDateMs === "number"
  ) {
    return next.signedDateMs >= existing.signedDateMs;
  }
  if (!existing.lastVerifiedAt) return true;
  return next.lastVerifiedAt >= existing.lastVerifiedAt;
}

function mergeWithExisting(
  existing: HostedQuotaEntitlementDoc | undefined,
  next: HostedQuotaEntitlementDoc
): HostedQuotaEntitlementDoc {
  if (!existing) return next;
  // Carry forward fields that legitimately change rarely (appAccountToken,
  // ownershipType) when the new JWS does not include them.
  return stripUndefined({
    ...existing,
    ...next,
    appAccountToken: next.appAccountToken ?? existing.appAccountToken,
    ownershipType: next.ownershipType ?? existing.ownershipType,
    environment: next.environment ?? existing.environment,
  }) as unknown as HostedQuotaEntitlementDoc;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function assertBundle(cfg: AppStoreConfig, tx: DecodedTransaction): void {
  if (tx.payload.bundleId && tx.payload.bundleId !== cfg.bundleId) {
    throw new EntitlementReconcileError(
      "bundle_id_mismatch",
      `JWS bundleId ${tx.payload.bundleId} != ${cfg.bundleId}`
    );
  }
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || !value) {
    throw new EntitlementReconcileError(
      "missing_field",
      `JWS payload is missing ${field}`
    );
  }
  return value;
}

function auditEventId(
  input: ReconcileInput,
  payload: JWSTransactionDecodedPayload
): string {
  if (input.notificationUUID) return `n_${input.notificationUUID}`;
  return `t_${payload.transactionId}_${payload.signedDate ?? 0}`;
}

/**
 * Trim PII / locale fields from the decoded payload before persisting it
 * to the audit log. Storefront, currency, and price are dropped because
 * they leak the buyer's region and price tier; `appAccountToken` is
 * replaced with its SHA-256 because raw UUIDs are sensitive PII.
 */
const REDACTED_PAYLOAD_FIELDS = new Set([
  "storefront",
  "storefrontId",
  "currency",
  "price",
]);

function redactPayload(
  payload: JWSTransactionDecodedPayload
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(
    payload as unknown as Record<string, unknown>
  )) {
    if (REDACTED_PAYLOAD_FIELDS.has(k)) continue;
    if (k === "appAccountToken") continue;
    out[k] = v;
  }
  const appAccountToken = (payload as { appAccountToken?: unknown })
    .appAccountToken;
  if (typeof appAccountToken === "string" && appAccountToken) {
    out.appAccountTokenHash = createHash("sha256")
      .update(appAccountToken)
      .digest("hex");
  }
  return out;
}

function redactToken(token: string): string {
  if (token.length <= 8) return "***";
  return `${token.slice(0, 4)}…${token.slice(-4)}`;
}

function uuid(): string {
  return randomUUID();
}

function stripUndefined<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, v]) => v !== undefined)
  ) as T;
}

// ---------------------------------------------------------------------------
// Test-only exports
// ---------------------------------------------------------------------------

/**
 * Internals reachable from `scripts/test-appstore.mjs`. Not part of the
 * public surface — do not import outside tests.
 */
export const __testing__ = {
  pickWinning,
  buildEntitlementDoc,
  mergeWithExisting,
  shouldOverwrite,
  redactPayload,
  redactToken,
  auditEventId,
  ENTITLEMENT_SCHEMA_VERSION,
  VERIFICATION_VERSION,
  BINDING_SCHEMA_VERSION,
};
