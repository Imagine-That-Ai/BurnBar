/**
 * @fileoverview Cloud KMS envelope encryption + Cloud Secret Manager storage.
 *
 * Design:
 *   1. Generate a 256-bit data-encryption key (DEK) locally.
 *   2. Encrypt the plaintext credential with AES-256-GCM using the DEK.
 *   3. Encrypt the DEK with the configured Cloud KMS key.
 *   4. Store the encrypted DEK + IV + ciphertext + authTag as a single Base64
 *      payload in Secret Manager.
 *   5. Firestore keeps only the secret resource name and version string.
 *
 * This gives us envelope encryption: KMS protects the DEK, Secret Manager
 * protects the encrypted payload, and Firestore never sees ciphertext.
 */

import { randomBytes, createCipheriv, createDecipheriv } from "crypto";
import { google } from "googleapis";
import { getConfig } from "./config.js";

const AES_KEY_LEN = 32;
const AES_IV_LEN = 12;
const AES_TAG_LEN = 16;
const AES_ALG = "aes-256-gcm";

/** Lazy-initialized KMS client. */
let kmsClient: ReturnType<typeof google.cloudkms> | undefined;
/** Lazy-initialized Secret Manager client. */
let smClient: ReturnType<typeof google.secretmanager> | undefined;
/** Lazy-initialized auth client for ADC. */
let authClient: Awaited<ReturnType<typeof google.auth.getClient>> | undefined;

async function getAuthClient() {
  if (!authClient) {
    authClient = await google.auth.getClient({
      scopes: [
        "https://www.googleapis.com/auth/cloudkms",
        "https://www.googleapis.com/auth/cloud-platform",
      ],
    });
  }
  return authClient;
}

async function getKms() {
  if (!kmsClient) {
    kmsClient = google.cloudkms({ version: "v1", auth: await getAuthClient() });
  }
  return kmsClient;
}

async function getSecretManager() {
  if (!smClient) {
    smClient = google.secretmanager({ version: "v1", auth: await getAuthClient() });
  }
  return smClient;
}

/**
 * Encode an envelope into a compact Base64 string.
 *
 * Layout: [4-byte BE len(encryptedDek)][encryptedDek][12-byte IV][ciphertext][16-byte tag]
 */
function packEnvelope(
  encryptedDek: Buffer,
  iv: Buffer,
  ciphertext: Buffer,
  tag: Buffer
): string {
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(encryptedDek.length, 0);
  return Buffer.concat([lenBuf, encryptedDek, iv, ciphertext, tag]).toString("base64");
}

/** Decode an envelope produced by packEnvelope. */
function unpackEnvelope(payload: string): {
  encryptedDek: Buffer;
  iv: Buffer;
  ciphertext: Buffer;
  tag: Buffer;
} {
  const buf = Buffer.from(payload, "base64");
  let off = 0;
  const dekLen = buf.readUInt32BE(off);
  off += 4;
  const encryptedDek = buf.subarray(off, off + dekLen);
  off += dekLen;
  const iv = buf.subarray(off, off + AES_IV_LEN);
  off += AES_IV_LEN;
  const tag = buf.subarray(buf.length - AES_TAG_LEN);
  const ciphertext = buf.subarray(off, buf.length - AES_TAG_LEN);
  return { encryptedDek, iv, ciphertext, tag };
}

/**
 * Encrypt a plaintext credential using envelope encryption.
 *
 * @param plaintext - Raw credential string.
 * @returns Base64-encoded envelope string.
 */
async function encryptEnvelope(plaintext: string): Promise<string> {
  const { kmsKeyName } = getConfig();
  if (!kmsKeyName) {
    throw new Error("KMS_KEY_NAME is not configured; cannot encrypt credentials.");
  }

  const dek = randomBytes(AES_KEY_LEN);
  const iv = randomBytes(AES_IV_LEN);
  const cipher = createCipheriv(AES_ALG, dek, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();

  const kms = await getKms();
  const { data } = await kms.projects.locations.keyRings.cryptoKeys.encrypt({
    name: kmsKeyName,
    requestBody: { plaintext: dek.toString("base64") },
  });
  const encryptedDek = Buffer.from(data!.ciphertext!, "base64");

  return packEnvelope(encryptedDek, iv, ciphertext, tag);
}

/**
 * Decrypt an envelope-encrypted credential.
 *
 * @param envelope - Base64-encoded envelope string.
 * @returns Original plaintext credential.
 */
async function decryptEnvelope(envelope: string): Promise<string> {
  const { kmsKeyName } = getConfig();
  if (!kmsKeyName) {
    throw new Error("KMS_KEY_NAME is not configured; cannot decrypt credentials.");
  }

  const { encryptedDek, iv, ciphertext, tag } = unpackEnvelope(envelope);

  const kms = await getKms();
  const { data } = await kms.projects.locations.keyRings.cryptoKeys.decrypt({
    name: kmsKeyName,
    requestBody: { ciphertext: encryptedDek.toString("base64") },
  });
  const dek = Buffer.from(data!.plaintext!, "base64");

  const decipher = createDecipheriv(AES_ALG, dek, iv);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(),
  ]).toString("utf8");
  return plaintext;
}

/**
 * Build a deterministic Secret Manager secret ID for a user+provider pair.
 *
 * @param uid - Firebase Auth UID.
 * @param provider - Provider key.
 * @returns Secret ID string.
 */
function secretIdFor(uid: string, provider: string): string {
  // Secret Manager IDs must match ^[a-zA-Z0-9_\-]{1,255}$
  // UIDs from Firebase Auth are typically alphanumeric; we sanitize just in case.
  const safeUid = uid.replace(/[^a-zA-Z0-9]/g, "-");
  return `obb-${safeUid}-${provider}`;
}

/**
 * Store an encrypted credential in Secret Manager, creating the secret if needed.
 *
 * @param uid - Firebase Auth UID.
 * @param provider - Provider key.
 * @param plaintext - Raw credential to protect.
 * @returns Resource name of the new secret version (e.g. projects/…/secrets/…/versions/1).
 */
export async function storeCredential(
  uid: string,
  provider: string,
  plaintext: string
): Promise<string> {
  const { projectId } = getConfig();
  const sm = await getSecretManager();
  const secretId = secretIdFor(uid, provider);
  const parent = `projects/${projectId}`;
  const secretName = `${parent}/secrets/${secretId}`;

  // Ensure the secret exists (idempotent).
  try {
    await sm.projects.secrets.get({ name: secretName });
  } catch (err: unknown) {
    const code = (err as { code?: number }).code;
    if (code === 404) {
      await sm.projects.secrets.create({
        parent,
        secretId,
        requestBody: {
          replication: { automatic: {} },
          labels: {
            app: "openburnbar",
            provider,
          },
        },
      });
    } else {
      throw err;
    }
  }

  const envelope = await encryptEnvelope(plaintext);

  const { data } = await sm.projects.secrets.addVersion({
    parent: secretName,
    requestBody: {
      payload: {
        data: Buffer.from(envelope).toString("base64"),
      },
    },
  });

  return data!.name!;
}

/**
 * Retrieve and decrypt a credential from Secret Manager.
 *
 * @param secretVersionName - Full resource name of the secret version.
 * @returns Plaintext credential string.
 */
export async function retrieveCredential(secretVersionName: string): Promise<string> {
  const sm = await getSecretManager();
  const { data } = await sm.projects.secrets.versions.access({
    name: secretVersionName,
  });
  const envelope = Buffer.from(data!.payload!.data!, "base64").toString("utf8");
  return decryptEnvelope(envelope);
}

/**
 * Destroy a secret version and disable the underlying secret.
 *
 * We do NOT delete the secret (to preserve audit history), but we destroy
 * the active version so the payload is irrecoverable.
 *
 * @param secretVersionName - Full resource name of the secret version.
 */
export async function destroyCredential(secretVersionName: string): Promise<void> {
  const sm = await getSecretManager();
  await sm.projects.secrets.versions.destroy({ name: secretVersionName });
}

/**
 * Build the initial secret version name given a uid and provider.
 * Used when we know the version is "1" on first write.
 *
 * @param uid - Firebase Auth UID.
 * @param provider - Provider key.
 * @returns Secret version resource name.
 */
export function initialSecretVersionName(uid: string, provider: string): string {
  const { projectId } = getConfig();
  return `projects/${projectId}/secrets/${secretIdFor(uid, provider)}/versions/1`;
}
