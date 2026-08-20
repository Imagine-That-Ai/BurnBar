/**
 * burnbar_attachments: begin / part URL / compose / finalize-once / download / delete.
 * Quotas and integrity come from GCS getMetadata, never client-declared size.
 */

import { randomBytes } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { boundedFirestoreDocumentId } from "./computerUseSecurityCodecs.js";
import { requireTrustedDeviceActionProof } from "./computerUseSecurityFirestore.js";
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString } from "./shared.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";

export const FILE_CAP_BYTES = 10 * 1024 * 1024 * 1024;
export const PRO_WITHOUT_MEDIA_SYNC_CAP_BYTES = 200 * 1024 * 1024;
export const COMPOSE_FANIN = 32;
const MAC_OR_PHONE = new Set(["macOS", "iOS", "iPadOS", "Android"]);

type ComposeCall = { sources: string[]; destination: string; ifGenerationMatch: number };

interface BurnbarStoragePort {
  getMetadata(path: string): Promise<{ size: number; generation: string }>;
  compose(sources: string[], destination: string, ifGenerationMatch: number): Promise<{ size: number; generation: string }>;
  delete(path: string): Promise<void>;
  mintPutUrl(path: string, contentLength: number, ttlSeconds: number): Promise<{ url: string; expiresAt: number }>;
  mintGetUrl(path: string, generation: string): Promise<{ url: string }>;
  revokePuts(prefix: string): Promise<void>;
}

const composeLog: ComposeCall[] = [];

export function takeComposeLog(): ComposeCall[] {
  const copy = [...composeLog];
  composeLog.length = 0;
  return copy;
}

type MemoryObject = { size: number; generation: string; revoked?: boolean; pending?: boolean };

const memoryObjects = new Map<string, MemoryObject>();

export function resetMemoryStorage(): void {
  memoryObjects.clear();
}

/** Simulate a successful signed PUT. Mint only reserves; compose cannot see pending objects. */
export async function putMemoryObject(path: string, size: number): Promise<void> {
  const existing = memoryObjects.get(path);
  if (existing?.revoked) throw new HttpsError("permission-denied", "Part URL revoked.");
  memoryObjects.set(path, { size, generation: String(Date.now()), pending: false });
}

export const memoryStoragePort: BurnbarStoragePort = {
  async getMetadata(path) {
    const obj = memoryObjects.get(path);
    if (!obj || obj.pending) throw new HttpsError("not-found", "Object missing.");
    return { size: obj.size, generation: obj.generation };
  },
  async compose(sources, destination, ifGenerationMatch) {
    composeLog.push({ sources: [...sources], destination, ifGenerationMatch });
    if (sources.length > COMPOSE_FANIN) {
      throw new HttpsError("invalid-argument", "compose exceeds 32 sources.");
    }
    if (ifGenerationMatch === 0 && memoryObjects.has(destination) && !memoryObjects.get(destination)?.pending) {
      throw new HttpsError("failed-precondition", "generation mismatch.");
    }
    let size = 0;
    for (const src of sources) {
      const obj = memoryObjects.get(src);
      if (!obj || obj.pending) throw new HttpsError("not-found", `Missing compose source ${src}`);
      size += obj.size;
    }
    const generation = String(Date.now());
    memoryObjects.set(destination, { size, generation });
    return { size, generation };
  },
  async delete(path) {
    memoryObjects.delete(path);
  },
  async mintPutUrl(path, contentLength, ttlSeconds) {
    const existing = memoryObjects.get(path);
    if (existing?.revoked) throw new HttpsError("permission-denied", "Part URL revoked.");
    // Reserve only. Do not materialize compose-visible bytes; a PUT must follow.
    memoryObjects.set(path, { size: 0, generation: existing?.generation ?? "0", pending: true });
    return { url: `https://storage.test/${path}?ttl=${ttlSeconds}&len=${contentLength}`, expiresAt: Date.now() + ttlSeconds * 1000 };
  },
  async mintGetUrl(path, generation) {
    const obj = memoryObjects.get(path);
    if (!obj || obj.generation !== generation) throw new HttpsError("failed-precondition", "generation pin failed.");
    return { url: `https://storage.test/${path}?gen=${generation}` };
  },
  async revokePuts(prefix) {
    for (const key of [...memoryObjects.keys()]) {
      if (key.startsWith(prefix) && (key.includes("/parts/") || key.includes("/mid/"))) {
        const obj = memoryObjects.get(key);
        if (obj) obj.revoked = true;
      }
    }
  },
};

export async function combineWithGenerationPin(
  bucket: {
    combine: (
      sources: string[],
      destination: string,
      options: { ifGenerationMatch: number },
    ) => Promise<[{ getMetadata: () => Promise<[{ size?: unknown; generation?: unknown }]> }]>;
  },
  sources: string[],
  destination: string,
  ifGenerationMatch: number,
): Promise<{ size: number; generation: string }> {
  const [file] = await bucket.combine(sources, destination, { ifGenerationMatch });
  const [metadata] = await file.getMetadata();
  return { size: Number(metadata.size ?? 0), generation: String(metadata.generation ?? "") };
}

export const gcsStoragePort: BurnbarStoragePort = {
  async getMetadata(path) {
    const [metadata] = await getStorage().bucket().file(path).getMetadata();
    return { size: Number(metadata.size ?? 0), generation: String(metadata.generation ?? "") };
  },
  async compose(sources, destination, ifGenerationMatch) {
    if (sources.length > COMPOSE_FANIN) {
      throw new HttpsError("invalid-argument", "compose exceeds 32 sources.");
    }
    composeLog.push({ sources: [...sources], destination, ifGenerationMatch });
    return combineWithGenerationPin(getStorage().bucket(), sources, destination, ifGenerationMatch);
  },
  async delete(path) {
    await getStorage().bucket().file(path).delete({ ignoreNotFound: true });
  },
  async mintPutUrl(path, contentLength, ttlSeconds) {
    const expires = Date.now() + ttlSeconds * 1000;
    const [url] = await getStorage().bucket().file(path).getSignedUrl({
      version: "v4",
      action: "write",
      expires,
      contentType: "application/octet-stream",
      extensionHeaders: {
        "content-length": String(contentLength),
        "x-goog-if-generation-match": "0",
      },
    });
    return { url, expiresAt: expires };
  },
  async mintGetUrl(path, generation) {
    const [url] = await getStorage().bucket().file(path).getSignedUrl({
      version: "v4",
      action: "read",
      expires: Date.now() + 15 * 60 * 1000,
      queryParams: { generation },
    });
    return { url };
  },
  async revokePuts(prefix) {
    // Tombstone, do not delete. A delete returns the object to generation 0
    // (unborn), which lets a still-live v4 PUT with ifGenerationMatch:0 recreate
    // the part. Overwriting pins a non-zero generation so those PUTs 412.
    const [files] = await getStorage().bucket().getFiles({ prefix });
    await Promise.all(
      files.map((file) =>
        file.save(Buffer.from("revoked"), {
          resumable: false,
          validation: false,
          contentType: "application/octet-stream",
          metadata: { metadata: { burnbarRevoked: "1" } },
        }),
      ),
    );
  },
};

let storagePort: BurnbarStoragePort = gcsStoragePort;
export function setBurnbarStoragePort(port: BurnbarStoragePort): void {
  storagePort = port;
}

export function activeBurnbarStoragePort(): BurnbarStoragePort {
  return storagePort;
}

function objectPath(uid: string, id: string, name: string): string {
  return `users/${uid}/burnbar_attachments/${id}/${name}`;
}

function attachRef(uid: string, id: string) {
  return db.doc(`users/${uid}/burnbar_attachments/${id}`);
}

function quotaRef(uid: string, dir: "in" | "out") {
  const day = new Date().toISOString().slice(0, 10);
  return db.doc(`users/${uid}/_rate_limits/burnbar_attach_${day}_${dir}`);
}

async function requireActor(request: CallableRequest<Record<string, unknown>>, actionKind: string, subjectId: string) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Authentication is required.");
  const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
  const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
  await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
  await requireTrustedDeviceActionProof({
    uid,
    deviceId,
    actionKind,
    subjectId,
    approve: true,
    nonce,
    proofRaw: request.data.actionProof,
    allowedPlatforms: MAC_OR_PHONE,
  });
  return { uid, deviceId };
}

export function planComposeHierarchy(partCount: number): string[][] {
  if (partCount <= 1) return [];
  const groups: string[][] = [];
  let layer = Array.from({ length: partCount }, (_, i) => `p${i}`);
  while (layer.length > 1) {
    const next: string[] = [];
    for (let i = 0; i < layer.length; i += COMPOSE_FANIN) {
      const chunk = layer.slice(i, i + COMPOSE_FANIN);
      groups.push(chunk);
      next.push(`m${groups.length}`);
    }
    layer = next;
  }
  return groups;
}

export async function composeParts(
  uid: string,
  id: string,
  chunkCount: number,
  port: BurnbarStoragePort = storagePort,
): Promise<void> {
  if (chunkCount < 1) throw new HttpsError("failed-precondition", "No parts to compose.");
  let layer = Array.from({ length: chunkCount }, (_, i) => objectPath(uid, id, `parts/${i}`));
  const finalPath = objectPath(uid, id, "final");
  if (layer.length === 1) {
    await port.compose(layer, finalPath, 0);
    return;
  }
  let mid = 0;
  while (layer.length > COMPOSE_FANIN) {
    const next: string[] = [];
    for (let i = 0; i < layer.length; i += COMPOSE_FANIN) {
      const sources = layer.slice(i, i + COMPOSE_FANIN);
      const dest = objectPath(uid, id, `mid/${mid}`);
      mid += 1;
      if (sources.length > COMPOSE_FANIN) {
        throw new HttpsError("invalid-argument", "compose exceeds 32 sources.");
      }
      await port.compose(sources, dest, 0);
      next.push(dest);
    }
    layer = next;
  }
  await port.compose(layer, finalPath, 0);
}

export const beginBurnbarAttachment = onCallProduction(
  "beginBurnbarAttachment",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const id = randomBytes(16).toString("hex");
    const { uid } = await requireActor(request, "burnbar_attachment_begin", id);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const byteCount = Number(request.data.byteCount);
    if (!Number.isFinite(byteCount) || byteCount <= 0 || byteCount > FILE_CAP_BYTES) {
      throw new HttpsError("invalid-argument", "byteCount exceeds the 10GiB file cap.");
    }
    const mediaSnap = await db.doc(`users/${uid}/entitlements/hosted_media_sync`).get();
    const mediaActive = mediaSnap.exists && mediaSnap.get("active") === true;
    if (!mediaActive && byteCount > PRO_WITHOUT_MEDIA_SYNC_CAP_BYTES) {
      throw new HttpsError(
        "permission-denied",
        "Files over 200MB require the hosted_media_sync entitlement.",
      );
    }
    const chunkCount = Math.max(1, Math.ceil(byteCount / (32 * 1024 * 1024)));
    const quota = quotaRef(uid, "in");
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(quota);
      const reserved = typeof snap.get("reservedBytes") === "number" ? snap.get("reservedBytes") : 0;
      const metered = typeof snap.get("meteredBytes") === "number" ? snap.get("meteredBytes") : 0;
      if (reserved + metered + byteCount > FILE_CAP_BYTES) {
        throw new HttpsError("resource-exhausted", "Daily inbound attachment budget exceeded.");
      }
      tx.set(quota, { reservedBytes: reserved + byteCount, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
      tx.set(attachRef(uid, id), {
        id,
        contentBlake3: boundedTrimmedString(request.data.contentBlake3, "contentBlake3", 64, true),
        byteCount,
        chunkCount,
        transport: request.data.transport === "p2p" ? "p2p" : "cloud",
        state: "pending_upload",
        storagePath: objectPath(uid, id, "final"),
        reservedBytes: byteCount,
        wrappedKeySlot: typeof request.data.wrappedKeySlot === "string" ? request.data.wrappedKeySlot : null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
    return { ok: true, id, chunkCount, fileCapBytes: FILE_CAP_BYTES };
  },
);

export const mintBurnbarAttachmentPartURL = onCallProduction(
  "mintBurnbarAttachmentPartURL",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const id = boundedFirestoreDocumentId(request.data.id, "id", 64);
    const { uid } = await requireActor(request, "burnbar_attachment_part", id);
    const partIndex = Number(request.data.partIndex);
    const contentLength = Number(request.data.contentLength);
    if (!Number.isInteger(partIndex) || partIndex < 0) throw new HttpsError("invalid-argument", "partIndex invalid.");
    if (!Number.isFinite(contentLength) || contentLength <= 0) {
      throw new HttpsError("invalid-argument", "contentLength required.");
    }
    const snap = await attachRef(uid, id).get();
    if (!snap.exists || snap.get("state") !== "pending_upload") {
      throw new HttpsError("failed-precondition", "Attachment is not accepting parts.");
    }
    const chunkCount = Number(snap.get("chunkCount") ?? 0);
    if (partIndex >= chunkCount) throw new HttpsError("invalid-argument", "partIndex out of range.");
    const reserved = Number(snap.get("reservedBytes") ?? snap.get("byteCount") ?? 0);
    const maxSealedPart = 32 * 1024 * 1024 + 12 + 16 + 1024;
    if (contentLength > maxSealedPart || contentLength > reserved + maxSealedPart) {
      throw new HttpsError("invalid-argument", "contentLength exceeds reserved sealed size.");
    }
    const path = objectPath(uid, id, `parts/${partIndex}`);
    const minted = await storagePort.mintPutUrl(path, contentLength, 10 * 60);
    return { ok: true, url: minted.url, path, ttlSeconds: 600 };
  },
);

export const composeBurnbarAttachment = onCallProduction(
  "composeBurnbarAttachment",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const id = boundedFirestoreDocumentId(request.data.id, "id", 64);
    const { uid } = await requireActor(request, "burnbar_attachment_compose", id);
    const chunkCount = await db.runTransaction(async (tx) => {
      const snap = await tx.get(attachRef(uid, id));
      if (!snap.exists) throw new HttpsError("not-found", "Attachment not found.");
      const state = snap.get("state");
      if (state === "uploaded") {
        throw new HttpsError("failed-precondition", "Finalized attachments cannot be recomposed.");
      }
      if (state !== "pending_upload" && state !== "composing") {
        throw new HttpsError("failed-precondition", "Attachment is not composable.");
      }
      const count = Number(snap.get("chunkCount") ?? 0);
      tx.set(attachRef(uid, id), { state: "composing", updatedAt: FieldValue.serverTimestamp() }, { merge: true });
      return count;
    });
    await composeParts(uid, id, chunkCount);
    return { ok: true, id, composeGroups: Math.max(planComposeHierarchy(chunkCount).length, 1) };
  },
);

export const finalizeBurnbarAttachment = onCallProduction(
  "finalizeBurnbarAttachment",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const id = boundedFirestoreDocumentId(request.data.id, "id", 64);
    const { uid } = await requireActor(request, "burnbar_attachment_finalize", id);
    const path = objectPath(uid, id, "final");
    const meta = await storagePort.getMetadata(path);
    const quotaPeek = await quotaRef(uid, "in").get();
    const meteredPeek = typeof quotaPeek.get("meteredBytes") === "number" ? quotaPeek.get("meteredBytes") : 0;
    if (meteredPeek + meta.size > FILE_CAP_BYTES) {
      await storagePort.delete(path);
      throw new HttpsError("resource-exhausted", "Final object exceeds daily budget.");
    }
    const ref = attachRef(uid, id);
    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new HttpsError("not-found", "Attachment not found.");
      const state = snap.get("state");
      if (state === "uploaded") {
        if (snap.get("storageGeneration") === meta.generation && snap.get("meteredBytes") === meta.size) {
          return { ok: true, idempotent: true, size: meta.size, generation: meta.generation };
        }
        throw new HttpsError("failed-precondition", "Finalize generation pin mismatch.");
      }
      if (state !== "pending_upload" && state !== "composing") {
        throw new HttpsError("failed-precondition", "Attachment is not finalizable.");
      }
      const reserved = typeof snap.get("reservedBytes") === "number" ? snap.get("reservedBytes") : 0;
      const quota = quotaRef(uid, "in");
      const q = await tx.get(quota);
      const reservedTotal = typeof q.get("reservedBytes") === "number" ? q.get("reservedBytes") : 0;
      const metered = typeof q.get("meteredBytes") === "number" ? q.get("meteredBytes") : 0;
      const nextMetered = metered + meta.size;
      if (nextMetered > FILE_CAP_BYTES) {
        throw new HttpsError("resource-exhausted", "Final object exceeds daily budget.");
      }
      tx.set(
        quota,
        {
          reservedBytes: Math.max(0, reservedTotal - reserved),
          meteredBytes: nextMetered,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      tx.set(
        ref,
        {
          state: "uploaded",
          storageGeneration: meta.generation,
          meteredBytes: meta.size,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return { ok: true, idempotent: false, size: meta.size, generation: meta.generation };
    });
    await storagePort.revokePuts(objectPath(uid, id, "parts/"));
    logInfo({ event: "callable_info", message: "burnbar_attachment_finalized", id, size: result.size });
    return result;
  },
);

export const ticketBurnbarAttachmentDownload = onCallProduction(
  "ticketBurnbarAttachmentDownload",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const id = boundedFirestoreDocumentId(request.data.id, "id", 64);
    const { uid } = await requireActor(request, "burnbar_attachment_download", id);
    const snap = await attachRef(uid, id).get();
    if (!snap.exists || snap.get("state") !== "uploaded") {
      throw new HttpsError("failed-precondition", "Attachment is not downloaded.");
    }
    const generation = String(snap.get("storageGeneration") ?? "");
    const size = Number(snap.get("meteredBytes") ?? 0);
    const quota = quotaRef(uid, "out");
    await db.runTransaction(async (tx) => {
      const q = await tx.get(quota);
      const reserved = typeof q.get("reservedBytes") === "number" ? q.get("reservedBytes") : 0;
      const metered = typeof q.get("meteredBytes") === "number" ? q.get("meteredBytes") : 0;
      if (reserved + metered + size > FILE_CAP_BYTES) {
        throw new HttpsError("resource-exhausted", "Daily outbound attachment budget exceeded.");
      }
      tx.set(
        quota,
        { meteredBytes: metered + size, updatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    });
    const minted = await storagePort.mintGetUrl(objectPath(uid, id, "final"), generation);
    return { ok: true, url: minted.url };
  },
);

export const deleteBurnbarAttachment = onCallProduction(
  "deleteBurnbarAttachment",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const id = boundedFirestoreDocumentId(request.data.id, "id", 64);
    const { uid } = await requireActor(request, "burnbar_attachment_delete", id);
    await storagePort.delete(objectPath(uid, id, "final"));
    await attachRef(uid, id).set({ state: "deleted", updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    return { ok: true, id };
  },
);
