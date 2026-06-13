/**
 * On-device AES-256-GCM sealing — the encrypt counterpart to decrypt.ts.
 *
 * Pensieve ingest (chat-derived memories, repo docs, notes) seals chunk text and
 * metadata on the device with the vault key before upload. The envelope shape is
 * exactly what the backend's requireSealedText validator accepts and what the
 * shim's decryptSealedText opens:
 *   { algorithm:"AES-256-GCM", keyVersion, nonce, ciphertext, tag } (base64).
 * Plaintext never leaves the device.
 */

import { createCipheriv, randomBytes } from "node:crypto";
import { cloudVaultAADContext, type SealedEnvelope } from "./decrypt.js";
import { loadVaultKeyBytes } from "./embed.js";

export const SEAL_KEY_VERSION = 1;

/** Seal a UTF-8 string into an AES-256-GCM envelope using a 32-byte key. */
export interface SealTextContext {
  uid: string;
  collection: string;
  docID: string;
  field: string;
}

export function sealText(plaintext: string, key: Buffer, context?: SealTextContext): SealedEnvelope {
  if (key.length !== 32) {throw new Error("Vault key must be 32 bytes for AES-256-GCM.");}
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const aad = context ? cloudVaultAADContext(context.uid, context.collection, context.docID, context.field) : undefined;
  if (aad) {cipher.setAAD(Buffer.from(aad, "utf8"));}
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const envelope: SealedEnvelope = {
    algorithm: "AES-256-GCM",
    keyVersion: SEAL_KEY_VERSION,
    nonce: nonce.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
  if (aad) {
    envelope.schemaVersion = 2;
    envelope.aad = aad;
  }
  return envelope;
}

/** Seal using the device vault key, or throw if it is unavailable. */
export function sealTextWithVaultKey(plaintext: string, context?: SealTextContext): SealedEnvelope {
  const key = loadVaultKeyBytes();
  if (!key) {throw new Error("Pensieve vault key unavailable — run `openburnbar mcp login`.");}
  return sealText(plaintext, key, context);
}
