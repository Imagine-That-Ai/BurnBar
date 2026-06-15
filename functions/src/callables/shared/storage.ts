/**
 * @fileoverview Encrypted session-log storage path and blob validation helpers.
 */

import { getStorage } from "firebase-admin/storage";
import { HttpsError } from "firebase-functions/v2/https";

import { getConfig } from "../../config.js";
import { boundedTrimmedString, requireHexDigest, safeCloudDocumentID } from "./validators.js";

function safeStoragePathDocumentSegment(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 512, true);
  if (
    value === "." ||
    value === ".." ||
    value.includes("/") ||
    value.includes("\\") ||
    /[\u0000-\u001F\u007F]/u.test(value)
  ) {
    throw new HttpsError("invalid-argument", `${fieldName} contains unsupported characters.`);
  }
  return value;
}

export function assertUserStoragePath(
  uid: string,
  storagePath: string,
  expectedBodyHash?: string,
  expectedDocumentID?: string,
): void {
  const parts = storagePath.split("/");
  if (
    parts.length !== 6 ||
    parts[0] !== "users" ||
    parts[1] !== uid ||
    parts[2] !== "session_logs" ||
    parts[4] !== "bodies" ||
    !parts[5].endsWith(".json.aesgcm")
  ) {
    throw new HttpsError("permission-denied", "Invalid encrypted session storage path.");
  }
  const pathDocumentID = expectedDocumentID
    ? safeCloudDocumentID(parts[3], "storagePath.documentID")
    : safeStoragePathDocumentSegment(parts[3], "storagePath.documentID");
  if (expectedDocumentID && pathDocumentID !== expectedDocumentID) {
    throw new HttpsError("invalid-argument", "Encrypted session storage path does not match documentID.");
  }
  const pathBodyHash = requireHexDigest(parts[5].slice(0, -".json.aesgcm".length), "storagePath.bodyHash");
  if (expectedBodyHash && pathBodyHash !== expectedBodyHash) {
    throw new HttpsError("invalid-argument", "Encrypted session storage path does not match bodyHash.");
  }
}

export async function assertEncryptedSessionBlobObject(args: {
  uid: string;
  storagePath: string;
  documentID: string;
  bodyHash: string;
  encryptedByteCount: number;
}): Promise<number> {
  assertUserStoragePath(args.uid, args.storagePath, args.bodyHash, args.documentID);
  let metadata: Record<string, unknown>;
  try {
    [metadata] = await getStorage().bucket().file(args.storagePath).getMetadata();
  } catch {
    throw new HttpsError(
      "failed-precondition",
      "Encrypted session body must be uploaded before committing the search index.",
    );
  }
  return resolveEncryptedSessionBlobByteCount({
    metadata,
    maxBytes: getConfig().encryptedSessionBlobMaxBytes,
  });
}

export function resolveEncryptedSessionBlobByteCount(args: {
  metadata: Record<string, unknown>;
  maxBytes: number;
}): number {
  const { metadata, maxBytes } = args;
  const size = Number(metadata.size);
  if (!Number.isFinite(size) || !Number.isInteger(size)) {
    throw new HttpsError("failed-precondition", "Encrypted session body has an invalid size.");
  }
  if (size < 1 || size > maxBytes) {
    throw new HttpsError("resource-exhausted", "Encrypted session body exceeds the configured upload limit.");
  }
  if (metadata.contentType !== "application/octet-stream") {
    throw new HttpsError("failed-precondition", "Encrypted session body has an invalid content type.");
  }
  return size;
}
