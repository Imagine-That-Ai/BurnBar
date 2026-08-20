/**
 * @fileoverview Input parsing and validation helpers for Cloud Function callables.
 */

import { HttpsError } from "firebase-functions/v2/https";
import { createHash, randomBytes } from "node:crypto";

import type { Provider, ProjectMemoryFreshness, CloudVaultBlobEnvelopeDoc } from "../../types.js";
import { isRecord, stripUndefinedObject } from "../../guards.js";

const ALLOWED_PROVIDERS = new Set<string>([
  "openai",
  "minimax",
  "zai",
  "factory",
  "cursor",
  "claude-code",
  "codex",
  "opencode",
  "antigravity",
  "xai",
  "mimo",
  "kimi",
]);

export function assertProvider(provider: unknown): asserts provider is Provider {
  if (typeof provider !== "string" || !ALLOWED_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Unsupported provider "${String(provider)}". Backend connections only support: ${[...ALLOWED_PROVIDERS].join(", ")}.`,
    );
  }
}

export function nowISO(): string {
  return new Date().toISOString();
}

export function safeIdentifier(raw: unknown, prefix: string): string {
  const value = typeof raw === "string" ? raw.trim() : "";
  const safe = value
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return safe || `${prefix}_${randomBytes(8).toString("hex")}`;
}

export function requiredIdentifier(raw: unknown, fieldName: string): string {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${fieldName} is required.`);
  }
  const safe = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!safe) {
    throw new HttpsError("invalid-argument", `${fieldName} must contain letters or numbers.`);
  }
  return safe;
}

function optionalTrimmedString(raw: unknown): string | undefined {
  if (typeof raw !== "string") {
    return undefined;
  }
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

export function boundedTrimmedString(raw: unknown, fieldName: string, maxLength: number, required: true): string;
export function boundedTrimmedString(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  required?: false,
): string | undefined;
export function boundedTrimmedString(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  required = false,
): string | undefined {
  const value = optionalTrimmedString(raw);
  if (!value) {
    if (required) {
      throw new HttpsError("invalid-argument", `${fieldName} is required.`);
    }
    return undefined;
  }
  if (value.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} must be ${maxLength} characters or fewer.`);
  }
  return value;
}

export function sha256Hex(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

export function safeCloudDocumentID(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 512, true);
  if (!/^[A-Za-z0-9_.:-]+$/u.test(value) || value.includes("..") || value.includes("/")) {
    throw new HttpsError("invalid-argument", `${fieldName} contains unsupported characters.`);
  }
  return value;
}

export function requireHexDigest(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 128, true);
  if (!/^[a-f0-9]{32,128}$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a lowercase hex digest.`);
  }
  return value;
}

export function requireBoundedNumber(raw: unknown, fieldName: string, min: number, max: number): number {
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a number.`);
  }
  const rounded = Math.floor(value);
  if (rounded < min || rounded > max) {
    throw new HttpsError("invalid-argument", `${fieldName} must be between ${min} and ${max}.`);
  }
  return rounded;
}

export function requireRecordArray(raw: unknown, fieldName: string, maxLength: number): Array<Record<string, unknown>> {
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  if (raw.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} can contain at most ${maxLength} items.`);
  }
  return raw.map((item, idx) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new HttpsError("invalid-argument", `${fieldName}[${idx}] must be an object.`);
    }
    return item;
  });
}

export function requireTokenHashes(raw: unknown, fieldName: string): string[] {
  return requireSearchHashes(raw, fieldName, true);
}

export function requireOptionalSearchHashes(raw: unknown, fieldName: string): string[] {
  return requireSearchHashes(raw, fieldName, false);
}

function requireSearchHashes(raw: unknown, fieldName: string, required: boolean): string[] {
  if (raw == null && !required) return [];
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  const unique = Array.from(new Set(raw.filter((item): item is string => typeof item === "string")));
  if ((required && unique.length === 0) || unique.length > 1024) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must contain ${required ? "between 1 and" : "at most"} 1024 hashes.`,
    );
  }
  for (const hash of unique) {
    if (!/^[a-f0-9]{32}$/u.test(hash)) {
      throw new HttpsError("invalid-argument", `${fieldName} contains an invalid hash.`);
    }
  }
  return unique;
}

const CLOUD_VAULT_AAD_CONTEXT_PREFIX = "OpenBurnBar-CloudVault-aad-v2";
const ROAMING_PROFILE_AAD_DOMAIN = "OpenBurnBar-RoamingProfile-v1";

function validateCloudVaultAADPart(value: unknown, fieldName: string): string {
  const part = boundedTrimmedString(value, fieldName, 512, true);
  if (!part || /[\u0000-\u001f\u007f|]/u.test(part)) {
    throw new HttpsError("invalid-argument", `${fieldName} contains an invalid CloudVault AAD component.`);
  }
  return part;
}

export function cloudVaultAADContext(
  uid: unknown,
  collection: unknown,
  docID: unknown,
  field: unknown,
  schemaVersion: unknown = 2,
  purpose: unknown = field,
): string {
  if (typeof schemaVersion !== "number" || !Number.isInteger(schemaVersion) || schemaVersion < 2) {
    throw new HttpsError("invalid-argument", "CloudVault AAD schema version must be at least 2.");
  }
  return [
    CLOUD_VAULT_AAD_CONTEXT_PREFIX,
    validateCloudVaultAADPart(uid, "uid"),
    validateCloudVaultAADPart(collection, "collection"),
    validateCloudVaultAADPart(docID, "docID"),
    validateCloudVaultAADPart(field, "field"),
    String(schemaVersion),
    validateCloudVaultAADPart(purpose, "purpose"),
  ].join("|");
}

export function roamingProfileAADContext(uid: unknown): string {
  return cloudVaultAADContext(uid, "roaming_profile", "current", "sealedPayload", 2, ROAMING_PROFILE_AAD_DOMAIN);
}

function requireCloudVaultAAD(raw: unknown, fieldName: string, expectedAAD?: string): string {
  const aad = boundedTrimmedString(raw, fieldName, 2048, true);
  if (expectedAAD) {
    if (aad !== expectedAAD) {
      throw new HttpsError("invalid-argument", `${fieldName} does not match the CloudVault document context.`);
    }
    return aad;
  }
  if (!aad.startsWith(`${CLOUD_VAULT_AAD_CONTEXT_PREFIX}|`)) {
    throw new HttpsError("invalid-argument", `${fieldName} must use the CloudVault aad-v2 context.`);
  }
  if (!/^OpenBurnBar-CloudVault-aad-v2\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|[2-9][0-9]*\|[^|]+$/u.test(aad)) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must bind uid, collection, document, field, schema version, and purpose.`,
    );
  }
  return aad;
}

export function requireSealedText(raw: unknown, fieldName: string, expectedAAD?: string): Record<string, unknown> {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an encrypted text envelope.`);
  }
  const envelope = raw;
  const algorithm = boundedTrimmedString(envelope.algorithm, `${fieldName}.algorithm`, 64, true);
  if (algorithm !== "AES-256-GCM") {
    throw new HttpsError("invalid-argument", `${fieldName}.algorithm must be AES-256-GCM.`);
  }
  const keyVersion = requireBoundedNumber(envelope.keyVersion, `${fieldName}.keyVersion`, 1, 100);
  const schemaVersion =
    envelope.schemaVersion == null
      ? undefined
      : requireBoundedNumber(envelope.schemaVersion, `${fieldName}.schemaVersion`, 1, 10);
  const version = schemaVersion ?? 1;
  const values: Record<string, unknown> = {
    schemaVersion,
    algorithm,
    keyVersion,
  };
  for (const key of ["nonce", "ciphertext", "tag"]) {
    const value = boundedTrimmedString(envelope[key], `${fieldName}.${key}`, 8192, true);
    if (!/^[A-Za-z0-9+/=]+$/u.test(value)) {
      throw new HttpsError("invalid-argument", `${fieldName}.${key} must be base64.`);
    }
    values[key] = value;
  }
  if (version >= 2) {
    values.aad = requireCloudVaultAAD(envelope.aad, `${fieldName}.aad`, expectedAAD);
  } else if (envelope.aad != null) {
    throw new HttpsError("invalid-argument", `${fieldName}.aad is only valid on schemaVersion >= 2.`);
  }
  return stripUndefinedObject(values);
}

function requireCloudVaultSealedPayload(
  raw: unknown,
  fieldName: string,
  expectedAAD?: string,
): Record<string, unknown> {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an encrypted payload envelope.`);
  }
  const envelope = raw;
  const algorithm = boundedTrimmedString(envelope.algorithm, `${fieldName}.algorithm`, 64, true);
  if (algorithm !== "AES-256-GCM") {
    throw new HttpsError("invalid-argument", `${fieldName}.algorithm must be AES-256-GCM.`);
  }
  const schemaVersion = requireBoundedNumber(envelope.schemaVersion, `${fieldName}.schemaVersion`, 2, 10);
  const keyVersion = requireBoundedNumber(envelope.keyVersion, `${fieldName}.keyVersion`, 1, 100);
  const vaultKeyID = boundedTrimmedString(envelope.vaultKeyID, `${fieldName}.vaultKeyID`, 64, true);
  if (!/^v1_[a-f0-9]{32}$/u.test(vaultKeyID)) {
    throw new HttpsError("invalid-argument", `${fieldName}.vaultKeyID must be a CloudVault vault key id.`);
  }
  const sealedBoxBase64 = boundedTrimmedString(envelope.sealedBoxBase64, `${fieldName}.sealedBoxBase64`, 900_000, true);
  if (!/^[A-Za-z0-9+/=]+$/u.test(sealedBoxBase64)) {
    throw new HttpsError("invalid-argument", `${fieldName}.sealedBoxBase64 must be base64.`);
  }
  const aad = requireCloudVaultAAD(envelope.aad, `${fieldName}.aad`, expectedAAD);
  return {
    schemaVersion,
    algorithm,
    keyVersion,
    vaultKeyID,
    sealedBoxBase64,
    aad,
  };
}

export function requireRoamingProfileEnvelope(raw: unknown, uid: unknown): Record<string, unknown> {
  return requireCloudVaultSealedPayload(raw, "sealedPayload", roamingProfileAADContext(uid));
}

function requireISODateString(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 64, true);
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an ISO 8601 date.`);
  }
  return new Date(parsed).toISOString();
}

export function optionalISODateString(raw: unknown, fieldName: string): string | undefined {
  if (raw == null) return undefined;
  return requireISODateString(raw, fieldName);
}

export function requireBoundedStringArray(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  itemMaxLength: number,
): string[] {
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  if (raw.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} can contain at most ${maxLength} items.`);
  }
  const values = raw.map((item, idx) => boundedTrimmedString(item, `${fieldName}[${idx}]`, itemMaxLength, true));
  return Array.from(new Set(values));
}

export function parseProjectMemoryFreshness(raw: unknown): ProjectMemoryFreshness {
  const value = boundedTrimmedString(raw, "freshness", 32, false);
  if (value === "needsRefresh" || value === "stale") return value;
  return "fresh";
}

export function requireCloudVaultBlobEnvelope(
  raw: unknown,
  fieldName: string,
  expectedAAD?: string,
): CloudVaultBlobEnvelopeDoc {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an encrypted blob envelope.`);
  }
  const envelope = raw;
  const algorithm = boundedTrimmedString(envelope.algorithm, `${fieldName}.algorithm`, 64, true);
  if (algorithm !== "AES-256-GCM") {
    throw new HttpsError("invalid-argument", `${fieldName}.algorithm must be AES-256-GCM.`);
  }
  const keyVersion = requireBoundedNumber(envelope.keyVersion, `${fieldName}.keyVersion`, 1, 100);
  const schemaVersion = requireBoundedNumber(envelope.schemaVersion ?? 1, `${fieldName}.schemaVersion`, 1, 10);
  const plaintextSHA256 =
    schemaVersion === 1 ? requireHexDigest(envelope.plaintextSHA256, `${fieldName}.plaintextSHA256`) : undefined;
  const plaintextHMAC =
    schemaVersion >= 2 ? requireHexDigest(envelope.plaintextHMAC, `${fieldName}.plaintextHMAC`) : undefined;
  const integrityHashVersion =
    schemaVersion >= 2
      ? requireBoundedNumber(envelope.integrityHashVersion, `${fieldName}.integrityHashVersion`, 1, 100)
      : undefined;
  const aad = schemaVersion >= 2 ? requireCloudVaultAAD(envelope.aad, `${fieldName}.aad`, expectedAAD) : undefined;
  const sealedBoxBase64 = boundedTrimmedString(
    envelope.sealedBoxBase64,
    `${fieldName}.sealedBoxBase64`,
    1_500_000,
    true,
  );
  if (!/^[A-Za-z0-9+/=]+$/u.test(sealedBoxBase64)) {
    throw new HttpsError("invalid-argument", `${fieldName}.sealedBoxBase64 must be base64.`);
  }
  const createdAt = optionalISODateString(envelope.createdAt, `${fieldName}.createdAt`) ?? nowISO();
  return {
    schemaVersion,
    algorithm,
    keyVersion,
    plaintextSHA256,
    plaintextHMAC,
    integrityHashVersion,
    sealedBoxBase64,
    createdAt,
    aad,
  };
}

export function boundedHttpsURL(
  raw: unknown,
  fieldName: string,
  allowedNonLoopbackHosts: readonly string[] = [],
): string {
  const value = boundedTrimmedString(raw, fieldName, 2048, true);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new HttpsError("invalid-argument", `${fieldName} must be a valid URL.`);
  }
  if (url.username || url.password) {
    throw new HttpsError("invalid-argument", `${fieldName} must not include credentials.`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new HttpsError("invalid-argument", `${fieldName} must be HTTPS.`);
  }

  const rawAuthority = value.slice(value.indexOf("//") + 2).split(/[/?#]/u, 1)[0] ?? "";
  const rawHost = rawAuthority.startsWith("[")
    ? rawAuthority.slice(0, rawAuthority.indexOf("]") + 1)
    : rawAuthority.split(":", 1)[0];
  const isExactLoopback = rawHost === "localhost" || rawHost === "127.0.0.1" || rawHost === "[::1]";
  if (url.protocol !== "https:" && !isExactLoopback) {
    throw new HttpsError("invalid-argument", `${fieldName} must be HTTPS.`);
  }
  if (allowedNonLoopbackHosts.length > 0 && !isExactLoopback) {
    const allowedHosts = new Set(allowedNonLoopbackHosts.map((host) => host.trim().toLowerCase()).filter(Boolean));
    if (!allowedHosts.has(url.host.toLowerCase())) {
      throw new HttpsError("invalid-argument", `${fieldName} must use an approved redirect host.`);
    }
  }
  return url.toString();
}
