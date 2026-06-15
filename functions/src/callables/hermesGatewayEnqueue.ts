/**
 * @fileoverview The Hermes Gateway owner-authenticated event enqueue callable
 * (the phone seals an event/model-switch and pushes it to the paired agent).
 * Split out of hermesGatewayCallables.ts to keep every gateway module under the
 * file-length cap; re-exported from ./hermesGateway.js byte-identically.
 */

import { onCall, HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { stripUndefinedObject } from "../guards.js";
import { wrapCallableHandler } from "../logging.js";
import {
  clientAdvertisesModel,
  gatewayPlaintextWriteAllowed,
  HERMES_GATEWAY_SCHEMA_VERSION,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayModelId,
  sanitizedAttachmentIds,
} from "../hermesGateway.js";
import type { HermesGatewayClientDoc } from "../types/generated/hermes-gateway.js";
import { checkHermesGatewayBearerRateLimit } from "./publicRateLimit.js";
import { boundedTrimmedString, nowISO, requiredIdentifier } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  assertActiveHermesGatewayClient,
  assertActiveHermesGatewayEntitlement,
  requireSafeGatewayEventId,
  requireUploadedGatewayAttachments,
  resolveGatewayWriteBody,
  type ResolvedGatewayWriteBody,
} from "./hermesGatewayResolve.js";

interface EnqueueEventInput {
  destinationId?: unknown;
  threadId?: unknown;
  senderId?: unknown;
  senderDisplayName?: unknown;
  text?: unknown;
  relayEnvelope?: unknown;
  ratchetEnvelope?: unknown;
  signalEnvelope?: unknown;
  eventId?: unknown;
  eventKind?: unknown;
  modelId?: unknown;
  targetClientId?: unknown;
  attachmentIds?: unknown;
}

/**
 * Resolve + validate the enqueue target client (a targetClientId is mandatory
 * for sealed events) and enforce the per-(uid, client) dispatch rate limit. A
 * pure relocation of the target-resolution prefix of enqueueHermesGatewayEvent.
 */
async function resolveEnqueueTargetClient(
  uid: string,
  targetClientId: string | undefined,
): Promise<HermesGatewayClientDoc> {
  const targetClient = targetClientId ? await assertActiveHermesGatewayClient(uid, targetClientId) : undefined;
  if (!targetClient) {
    throw new HttpsError("invalid-argument", "targetClientId is required for sealed Hermes Gateway events.");
  }
  // L3: throttle owner-authenticated event dispatch per (uid, clientId). Every
  // enqueued event/model-switch can wake the paired agent and drive billable
  // LLM work, so cap the rate even though the surface is uid-scoped.
  await checkHermesGatewayBearerRateLimit(uid, targetClient.id, "hermes_gateway_event_enqueue");
  return targetClient;
}

/**
 * Resolve the sealed (or legacy) event body for a model_switch event. Sealed
 * relay-capable switches require an envelope and persist no cleartext modelId;
 * legacy switches keep the plaintext-catalog guard. A pure relocation.
 */
function resolveModelSwitchBody(
  data: EnqueueEventInput,
  targetClient: HermesGatewayClientDoc,
  targetIsRelayCapable: boolean,
  requestedModelId: string | undefined,
): ResolvedGatewayWriteBody {
  if (targetIsRelayCapable) {
    // Sealed model_switch: require the envelope (the command body is sealed
    // to the agent's relay/ratchet key). Do not require or persist a
    // cleartext modelId for relay-capable clients; the agent opens the
    // command and validates it against its own catalog after decrypting.
    const sealedBody = resolveGatewayWriteBody(
      data.relayEnvelope,
      data.ratchetEnvelope,
      data.signalEnvelope,
      undefined,
      targetClient,
      "events",
    );
    if (!sealedBody.relayEnvelope && !sealedBody.ratchetEnvelope && !sealedBody.signalEnvelope) {
      throw new HttpsError(
        "invalid-argument",
        "ciphertext_required: provide a relayEnvelope, ratchetEnvelope, or signalEnvelope for sealed model_switch events.",
      );
    }
    return sealedBody;
  }
  // Legacy (grace-window) model_switch: no sealed body. We keep the old
  // plaintext-catalog guard ONLY for these legacy clients so a typo'd model
  // surfaces an error pre-E2E; relay-capable clients defer to the agent.
  if (requestedModelId) {
    const hasCatalog = (targetClient.runtimeModelOptions?.length ?? 0) > 0;
    if (hasCatalog && !clientAdvertisesModel(targetClient, requestedModelId)) {
      throw new HttpsError(
        "invalid-argument",
        `model_not_available: ${requestedModelId} is not in the selected client's advertised models.`,
      );
    }
  }
  return {};
}

/** Resolve the sealed (or legacy) event body for a non-model_switch message event. */
function resolveMessageEventBody(
  data: EnqueueEventInput,
  targetClient: HermesGatewayClientDoc,
  targetClientId: string | undefined,
): ResolvedGatewayWriteBody {
  const relayClient = targetClient ?? { id: targetClientId ?? "broadcast", relayCapable: undefined };
  const sealedBody = resolveGatewayWriteBody(
    data.relayEnvelope,
    data.ratchetEnvelope,
    data.signalEnvelope,
    data.text,
    relayClient,
    "events",
  );
  if (
    !sealedBody.relayEnvelope &&
    !sealedBody.ratchetEnvelope &&
    !sealedBody.signalEnvelope &&
    !sealedBody.legacyText
  ) {
    throw new HttpsError(
      "invalid-argument",
      "text is required: provide a relayEnvelope, ratchetEnvelope, or signalEnvelope (sealed event body).",
    );
  }
  return sealedBody;
}

/** Assemble the event doc persisted by enqueueHermesGatewayEvent. A pure builder. */
function buildEnqueueEventDoc(input: {
  data: EnqueueEventInput;
  eventId: string;
  sequence: number;
  eventKind: "model_switch" | "message";
  destinationId: string | undefined;
  targetClientId: string | undefined;
  targetIsRelayCapable: boolean;
  requestedModelId: string | undefined;
  attachmentIds: string[];
  sealedBody: ResolvedGatewayWriteBody;
  now: string;
}): Record<string, unknown> {
  const { sealedBody, eventKind, data } = input;
  const sealedOrModelSwitch =
    !!sealedBody.relayEnvelope ||
    !!sealedBody.ratchetEnvelope ||
    !!sealedBody.signalEnvelope ||
    eventKind === "model_switch";
  return stripUndefinedObject({
    id: input.eventId,
    sequence: input.sequence,
    kind: eventKind,
    destinationId: input.destinationId,
    targetClientId: input.targetClientId,
    // senderId is a non-PII routing id. The private fields
    // (text/senderDisplayName/threadId/modelId) live ONLY inside the
    // envelope for relay-capable clients. Model switches do not carry a
    // plaintext command body or thread id.
    threadId: sealedOrModelSwitch ? undefined : boundedTrimmedString(data.threadId, "threadId", 160, false),
    senderId: boundedTrimmedString(data.senderId, "senderId", 160, false) ?? "burnbar-user",
    senderDisplayName: sealedOrModelSwitch
      ? undefined
      : boundedTrimmedString(data.senderDisplayName, "senderDisplayName", 80, false),
    text: sealedBody.legacyText,
    relayEnvelope: sealedBody.relayEnvelope,
    ratchetEnvelope: sealedBody.ratchetEnvelope,
    signalEnvelope: sealedBody.signalEnvelope,
    modelId: input.targetIsRelayCapable ? undefined : input.requestedModelId,
    attachmentIds: input.attachmentIds,
    createdAt: input.now,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
}

export const enqueueHermesGatewayEvent = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("enqueueHermesGatewayEvent", async (request: CallableRequest<EnqueueEventInput>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before sending Hermes Gateway events.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHermesGatewayEntitlement(uid);
    const eventKind = request.data.eventKind === "model_switch" ? "model_switch" : "message";
    const requestedModelId = sanitizeHermesGatewayModelId(request.data.modelId);
    const targetClientId = request.data.targetClientId
      ? requiredIdentifier(request.data.targetClientId, "targetClientId")
      : undefined;
    const targetClient = await resolveEnqueueTargetClient(uid, targetClientId);
    const targetIsRelayCapable = targetClient.relayCapable === true;
    // A non-relay-capable (legacy pre-E2E) target is only tolerable while the
    // plaintext grace window is open. New deployments have it closed, so an
    // unsealed target is rejected and the client must re-pair to seal.
    if (!targetIsRelayCapable && !gatewayPlaintextWriteAllowed(targetClient.relayCapable)) {
      throw new HttpsError(
        "failed-precondition",
        "unsealed_target_unsupported: update and re-pair the Hermes Gateway client so messages stay end-to-end encrypted.",
      );
    }
    if (eventKind === "model_switch" && !targetIsRelayCapable && !requestedModelId) {
      throw new HttpsError("invalid-argument", "modelId is required for legacy Hermes Gateway model switches.");
    }
    // The phone seals the event body before this call; the server forwards the
    // opaque envelope and never reads it. A model_switch on a relay-capable
    // target ALSO travels sealed: the model command ("/model …") is private, so
    // the server REQUIRES the relayEnvelope and forwards it blindly. The agent
    // opens it and validates the requested model against its own catalog AFTER
    // decrypting — the server keeps no plaintext clientAdvertisesModel gate that
    // would force it to read the (sealed) command or leak the catalog decision.
    const sealedBody =
      eventKind === "model_switch"
        ? resolveModelSwitchBody(request.data, targetClient, targetIsRelayCapable, requestedModelId)
        : resolveMessageEventBody(request.data, targetClient, targetClientId);
    const destinationId = sanitizeHermesGatewayDestinationId(request.data.destinationId);
    const attachmentIds = sanitizedAttachmentIds(request.data.attachmentIds);
    await requireUploadedGatewayAttachments({ uid, clientId: targetClientId, destinationId, attachmentIds });
    const eventId =
      sealedBody.relayEnvelope != null || sealedBody.ratchetEnvelope != null || sealedBody.signalEnvelope != null
        ? requireSafeGatewayEventId(request.data.eventId)
        : `evt_${randomBytes(12).toString("hex")}`;
    const now = nowISO();
    const eventRef = db.doc(`users/${uid}/hermes_gateway_events/${eventId}`);
    let sequence = 0;
    await db.runTransaction(async (tx) => {
      const stateRef = db.doc(`users/${uid}/hermes_gateway_state/cursors`);
      const stateSnap = await tx.get(stateRef);
      // (Remediation R9) Mirror the message-path create-if-absent 409 guard: a
      // replayed client-supplied eventId must not clobber a stored event or
      // re-bump the sequence counter. Reads precede writes in a transaction.
      const existingEvent = await tx.get(eventRef);
      if (existingEvent.exists) {
        throw new HttpsError("already-exists", "Hermes Gateway event already enqueued.");
      }
      const current = Number(stateSnap.get("eventSequence") ?? 0);
      sequence = Number.isFinite(current) ? current + 1 : 1;
      tx.set(
        stateRef,
        { eventSequence: sequence, updatedAt: now, schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION },
        { merge: true },
      );
      tx.set(
        eventRef,
        buildEnqueueEventDoc({
          data: request.data,
          eventId,
          sequence,
          eventKind,
          destinationId,
          targetClientId,
          targetIsRelayCapable,
          requestedModelId,
          attachmentIds,
          sealedBody,
          now,
        }),
      );
      // Optimistically mark the switch in flight so /state reports "switching…"
      // until the runtime republishes the applied model (or the TTL lapses).
      if (eventKind === "model_switch" && requestedModelId && targetClientId && !targetIsRelayCapable) {
        tx.set(
          db.doc(`users/${uid}/hermes_gateway_clients/${targetClientId}`),
          { pendingModelId: requestedModelId, pendingModelRequestedAt: now, updatedAt: now },
          { merge: true },
        );
      }
    });
    return stripUndefinedObject({
      id: eventId,
      sequence,
      targetClientId,
      pendingModelId: eventKind === "model_switch" && !targetIsRelayCapable ? requestedModelId : undefined,
    });
  }),
);
