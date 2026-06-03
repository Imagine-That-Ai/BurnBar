/**
 * @fileoverview BurnBar Cloud Hermes Gateway HTTP API and management callables.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { createHash, randomBytes } from "node:crypto";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallable } from "../appCheckAttestation.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import {
  bearerTokenFromAuthorizationHeader,
  canonicalHermesGatewayUserCode,
  clampHermesGatewayLimit,
  clientAdvertisesModel,
  effectiveOversightMode,
  gatewayApprovalExpiryISO,
  generateHermesGatewayBearerToken,
  gatewayTokenExpiryISO,
  generateHermesGatewayDeviceCode,
  generateHermesGatewayDeviceSecret,
  hashHermesGatewayBearerToken,
  isHermesGatewayApprovalDoc,
  isHermesGatewayApprovalExpired,
  isHermesGatewayClientOnline,
  isHermesGatewayTokenExpired,
  hashHermesGatewayDeviceSecret,
  hasHermesGatewayScope,
  HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
  HERMES_GATEWAY_DEVICE_SESSION_TTL_MS,
  HERMES_GATEWAY_MAX_ATTACHMENT_BYTES,
  HERMES_GATEWAY_MAX_EVENT_TEXT,
  HERMES_GATEWAY_MAX_MESSAGE_TEXT,
  HERMES_GATEWAY_PROTOCOL_VERSION,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isHermesGatewayClientDoc,
  isHermesGatewayAttachmentManifestDoc,
  isSha256Hex,
  makeHermesGatewaySSE,
  parseHermesGatewayCursor,
  pendingModelSwitchInFlight,
  publicApprovalView,
  publicClientView,
  randomHermesGatewayUserCode,
  safeEqualHex,
  sha256Hex,
  sanitizeHermesGatewayApprovalSummary,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayModelId,
  sanitizeHermesGatewayModelOptions,
  sanitizeHermesGatewayOversightMode,
  sanitizeHermesGatewayScopes,
  sanitizedAttachmentIds,
  sanitizedGatewayDisplayName,
  serializeHermesGatewayEvent,
  tokenPreview,
  type HermesGatewayApprovalDoc,
  type HermesGatewayAttachmentManifestDoc,
  type HermesGatewayClientDoc,
  type HermesGatewayScope,
} from "../hermesGateway.js";
import { logError, logInfo, wrapCallableHandler } from "../logging.js";
import {
  assertCallableApprovalNotLocked,
  checkPublicHttpRateLimit,
  clientIpFromHttpRequest,
  recordCallableApprovalFailure,
} from "./publicRateLimit.js";
import {
  boundedTrimmedString,
  isActiveBurnBarCloudProEntitlement,
  isActiveHostedQuotaEntitlement,
  isActivePremiumEntitlement,
  nowISO,
  requiredIdentifier,
  safeIdentifier,
} from "./shared.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";

type HttpRequest = {
  method?: string;
  path?: string;
  url?: string;
  body?: unknown;
  headers?: Record<string, unknown>;
  ip?: string;
  socket?: { remoteAddress?: string };
  query: Record<string, unknown>;
  get(name: string): string | undefined;
};

type HttpResponse = {
  status(code: number): HttpResponse;
  json(body: unknown): void;
  send(body?: unknown): void;
  set(name: string, value: string): void;
};

interface ResolvedGatewayGrant {
  uid: string;
  client: HermesGatewayClientDoc;
}

interface GatewayHttpError {
  status: number;
  error: string;
  detail?: string;
}

type StorageBucket = ReturnType<ReturnType<typeof getStorage>["bucket"]>;
type StorageFile = ReturnType<StorageBucket["file"]>;

// Platforms eligible to resolve an oversight gate. Mirrors the trusted-native
// escrow set enforced by the CLI-agent mission approval path so the gateway and
// mission oversight share one trust model (a web/headless device cannot approve).
const NATIVE_ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);

function httpError(status: number, error: string, detail?: string): GatewayHttpError {
  return { status, error, detail };
}

function isGatewayHttpError(error: unknown): error is GatewayHttpError {
  const record = recordOrUndefined(error);
  return !!record && typeof record.status === "number" && typeof record.error === "string";
}

function sendJSON(res: HttpResponse, status: number, body: Record<string, unknown>): void {
  res.status(status).json(body);
}

function setNoStore(res: HttpResponse): void {
  res.set("Cache-Control", "no-store");
}

function assertSafeAttachmentContentType(contentType: string): void {
  const mediaType = baseAttachmentContentType(contentType);
  const blocked = new Set([
    "text/html",
    "text/javascript",
    "application/javascript",
    "application/ecmascript",
    "application/xhtml+xml",
    "application/xml",
    "text/xml",
    "image/svg+xml",
  ]);
  if (!mediaType || blocked.has(mediaType)) {
    throw httpError(400, "unsafe_content_type");
  }
}

function baseAttachmentContentType(contentType: string): string {
  return contentType.split(";")[0]?.trim().toLowerCase() ?? "";
}

function requiredHttpIdentifier(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 160, true);
  if (!/^[A-Za-z0-9_.:-]+$/u.test(value)) {
    throw httpError(400, `invalid_${fieldName}`);
  }
  return value;
}

function requestedAttachmentHash(raw: unknown): string | undefined {
  if (raw == null) return undefined;
  if (!isSha256Hex(raw)) {
    throw httpError(400, "invalid_sha256");
  }
  return raw.trim().toLowerCase();
}

function statusCodeForAttachmentManifest(status: HermesGatewayAttachmentManifestDoc["status"]): number {
  if (status === "expired") return 410;
  if (status === "rejected" || status === "failed") return 409;
  return 400;
}

async function sha256ForStorageFile(file: StorageFile): Promise<string> {
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

async function requireUploadedGatewayAttachments(params: {
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

function gatewayPath(req: HttpRequest): string {
  const path = req.path || new URL(req.url || "/", "https://api.burnbar.ai").pathname;
  return (
    path
      .replace(/^\/burnBarHermesGateway\b/, "")
      .replace(/^\/v1\/hermes-gateway\b/, "")
      .replace(/\/+$/, "") || "/"
  );
}

function requestBody(req: HttpRequest): Record<string, unknown> {
  return recordOrUndefined(req.body) ?? {};
}

function header(req: HttpRequest, name: string): string | undefined {
  const value = req.get(name);
  return typeof value === "string" ? value : undefined;
}

async function assertActiveHermesGatewayEntitlement(uid: string): Promise<void> {
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

async function assertActiveHermesGatewayClient(uid: string, targetClientId: string): Promise<HermesGatewayClientDoc> {
  const ref = db.doc(`users/${uid}/hermes_gateway_clients/${targetClientId}`);
  const snap = await ref.get();
  const client = snap.data();
  if (!snap.exists || !isHermesGatewayClientDoc(client) || client.status !== "active" || client.id !== targetClientId) {
    throw new HttpsError("failed-precondition", "Selected Hermes Gateway client is not active.");
  }
  return client;
}

async function resolveGatewayGrant(req: HttpRequest, scope: HermesGatewayScope): Promise<ResolvedGatewayGrant> {
  const token = bearerTokenFromAuthorizationHeader(header(req, "authorization"));
  if (!token) throw httpError(401, "missing_bearer_token");
  const tokenHash = hashHermesGatewayBearerToken(token);
  const indexSnap = await db.doc(`hermes_gateway_token_index/${tokenHash}`).get();
  const index = recordOrUndefined(indexSnap.data());
  if (!indexSnap.exists || !index || typeof index.uid !== "string" || typeof index.clientId !== "string") {
    throw httpError(401, "invalid_bearer_token");
  }
  const clientRef = db.doc(`users/${index.uid}/hermes_gateway_clients/${index.clientId}`);
  const clientSnap = await clientRef.get();
  const client = clientSnap.data();
  if (!clientSnap.exists || !isHermesGatewayClientDoc(client) || client.status !== "active") {
    throw httpError(401, "revoked_bearer_token");
  }
  if (isHermesGatewayTokenExpired(client.expiresAt)) {
    throw httpError(401, "expired_bearer_token");
  }
  if (!hasHermesGatewayScope(client.scopes, scope)) {
    throw httpError(403, "missing_scope", scope);
  }
  await assertActiveHermesGatewayEntitlement(index.uid);
  const now = nowISO();
  // Grandfather legacy tokens: backfill a default expiry on first use so
  // pre-expiry tokens eventually age out without mass-invalidation.
  const expiresAtBackfill = client.expiresAt ? undefined : gatewayTokenExpiryISO();
  await Promise.all([
    clientRef.set(
      stripUndefinedObject({ lastSeenAt: now, updatedAt: now, expiresAt: expiresAtBackfill }),
      { merge: true },
    ),
    expiresAtBackfill
      ? db.doc(`hermes_gateway_token_index/${tokenHash}`).set({ expiresAt: expiresAtBackfill }, { merge: true })
      : Promise.resolve(),
  ]);
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

async function ensureDefaultDestination(uid: string, now = nowISO()): Promise<void> {
  await db.doc(`users/${uid}/hermes_gateway_destinations/home`).set(defaultDestinationDoc(now), { merge: true });
}

async function handleDeviceStart(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  await checkPublicHttpRateLimit(clientIpFromHttpRequest(req), "hermes_gateway_device_start");
  const body = requestBody(req);
  const providedSecretHash = typeof body.deviceSecretHash === "string" ? body.deviceSecretHash.trim() : "";
  if (providedSecretHash && !isSha256Hex(providedSecretHash)) {
    throw httpError(400, "invalid_device_secret_hash");
  }
  const generatedSecret = providedSecretHash ? undefined : generateHermesGatewayDeviceSecret();
  const deviceSecretHash = generatedSecret ? hashHermesGatewayDeviceSecret(generatedSecret) : providedSecretHash;
  const deviceCode = generateHermesGatewayDeviceCode();
  const userCode = randomHermesGatewayUserCode();
  const now = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(Date.now() + HERMES_GATEWAY_DEVICE_SESSION_TTL_MS);
  const clientName = sanitizedGatewayDisplayName(body.clientName, "Hermes Agent");
  const requestedScopes = sanitizeHermesGatewayScopes(body.scopes);

  await db.doc(`hermes_gateway_device_sessions/${deviceCode}`).set({
    deviceCode,
    userCode,
    deviceSecretHash,
    status: "pending",
    clientName,
    requestedScopes,
    createdAt: now,
    updatedAt: now,
    expiresAt,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });

  const domain = process.env.BURNBAR_WEBSITE_DOMAIN ?? "https://burnbar.ai";
  setNoStore(res);
  sendJSON(res, 200, {
    deviceCode,
    deviceSecret: generatedSecret,
    userCode,
    verificationUri: `${domain}/hermes/connect`,
    verificationUriComplete: `${domain}/hermes/connect?code=${encodeURIComponent(userCode)}`,
    interval: 3,
    expiresIn: HERMES_GATEWAY_DEVICE_SESSION_TTL_MS / 1000,
  });
}

async function handleDevicePoll(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const body = requestBody(req);
  const deviceCode = boundedTrimmedString(body.deviceCode, "deviceCode", 80, true);
  const deviceSecret = boundedTrimmedString(body.deviceSecret, "deviceSecret", 160, true);
  const ref = db.doc(`hermes_gateway_device_sessions/${deviceCode}`);
  const snap = await ref.get();
  if (!snap.exists) {
    sendJSON(res, 200, { status: "expired" });
    return;
  }
  const data = recordOrUndefined(snap.data());
  if (!data || typeof data.deviceSecretHash !== "string") {
    throw httpError(400, "invalid_session");
  }
  if (!safeEqualHex(hashHermesGatewayDeviceSecret(deviceSecret), data.deviceSecretHash)) {
    throw httpError(403, "invalid_device_secret");
  }
  const expiresAt = data.expiresAt instanceof Timestamp ? data.expiresAt.toMillis() : 0;
  if (expiresAt <= Date.now()) {
    await ref.set({ status: "expired", updatedAt: Timestamp.now() }, { merge: true });
    sendJSON(res, 200, { status: "expired" });
    return;
  }
  if (data.status === "approved") {
    const accessToken = typeof data.accessToken === "string" ? data.accessToken : undefined;
    if (!accessToken) throw httpError(500, "missing_access_token");
    sendJSON(res, 200, {
      status: "approved",
      accessToken,
      tokenType: "Bearer",
      scopes: Array.isArray(data.scopes) ? data.scopes : [],
      clientId: typeof data.clientId === "string" ? data.clientId : undefined,
      homeDestinationId:
        typeof data.homeDestinationId === "string" ? data.homeDestinationId : HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
    });
    await ref.delete();
    return;
  }
  if (data.status === "denied") {
    await ref.delete();
    sendJSON(res, 200, { status: "denied" });
    return;
  }
  sendJSON(res, 200, { status: "authorization_pending" });
}

async function handleDestinations(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  await ensureDefaultDestination(grant.uid);
  const snap = await db.collection(`users/${grant.uid}/hermes_gateway_destinations`).get();
  const destinations = snap.docs
    .map((doc) => doc.data())
    .filter((doc) => doc.status !== "archived")
    .sort((left, right) => {
      if (left.isDefault === true) return -1;
      if (right.isDefault === true) return 1;
      return String(left.displayName ?? "").localeCompare(String(right.displayName ?? ""));
    });
  sendJSON(res, 200, { destinations });
}

async function handleEvents(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  const cursor = parseHermesGatewayCursor(req.query.cursor);
  const limit = clampHermesGatewayLimit(req.query.limit);
  const destinationId =
    typeof req.query.destinationId === "string"
      ? sanitizeHermesGatewayDestinationId(req.query.destinationId)
      : undefined;
  let query = db
    .collection(`users/${grant.uid}/hermes_gateway_events`)
    .where("sequence", ">", cursor)
    .orderBy("sequence", "asc")
    .limit(limit);
  if (destinationId) {
    query = db
      .collection(`users/${grant.uid}/hermes_gateway_events`)
      .where("destinationId", "==", destinationId)
      .where("sequence", ">", cursor)
      .orderBy("sequence", "asc")
      .limit(limit);
  }
  const snap = await query.get();
  const scannedEvents = snap.docs.flatMap((doc) => {
    const event = serializeHermesGatewayEvent(doc.data());
    return event ? [event] : [];
  });
  const events = scannedEvents.filter((event) => !event.targetClientId || event.targetClientId === grant.client.id);
  const nextCursor = scannedEvents.reduce((max, event) => Math.max(max, event.sequence), cursor);
  if (header(req, "accept")?.includes("text/event-stream") || req.query.stream === "true") {
    res.set("Content-Type", "text/event-stream; charset=utf-8");
    res.set("Cache-Control", "no-store");
    res.status(200).send(makeHermesGatewaySSE(events, nextCursor));
    return;
  }
  sendJSON(res, 200, { events, nextCursor });
}

async function handleMessageSend(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const text = boundedTrimmedString(body.text, "text", HERMES_GATEWAY_MAX_MESSAGE_TEXT, false);
  const attachmentIds = sanitizedAttachmentIds(body.attachmentIds);
  if (!text && attachmentIds.length === 0) {
    throw httpError(400, "empty_message");
  }
  await requireUploadedGatewayAttachments({ uid: grant.uid, clientId: grant.client.id, destinationId, attachmentIds });
  const now = nowISO();
  const id = safeIdentifier(body.messageId, "msg");
  const doc = stripUndefinedObject({
    id,
    clientId: grant.client.id,
    kind: "agent_message",
    destinationId,
    threadId: boundedTrimmedString(body.threadId, "threadId", 160, false),
    replyToEventId: boundedTrimmedString(body.replyToEventId, "replyToEventId", 160, false),
    text,
    attachmentIds,
    createdAt: now,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
  await db.doc(`users/${grant.uid}/hermes_gateway_messages/${id}`).set(doc, { merge: false });
  logInfo({ event: "hermes_gateway.message_sent", client_id: grant.client.id, message_id: id });
  sendJSON(res, 200, { message: doc });
}

async function handleTyping(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const now = nowISO();
  const doc = stripUndefinedObject({
    id: grant.client.id,
    clientId: grant.client.id,
    kind: "typing",
    destinationId,
    threadId: boundedTrimmedString(body.threadId, "threadId", 160, false),
    createdAt: now,
    expiresAt: new Date(Date.now() + 15_000).toISOString(),
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
  await db.doc(`users/${grant.uid}/hermes_gateway_typing/${grant.client.id}`).set(doc, { merge: true });
  sendJSON(res, 200, { success: true });
}

async function handleRuntimeStatus(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const runtimeModelId = sanitizeHermesGatewayModelId(body.currentModelId);
  const runtimeProviderId = boundedTrimmedString(body.currentProviderId, "currentProviderId", 80, false);
  const runtimeModelOptions = sanitizeHermesGatewayModelOptions(body.modelOptions);
  const agentVersion = boundedTrimmedString(body.agentVersion, "agentVersion", 120, false);
  const now = nowISO();
  // Reconcile the optimistic model-switch marker: once the runtime reports it is
  // actually running the requested model, clear pendingModelId so /state stops
  // reporting "switching…". A no-op when there is no pending switch.
  const pending = typeof grant.client.pendingModelId === "string" ? grant.client.pendingModelId.trim() : "";
  const settled = !!pending && !!runtimeModelId && pending.toLowerCase() === runtimeModelId.trim().toLowerCase();
  await db.doc(`users/${grant.uid}/hermes_gateway_clients/${grant.client.id}`).set(
    stripUndefinedObject({
      runtimeModelId,
      runtimeProviderId,
      runtimeModelOptions,
      agentVersion,
      runtimeUpdatedAt: now,
      lastSeenAt: now,
      updatedAt: now,
      pendingModelId: settled ? FieldValue.delete() : undefined,
      pendingModelRequestedAt: settled ? FieldValue.delete() : undefined,
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    }),
    { merge: true },
  );
  sendJSON(res, 200, {
    success: true,
    runtimeModelId,
    runtimeProviderId,
    agentVersion,
    modelOptionCount: runtimeModelOptions.length,
    pendingModelSwitchSettled: settled,
    runtimeUpdatedAt: now,
  });
}

/**
 * GET /state — a single truthful snapshot of the gateway: the event cursor, the
 * paired clients with DERIVED online/offline + in-flight model switch, the
 * current model, the oversight mode, and version metadata. Read-only: it never
 * bumps the event cursor. Presence is derived from lastSeenAt at read time, so a
 * stopped gateway reports offline without any write.
 */
async function handleGatewayState(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  const now = Date.now();
  const nowIso = new Date(now).toISOString();
  const [stateSnap, clientsSnap] = await Promise.all([
    db.doc(`users/${grant.uid}/hermes_gateway_state/cursors`).get(),
    db.collection(`users/${grant.uid}/hermes_gateway_clients`).get(),
  ]);
  const eventSequence = Number(stateSnap.get("eventSequence") ?? 0);
  const activeClients = clientsSnap.docs
    .flatMap((doc): HermesGatewayClientDoc[] => {
      const client = doc.data();
      return isHermesGatewayClientDoc(client) ? [client] : [];
    })
    .filter((client) => client.status === "active")
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  const clients = activeClients.map((client) => ({
    ...publicClientView(client),
    online: isHermesGatewayClientOnline(client.lastSeenAt, now),
    pendingModelSwitch: pendingModelSwitchInFlight(client, now),
  }));
  const onlineCount = activeClients.filter((client) => isHermesGatewayClientOnline(client.lastSeenAt, now)).length;
  // The "current model" is whatever the freshest online client is running.
  const primary = activeClients.find((client) => isHermesGatewayClientOnline(client.lastSeenAt, now));
  sendJSON(res, 200, {
    online: onlineCount > 0,
    generatedAt: nowIso,
    eventSequence: Number.isFinite(eventSequence) ? eventSequence : 0,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    protocolVersion: HERMES_GATEWAY_PROTOCOL_VERSION,
    currentModelId: primary?.runtimeModelId ?? null,
    currentProviderId: primary?.runtimeProviderId ?? null,
    agentVersion: primary?.agentVersion ?? null,
    oversightMode: effectiveOversightMode(primary?.oversightMode),
    connectedClientCount: onlineCount,
    clientCount: clients.length,
    clients,
  });
}

async function handleAttachmentInit(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const fileName = boundedTrimmedString(body.fileName, "fileName", 255, true).replace(/[\\/]/g, "-");
  const contentType = boundedTrimmedString(body.contentType, "contentType", 128, true);
  assertSafeAttachmentContentType(contentType);
  const byteCount = typeof body.byteCount === "number" ? body.byteCount : Number(body.byteCount);
  if (!Number.isFinite(byteCount) || byteCount < 1 || byteCount > HERMES_GATEWAY_MAX_ATTACHMENT_BYTES) {
    throw httpError(400, "invalid_byte_count");
  }
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const attachmentId = safeIdentifier(body.attachmentId, `att_${randomBytes(8).toString("hex")}`);
  const storagePath = `users/${grant.uid}/hermes_gateway_attachments/${grant.client.id}/${attachmentId}/${fileName}`;
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
  const [uploadURL] = await getStorage().bucket().file(storagePath).getSignedUrl({
    version: "v4",
    action: "write",
    expires: expiresAt,
    contentType,
  });
  const now = nowISO();
  const manifest = {
    id: attachmentId,
    clientId: grant.client.id,
    destinationId,
    fileName,
    contentType,
    byteCount,
    storagePath,
    status: "pending_upload",
    createdAt: now,
    expiresAt: expiresAt.toISOString(),
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  };
  await db.doc(`users/${grant.uid}/hermes_gateway_attachments/${attachmentId}`).set(manifest, { merge: false });
  sendJSON(res, 200, { attachment: manifest, uploadURL, maxBytes: HERMES_GATEWAY_MAX_ATTACHMENT_BYTES });
}

async function handleAttachmentFinalize(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const attachmentId = requiredHttpIdentifier(body.attachmentId, "attachmentId");
  const expectedSha256 = requestedAttachmentHash(body.sha256);
  const requestedDestinationId =
    body.destinationId == null ? undefined : sanitizeHermesGatewayDestinationId(body.destinationId);
  const ref = db.doc(`users/${grant.uid}/hermes_gateway_attachments/${attachmentId}`);
  const snap = await ref.get();
  const manifest = snap.data();
  if (!snap.exists || !isHermesGatewayAttachmentManifestDoc(manifest) || manifest.id !== attachmentId) {
    throw httpError(404, "attachment_not_found");
  }
  if (manifest.clientId !== grant.client.id) {
    throw httpError(403, "attachment_client_mismatch");
  }
  if (requestedDestinationId && manifest.destinationId && manifest.destinationId !== requestedDestinationId) {
    throw httpError(400, "attachment_destination_mismatch");
  }
  const expectedPathPrefix = `users/${grant.uid}/hermes_gateway_attachments/${grant.client.id}/${attachmentId}/`;
  if (!manifest.storagePath.startsWith(expectedPathPrefix)) {
    throw httpError(403, "attachment_storage_path_mismatch");
  }
  if (manifest.status === "uploaded") {
    if (expectedSha256 && manifest.sha256 && manifest.sha256 !== expectedSha256) {
      throw httpError(409, "attachment_hash_mismatch");
    }
    sendJSON(res, 200, { attachment: manifest });
    return;
  }
  if (manifest.status !== "pending_upload") {
    throw httpError(statusCodeForAttachmentManifest(manifest.status), "attachment_not_uploadable", manifest.status);
  }
  const expiresAtMs = Date.parse(manifest.expiresAt);
  if (!Number.isFinite(expiresAtMs) || expiresAtMs <= Date.now()) {
    await ref.set({ status: "expired", updatedAt: nowISO() }, { merge: true });
    throw httpError(410, "attachment_upload_expired");
  }
  if (manifest.byteCount < 1 || manifest.byteCount > HERMES_GATEWAY_MAX_ATTACHMENT_BYTES) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "invalid_attachment_manifest");
  }

  const file = getStorage().bucket().file(manifest.storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    throw httpError(404, "attachment_object_missing");
  }
  const [metadata] = await file.getMetadata();
  const observedByteCount = Number(metadata.size);
  const observedContentType = typeof metadata.contentType === "string" ? metadata.contentType : "";
  const declaredMediaType = baseAttachmentContentType(manifest.contentType);
  const observedMediaType = baseAttachmentContentType(observedContentType);
  if (!Number.isFinite(observedByteCount) || observedByteCount !== manifest.byteCount) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "attachment_size_mismatch");
  }
  if (!observedMediaType || observedMediaType !== declaredMediaType) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "attachment_content_type_mismatch");
  }
  assertSafeAttachmentContentType(observedContentType);

  const sha256 = await sha256ForStorageFile(file);
  if (expectedSha256 && sha256 !== expectedSha256) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(409, "attachment_hash_mismatch");
  }

  const now = nowISO();
  const finalized = stripUndefinedObject({
    ...manifest,
    status: "uploaded",
    updatedAt: now,
    uploadedAt: now,
    finalizedAt: now,
    sha256,
    storageGeneration:
      typeof metadata.generation === "string"
        ? metadata.generation
        : metadata.generation == null
          ? undefined
          : String(metadata.generation),
  });
  await ref.set(finalized, { merge: true });
  sendJSON(res, 200, { attachment: finalized });
}

// Deterministic gate id so a retried arm request from the agent is idempotent
// (same client + actionId always maps to the same approval document).
function gatewayApprovalDocId(clientId: string, actionId: string): string {
  return `hga_${sha256Hex(`${clientId}:${actionId}`).slice(0, 40)}`;
}

/**
 * POST /approvals — the agent arms a human-in-the-loop gate before a risky
 * action. Idempotent: arming the same (clientId, actionId) twice returns the
 * existing gate (and its resolution if already decided). The gate is resolved by
 * a trusted native device via the respondHermesGatewayApproval callable; the
 * agent's write scope can never self-approve.
 */
async function handleArmApproval(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const actionId = requiredHttpIdentifier(body.actionId, "actionId");
  const toolName = boundedTrimmedString(body.toolName, "toolName", 120, false);
  const summary = sanitizeHermesGatewayApprovalSummary(body.summary);
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const approvalId = gatewayApprovalDocId(grant.client.id, actionId);
  const ref = db.doc(`users/${grant.uid}/hermes_gateway_approvals/${approvalId}`);
  const now = Date.now();
  const nowIso = new Date(now).toISOString();
  const existingSnap = await ref.get();
  const existing = existingSnap.data();
  if (existingSnap.exists && isHermesGatewayApprovalDoc(existing)) {
    // Return the live gate (idempotent re-arm). publicApprovalView derives an
    // expired status for a stale waiting gate so the agent stops blocking.
    setNoStore(res);
    sendJSON(res, 200, { approval: publicApprovalView(existing, now) });
    return;
  }
  const doc: HermesGatewayApprovalDoc = {
    id: approvalId,
    clientId: grant.client.id,
    destinationId,
    actionId,
    toolName,
    summary,
    status: "waiting_for_approval",
    requestedAt: nowIso,
    expiresAt: gatewayApprovalExpiryISO(now),
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  };
  await ref.set(stripUndefinedObject(doc), { merge: false });
  logInfo({ event: "hermes_gateway.approval_armed", client_id: grant.client.id, approval_id: approvalId });
  setNoStore(res);
  sendJSON(res, 200, { approval: publicApprovalView(doc, now) });
}

/**
 * GET /approvals — the agent polls its gates for resolution. Returns the calling
 * client's approvals (optionally one, via ?actionId=). Read-only; status is
 * derived so an expired-but-unreaped gate reads as "expired".
 */
async function handleListApprovals(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  const now = Date.now();
  const actionId = typeof req.query.actionId === "string" ? req.query.actionId.trim() : "";
  if (actionId) {
    const ref = db.doc(`users/${grant.uid}/hermes_gateway_approvals/${gatewayApprovalDocId(grant.client.id, actionId)}`);
    const snap = await ref.get();
    const doc = snap.data();
    setNoStore(res);
    if (!snap.exists || !isHermesGatewayApprovalDoc(doc) || doc.clientId !== grant.client.id) {
      sendJSON(res, 404, { error: "not_found" });
      return;
    }
    sendJSON(res, 200, { approval: publicApprovalView(doc, now) });
    return;
  }
  const snap = await db
    .collection(`users/${grant.uid}/hermes_gateway_approvals`)
    .where("clientId", "==", grant.client.id)
    .get();
  const approvals = snap.docs
    .flatMap((doc): HermesGatewayApprovalDoc[] => {
      const approval = doc.data();
      return isHermesGatewayApprovalDoc(approval) ? [approval] : [];
    })
    .sort((left, right) => right.requestedAt.localeCompare(left.requestedAt))
    .slice(0, 50)
    .map((approval) => publicApprovalView(approval, now));
  setNoStore(res);
  sendJSON(res, 200, { approvals });
}

export const burnBarHermesGateway = onRequest(
  {
    region: FUNCTIONS_REGION,
    cors: true,
    maxInstances: 100,
    ...HOT_PATH_OPTIONS,
  },
  async (req, res): Promise<void> => {
    if (req.method === "OPTIONS") {
      res.status(204).send("");
      return;
    }
    try {
      const path = gatewayPath(req);
      if (path === "/device/start") return await handleDeviceStart(req, res);
      if (path === "/device/poll") return await handleDevicePoll(req, res);
      if (path === "/destinations") return await handleDestinations(req, res);
      if (path === "/events") return await handleEvents(req, res);
      if (path === "/messages") return await handleMessageSend(req, res);
      if (path === "/typing") return await handleTyping(req, res);
      if (path === "/runtime") return await handleRuntimeStatus(req, res);
      if (path === "/state") return await handleGatewayState(req, res);
      if (path === "/approvals") {
        return req.method === "GET" ? await handleListApprovals(req, res) : await handleArmApproval(req, res);
      }
      if (path === "/attachments/init") return await handleAttachmentInit(req, res);
      if (path === "/attachments/finalize") return await handleAttachmentFinalize(req, res);
      sendJSON(res, 404, { error: "not_found" });
    } catch (err) {
      if (isGatewayHttpError(err)) {
        sendJSON(res, err.status, stripUndefinedObject({ error: err.error, detail: err.detail }));
        return;
      }
      if (err instanceof HttpsError) {
        const status = err.code === "invalid-argument" ? 400 : err.code === "permission-denied" ? 403 : 500;
        sendJSON(res, status, { error: err.code, detail: err.message });
        return;
      }
      logError({ event: "hermes_gateway.http_failed", error: String(err) });
      sendJSON(res, 500, { error: "internal" });
    }
  },
);

export const approveHermesGatewayDeviceGrant = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "approveHermesGatewayDeviceGrant",
    async (
      request: CallableRequest<{
        userCode?: unknown;
        displayName?: unknown;
        destinationId?: unknown;
        scopes?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before approving Hermes Gateway.");
      enforceAuthAndAppCheck(request, uid);
      await assertCallableApprovalNotLocked(uid, "hermes_gateway_approve_fail");
      await assertActiveHermesGatewayEntitlement(uid);
      const userCode = canonicalHermesGatewayUserCode(request.data.userCode);
      if (!userCode) throw new HttpsError("invalid-argument", "userCode must be an 8-character Hermes Gateway code.");

      const sessions = await db
        .collection("hermes_gateway_device_sessions")
        .where("userCode", "==", userCode)
        .where("status", "==", "pending")
        .limit(1)
        .get();
      if (sessions.empty) {
        await recordCallableApprovalFailure(uid, "hermes_gateway_approve_fail");
        throw new HttpsError("not-found", "Hermes Gateway pairing code was not found.");
      }
      const sessionRef = sessions.docs[0].ref;
      const session = recordOrUndefined(sessions.docs[0].data());
      if (!session) throw new HttpsError("failed-precondition", "Hermes Gateway pairing session is invalid.");
      const expiresAt = session.expiresAt instanceof Timestamp ? session.expiresAt.toMillis() : 0;
      if (expiresAt <= Date.now()) {
        await sessionRef.set({ status: "expired", updatedAt: Timestamp.now() }, { merge: true });
        throw new HttpsError("deadline-exceeded", "Hermes Gateway pairing code has expired.");
      }

      const token = generateHermesGatewayBearerToken();
      const tokenHash = hashHermesGatewayBearerToken(token);
      const now = nowISO();
      const tokenExpiresAt = gatewayTokenExpiryISO();
      const clientId = `hgw_${randomBytes(12).toString("hex")}`;
      const scopes = sanitizeHermesGatewayScopes(request.data.scopes ?? session.requestedScopes);
      const homeDestinationId = sanitizeHermesGatewayDestinationId(request.data.destinationId);
      const displayName = sanitizedGatewayDisplayName(
        request.data.displayName,
        String(session.clientName ?? "Hermes Agent"),
      );
      const clientDoc: HermesGatewayClientDoc = {
        id: clientId,
        uid,
        displayName,
        status: "active",
        tokenHash,
        tokenPreview: tokenPreview(token),
        scopes,
        homeDestinationId,
        expiresAt: tokenExpiresAt,
        createdAt: now,
        updatedAt: now,
        schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
      };

      await ensureDefaultDestination(uid, now);
      await Promise.all([
        db
          .doc(`users/${uid}/hermes_gateway_clients/${clientId}`)
          .set(stripUndefinedObject(clientDoc), { merge: false }),
        db
          .doc(`hermes_gateway_token_index/${tokenHash}`)
          .set({ uid, clientId, status: "active", createdAt: now, expiresAt: tokenExpiresAt }),
        sessionRef.set(
          {
            status: "approved",
            uid,
            clientId,
            accessToken: token,
            scopes,
            homeDestinationId,
            approvedAt: now,
            updatedAt: Timestamp.now(),
          },
          { merge: true },
        ),
      ]);
      logInfo({ event: "hermes_gateway.device_grant_approved", user_id_hash: uid.slice(0, 8), client_id: clientId });
      return { client: publicClientView(clientDoc), homeDestinationId };
    },
  ),
);

export const listHermesGatewayClients = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("listHermesGatewayClients", async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing Hermes Gateway clients.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHermesGatewayEntitlement(uid);
    const snap = await db.collection(`users/${uid}/hermes_gateway_clients`).get();
    const clients = snap.docs
      .flatMap((doc): HermesGatewayClientDoc[] => {
        const client = doc.data();
        return isHermesGatewayClientDoc(client) ? [client] : [];
      })
      .filter((client) => request.data.includeRevoked === true || client.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
      .map(publicClientView);
    return { clients };
  }),
);

export const revokeHermesGatewayClient = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("revokeHermesGatewayClient", async (request: CallableRequest<{ clientId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking Hermes Gateway clients.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHermesGatewayEntitlement(uid);
    const clientId = requiredIdentifier(request.data.clientId, "clientId");
    const ref = db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`);
    const snap = await ref.get();
    const client = snap.data();
    if (!snap.exists || !isHermesGatewayClientDoc(client)) {
      throw new HttpsError("not-found", "Hermes Gateway client not found.");
    }
    const now = nowISO();
    await Promise.all([
      ref.set({ status: "revoked", revokedAt: now, updatedAt: now }, { merge: true }),
      db.doc(`hermes_gateway_token_index/${client.tokenHash}`).delete(),
    ]);
    return { success: true, clientId };
  }),
);

export const rotateHermesGatewayClientToken = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "rotateHermesGatewayClientToken",
    async (request: CallableRequest<{ clientId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before rotating Hermes Gateway tokens.");
      enforceAuthAndAppCheck(request, uid);
      await assertCallableApprovalNotLocked(uid, "hermes_gateway_approve_fail");
      await assertActiveHermesGatewayEntitlement(uid);
      const clientId = requiredIdentifier(request.data.clientId, "clientId");
      const ref = db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`);
      const snap = await ref.get();
      const client = snap.data();
      if (!snap.exists || !isHermesGatewayClientDoc(client)) {
        await recordCallableApprovalFailure(uid, "hermes_gateway_approve_fail");
        throw new HttpsError("not-found", "Hermes Gateway client not found.");
      }
      if (client.status !== "active") {
        throw new HttpsError("failed-precondition", "Revoked Hermes Gateway clients cannot be rotated.");
      }
      const previousTokenHash = client.tokenHash;
      const token = generateHermesGatewayBearerToken();
      const tokenHash = hashHermesGatewayBearerToken(token);
      if (tokenHash === previousTokenHash) {
        throw new HttpsError("aborted", "Token rotation collision; please retry.");
      }
      const now = nowISO();
      const tokenExpiresAt = gatewayTokenExpiryISO();
      // Atomic-enough swap: write the NEW index first (so a crash mid-rotation
      // leaves the new token usable rather than locking the client out), then
      // repoint the client doc, then delete the OLD index hash. The old token is
      // invalidated the moment the client doc's tokenHash changes because
      // resolveGatewayGrant re-derives and compares against the client doc.
      const batch = db.batch();
      batch.set(db.doc(`hermes_gateway_token_index/${tokenHash}`), {
        uid,
        clientId,
        status: "active",
        createdAt: now,
        expiresAt: tokenExpiresAt,
      });
      batch.set(
        ref,
        {
          tokenHash,
          tokenPreview: tokenPreview(token),
          expiresAt: tokenExpiresAt,
          rotatedAt: now,
          updatedAt: now,
        },
        { merge: true },
      );
      if (previousTokenHash && previousTokenHash !== tokenHash) {
        batch.delete(db.doc(`hermes_gateway_token_index/${previousTokenHash}`));
      }
      await batch.commit();
      logInfo({
        event: "hermes_gateway.token_rotated",
        user_id_hash: uid.slice(0, 8),
        client_id: clientId,
      });
      const rotated: HermesGatewayClientDoc = {
        ...client,
        tokenHash,
        tokenPreview: tokenPreview(token),
        expiresAt: tokenExpiresAt,
        rotatedAt: now,
        updatedAt: now,
      };
      return { client: publicClientView(rotated), accessToken: token, tokenType: "Bearer", expiresAt: tokenExpiresAt };
    },
  ),
);

export const enqueueHermesGatewayEvent = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "enqueueHermesGatewayEvent",
    async (
      request: CallableRequest<{
        destinationId?: unknown;
        threadId?: unknown;
        senderId?: unknown;
        senderDisplayName?: unknown;
        text?: unknown;
        eventKind?: unknown;
        modelId?: unknown;
        targetClientId?: unknown;
        attachmentIds?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before sending Hermes Gateway events.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveHermesGatewayEntitlement(uid);
      const eventKind = request.data.eventKind === "model_switch" ? "model_switch" : "message";
      const requestedModelId = sanitizeHermesGatewayModelId(request.data.modelId);
      const text =
        eventKind === "model_switch"
          ? `/model ${requestedModelId ?? ""}`.trim()
          : boundedTrimmedString(request.data.text, "text", HERMES_GATEWAY_MAX_EVENT_TEXT, true);
      if (eventKind === "model_switch" && !requestedModelId) {
        throw new HttpsError("invalid-argument", "modelId is required for Hermes Gateway model switches.");
      }
      const targetClientId = request.data.targetClientId
        ? requiredIdentifier(request.data.targetClientId, "targetClientId")
        : undefined;
      let targetClient: HermesGatewayClientDoc | undefined;
      if (targetClientId) {
        targetClient = await assertActiveHermesGatewayClient(uid, targetClientId);
      }
      // Validate the requested model against the target runtime's advertised
      // catalog. We only reject when the runtime has actually published a
      // non-empty catalog and the model is absent — before inventory is known, a
      // custom model id is allowed through (the runtime is the final authority).
      if (eventKind === "model_switch" && requestedModelId && targetClient) {
        const hasCatalog = (targetClient.runtimeModelOptions?.length ?? 0) > 0;
        if (hasCatalog && !clientAdvertisesModel(targetClient, requestedModelId)) {
          throw new HttpsError(
            "invalid-argument",
            `model_not_available: ${requestedModelId} is not in the selected client's advertised models.`,
          );
        }
      }
      const destinationId = sanitizeHermesGatewayDestinationId(request.data.destinationId);
      const attachmentIds = sanitizedAttachmentIds(request.data.attachmentIds);
      await requireUploadedGatewayAttachments({ uid, clientId: targetClientId, destinationId, attachmentIds });
      const eventId = `evt_${randomBytes(12).toString("hex")}`;
      const now = nowISO();
      let sequence = 0;
      await db.runTransaction(async (tx) => {
        const stateRef = db.doc(`users/${uid}/hermes_gateway_state/cursors`);
        const stateSnap = await tx.get(stateRef);
        const current = Number(stateSnap.get("eventSequence") ?? 0);
        sequence = Number.isFinite(current) ? current + 1 : 1;
        tx.set(
          stateRef,
          { eventSequence: sequence, updatedAt: now, schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION },
          { merge: true },
        );
        tx.set(
          db.doc(`users/${uid}/hermes_gateway_events/${eventId}`),
          stripUndefinedObject({
            id: eventId,
            sequence,
            kind: eventKind,
            destinationId,
            targetClientId,
            threadId: boundedTrimmedString(request.data.threadId, "threadId", 160, false),
            senderId: boundedTrimmedString(request.data.senderId, "senderId", 160, false) ?? "burnbar-user",
            senderDisplayName: boundedTrimmedString(request.data.senderDisplayName, "senderDisplayName", 80, false),
            text,
            modelId: requestedModelId,
            attachmentIds,
            createdAt: now,
            schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
          }),
        );
        // Optimistically mark the switch in flight so /state reports "switching…"
        // until the runtime republishes the applied model (or the TTL lapses).
        if (eventKind === "model_switch" && requestedModelId && targetClientId) {
          tx.set(
            db.doc(`users/${uid}/hermes_gateway_clients/${targetClientId}`),
            { pendingModelId: requestedModelId, pendingModelRequestedAt: now, updatedAt: now },
            { merge: true },
          );
        }
      });
      return stripUndefinedObject({ id: eventId, sequence, targetClientId, pendingModelId: eventKind === "model_switch" ? requestedModelId : undefined });
    },
  ),
);

/**
 * Set a paired client's human-in-the-loop oversight mode. "supervised" arms an
 * approval gate before each risky agent action; "autonomous" runs unattended.
 * The runtime reads this via /state and obeys it. Default (unset) is supervised.
 */
export const setHermesGatewayOversightMode = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "setHermesGatewayOversightMode",
    async (request: CallableRequest<{ clientId?: unknown; mode?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before changing Hermes Gateway oversight.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveHermesGatewayEntitlement(uid);
      const clientId = requiredIdentifier(request.data.clientId, "clientId");
      const mode = sanitizeHermesGatewayOversightMode(request.data.mode);
      if (!mode) throw new HttpsError("invalid-argument", "mode must be 'supervised' or 'autonomous'.");
      await assertActiveHermesGatewayClient(uid, clientId);
      const now = nowISO();
      await db
        .doc(`users/${uid}/hermes_gateway_clients/${clientId}`)
        .set({ oversightMode: mode, updatedAt: now }, { merge: true });
      logInfo({ event: "hermes_gateway.oversight_mode_set", client_id: clientId, mode });
      return { clientId, oversightMode: mode };
    },
  ),
);

/**
 * Resolve a Hermes Gateway oversight gate from a TRUSTED NATIVE device.
 *
 * This reuses the exact hardened approval semantics of the CLI-agent mission
 * primitive — App-Check-bound caller, a trusted native escrow device, single
 * transactional resolution, and a server-stamped `approvedByDeviceId` — but
 * targets the gateway's own `hermes_gateway_approvals` collection (the agent
 * arms gates over a bearer token and can never self-approve). It does NOT touch
 * the E2E-sealed `cli_agent_mission_requests` collection, which is client-created
 * and cannot be armed by a server-side gateway action.
 */
export const respondHermesGatewayApproval = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "respondHermesGatewayApproval",
    async (request: CallableRequest<{ approvalId?: unknown; approve?: unknown; deviceId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before responding to an oversight request.");
      enforceHighRiskComputerUseCallable(request, uid);
      const approvalId = boundedTrimmedString(request.data.approvalId, "approvalId", 160, true);
      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      if (typeof request.data.approve !== "boolean") {
        throw new HttpsError("invalid-argument", "approve must be a boolean.");
      }
      const approve = request.data.approve;

      const approvalRef = db.doc(`users/${uid}/hermes_gateway_approvals/${approvalId}`);
      const deviceRef = db.doc(`users/${uid}/escrow_devices/${deviceId}`);

      const result = await db.runTransaction(async (transaction) => {
        const [approvalSnap, deviceSnap] = await Promise.all([
          transaction.get(approvalRef),
          transaction.get(deviceRef),
        ]);
        const approval = approvalSnap.data();
        if (!approvalSnap.exists || !isHermesGatewayApprovalDoc(approval)) {
          throw new HttpsError("not-found", "Oversight request was not found.");
        }
        if (approval.status !== "waiting_for_approval") {
          throw new HttpsError("failed-precondition", "Oversight request has already been resolved.");
        }
        if (isHermesGatewayApprovalExpired(approval.expiresAt)) {
          throw new HttpsError("failed-precondition", "Oversight request has expired.");
        }
        if (
          !deviceSnap.exists ||
          deviceSnap.get("trustState") !== "trusted" ||
          !NATIVE_ESCROW_PLATFORMS.has(deviceSnap.get("platform"))
        ) {
          throw new HttpsError(
            "permission-denied",
            "Oversight approvals require a trusted native device. Trust this device first.",
          );
        }
        transaction.set(
          approvalRef,
          {
            status: approve ? "approved" : "rejected",
            respondedAt: nowISO(),
            approvedByDeviceId: deviceId,
          },
          { merge: true },
        );
        return { status: approve ? "approved" : ("rejected" as HermesGatewayApprovalDoc["status"]) };
      });

      logInfo({
        event: "hermes_gateway.approval_resolved",
        approval_id: approvalId,
        approved_by_device_id: deviceId,
        status: result.status,
      });
      return { ok: true, approvalId, status: result.status, approvedByDeviceId: deviceId };
    },
  ),
);

/**
 * Reap oversight gates left unanswered past their TTL by flipping them to
 * "expired" so the phone UI and the agent both see a terminal state. Resolution
 * paths already fail-close on expiry (publicApprovalView derives "expired"), so
 * this is a tidy-up sweep, not a correctness dependency.
 */
export const reapHermesGatewayApprovals = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 120,
  },
  async () => {
    const now = Date.now();
    const snap = await db
      .collectionGroup("hermes_gateway_approvals")
      .where("status", "==", "waiting_for_approval")
      .limit(400)
      .get();
    let reaped = 0;
    let batch = db.batch();
    for (const doc of snap.docs) {
      const approval = doc.data();
      if (!isHermesGatewayApprovalDoc(approval) || !isHermesGatewayApprovalExpired(approval.expiresAt, now)) continue;
      batch.set(doc.ref, { status: "expired", respondedAt: new Date(now).toISOString() }, { merge: true });
      reaped += 1;
      if (reaped % 400 === 0) {
        await batch.commit();
        batch = db.batch();
      }
    }
    if (reaped % 400 !== 0) await batch.commit();
    if (reaped > 0) logInfo({ event: "hermes_gateway.approvals_reaped", count: reaped });
  },
);
