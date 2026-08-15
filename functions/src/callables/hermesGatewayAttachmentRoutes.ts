/**
 * @fileoverview Hermes Gateway attachment HTTP routes (/attachments/init,
 * /attachments/finalize), the attachment download-url callable handler, and the
 * oversight-approval HTTP routes (/approvals arm + list). Split out of
 * hermesGatewayRoutes.ts to keep every gateway module under the file-length cap;
 * the dispatcher and the download onCall wrapper import the exported handlers.
 */

import { getStorage } from "firebase-admin/storage";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { stripUndefinedObject } from "../guards.js";
import {
  gatewayApprovalExpiryISO,
  gatewaySignalAttachmentBindingMatches,
  gatewayPlaintextWriteAllowed,
  HERMES_GATEWAY_MAX_ATTACHMENT_BYTES,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isHermesGatewayApprovalDoc,
  isHermesGatewayAttachmentManifestDoc,
  publicApprovalView,
  requireProductionGatewayRatchetEnvelope,
  requireProductionGatewayRelayEnvelope,
  requireProductionGatewaySignalEnvelope,
  sanitizeHermesGatewayApprovalTTL,
  sanitizeHermesGatewayDestinationId,
  sha256Hex,
} from "../hermesGateway.js";
import { logInfo } from "../logging.js";
import type {
  HermesGatewayApprovalDoc,
  HermesGatewayAttachmentManifestDoc,
} from "../types/generated/hermes-gateway.js";
import { boundedTrimmedString, nowISO } from "./shared.js";
import {
  assertJsonWriteContentType,
  assertSafeAttachmentContentType,
  adoptedGatewayDocId,
  type HttpRequest,
  type HttpResponse,
  httpError,
  requestBody,
  requestedAttachmentHash,
  requiredHttpIdentifier,
  sendJSON,
  setNoStore,
} from "./hermesGatewayHttp.js";
import {
  assertLegacyAttachmentContentType,
  resolveGatewayGrant,
  sha256ForStorageFile,
  statusCodeForAttachmentManifest,
} from "./hermesGatewayResolve.js";
import { checkHermesGatewayBearerRateLimit } from "./publicRateLimit.js";

const CONTENT_LENGTH_HEADER = "content-length";

function attachmentUploadHeaders(byteCount: number): Record<string, string> {
  return { [CONTENT_LENGTH_HEADER]: String(byteCount) };
}

function storageGenerationString(raw: unknown): string | undefined {
  if (typeof raw === "string" && raw.length > 0) return raw;
  if (typeof raw === "number" && Number.isFinite(raw)) return String(raw);
  return undefined;
}

async function assertFinalizedObjectMatchesManifest(
  file: ReturnType<ReturnType<ReturnType<typeof getStorage>["bucket"]>["file"]>,
  manifest: HermesGatewayAttachmentManifestDoc,
): Promise<void> {
  const [metadata] = await file.getMetadata();
  const observedByteCount = Number(metadata.size);
  if (!Number.isFinite(observedByteCount) || observedByteCount !== manifest.byteCount) {
    throw new HttpsError("failed-precondition", "Gateway attachment body size no longer matches its manifest.");
  }
  const expectedGeneration = storageGenerationString(manifest.storageGeneration);
  const observedGeneration = storageGenerationString(metadata.generation);
  if (!expectedGeneration || observedGeneration !== expectedGeneration) {
    throw new HttpsError("failed-precondition", "Gateway attachment body generation no longer matches its manifest.");
  }
}

export async function handleAttachmentInit(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  assertJsonWriteContentType(req);
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  await checkHermesGatewayBearerRateLimit(grant.uid, grant.client.id, "hermes_gateway_attachment_init");
  const body = requestBody(req);
  // Sealed attachments (schema 2+): the agent seals the BYTES before uploading,
  // and seals {fileName,byteCount,contentType} into either relayEnvelope or the
  // Phase 6 ratchetEnvelope. The server never sees the plaintext name or bytes.
  // byteCount is the CIPHERTEXT length (≈ plaintext + 28B GCM overhead); the
  // stored object is opaque (application/octet-stream).
  const providedEnvelopeCount = [body.relayEnvelope, body.ratchetEnvelope, body.signalEnvelope].filter(
    (value) => value != null,
  ).length;
  if (providedEnvelopeCount > 1) {
    throw new HttpsError(
      "invalid-argument",
      "ambiguous_ciphertext: provide only one of relayEnvelope, ratchetEnvelope, or signalEnvelope.",
    );
  }
  const signalEnvelope =
    body.signalEnvelope != null
      ? requireProductionGatewaySignalEnvelope(body.signalEnvelope, "signalEnvelope")
      : undefined;
  if (signalEnvelope) {
    const attachmentId = typeof body.attachmentId === "string" ? body.attachmentId : "";
    if (!gatewaySignalAttachmentBindingMatches(signalEnvelope, attachmentId)) {
      throw new HttpsError("invalid-argument", "attachment_signal_binding_mismatch");
    }
  }
  const sealedEnvelope =
    body.relayEnvelope != null ? requireProductionGatewayRelayEnvelope(body.relayEnvelope, "relayEnvelope") : undefined;
  const ratchetEnvelope =
    body.ratchetEnvelope != null
      ? requireProductionGatewayRatchetEnvelope(body.ratchetEnvelope, "ratchetEnvelope")
      : undefined;
  const sealed = sealedEnvelope != null || ratchetEnvelope != null || signalEnvelope != null;
  if (!sealed && !gatewayPlaintextWriteAllowed(grant.client.relayCapable)) {
    throw new HttpsError(
      "invalid-argument",
      "ciphertext_required: a relayEnvelope or ratchetEnvelope (with the sealed fileName) is required for Hermes Gateway attachments.",
    );
  }
  // Plaintext fileName is never accepted for new writes; the name lives inside
  // the envelope and is never stored cleartext.
  const legacyFileName = sealed
    ? undefined
    : boundedTrimmedString(body.fileName, "fileName", 255, true).replace(/[\\/]/g, "-");
  if (legacyFileName !== undefined) {
    logInfo({ event: "hermes_gateway.plaintext_filename_deprecated", client_id: grant.client.id });
  }
  // Declared content type: opaque ciphertext on the sealed path, the real type on
  // the legacy path (where it is still validated against the unsafe-type list).
  const declaredContentType = sealed
    ? "application/octet-stream"
    : boundedTrimmedString(body.contentType, "contentType", 128, true);
  if (!sealed) {
    assertSafeAttachmentContentType(declaredContentType);
  }
  const byteCount = typeof body.byteCount === "number" ? body.byteCount : Number(body.byteCount);
  if (!Number.isFinite(byteCount) || byteCount < 1 || byteCount > HERMES_GATEWAY_MAX_ATTACHMENT_BYTES) {
    throw httpError(400, "invalid_byte_count");
  }
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  // Adopt a client-supplied attachmentId only when it ALSO passes the canonical
  // finalize contract (≤160, [A-Za-z0-9_.:-]); otherwise mint a fresh token. This
  // keeps init↔finalize symmetric (no id init accepts that finalize would reject).
  const attachmentId = adoptedGatewayDocId(body.attachmentId, () => `att_${randomBytes(8).toString("hex")}`);
  // The storage object name carries NO fileName segment — the file name is
  // private and never appears in a path the server (or a Storage listing) sees.
  const storagePath = `users/${grant.uid}/hermes_gateway_attachments/${grant.client.id}/${attachmentId}`;
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
  const uploadHeaders = attachmentUploadHeaders(byteCount);
  const [uploadURL] = await getStorage().bucket().file(storagePath).getSignedUrl({
    version: "v4",
    action: "write",
    expires: expiresAt,
    contentType: declaredContentType,
    extensionHeaders: uploadHeaders,
  });
  const now = nowISO();
  const manifest = stripUndefinedObject({
    id: attachmentId,
    clientId: grant.client.id,
    destinationId,
    fileName: legacyFileName,
    relayEnvelope: sealedEnvelope,
    ratchetEnvelope,
    signalEnvelope,
    contentType: declaredContentType,
    byteCount,
    storagePath,
    status: "pending_upload",
    createdAt: now,
    expiresAt: expiresAt.toISOString(),
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
  // Create-if-absent: a blind `set(merge:false)` would re-mint a fresh signed
  // upload URL over an already-initialized attachment doc. Adopting an id is now a
  // create — a re-init of an existing id (malicious or buggy) is rejected (409)
  // rather than clobbering the prior manifest. The agent's 128-bit token_hex makes
  // an honest collision negligible.
  const attachmentRef = db.doc(`users/${grant.uid}/hermes_gateway_attachments/${attachmentId}`);
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(attachmentRef);
    if (existing.exists) {
      throw httpError(409, "attachment_already_initialized");
    }
    tx.set(attachmentRef, manifest);
  });
  sendJSON(res, 200, {
    attachment: manifest,
    uploadURL,
    uploadHeaders,
    maxBytes: HERMES_GATEWAY_MAX_ATTACHMENT_BYTES,
  });
}

function attachmentManifestOrThrow(snap: {
  exists: boolean;
  data(): unknown;
}): HermesGatewayAttachmentManifestDoc | undefined {
  const manifest = snap.data();
  if (!snap.exists || !isHermesGatewayAttachmentManifestDoc(manifest)) return undefined;
  return manifest;
}

/**
 * Manifest-level guards for /attachments/finalize: existence, ownership,
 * destination, and storage-path containment. Throws the same structured HTTP
 * errors the inline checks did. A pure relocation that keeps the route handler
 * within the complexity cap.
 */
function assertFinalizeManifestGuards(
  manifest: HermesGatewayAttachmentManifestDoc | undefined,
  options: { uid: string; clientId: string; attachmentId: string; requestedDestinationId: string | undefined },
): asserts manifest is HermesGatewayAttachmentManifestDoc {
  if (!manifest || manifest.id !== options.attachmentId) {
    throw httpError(404, "attachment_not_found");
  }
  if (manifest.clientId !== options.clientId) {
    throw httpError(403, "attachment_client_mismatch");
  }
  if (
    options.requestedDestinationId &&
    manifest.destinationId &&
    manifest.destinationId !== options.requestedDestinationId
  ) {
    throw httpError(400, "attachment_destination_mismatch");
  }
  // Sealed manifests store the object at .../{attachmentId} (no fileName
  // segment); legacy manifests stored it at .../{attachmentId}/{fileName}. Accept
  // the bare id and the id-plus-segment form, but nothing outside this client's
  // attachment namespace.
  const expectedPathBase = `users/${options.uid}/hermes_gateway_attachments/${options.clientId}/${options.attachmentId}`;
  if (manifest.storagePath !== expectedPathBase && !manifest.storagePath.startsWith(`${expectedPathBase}/`)) {
    throw httpError(403, "attachment_storage_path_mismatch");
  }
}

export async function handleAttachmentFinalize(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  assertJsonWriteContentType(req);
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const attachmentId = requiredHttpIdentifier(body.attachmentId, "attachmentId");
  const expectedSha256 = requestedAttachmentHash(body.sha256);
  const requestedDestinationId =
    body.destinationId == null ? undefined : sanitizeHermesGatewayDestinationId(body.destinationId);
  const ref = db.doc(`users/${grant.uid}/hermes_gateway_attachments/${attachmentId}`);
  const snap = await ref.get();
  const manifest = attachmentManifestOrThrow(snap);
  assertFinalizeManifestGuards(manifest, {
    uid: grant.uid,
    clientId: grant.client.id,
    attachmentId,
    requestedDestinationId,
  });
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
  const sealed = manifest.relayEnvelope != null || manifest.ratchetEnvelope != null || manifest.signalEnvelope != null;
  const [metadata] = await file.getMetadata();
  const observedByteCount = Number(metadata.size);
  const observedContentType = typeof metadata.contentType === "string" ? metadata.contentType : "";
  if (!Number.isFinite(observedByteCount) || observedByteCount !== manifest.byteCount) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "attachment_size_mismatch");
  }
  // For a sealed upload the bytes are ciphertext: the real media type is sealed
  // inside relayEnvelope/ratchetEnvelope and the stored object is opaque, so the
  // server neither matches nor safety-sniffs the content type (the sha256 below
  // is the integrity gate on the ciphertext). Legacy plaintext uploads validate.
  if (!sealed) {
    await assertLegacyAttachmentContentType(ref, manifest.contentType, observedContentType);
  }

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

export async function handleHermesGatewayAttachmentDownloadUrl(
  request: CallableRequest<{
    attachmentId?: unknown;
    clientId?: unknown;
    destinationId?: unknown;
  }>,
): Promise<{ downloadURL: string; expiresAt: string; attachmentId: string; maxBytes: number }> {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in before downloading Gateway attachments.");
  enforceAuthAndAppCheck(request, uid);

  const attachmentId = requiredHttpIdentifier(request.data.attachmentId, "attachmentId");
  const requestedClientId = requiredHttpIdentifier(request.data.clientId, "clientId");
  const requestedDestinationId =
    request.data.destinationId == null ? undefined : sanitizeHermesGatewayDestinationId(request.data.destinationId);

  const ref = db.doc(`users/${uid}/hermes_gateway_attachments/${attachmentId}`);
  const snap = await ref.get();
  const manifest = snap.data();
  if (!snap.exists || !isHermesGatewayAttachmentManifestDoc(manifest) || manifest.id !== attachmentId) {
    throw new HttpsError("not-found", "Gateway attachment not found.");
  }
  if (manifest.clientId !== requestedClientId) {
    throw new HttpsError("permission-denied", "Gateway attachment belongs to another client.");
  }
  if (requestedDestinationId && manifest.destinationId && manifest.destinationId !== requestedDestinationId) {
    throw new HttpsError("permission-denied", "Gateway attachment belongs to another destination.");
  }
  if (manifest.status !== "uploaded") {
    throw new HttpsError("failed-precondition", "Gateway attachment is not finalized.");
  }

  const expectedPathBase = `users/${uid}/hermes_gateway_attachments/${manifest.clientId}/${attachmentId}`;
  if (manifest.storagePath !== expectedPathBase && !manifest.storagePath.startsWith(`${expectedPathBase}/`)) {
    throw new HttpsError("permission-denied", "Gateway attachment storage path is outside the client namespace.");
  }
  if (manifest.byteCount < 1 || manifest.byteCount > HERMES_GATEWAY_MAX_ATTACHMENT_BYTES) {
    throw new HttpsError("failed-precondition", "Gateway attachment manifest is invalid.");
  }

  const file = getStorage().bucket().file(manifest.storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    throw new HttpsError("not-found", "Gateway attachment body is no longer stored in the cloud.");
  }
  await assertFinalizedObjectMatchesManifest(file, manifest);

  const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
  // T-ATT-08: force the browser/OS to DOWNLOAD the (sealed, opaque) blob rather
  // than render it inline. A malicious actor who managed to seal an HTML/SVG/JS
  // payload into an attachment must not be able to get it executed in the app's
  // origin by opening the signed URL: `responseType` overrides the stored
  // object's content type with `application/octet-stream`, and
  // `responseDisposition: attachment` forces a save dialog with a fixed, inert
  // filename. The signed-URL query params are tamper-evident (they are part of
  // the V4 signature), so a caller cannot strip them to coax inline rendering.
  const [downloadURL] = await file.getSignedUrl({
    version: "v4",
    action: "read",
    expires: expiresAt,
    responseType: "application/octet-stream",
    responseDisposition: `attachment; filename="${attachmentId}.bin"`,
  });

  return {
    downloadURL,
    expiresAt: expiresAt.toISOString(),
    attachmentId,
    maxBytes: HERMES_GATEWAY_MAX_ATTACHMENT_BYTES,
  };
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
export async function handleArmApproval(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  assertJsonWriteContentType(req);
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const actionId = requiredHttpIdentifier(body.actionId, "actionId");
  const toolName = boundedTrimmedString(body.toolName, "toolName", 120, false);
  // PRIVACY BOUNDARY: the oversight gate is CONTROL-PLANE only — it carries the
  // actionId + a coarse toolName category and a SERVER-DERIVED label, never the
  // agent's free-text command. The human-readable action detail is delivered
  // end-to-end ENCRYPTED over the message channel (the adapter's send_slash_confirm
  // posts a sealed prompt the phone correlates by actionId), so the server is never
  // able to read it. We deliberately IGNORE any client-supplied `summary`, even if
  // an older adapter sends one — enforced here at the trust boundary so no client
  // can reintroduce server-readable private text on the sealed gateway.
  const summary = toolName ? `Approve ${toolName} action` : "Approve agent action";
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const ttlMillis = sanitizeHermesGatewayApprovalTTL(body.expiresInSeconds);
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
    expiresAt: gatewayApprovalExpiryISO(now, ttlMillis),
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
export async function handleListApprovals(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  const now = Date.now();
  const actionId = typeof req.query.actionId === "string" ? req.query.actionId.trim() : "";
  if (actionId) {
    const ref = db.doc(
      `users/${grant.uid}/hermes_gateway_approvals/${gatewayApprovalDocId(grant.client.id, actionId)}`,
    );
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
