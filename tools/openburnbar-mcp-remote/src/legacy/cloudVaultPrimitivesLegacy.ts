import { createCipheriv, createDecipheriv, createHmac, hkdfSync } from "node:crypto";

function hasAADForbiddenCharacter(value: string): boolean {
  for (const character of value) {
    const code = character.charCodeAt(0);
    if (code <= 0x1f || code === 0x7f || character === "|") {
      return true;
    }
  }
  return false;
}

export function legacyCloudVaultAADContext(
  uid: string,
  collection: string,
  docID: string,
  field: string,
  schemaVersion = 2,
  purpose = field,
): string {
  for (const [name, value] of Object.entries({ uid, collection, docID, field, purpose })) {
    if (!value || hasAADForbiddenCharacter(value)) {
      throw new Error(`Invalid CloudVault AAD ${name}.`);
    }
  }
  if (!Number.isInteger(schemaVersion) || schemaVersion < 2) {
    throw new Error("Invalid CloudVault AAD schemaVersion.");
  }
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docID}|${field}|${schemaVersion}|${purpose}`;
}

export function legacyAesGcmSealCombined(
  plaintext: Uint8Array,
  key: Uint8Array,
  nonce: Uint8Array,
  aad: Uint8Array,
): Buffer {
  if (key.byteLength !== 32) {
    throw new Error("Vault key must be 32 bytes for AES-256-GCM.");
  }
  if (nonce.byteLength !== 12) {
    throw new Error("AES-256-GCM nonce must be 12 bytes.");
  }
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  if (aad.byteLength > 0) {
    cipher.setAAD(aad);
  }
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([Buffer.from(nonce), ciphertext, cipher.getAuthTag()]);
}

export function legacyAesGcmOpenCombined(
  combined: Uint8Array,
  key: Uint8Array,
  aad: Uint8Array,
): Buffer {
  if (key.byteLength !== 32) {
    throw new Error("Vault key must be 32 bytes for AES-256-GCM.");
  }
  if (combined.byteLength < 28) {
    throw new Error("Invalid AES-256-GCM combined payload.");
  }
  const value = Buffer.from(combined);
  const nonce = value.subarray(0, 12);
  const ciphertext = value.subarray(12, -16);
  const tag = value.subarray(-16);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  if (aad.byteLength > 0) {
    decipher.setAAD(aad);
  }
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

export function legacyPensieveHmac(
  vaultKey: Uint8Array,
  label: "content" | "slug" | "provenance",
  value: string,
): string {
  const key = Buffer.from(hkdfSync("sha256", vaultKey, Buffer.alloc(0), `pensieve-dedup:${label}`, 32));
  try {
    return createHmac("sha256", key).update(value, "utf8").digest("hex");
  } finally {
    key.fill(0);
  }
}
