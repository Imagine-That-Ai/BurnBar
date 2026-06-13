import { createDecipheriv } from "node:crypto";
import { readVaultKey } from "./vaultStore.js";

function hasAADForbiddenCharacter(value: string): boolean {
  for (const character of value) {
    const code = character.charCodeAt(0);
    if (code <= 0x1f || code === 0x7f || character === "|") {
      return true;
    }
  }
  return false;
}


export interface SealedEnvelope {
  schemaVersion?: number;
  algorithm: "AES-256-GCM";
  keyVersion: number;
  nonce: string;
  ciphertext: string;
  tag: string;
  aad?: string;
}

export function cloudVaultAADContext(
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

function safeCloudVaultAADContext(uid: string, collection: string, docID: string, field: string): string | undefined {
  try {
    return cloudVaultAADContext(uid, collection, docID, field);
  } catch {
    return undefined;
  }
}

function vaultKey(): Buffer | undefined {
  const raw = readVaultKey();
  if (!raw) {return undefined;}
  const key = Buffer.from(raw, "base64");
  return key.length === 32 ? key : undefined;
}

export function hasVaultKey(): boolean {
  return vaultKey() !== undefined;
}

export function decryptSealedText(envelope: unknown, expectedAAD?: string): string | undefined {
  const key = vaultKey();
  if (!key || !envelope || typeof envelope !== "object") {return undefined;}
  const item = envelope as Partial<SealedEnvelope>;
  if (item.algorithm !== "AES-256-GCM" || !item.nonce || !item.ciphertext || !item.tag) {return undefined;}
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(item.nonce, "base64"));
  if ((item.schemaVersion ?? 1) >= 2) {
    if (!expectedAAD || item.aad !== expectedAAD) {return undefined;}
    decipher.setAAD(Buffer.from(expectedAAD, "utf8"));
  }
  decipher.setAuthTag(Buffer.from(item.tag, "base64"));
  const opened = Buffer.concat([
    decipher.update(Buffer.from(item.ciphertext, "base64")),
    decipher.final()
  ]);
  return opened.toString("utf8");
}

function safeDecryptSealedText(envelope: unknown, expectedAAD?: string): string | undefined {
  try {
    return decryptSealedText(envelope, expectedAAD);
  } catch {
    return undefined;
  }
}

export function decryptSearchResultJson(text: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return text;
  }
  if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as { hits?: unknown }).hits)) {return text;}
  const hits = (parsed as { hits: Array<Record<string, unknown>> }).hits.map((hit) => {
    const uid = typeof hit.uid === "string" ? hit.uid : "";
    const documentID = typeof hit.documentID === "string" ? hit.documentID : "";
    const chunkID = typeof hit.chunkID === "string" ? hit.chunkID : "";
    const titleAAD = uid && documentID ? safeCloudVaultAADContext(uid, "cloud_search_documents", documentID, "sealedTitle") : undefined;
    const previewAAD = uid && documentID ? safeCloudVaultAADContext(uid, "cloud_search_documents", documentID, "sealedBodyPreview") : undefined;
    const snippetAAD = uid && chunkID ? safeCloudVaultAADContext(uid, "cloud_search_chunks", chunkID, "sealedSnippet") : undefined;
    return {
      ...hit,
      title: safeDecryptSealedText(hit.sealedTitle, titleAAD),
      snippet: safeDecryptSealedText(hit.sealedSnippet, snippetAAD),
      bodyPreview: safeDecryptSealedText(hit.sealedBodyPreview, previewAAD),
      sealedTitle: undefined,
      sealedSnippet: undefined,
      sealedBodyPreview: undefined
    };
  });
  return JSON.stringify({ ...(parsed as Record<string, unknown>), hits });
}
