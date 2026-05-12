import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { HttpsError } from "firebase-functions/v2/https";

import type {
  PiAgentConnectionDoc,
  PiAgentConnectionMode,
  PiAgentPairingDoc,
  PiAgentInstanceDoc,
  PiAgentRuntimeModelDoc,
} from "./types.js";

export function randomPiAgentPairingCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = randomBytes(8);
  const chars = Array.from(bytes, (byte) => alphabet[byte % alphabet.length]);
  return `${chars.slice(0, 4).join("")}-${chars.slice(4).join("")}`;
}

export function piAgentPairingCodeDigest(code: string): string {
  const canonical = code.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
  return createHash("sha256").update(canonical).digest("hex");
}

export function piAgentSafeEqualHex(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left, "hex");
  const rightBuffer = Buffer.from(right, "hex");
  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }
  return timingSafeEqual(leftBuffer, rightBuffer);
}

export function parsePiAgentConnectionMode(raw: unknown): PiAgentConnectionMode {
  if (raw === "local" || raw === "directURL" || raw === "relayLink") {
    return raw;
  }
  throw new HttpsError("invalid-argument", "mode must be local, directURL, or relayLink.");
}

export function parsePiAgentPlatform(raw: unknown): PiAgentPairingDoc["requestedByPlatform"] | undefined {
  if (raw === undefined || raw === null || raw === "") {
    return undefined;
  }
  if (raw === "ios" || raw === "ipados" || raw === "android" || raw === "macos" || raw === "web") {
    return raw;
  }
  throw new HttpsError("invalid-argument", "platform must be ios, ipados, android, macos, or web.");
}

export function sanitizePiAgentCapabilities(raw: unknown): string[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0 && item.length <= 64)
    .slice(0, 32);
}

export function sanitizePiAgentInstances(raw: unknown): PiAgentInstanceDoc[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.flatMap((item): PiAgentInstanceDoc[] => {
    if (!item || typeof item !== "object") return [];
    const value = item as Record<string, unknown>;
    const id = boundedTrimmedString(value.id, "instance.id", 128);
    const displayName = boundedTrimmedString(value.displayName, "instance.displayName", 120);
    if (!id || !displayName) return [];
    const status = parseOptionalPiAgentStatus(value.status) ?? "offline";
    return [{
      id,
      displayName,
      endpointURL: validateOptionalEndpointURL(value.endpointURL),
      status,
      modelName: boundedTrimmedString(value.modelName, "instance.modelName", 160),
      capabilities: sanitizePiAgentCapabilities(value.capabilities),
      lastSeenAt: boundedTrimmedString(value.lastSeenAt, "instance.lastSeenAt", 80),
      schemaVersion: typeof value.schemaVersion === "number" ? value.schemaVersion : 1,
    }];
  }).slice(0, 32);
}

export function sanitizePiAgentModels(raw: unknown): PiAgentRuntimeModelDoc[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.flatMap((item): PiAgentRuntimeModelDoc[] => {
    if (!item || typeof item !== "object") return [];
    const value = item as Record<string, unknown>;
    const modelID = boundedTrimmedString(value.modelID, "model.modelID", 160);
    const providerID = boundedTrimmedString(value.providerID, "model.providerID", 80) ?? "pi";
    if (!modelID) return [];
    return [{
      id: boundedTrimmedString(value.id, "model.id", 240) ?? `${providerID}:${modelID}`,
      providerID,
      providerName: boundedTrimmedString(value.providerName, "model.providerName", 120) ?? "Pi",
      modelID,
      displayName: boundedTrimmedString(value.displayName, "model.displayName", 160) ?? modelID,
      instanceID: boundedTrimmedString(value.instanceID, "model.instanceID", 128),
      schemaVersion: typeof value.schemaVersion === "number" ? value.schemaVersion : 1,
    }];
  }).slice(0, 128);
}

export function validatePiAgentEndpointURL(raw: unknown, mode: PiAgentConnectionMode): string | undefined {
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
  throw new HttpsError("invalid-argument", "Use HTTPS, or HTTP only for localhost/private LAN Pi Agent hosts.");
}

export function isPiAgentConnectionDoc(doc: Partial<PiAgentConnectionDoc>): doc is PiAgentConnectionDoc {
  return typeof doc.id === "string"
    && typeof doc.displayName === "string"
    && (doc.mode === "local" || doc.mode === "directURL" || doc.mode === "relayLink")
    && (doc.status === "pending"
      || doc.status === "online"
      || doc.status === "offline"
      || doc.status === "unauthorized"
      || doc.status === "revoked"
      || doc.status === "degraded")
    && Array.isArray(doc.capabilities)
    && typeof doc.createdAt === "string"
    && typeof doc.updatedAt === "string"
    && typeof doc.schemaVersion === "number";
}

function parseOptionalPiAgentStatus(raw: unknown): PiAgentConnectionDoc["status"] | undefined {
  if (
    raw === "pending" ||
    raw === "online" ||
    raw === "offline" ||
    raw === "unauthorized" ||
    raw === "revoked" ||
    raw === "degraded"
  ) {
    return raw;
  }
  return undefined;
}

function validateOptionalEndpointURL(raw: unknown): string | undefined {
  if (raw === undefined || raw === null || raw === "") {
    return undefined;
  }
  return validatePiAgentEndpointURL(raw, "directURL");
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
