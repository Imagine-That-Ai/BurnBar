import { createHash } from "node:crypto";
import { PublicError } from "./errors.js";

export type JsonObject = Record<string, unknown>;

export function object(value: unknown, name: string): JsonObject {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new PublicError(400, "bad_request", `${name} must be an object`);
  }
  return value as JsonObject;
}

export function exactKeys(value: JsonObject, allowed: readonly string[], name: string): void {
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!allowedSet.has(key)) throw new PublicError(400, "bad_request", `${name} has unsupported fields`);
  }
}

export function string(value: unknown, name: string, max = 512): string {
  if (typeof value !== "string" || value.length === 0 || value.length > max) {
    throw new PublicError(400, "bad_request", `${name} is invalid`);
  }
  return value;
}

export function identifier(value: unknown, name: string): string {
  const result = string(value, name, 128);
  if (!/^[A-Za-z0-9._:-]+$/.test(result)) throw new PublicError(400, "bad_request", `${name} is invalid`);
  return result;
}

export function brokerLabel(value: unknown, name: string, max = 160): string {
  const result = string(value, name, max);
  if (!/^[A-Za-z0-9._:+/=-]+$/.test(result)) throw new PublicError(400, "bad_request", `${name} is invalid`);
  return result;
}

export function integer(value: unknown, name: string, min: number, max: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < min || (value as number) > max) {
    throw new PublicError(400, "bad_request", `${name} is invalid`);
  }
  return value as number;
}

export function sha256Hex(value: unknown, name: string): string {
  const result = string(value, name, 64);
  if (!/^[a-f0-9]{64}$/.test(result)) throw new PublicError(400, "bad_request", `${name} is invalid`);
  return result;
}

export function base64(value: unknown, name: string, maxDecodedBytes: number): string {
  const result = string(value, name, Math.ceil(maxDecodedBytes * 4 / 3) + 4);
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(result)) {
    throw new PublicError(400, "bad_request", `${name} is invalid`);
  }
  const decoded = Buffer.from(result, "base64");
  if (decoded.byteLength > maxDecodedBytes || decoded.toString("base64") !== result) {
    throw new PublicError(400, "bad_request", `${name} is invalid`);
  }
  return result;
}

export function base64url(value: unknown, name: string, maxDecodedBytes: number): string {
  const result = string(value, name, Math.ceil(maxDecodedBytes * 4 / 3));
  if (!/^[A-Za-z0-9_-]+$/.test(result)) throw new PublicError(400, "bad_request", `${name} is invalid`);
  const decoded = Buffer.from(result, "base64url");
  if (decoded.byteLength === 0 || decoded.byteLength > maxDecodedBytes || decoded.toString("base64url") !== result) {
    throw new PublicError(400, "bad_request", `${name} is invalid`);
  }
  return result;
}

export function sha256(data: string | Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

export function parseJsonBuffer(buffer: Buffer, name: string): unknown {
  try {
    return JSON.parse(buffer.toString("utf8")) as unknown;
  } catch {
    throw new PublicError(400, "bad_request", `${name} must be valid JSON`);
  }
}
