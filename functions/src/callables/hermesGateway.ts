/**
 * @fileoverview BurnBar Cloud Hermes Gateway HTTP API and management callables.
 */

import { Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import {
  bearerTokenFromAuthorizationHeader,
  canonicalHermesGatewayUserCode,
  clampHermesGatewayLimit,
  generateHermesGatewayBearerToken,
  generateHermesGatewayDeviceCode,
  generateHermesGatewayDeviceSecret,
  hashHermesGatewayBearerToken,
  hashHermesGatewayDeviceSecret,
  hasHermesGatewayScope,
  HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
  HERMES_GATEWAY_DEVICE_SESSION_TTL_MS,
  HERMES_GATEWAY_MAX_ATTACHMENT_BYTES,
  HERMES_GATEWAY_MAX_EVENT_TEXT,
  HERMES_GATEWAY_MAX_MESSAGE_TEXT,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isHermesGatewayClientDoc,
  isSha256Hex,
  makeHermesGatewaySSE,
  parseHermesGatewayCursor,
  publicClientView,
  randomHermesGatewayUserCode,
  safeEqualHex,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayModelId,
  sanitizeHermesGatewayModelOptions,
  sanitizeHermesGatewayScopes,
  sanitizedAttachmentIds,
  sanitizedGatewayDisplayName,
  serializeHermesGatewayEvent,
  tokenPreview,
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
  const mediaType = contentType.split(";")[0]?.trim().toLowerCase() ?? "";
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

async function assertActiveHermesGatewayClient(uid: string, targetClientId: string): Promise<void> {
  const ref = db.doc(`users/${uid}/hermes_gateway_clients/${targetClientId}`);
  const snap = await ref.get();
  const client = snap.data();
  if (!snap.exists || !isHermesGatewayClientDoc(client) || client.status !== "active" || client.id !== targetClientId) {
    throw new HttpsError("failed-precondition", "Selected Hermes Gateway client is not active.");
  }
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
  if (!hasHermesGatewayScope(client.scopes, scope)) {
    throw httpError(403, "missing_scope", scope);
  }
  await assertActiveHermesGatewayEntitlement(index.uid);
  const now = nowISO();
  await clientRef.set({ lastSeenAt: now, updatedAt: now }, { merge: true });
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
  const deviceSecretHash = providedSecretHash || hashHermesGatewayDeviceSecret(generatedSecret!);
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
  const now = nowISO();
  await db.doc(`users/${grant.uid}/hermes_gateway_clients/${grant.client.id}`).set(
    stripUndefinedObject({
      runtimeModelId,
      runtimeProviderId,
      runtimeModelOptions,
      runtimeUpdatedAt: now,
      lastSeenAt: now,
      updatedAt: now,
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    }),
    { merge: true },
  );
  sendJSON(res, 200, {
    success: true,
    runtimeModelId,
    runtimeProviderId,
    modelOptionCount: runtimeModelOptions.length,
    runtimeUpdatedAt: now,
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

export const burnBarHermesGateway = onRequest(
  {
    region: "us-central1",
    cors: true,
    maxInstances: 100,
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
      if (path === "/attachments/init") return await handleAttachmentInit(req, res);
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
    region: "us-central1",
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
        createdAt: now,
        updatedAt: now,
        schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
      };

      await ensureDefaultDestination(uid, now);
      await Promise.all([
        db
          .doc(`users/${uid}/hermes_gateway_clients/${clientId}`)
          .set(stripUndefinedObject(clientDoc), { merge: false }),
        db.doc(`hermes_gateway_token_index/${tokenHash}`).set({ uid, clientId, status: "active", createdAt: now }),
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
    region: "us-central1",
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
    region: "us-central1",
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

export const enqueueHermesGatewayEvent = onCall(
  {
    region: "us-central1",
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
      if (targetClientId) {
        await assertActiveHermesGatewayClient(uid, targetClientId);
      }
      const destinationId = sanitizeHermesGatewayDestinationId(request.data.destinationId);
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
            attachmentIds: sanitizedAttachmentIds(request.data.attachmentIds),
            createdAt: now,
            schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
          }),
        );
      });
      return stripUndefinedObject({ id: eventId, sequence, targetClientId });
    },
  ),
);
