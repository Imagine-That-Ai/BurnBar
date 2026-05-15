import type { Firestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { verifyCursor, signCursor } from "./cursors.js";
import { HttpError } from "./errors.js";

const RESOURCE_RE = /^burnbar:\/\/conversation\/([A-Za-z0-9_.:-]+)$/u;

export async function listResources(db: Firestore, uid: string) {
  const docs = await db.collection(`users/${uid}/cloud_search_documents`).limit(50).get();
  return {
    resources: docs.docs.map((doc) => ({
      uri: `burnbar://conversation/${doc.id}`,
      name: doc.get("sourceID") ?? doc.id,
      mimeType: "application/vnd.openburnbar.sealed-session+json",
      description: "Encrypted OpenBurnBar session log. Use the local shim to decrypt on device."
    }))
  };
}

export async function readConversationBody(
  db: Firestore,
  uid: string,
  args: { resourceUri?: string; maxChars?: number; cursor?: string }
) {
  const uri = typeof args.resourceUri === "string" ? args.resourceUri : "";
  const match = RESOURCE_RE.exec(uri);
  if (!match) throw new HttpError(400, "resourceUri must be a stable URI returned by search.", "invalid_resource_uri");
  const docId = match[1];
  const maxChars = Math.max(1024, Math.min(Number(args.maxChars ?? 24_000), 96_000));
  const cursor = args.cursor ? verifyCursor(args.cursor, uid, "burnbar_get_conversation_body") : undefined;
  if (cursor?.resourceUri && cursor.resourceUri !== uri) {
    throw new HttpError(400, "Cursor does not match resource URI.", "cursor_scope_mismatch");
  }
  const offset = cursor?.offset ?? 0;
  const snap = await db.doc(`users/${uid}/cloud_search_documents/${docId}`).get();
  if (!snap.exists) throw new HttpError(404, "Conversation resource not found.", "resource_not_found");
  const data = snap.data() ?? {};
  const storagePath = typeof data.storagePath === "string" ? data.storagePath : "";
  const bodyHash = typeof data.bodyHash === "string" ? data.bodyHash : "";
  if (!storagePath.startsWith(`users/${uid}/session_logs/${docId}/bodies/`) || !bodyHash) {
    throw new HttpError(403, "Conversation body path is not owner-scoped.", "invalid_storage_path");
  }
  const [bytes] = await getStorage().bucket().file(storagePath).download();
  const encoded = bytes.toString("utf8");
  const page = encoded.slice(offset, offset + maxChars);
  return {
    resourceUri: uri,
    bodyHash,
    encryptedBodyPage: page,
    encrypted: true,
    decryptMode: "local_decrypt_shim",
    nextCursor: offset + maxChars < encoded.length
      ? signCursor({ uid, tool: "burnbar_get_conversation_body", offset: offset + maxChars, resourceUri: uri, exp: Date.now() + 15 * 60_000 })
      : undefined,
    storageReads: 1
  };
}

export async function recentUsage(db: Firestore, uid: string) {
  const snap = await db.collection(`users/${uid}/usage`).orderBy("startTime", "desc").limit(25).get();
  return {
    usage: snap.docs.map((doc) => {
      const data = doc.data();
      return {
        id: doc.id,
        provider: data.provider,
        model: data.model,
        projectName: data.projectName,
        startTime: data.startTime,
        inputTokens: data.inputTokens,
        outputTokens: data.outputTokens,
        estimatedCostUSD: data.estimatedCostUSD
      };
    })
  };
}
