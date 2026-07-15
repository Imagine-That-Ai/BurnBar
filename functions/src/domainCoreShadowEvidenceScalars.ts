import { HttpsError } from "firebase-functions/v2/https";

export const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const CORE_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/u;
export const CANONICAL_CORE_VERSION =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;
export const GIT_COMMIT = /^[0-9a-f]{40}$/u;
export const SHA256 = /^[0-9a-f]{64}$/u;

export function exactKeys(record: Record<string, unknown>, expected: readonly string[], label: string): void {
  const actual = Object.keys(record).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new HttpsError("invalid-argument", `${label} has an invalid field set.`);
  }
}

export function boundedMicros(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > 600_000_000) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

export function coreAbiVersion(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1 || value > 0xffff_ffff) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

export function coreVersion(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length > 64 || !CORE_VERSION.test(value)) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

export function canonicalCoreVersion(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length > 64 || !CANONICAL_CORE_VERSION.test(value)) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}

export function sourceSha256(value: unknown, label: string): string {
  if (typeof value !== "string" || !SHA256.test(value)) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return value;
}