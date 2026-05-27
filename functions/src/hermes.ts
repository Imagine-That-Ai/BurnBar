import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { HttpsError } from "firebase-functions/v2/https";

import type {
  HermesConnectionDoc,
  HermesConnectionMode,
  HermesPairingDoc,
} from "./types.js";
import { isRecord, recordOrUndefined } from "./guards.js";

export function randomPairingCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = randomBytes(8);
  const chars = Array.from(bytes, (byte) => alphabet[byte % alphabet.length]);
  return `${chars.slice(0, 4).join("")}-${chars.slice(4).join("")}`;
}

export function pairingCodeDigest(code: string): string {
  const canonical = code.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
  return createHash("sha256").update(canonical).digest("hex");
}

export function safeEqualHex(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left, "hex");
  const rightBuffer = Buffer.from(right, "hex");
  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }
  return timingSafeEqual(leftBuffer, rightBuffer);
}

export function parseHermesConnectionMode(raw: unknown): HermesConnectionMode {
  if (raw === "local" || raw === "directURL" || raw === "relayLink") {
    return raw;
  }
  throw new HttpsError("invalid-argument", "mode must be local, directURL, or relayLink.");
}

export function parseHermesPlatform(raw: unknown): HermesPairingDoc["requestedByPlatform"] | undefined {
  if (raw === undefined || raw === null || raw === "") {
    return undefined;
  }
  if (raw === "ios" || raw === "ipados" || raw === "macos" || raw === "web") {
    return raw;
  }
  throw new HttpsError("invalid-argument", "platform must be ios, ipados, macos, or web.");
}

export function sanitizeHermesCapabilities(raw: unknown): string[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0 && item.length <= 64)
    .slice(0, 32);
}

export function validateHermesEndpointURL(raw: unknown, mode: HermesConnectionMode): string | undefined {
  const value = boundedTrimmedString(raw, "endpointURL", 2048, mode === "directURL");
  if (!value) {
    return undefined;
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new HttpsError("invalid-argument", "endpointURL must be a valid URL.");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new HttpsError("invalid-argument", "endpointURL must not include credentials, query strings, or fragments.");
  }
  const scheme = url.protocol.replace(":", "").toLowerCase();
  const host = url.hostname.toLowerCase();
  const isLocalhost = host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]";
  if (scheme === "https" || (scheme === "http" && (isLocalhost || isPrivateIPv4(host)))) {
    url.pathname = url.pathname.replace(/\/+$/, "");
    return url.toString().replace(/\/$/, "");
  }
  throw new HttpsError("invalid-argument", "Use HTTPS, or HTTP only for localhost/private LAN Hermes hosts.");
}

export function isHermesConnectionDoc(doc: unknown): doc is HermesConnectionDoc {
  const record = recordOrUndefined(doc);
  if (!record) return false;
  return typeof record.id === "string"
    && typeof record.displayName === "string"
    && (record.mode === "local" || record.mode === "directURL" || record.mode === "relayLink")
    && (record.status === "pending"
      || record.status === "online"
      || record.status === "offline"
      || record.status === "unauthorized"
      || record.status === "revoked"
      || record.status === "degraded")
    && Array.isArray(record.capabilities)
    && typeof record.createdAt === "string"
    && typeof record.updatedAt === "string"
    && typeof record.schemaVersion === "number";
}

export function parseHermesPairingDoc(raw: unknown): HermesPairingDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  if (
    typeof record.id !== "string" ||
    typeof record.codeHash !== "string" ||
    typeof record.expiresAt !== "string" ||
    (record.status !== "pending" &&
      record.status !== "completed" &&
      record.status !== "expired" &&
      record.status !== "revoked") ||
    typeof record.createdAt !== "string" ||
    typeof record.updatedAt !== "string" ||
    typeof record.schemaVersion !== "number"
  ) {
    return undefined;
  }
  return {
    id: record.id,
    codeHash: record.codeHash,
    expiresAt: record.expiresAt,
    status: record.status,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    schemaVersion: record.schemaVersion,
    displayName: typeof record.displayName === "string" ? record.displayName : undefined,
    connectionId: typeof record.connectionId === "string" ? record.connectionId : undefined,
    failedAttempts: typeof record.failedAttempts === "number" ? record.failedAttempts : undefined,
    requestedByDeviceId:
      typeof record.requestedByDeviceId === "string" ? record.requestedByDeviceId : undefined,
    requestedByPlatform:
      record.requestedByPlatform === "ios" ||
      record.requestedByPlatform === "ipados" ||
      record.requestedByPlatform === "macos" ||
      record.requestedByPlatform === "web"
        ? record.requestedByPlatform
        : undefined,
  };
}

export function requireHermesPairingDoc(raw: unknown): HermesPairingDoc {
  const doc = parseHermesPairingDoc(raw);
  if (!doc) {
    throw new HttpsError("internal", "Corrupt Hermes pairing document.");
  }
  return doc;
}

function optionalTrimmedString(raw: unknown): string | undefined {
  if (typeof raw !== "string") {
    return undefined;
  }
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

function boundedTrimmedString(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  required = false
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

function isPrivateIPv4(host: string): boolean {
  const parts = host.split(".").map((part) => Number.parseInt(part, 10));
  if (parts.length !== 4 || parts.some((part) => Number.isNaN(part) || part < 0 || part > 255)) {
    return false;
  }
  const [first, second] = parts;
  return first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168);
}
