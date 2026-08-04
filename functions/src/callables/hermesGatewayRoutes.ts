/**
 * @fileoverview Core Hermes Gateway HTTP route handlers (destinations, events,
 * messages, typing, runtime status, state), the request dispatcher, the wrapped
 * onRequest entrypoint, and the attachment download-url onCall wrapper. Device,
 * attachment, and approval routes live in sibling modules; this module wires
 * them into the dispatcher. Split out of the original monolith to keep every
 * gateway module under the file-length cap.
 */

import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { stripUndefinedObject } from "../guards.js";
import {
  clampHermesGatewayLimit,
  effectiveOversightMode,
  gatewaySignalEnvelopeV4Disabled,
  gatewaySignalRequiredMode,
  HERMES_GATEWAY_PROTOCOL_VERSION,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isHermesGatewayClientDoc,
  isHermesGatewayClientOnline,
  makeHermesGatewaySSE,
  negotiateGatewayRelayEnvelopeCapabilities,
  parseHermesGatewayCursor,
  pendingModelSwitchInFlight,
  publicClientView,
  sanitizeGatewayRelayEnvelopeCapabilities,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayModelId,
  sanitizeHermesGatewayModelOptions,
  sanitizedAttachmentIds,
  serializeHermesGatewayEvent,
  serializeHermesGatewayTypingDoc,
  type HermesGatewayRelayEnvelopeCapabilities,
} from "../hermesGateway.js";
import { logError, logInfo, wrapCallableHandler } from "../logging.js";
import type {
  HermesGatewayClientDoc,
} from "../types/generated/hermes-gateway.js";
import { parseGatewaySignalPrekeyBundle } from "../hermesGatewaySignalPrekeys.js";
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString, nowISO, safeIdentifier } from "./shared.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";
import {
  assertJsonWriteContentType,
  gatewayPath,
  header,
  type HttpRequest,
  type HttpResponse,
  httpError,
  isGatewayHttpError,
  requestBody,
  requestCarriesActiveFusionPlugin,
  sendJSON,
  toHermesHttpRequest,
  toHermesHttpResponse,
} from "./hermesGatewayHttp.js";
import {
  parseRatchetPrekeyBundle,
  parseRelayPublicKey,
  type ParsedRatchetPrekeyBundle,
  type ParsedRelayPublicKey,
} from "./hermesGatewayCrypto.js";
import {
  ensureDefaultDestination,
  requireUploadedGatewayAttachments,
  resolveGatewayGrant,
  resolveGatewayWriteBody,
} from "./hermesGatewayResolve.js";
import { checkHermesGatewayBearerRateLimit, checkPublicHttpEndpointRateLimit, clientIpFromHttpRequest, isPublicRateLimitExceeded } from "./publicRateLimit.js";
import { handleDevicePoll, handleDeviceStart } from "./hermesGatewayDeviceRoutes.js";
import {
  handleArmApproval,
  handleAttachmentFinalize,
  handleAttachmentInit,
  handleHermesGatewayAttachmentDownloadUrl,
  handleListApprovals,
} from "./hermesGatewayAttachmentRoutes.js";
import { buildRuntimePersistDoc, resolveRuntimeSignalPrekeyWrite } from "./hermesGatewayRuntimeState.js";

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
  // T-GW-05: the targeting filter is enforced as a Firestore query constraint
  // (`targetClientId in [null, clientId]`) rather than only in app code, so a bug
  // in app-layer filtering can never let a client over-read another client's
  // targeted events. `null` covers legacy broadcast/untargeted documents (the
  // field is only ever a string or absent on new writes); the `in` membership
  // also implicitly excludes any document whose `targetClientId` is some OTHER
  // client id. The app-layer filter below is retained as defense-in-depth.
  const targetIn: Array<string | null> = [null, grant.client.id];
  const baseCollection = db.collection(`users/${grant.uid}/hermes_gateway_events`);
  let query = baseCollection
    .where("targetClientId", "in", targetIn)
    .where("sequence", ">", cursor)
    .orderBy("sequence", "asc")
    .limit(limit);
  if (destinationId) {
    query = baseCollection
      .where("destinationId", "==", destinationId)
      .where("targetClientId", "in", targetIn)
      .where("sequence", ">", cursor)
      .orderBy("sequence", "asc")
      .limit(limit);
  }
  const snap = await query.get();
  const scannedEvents = snap.docs.flatMap((doc) => {
    const event = serializeHermesGatewayEvent(doc.data());
    return event ? [event] : [];
  });
  // Defense-in-depth: re-apply the targeting filter in app code even though the
  // query already constrains it.
  const events = scannedEvents.filter((event) => !event.targetClientId || event.targetClientId === grant.client.id);
  // Advance the cursor across the FULL window (including other clients' events)
  // so a run of events targeted at a different client never wedges this client's
  // pagination on an empty-but-unadvancing window. A projection (`select`) keeps
  // this scan cheap — it reads only the `sequence` field, not event bodies.
  const cursorAdvanceQuery = (
    destinationId ? baseCollection.where("destinationId", "==", destinationId) : baseCollection
  )
    .where("sequence", ">", cursor)
    .orderBy("sequence", "asc")
    .limit(limit)
    .select("sequence");
  const cursorSnap = await cursorAdvanceQuery.get();
  const nextCursor = cursorSnap.docs.reduce((max, doc) => {
    const seq = doc.get("sequence");
    return typeof seq === "number" && Number.isFinite(seq) ? Math.max(max, seq) : max;
  }, cursor);
  if (header(req, "accept")?.includes("text/event-stream") || req.query.stream === "true") {
    res.set("Content-Type", "text/event-stream; charset=utf-8");
    res.set("Cache-Control", "no-store");
    res.status(200).send(makeHermesGatewaySSE(events, nextCursor));
    return;
  }
  sendJSON(res, 200, { events, nextCursor });
}

/**
 * Elder Wand (plugin id "fusion"): a forwarded chat-completions request that
 * opts into the multi-model analysis router must additionally hold Cloud Pro
 * ("Pro Max"). Gate BEFORE any persistence/forward so a non-Pro caller spends
 * nothing downstream. Re-raise the permission-denied as the structured 403 the
 * clients key off (so the body carries requiredTier/feature).
 */
async function assertFusionPluginEntitlement(uid: string, body: Record<string, unknown>): Promise<void> {
  if (!requestCarriesActiveFusionPlugin(body)) return;
  try {
    await assertActiveBurnBarCloudProEntitlement(uid);
  } catch {
    throw httpError(403, "entitlement_required", "BurnBar Cloud Pro is required for The Elder Wand.", {
      requiredTier: "pro",
      feature: "elderWand",
    });
  }
}

async function handleMessageSend(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  assertJsonWriteContentType(req);
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  await checkHermesGatewayBearerRateLimit(grant.uid, grant.client.id, "hermes_gateway_message_send");
  const body = requestBody(req);
  await assertFusionPluginEntitlement(grant.uid, body);
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const attachmentIds = sanitizedAttachmentIds(body.attachmentIds);
  if (grant.client.relayCapable !== true) {
    throw httpError(400, "unsealed_client_unsupported");
  }
  // The agent seals its reply body (the message text) to the phone's relay key
  // BEFORE this call; the server only forwards the opaque envelope. Plaintext
  // `text` is rejected on every new write.
  const sealed = resolveGatewayWriteBody(
    body.relayEnvelope,
    body.ratchetEnvelope,
    body.signalEnvelope,
    body.text,
    grant.client,
    "messages",
  );
  const attachmentsOnly = attachmentIds.length > 0;
  if (
    !sealed.relayEnvelope &&
    !sealed.ratchetEnvelope &&
    !sealed.signalEnvelope &&
    !sealed.legacyText &&
    !attachmentsOnly
  ) {
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
    // threadId/replyToEventId are private conversation-routing metadata. For new
    // sealed messages they must live inside relayEnvelope, not as top-level
    // Firestore fields.
    threadId: sealed.legacyText ? boundedTrimmedString(body.threadId, "threadId", 160, false) : undefined,
    replyToEventId: sealed.legacyText
      ? boundedTrimmedString(body.replyToEventId, "replyToEventId", 160, false)
      : undefined,
    // Sealed body for schema 2+; plaintext text is never accepted for new writes.
    relayEnvelope: sealed.relayEnvelope,
    ratchetEnvelope: sealed.ratchetEnvelope,
    signalEnvelope: sealed.signalEnvelope,
    text: sealed.legacyText,
    attachmentIds,
    createdAt: now,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
  // Create-if-absent, same hardening as attachments/init: a blind
  // `set(merge:false)` would let a re-send of the same messageId clobber an
  // already-stored sealed message. We keep `safeIdentifier` (not the stricter
  // adoptedGatewayDocId) for the id here ON PURPOSE: the agent derives messageId
  // as token_hex(16) and BINDS it into the sealed body's AES-GCM AAD
  // (gatewayMessage/gatewayMessageKey). The phone re-derives that AAD from the
  // stored `id` to open the body — so the server must echo the client's id
  // byte-for-byte. token_hex(16) is already lowercase-hex, so safeIdentifier is a
  // pass-through for the real client; swapping the resolver risks perturbing an
  // AAD-bound value, and unlike attachments there is no stricter finalize
  // validator to stay symmetric with. The transaction below still closes the
  // clobber half of the finding.
  const messageRef = db.doc(`users/${grant.uid}/hermes_gateway_messages/${id}`);
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(messageRef);
    if (existing.exists) {
      throw httpError(409, "message_already_sent");
    }
    tx.set(messageRef, doc);
  });
  logInfo({ event: "hermes_gateway.message_sent", client_id: grant.client.id, message_id: id });
  sendJSON(res, 200, { message: doc });
}

async function handleTyping(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  assertJsonWriteContentType(req);
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  if (grant.client.relayCapable !== true) {
    throw httpError(400, "unsealed_client_unsupported");
  }
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const now = nowISO();
  const doc = serializeHermesGatewayTypingDoc({
    clientId: grant.client.id,
    destinationId,
    createdAt: now,
    expiresAt: new Date(Date.now() + 15_000).toISOString(),
  });
  await db.doc(`users/${grant.uid}/hermes_gateway_typing/${grant.client.id}`).set(doc, { merge: true });
  sendJSON(res, 200, { success: true });
}

interface RuntimeRelayKeyResolution {
  agentRelayKeyWrite: ParsedRelayPublicKey | undefined;
  agentCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
}

/**
 * Pin-only relay-key write decision for /runtime. We write the relay-key fields
 * ONLY on first pairing (no key pinned yet). A re-publish of the SAME pinned key
 * is a harmless no-op; a DIFFERENT key is dropped and logged as a substitution
 * attempt. A pure relocation of handleRuntimeStatus's relay branch.
 */
function resolveRuntimeRelayKeyWrite(
  agentRelay: ParsedRelayPublicKey | undefined,
  pinnedAgentKey: string | undefined,
  body: Record<string, unknown>,
  client: HermesGatewayClientDoc,
  uid: string,
): RuntimeRelayKeyResolution {
  if (!agentRelay) return { agentRelayKeyWrite: undefined, agentCapabilities: undefined };
  if (!pinnedAgentKey) {
    return { agentRelayKeyWrite: agentRelay, agentCapabilities: sanitizeGatewayRelayEnvelopeCapabilities(body) };
  }
  if (agentRelay.publicKey === pinnedAgentKey) {
    return { agentRelayKeyWrite: undefined, agentCapabilities: sanitizeGatewayRelayEnvelopeCapabilities(body) };
  }
  logInfo({
    event: "hermes_gateway.relay_key_change_rejected",
    reason: "agent_relay_public_key_immutable",
    client_id: client.id,
    user_id_hash: uid.slice(0, 8),
  });
  return { agentRelayKeyWrite: undefined, agentCapabilities: undefined };
}

/**
 * Pin-only ratchet-identity write decision for /runtime. The ratchet bundle is
 * written when no identity is pinned or the incoming identity matches the pin;
 * a mismatched identity is dropped and logged. A pure relocation of
 * handleRuntimeStatus's ratchet branch.
 */
function resolveRuntimeRatchetWrite(
  requestedAgentRatchet: ParsedRatchetPrekeyBundle | undefined,
  pinnedAgentRatchetIdentity: string | undefined,
  client: HermesGatewayClientDoc,
  uid: string,
): ParsedRatchetPrekeyBundle | undefined {
  if (!requestedAgentRatchet) return undefined;
  if (!pinnedAgentRatchetIdentity || requestedAgentRatchet.identityPublicKey === pinnedAgentRatchetIdentity) {
    return requestedAgentRatchet;
  }
  logInfo({
    event: "hermes_gateway.ratchet_identity_change_rejected",
    reason: "agent_ratchet_identity_immutable",
    client_id: client.id,
    user_id_hash: uid.slice(0, 8),
  });
  return undefined;
}

function negotiatedRuntimeCapabilities(
  agentCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined,
  client: HermesGatewayClientDoc,
): HermesGatewayRelayEnvelopeCapabilities | undefined {
  const phoneKeyOnRecord = typeof client.phoneRelayPublicKey === "string";
  const phoneCapabilities = phoneKeyOnRecord
    ? sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: client.phoneSupportsRelayEnvelopeVersions,
        preferredRelayEnvelopeVersion: client.phonePreferredRelayEnvelopeVersion,
        supportsHpkeV3: client.phoneSupportsHpkeV3,
        supportsSignalEnvelope: client.phoneSupportsSignalEnvelope,
        clientPlatform: client.phonePlatform,
        clientAppBuild: client.phoneAppBuild,
      })
    : undefined;
  return agentCapabilities && phoneCapabilities
    ? negotiateGatewayRelayEnvelopeCapabilities(agentCapabilities, phoneCapabilities)
    : undefined;
}

async function handleRuntimeStatus(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  assertJsonWriteContentType(req);
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const runtimeModelId = sanitizeHermesGatewayModelId(body.currentModelId);
  const runtimeProviderId = boundedTrimmedString(body.currentProviderId, "currentProviderId", 80, false);
  const runtimeModelOptions = sanitizeHermesGatewayModelOptions(body.modelOptions);
  const agentVersion = boundedTrimmedString(body.agentVersion, "agentVersion", 120, false);
  // The agent MAY publish its relay public key here, but only to ESTABLISH it on
  // first pairing (trust-on-first-use). Once a key is pinned on the client doc it
  // is IMMUTABLE: a /runtime request can never overwrite it. A bearer token alone
  // must not be able to swap the pinned relay key — that would let the server (or
  // any token holder) substitute its own key and MITM the sealed channel. Rotation
  // is explicit re-pair only: no relay-supplied update, signed or unsigned, can
  // change a pin in place.
  const agentRelay = parseRelayPublicKey(
    body,
    {
      publicKeyField: "agentRelayPublicKey",
      keyVersionField: "agentRelayKeyVersion",
      encryptionField: "agentRelayEncryption",
    },
    (message) => {
      throw new HttpsError("invalid-argument", message);
    },
  );
  const pinnedAgentKey =
    typeof grant.client.agentRelayPublicKey === "string" ? grant.client.agentRelayPublicKey : undefined;
  const { agentRelayKeyWrite, agentCapabilities } = resolveRuntimeRelayKeyWrite(
    agentRelay,
    pinnedAgentKey,
    body,
    grant.client,
    grant.uid,
  );
  const requestedAgentRatchet = parseRatchetPrekeyBundle(body, "agent", (message) => {
    throw new HttpsError("invalid-argument", message);
  });
  const pinnedAgentRatchetIdentity =
    typeof grant.client.agentRatchetIdentityPublicKey === "string"
      ? grant.client.agentRatchetIdentityPublicKey
      : undefined;
  const agentRatchetWrite = resolveRuntimeRatchetWrite(
    requestedAgentRatchet,
    pinnedAgentRatchetIdentity,
    grant.client,
    grant.uid,
  );
  const requestedAgentSignalPrekeyBundle = parseGatewaySignalPrekeyBundle(body, "agent", (message) => {
    throw new HttpsError("invalid-argument", message);
  });
  const agentSignalPrekeyBundleWrite = resolveRuntimeSignalPrekeyWrite(
    requestedAgentSignalPrekeyBundle,
    grant.client.agentSignalPrekeyBundle,
    grant.client,
    grant.uid,
  );
  if (
    agentCapabilities?.supportsSignalEnvelope === true &&
    !requestedAgentSignalPrekeyBundle &&
    !grant.client.agentSignalPrekeyBundle
  ) {
    throw new HttpsError(
      "invalid-argument",
      "missing_agent_signal_prekey_bundle: Signal-capable runtimes require a PQXDH bundle.",
    );
  }
  const now = nowISO();
  // Reconcile the optimistic model-switch marker: once the runtime reports it is
  // actually running the requested model, clear pendingModelId so /state stops
  // reporting "switching…". A no-op when there is no pending switch.
  const pending = typeof grant.client.pendingModelId === "string" ? grant.client.pendingModelId.trim() : "";
  const settled = !!pending && !!runtimeModelId && pending.toLowerCase() === runtimeModelId.trim().toLowerCase();
  // relayCapable becomes true once BOTH endpoints have a key on record. The agent
  // key counts whether it was just pinned now or pinned earlier.
  const phoneKeyOnRecord = typeof grant.client.phoneRelayPublicKey === "string";
  const agentKeyOnRecord = pinnedAgentKey !== undefined || agentRelayKeyWrite != null;
  const relayCapable = agentKeyOnRecord && phoneKeyOnRecord ? true : undefined;
  const negotiatedCapabilities = negotiatedRuntimeCapabilities(agentCapabilities, grant.client);
  const agentRatchetOnRecord = pinnedAgentRatchetIdentity !== undefined || agentRatchetWrite != null;
  const phoneRatchetOnRecord = grant.client.phoneSupportsRatchetV1 === true;
  const supportsRatchetV1 = agentRatchetOnRecord && phoneRatchetOnRecord ? true : undefined;
  if (
    gatewaySignalRequiredMode() &&
    (negotiatedCapabilities?.supportsSignalEnvelope !== true ||
      !(grant.client.agentSignalPrekeyBundle || agentSignalPrekeyBundleWrite) ||
      !grant.client.phoneSignalPrekeyBundle)
  ) {
    throw new HttpsError(
      "failed-precondition",
      "signal_runtime_required: the paired phone and agent must both advertise Signal v4 with pinned PQXDH bundles.",
    );
  }
  await db.doc(`users/${grant.uid}/hermes_gateway_clients/${grant.client.id}`).set(
    buildRuntimePersistDoc({
      runtimeModelId,
      runtimeProviderId,
      runtimeModelOptions,
      agentVersion,
      agentRelayKeyWrite,
      agentCapabilities,
      negotiatedCapabilities,
      agentRatchetWrite,
      agentSignalPrekeyBundleWrite,
      supportsRatchetV1,
      relayCapable,
      settled,
      now,
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
    phoneSignalPrekeyBundle: grant.client.phoneSignalPrekeyBundle,
    supportsSignalEnvelope: negotiatedCapabilities?.supportsSignalEnvelope === true,
    signalRequired: gatewaySignalRequiredMode(),
    signalEnvelopeV4Disabled: gatewaySignalEnvelopeV4Disabled(),
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

/** Map a thrown gateway error to the dispatch JSON response. */
function writeGatewayDispatchError(res: HttpResponse, err: unknown): void {
  if (isGatewayHttpError(err)) {
    sendJSON(res, err.status, stripUndefinedObject({ ...err.extra, error: err.error, detail: err.detail }));
    return;
  }
  if (err instanceof HttpsError) {
    const status =
      err.code === "invalid-argument"
        ? 400
        : err.code === "permission-denied"
          ? 403
          : err.code === "resource-exhausted"
            ? 429
            : err.code === "failed-precondition"
              ? 412
              : 500;
    sendJSON(res, status, { error: err.code, detail: err.message });
    return;
  }
  logError({ event: "hermes_gateway.http_failed", error: String(err) });
  sendJSON(res, 500, { error: "internal" });
}

/** Route a resolved gateway path to its handler. Returns true once handled. */
async function routeGatewayRequest(path: string, req: HttpRequest, res: HttpResponse): Promise<boolean> {
  if (path === "/device/start") return (await handleDeviceStart(req, res), true);
  if (path === "/device/poll") return (await handleDevicePoll(req, res), true);
  if (path === "/destinations") return (await handleDestinations(req, res), true);
  if (path === "/events") return (await handleEvents(req, res), true);
  if (path === "/messages") return (await handleMessageSend(req, res), true);
  if (path === "/typing") return (await handleTyping(req, res), true);
  if (path === "/runtime") return (await handleRuntimeStatus(req, res), true);
  if (path === "/state") return (await handleGatewayState(req, res), true);
  if (path === "/approvals") {
    if (req.method === "GET") await handleListApprovals(req, res);
    else await handleArmApproval(req, res);
    return true;
  }
  if (path === "/attachments/init") return (await handleAttachmentInit(req, res), true);
  if (path === "/attachments/finalize") return (await handleAttachmentFinalize(req, res), true);
  return false;
}

/**
 * Inner request dispatcher for the Hermes Gateway HTTP API. Pure
 * `(req, res) => Promise<void>` with no onRequest/CORS plumbing, so it is the
 * exact path production runs AND the seam tests drive directly (the wrapped
 * `burnBarHermesGateway` only adds CORS/trace middleware around this).
 */
/**
 * Known gateway paths and their accepted methods. Used to short-circuit
 * wrong-method / unknown-path requests with 405 / 404 BEFORE the endpoint-level
 * rate limiter touches Firestore, preserving the pre-fix invariant that method
 * guards run before any DB access.
 */
const GATEWAY_ROUTE_METHODS: Record<string, Set<string>> = {
  "/device/start": new Set(["POST"]),
  "/device/poll": new Set(["POST"]),
  "/destinations": new Set(["GET"]),
  "/events": new Set(["GET"]),
  "/messages": new Set(["POST"]),
  "/typing": new Set(["POST"]),
  "/runtime": new Set(["POST"]),
  "/state": new Set(["GET"]),
  "/approvals": new Set(["GET", "POST"]),
  "/attachments/init": new Set(["POST"]),
  "/attachments/finalize": new Set(["POST"]),
};

export async function dispatchHermesGatewayRequest(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method === "OPTIONS") {
    res.status(204).send("");
    return;
  }
  const path = gatewayPath(req) ?? "";
  // Cheap path/method validation before any Firestore access — preserves the
  // invariant that wrong-method requests return 405 and unknown paths return 404
  // without hitting the rate limiter's Firestore transaction.
  const allowedMethods = GATEWAY_ROUTE_METHODS[path];
  if (!allowedMethods) {
    sendJSON(res, 404, { error: "not_found" });
    return;
  }
  if (!req.method || !allowedMethods.has(req.method)) {
    sendJSON(res, 405, { error: "method_not_allowed" });
    return;
  }
  try {
    // Endpoint-level per-IP rate limit (defense-in-depth before bearer token
    // resolution). The `burnBarHermesGateway` limit (120/min per IP) caps abuse
    // of the public HTTP surface for ALL routes, including those that only have
    // bearer auth (no per-uid limiter). Only fires for valid (path, method)
    // pairs so wrong-method requests never touch Firestore.
    try {
      await checkPublicHttpEndpointRateLimit("burnBarHermesGateway", clientIpFromHttpRequest(req));
    } catch (err) {
      if (isPublicRateLimitExceeded(err)) {
        sendJSON(res, 429, { error: "too_many_requests" });
        return;
      }
      throw err;
    }
    const handled = await routeGatewayRequest(path, req, res);
    if (!handled) sendJSON(res, 404, { error: "not_found" });
  } catch (err) {
    writeGatewayDispatchError(res, err);
  }
}

export const burnBarHermesGateway = onRequest(
  {
    region: FUNCTIONS_REGION,
    cors: true,
    maxInstances: 100,
    ...HOT_PATH_OPTIONS,
  },
  async (req, res): Promise<void> => {
    await dispatchHermesGatewayRequest(toHermesHttpRequest(req), toHermesHttpResponse(res));
  },
);

export const getHermesGatewayAttachmentDownloadUrl = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("getHermesGatewayAttachmentDownloadUrl", handleHermesGatewayAttachmentDownloadUrl),
);
