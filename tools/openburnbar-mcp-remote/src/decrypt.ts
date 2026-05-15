import { createDecipheriv } from "node:crypto";

export interface SealedEnvelope {
  algorithm: "AES-256-GCM";
  keyVersion: number;
  nonce: string;
  ciphertext: string;
  tag: string;
}

function vaultKey(): Buffer | undefined {
  const raw = process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64;
  if (!raw) return undefined;
  const key = Buffer.from(raw, "base64");
  return key.length === 32 ? key : undefined;
}

export function decryptSealedText(envelope: unknown): string | undefined {
  const key = vaultKey();
  if (!key || !envelope || typeof envelope !== "object") return undefined;
  const item = envelope as Partial<SealedEnvelope>;
  if (item.algorithm !== "AES-256-GCM" || !item.nonce || !item.ciphertext || !item.tag) return undefined;
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(item.nonce, "base64"));
  decipher.setAuthTag(Buffer.from(item.tag, "base64"));
  const opened = Buffer.concat([
    decipher.update(Buffer.from(item.ciphertext, "base64")),
    decipher.final()
  ]);
  return opened.toString("utf8");
}

export function decryptSearchResultJson(text: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return text;
  }
  if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as { hits?: unknown }).hits)) return text;
  const hits = (parsed as { hits: Array<Record<string, unknown>> }).hits.map((hit) => ({
    ...hit,
    title: decryptSealedText(hit.sealedTitle),
    snippet: decryptSealedText(hit.sealedSnippet),
    bodyPreview: decryptSealedText(hit.sealedBodyPreview),
    sealedTitle: undefined,
    sealedSnippet: undefined,
    sealedBodyPreview: undefined
  }));
  return JSON.stringify({ ...(parsed as Record<string, unknown>), hits });
}
