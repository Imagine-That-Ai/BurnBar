import type { DaemonSubscriptionTopic } from './tauriBridgeTypes.js';

//
// The daemon returns JSON whose exact field names depend on Swift Codable
// serialization. These mappers are defensive: they read the fields they know
// about, fall back to zero/empty, and never throw.  The jsdom test suite
// exercises fixture mode (no bridge) so only the packaged Tauri runtime calls
// these — a mismatched field name degrades to empty data rather than crashing.

export type RawJsonValue = unknown;

export function num(v: RawJsonValue, fallback = 0): number {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v) : NaN;
  return Number.isFinite(n) ? n : fallback;
}

export function str(v: RawJsonValue, fallback = ''): string {
  return typeof v === 'string' ? v : fallback;
}

export function arr(v: RawJsonValue): RawJsonValue[] {
  return Array.isArray(v) ? v : [];
}

export function obj(v: RawJsonValue): Record<string, RawJsonValue> {
  return v && typeof v === 'object' && !Array.isArray(v)
    ? v as Record<string, RawJsonValue>
    : {};
}

export function pick(v: RawJsonValue, ...keys: string[]): RawJsonValue {
  if (v && typeof v === 'object') {
    const o = v as Record<string, RawJsonValue>;
    for (const k of keys) {
      if (k in o) return o[k];
    }
  }
  return undefined;
}

export function requireObject(v: RawJsonValue, label: string): Record<string, RawJsonValue> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) {
    throw new Error(`${label} must be an object.`);
  }
  return v as Record<string, RawJsonValue>;
}

export function requireString(v: RawJsonValue, label: string): string {
  if (typeof v !== 'string' || v.length === 0) {
    throw new Error(`${label} must be a non-empty string.`);
  }
  return v;
}

export function requireBoolean(v: RawJsonValue, label: string): boolean {
  if (typeof v !== 'boolean') throw new Error(`${label} must be a boolean.`);
  return v;
}

export function optionalBoolean(v: RawJsonValue, label: string, fallback = false): boolean {
  if (v === undefined || v === null) return fallback;
  return requireBoolean(v, label);
}

export function requireSequence(v: RawJsonValue, label: string): number {
  if (typeof v !== 'number' || !Number.isSafeInteger(v) || v < 0) {
    throw new Error(`${label} must be a non-negative safe integer.`);
  }
  return v;
}

export function decodeSubscriptionTopic(v: RawJsonValue): DaemonSubscriptionTopic {
  if (v === 'data' || v === 'health' || v === 'run') return v;
  throw new Error('subscription.topic is unsupported.');
}
