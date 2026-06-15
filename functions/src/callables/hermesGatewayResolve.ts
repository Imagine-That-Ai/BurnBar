/**
 * @fileoverview Resolution + persistence helpers for the BurnBar Cloud Hermes
 * Gateway — entitlement gates, bearer-grant resolution, sealed write-body
 * resolution, attachment manifest checks, and destination bootstrap. Split out
 * of hermesGateway.ts to keep every gateway module under the file-length cap;
 * re-exported from there byte-identically.
 */

import { getStorage } from "firebase-admin/storage";
import { HttpsError } from "firebase-functions/v2/https";
import { createHash } from "node:crypto";

import { db } from "../adminRuntime.js";
import { recordOrUndefined } from "../guards.js";
import {
  bearerTokenFromAuthorizationHeader,
  gatewayPlaintextWriteAllowed,
  hasHermesGatewayScope,
  hashHermesGatewayBearerToken,
  HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
  HERMES_GATEWAY_MAX_EVENT_TEXT,
  HERMES_GATEWAY_MAX_MESSAGE_TEXT,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isHermesGatewayAttachmentManifestDoc,
  isHermesGatewayClientDoc,
  isHermesGatewayTokenExpired,
  requireProductionGatewayRatchetEnvelope,
  requireProductionGatewayRelayEnvelope,
  requireProductionGatewaySignalEnvelope,
  shouldCoalesceHermesGatewayLastSeen,
  type HermesGatewayScope,
} from "../hermesGateway.js";
import { logInfo } from "../logging.js";
import type {
  GatewayRatchetEnvelopeDoc,
  GatewayRelayEnvelopeDoc,
  GatewaySignalEnvelopeDoc,
  HermesGatewayAttachmentManifestDoc,
  HermesGatewayClientDoc,
} from "../types/generated/hermes-gateway.js";
import {
  assertSafeAttachmentContentType,
  baseAttachmentContentType,
  header,
  type HttpRequest,
  httpError,
} from "./hermesGatewayHttp.js";
import { verifyGatewayRequestPoP } from "./hermesGatewayCrypto.js";
import {
  isActiveBurnBarCloudProEntitlement,
  isActiveHostedQuotaEntitlement,
  isActivePremiumEntitlement,
  nowISO,
  requiredIdentifier,
  safeIdentifier,
} from "./shared.js";

interface ResolvedGatewayGrant {
  uid: string;
  client: HermesGatewayClientDoc;
}

// Platforms eligible to resolve an oversight gate. Mirrors the trusted-native
// escrow set enforced by the CLI-agent mission approval path so the gateway and
// mission oversight share one trust model (a web/headless device cannot approve).
export const NATIVE_ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);

type StorageBucket = ReturnType<ReturnType<typeof getStorage>["bucket"]>;
type StorageFile = ReturnType<StorageBucket["file"]>;

interface ResolvedGatewayWriteBody {
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  signalEnvelope?: GatewaySignalEnvelopeDoc;
  legacyText?: string;
}

// Internal cross-module plumbing type (not schema/wire surface): declared
// module-private and re-exported so sibling gateway modules can import it
// without growing the hand-maintained exported-type budget.
export type { ResolvedGatewayWriteBody };

/**
 * Decide whether a phone/agent write carries a sealed body and enforce the
 * privacy gate. Precedence:
 *   1. A present relayEnvelope is validated (shape only) and ALWAYS used; any
 *      plaintext text supplied alongside it is ignored (the sealed body wins).
 *   2. With no envelope, plaintext is rejected. The legacy plaintext output is
 *      retained only as dead-code-compatible shape for old test fixtures and
 *      read paths; gatewayPlaintextWriteAllowed() now always returns false.
 */
export function resolveGatewayWriteBody(
  rawEnvelope: unknown,
  rawRatchetEnvelope: unknown,
  rawSignalEnvelope: unknown,
  rawText: unknown,
  client: Pick<HermesGatewayClientDoc, "id" | "relayCapable">,
  surface: "events" | "messages",
): ResolvedGatewayWriteBody {
  const providedEnvelopeCount = [rawEnvelope, rawRatchetEnvelope, rawSignalEnvelope].filter(
    (value) => value != null,
  ).length;
  if (providedEnvelopeCount > 1) {
    throw new HttpsError(
      "invalid-argument",
      "ambiguous_ciphertext: provide only one of relayEnvelope, ratchetEnvelope, or signalEnvelope.",
    );
  }
  if (rawSignalEnvelope != null) {
    return { signalEnvelope: requireProductionGatewaySignalEnvelope(rawSignalEnvelope, "signalEnvelope") };
  }
  if (rawRatchetEnvelope != null) {
    return { ratchetEnvelope: requireProductionGatewayRatchetEnvelope(rawRatchetEnvelope, "ratchetEnvelope") };
  }
  if (rawEnvelope != null) {
    return { relayEnvelope: requireProductionGatewayRelayEnvelope(rawEnvelope, "relayEnvelope") };
  }
  const text = typeof rawText === "string" ? rawText.trim() : "";
  if (!text) return {};
  if (!gatewayPlaintextWriteAllowed(client.relayCapable)) {
    throw new HttpsError(
      "invalid-argument",
      "ciphertext_required: a relayEnvelope or ratchetEnvelope is required for Hermes Gateway message bodies.",
    );
  }
  logInfo({
    event: "hermes_gateway.plaintext_body_deprecated",
    surface,
    client_id: client.id,
    relay_capable: client.relayCapable === true,
  });
  const maxLen = surface === "events" ? HERMES_GATEWAY_MAX_EVENT_TEXT : HERMES_GATEWAY_MAX_MESSAGE_TEXT;
  return { legacyText: text.slice(0, maxLen) };
}

export function requireSafeGatewayEventId(raw: unknown): string {
  const value = requiredIdentifier(raw, "eventId");
  const safe = safeIdentifier(value, "evt");
  if (safe !== value || !safe.startsWith("evt_")) {
    throw new HttpsError("invalid-argument", "eventId must be a safe evt_ identifier.");
  }
  return safe;
}

export function statusCodeForAttachmentManifest(status: HermesGatewayAttachmentManifestDoc["status"]): number {
  if (status === "expired") return 410;
  if (status === "rejected" || status === "failed") return 409;
  return 400;
}

/**
 * Legacy (unsealed) attachment integrity: the stored object's observed media
 * type must match the declared one and be a safe type. Rejects the manifest on
 * mismatch. Sealed uploads skip this entirely — their bytes are opaque
 * ciphertext, integrity-checked by the ciphertext sha256.
 */
export async function assertLegacyAttachmentContentType(
  ref: { set: (data: Record<string, unknown>, opts: { merge: boolean }) => Promise<unknown> },
  declaredContentType: string,
  observedContentType: string,
): Promise<void> {
  const declaredMediaType = baseAttachmentContentType(declaredContentType);
  const observedMediaType = baseAttachmentContentType(observedContentType);
  if (!observedMediaType || observedMediaType !== declaredMediaType) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "attachment_content_type_mismatch");
  }
  assertSafeAttachmentContentType(observedContentType);
}

export async function sha256ForStorageFile(file: StorageFile): Promise<string> {
  return await new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    file
      .createReadStream()
      .on("data", (chunk: Buffer | string) => {
        hash.update(chunk);
      })
      .on("error", reject)
      .on("end", () => {
        resolve(hash.digest("hex"));
      });
  });
}

export async function requireUploadedGatewayAttachments(params: {
  uid: string;
  clientId?: string;
  destinationId?: string;
  attachmentIds: string[];
}): Promise<void> {
  await Promise.all(
    params.attachmentIds.map(async (attachmentId) => {
      const snap = await db.doc(`users/${params.uid}/hermes_gateway_attachments/${attachmentId}`).get();
      const manifest = snap.data();
      if (!snap.exists || !isHermesGatewayAttachmentManifestDoc(manifest)) {
        throw new HttpsError("invalid-argument", `Hermes Gateway attachment ${attachmentId} was not found.`);
      }
      if (params.clientId && manifest.clientId !== params.clientId) {
        throw new HttpsError(
          "permission-denied",
          `Hermes Gateway attachment ${attachmentId} belongs to another client.`,
        );
      }
      if (params.destinationId && manifest.destinationId && manifest.destinationId !== params.destinationId) {
        throw new HttpsError(
          "invalid-argument",
          `Hermes Gateway attachment ${attachmentId} belongs to another destination.`,
        );
      }
      if (manifest.status !== "uploaded") {
        throw new HttpsError(
          "invalid-argument",
          `Hermes Gateway attachment ${attachmentId} must be finalized before use.`,
        );
      }
    }),
  );
}

export async function assertActiveHermesGatewayEntitlement(uid: string): Promise<void> {
  const [hostedSnap, proSnap, proMaxSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/burnbar_pro`).get(),
    db.doc(`users/${uid}/entitlements/burnbar_pro_max`).get(),
  ]);
  if (isActiveHostedQuotaEntitlement(hostedSnap.data())) return;
  if (isActivePremiumEntitlement(proSnap.data())) return;
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return;
  throw new HttpsError("permission-denied", "BurnBar Cloud or BurnBar Cloud Pro is required for Hermes Gateway.");
}

export async function assertActiveHermesGatewayClient(
  uid: string,
  targetClientId: string,
): Promise<HermesGatewayClientDoc> {
  const ref = db.doc(`users/${uid}/hermes_gateway_clients/${targetClientId}`);
  const snap = await ref.get();
  const client = snap.data();
  if (!snap.exists || !isHermesGatewayClientDoc(client) || client.status !== "active" || client.id !== targetClientId) {
    throw new HttpsError("failed-precondition", "Selected Hermes Gateway client is not active.");
  }
  return client;
}

export async function assertTrustedNativeEscrowDevice(uid: string, deviceId: string): Promise<void> {
  const deviceSnap = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
  if (
    !deviceSnap.exists ||
    deviceSnap.get("trustState") !== "trusted" ||
    !NATIVE_ESCROW_PLATFORMS.has(deviceSnap.get("platform"))
  ) {
    throw new HttpsError(
      "permission-denied",
      "This operation requires a trusted native escrow device. Trust this device first.",
    );
  }
}

export async function resolveGatewayGrant(req: HttpRequest, scope: HermesGatewayScope): Promise<ResolvedGatewayGrant> {
  const token = bearerTokenFromAuthorizationHeader(header(req, "authorization"));
  if (!token) throw httpError(401, "missing_bearer_token");
  const tokenHash = hashHermesGatewayBearerToken(token);
  const indexSnap = await db.doc(`hermes_gateway_token_index/${tokenHash}`).get();
  const index = recordOrUndefined(indexSnap.data());
  if (!indexSnap.exists || !index || typeof index.uid !== "string" || typeof index.clientId !== "string") {
    throw httpError(401, "invalid_bearer_token");
  }
  // The entitlement reads need only the uid, so they overlap the client get and
  // PoP replay-guard round-trips below instead of serializing after them. The
  // detached handler keeps a rejection from surfacing as unhandled when one of
  // the intervening 401 checks throws first; the outcome is awaited further down.
  const entitlementCheck = assertActiveHermesGatewayEntitlement(index.uid);
  void entitlementCheck.catch(() => undefined);
  const clientRef = db.doc(`users/${index.uid}/hermes_gateway_clients/${index.clientId}`);
  const clientSnap = await clientRef.get();
  const client = clientSnap.data();
  if (!clientSnap.exists || !isHermesGatewayClientDoc(client) || client.status !== "active") {
    throw httpError(401, "revoked_bearer_token");
  }
  if (client.tokenHash !== tokenHash) {
    await db
      .doc(`hermes_gateway_token_index/${tokenHash}`)
      .delete()
      .catch(() => undefined);
    throw httpError(401, "stale_bearer_token");
  }
  if (isHermesGatewayTokenExpired(client.expiresAt)) {
    throw httpError(401, "expired_bearer_token");
  }
  // allSettled, NOT Promise.all: a PoP failure must always be thrown before an
  // entitlement failure so a bearer-token holder without the PoP signing key
  // sees 401 — never a 403 that leaks the account's subscription state.
  const [popResult, entitlementResult] = await Promise.allSettled([
    verifyGatewayRequestPoP(req, {
      uid: index.uid,
      clientId: index.clientId,
      client,
      tokenHash,
    }),
    entitlementCheck,
  ]);
  if (popResult.status === "rejected") throw popResult.reason;
  if (!hasHermesGatewayScope(client.scopes, scope)) {
    throw httpError(403, "missing_scope", scope);
  }
  if (entitlementResult.status === "rejected") throw entitlementResult.reason;
  // Presence bump, coalesced: skip the write while lastSeenAt is fresher than a
  // third of the presence window — the dominant write on the 1s polling hot path.
  if (!shouldCoalesceHermesGatewayLastSeen(client.lastSeenAt)) {
    const now = nowISO();
    await clientRef.set({ lastSeenAt: now, updatedAt: now }, { merge: true });
  }
  return { uid: index.uid, client };
}

function defaultDestinationDoc(now: string) {
  return {
    id: HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
    displayName: "BurnBar Home",
    kind: "home",
    status: "active",
    isDefault: true,
    createdAt: now,
    updatedAt: now,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  };
}

export async function ensureDefaultDestination(uid: string, now = nowISO()): Promise<void> {
  await db.doc(`users/${uid}/hermes_gateway_destinations/home`).set(defaultDestinationDoc(now), { merge: true });
}
