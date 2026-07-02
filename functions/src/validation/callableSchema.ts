/**
 * @fileoverview Declarative input schema for Cloud Function callables.
 *
 * A tiny, dependency-free schema layer that sits on top of the existing
 * `HttpsError("invalid-argument", ...)` field validators in
 * `callables/shared/validators.ts`. A callable declares the shape of its
 * `request.data` payload once and parses + validates it in a single call
 * ({@link parseCallableInput}) instead of pulling fields out ad hoc.
 *
 * Every rejection is a `functions/invalid-argument` HttpsError carrying the same
 * field-level messages the hand-rolled helpers already emit, so wrapping an
 * existing callable is behaviour-preserving (the client-visible error contract
 * does not drift). Two hardening guarantees are added on top:
 *   1. A non-object top-level payload (array / string / number) is rejected up
 *      front instead of silently reading `undefined` off it.
 *   2. Only declared fields are read; unknown keys are never forwarded, and can
 *      be rejected outright with `{ rejectUnknownKeys: true }`.
 *
 * No third-party dependency (deliberately not zod): the backend already
 * standardizes on the HttpsError validator idiom, this reuses it verbatim, and
 * it adds zero runtime surface to the deployed Functions bundle — which matters
 * for a production callable that must not gain a new supply-chain / cold-start
 * dependency mid-flight.
 */

import { HttpsError } from "firebase-functions/v2/https";

import {
  boundedHttpsURL,
  boundedTrimmedString,
  requireBoundedNumber,
  requireBoundedStringArray,
  requireHexDigest,
} from "../callables/shared/validators.js";

/** Default max length applied to string fields that do not set one explicitly. */
const DEFAULT_STRING_MAX_LENGTH = 1024;
/** Default max length applied to enum tokens (short discriminators). */
const DEFAULT_ENUM_MAX_LENGTH = 64;

/**
 * One field in a callable schema: validates a single raw value pulled from the
 * request payload and throws `HttpsError("invalid-argument")` on failure.
 */
type CallableInputValue = string | number | boolean | string[] | undefined;

interface CallableField<T extends CallableInputValue = CallableInputValue> {
  /** True when the field may be omitted (absent / null / empty) without error. */
  readonly optional: boolean;
  /** Validate one field value; throws `HttpsError("invalid-argument")` on failure. */
  parse(raw: unknown, fieldName: string): T;
}

/** A callable input schema: field name → field validator. */
type CallableSchema = Record<string, CallableField>;

interface StringFieldOptions {
  readonly maxLength?: number;
  /** Optional format constraint applied after trimming + length checks. */
  readonly pattern?: RegExp;
  /** Message used when `pattern` fails; defaults to a generic format error. */
  readonly patternMessage?: string;
}

function applyPattern(value: string, fieldName: string, options: StringFieldOptions): string {
  if (options.pattern && !options.pattern.test(value)) {
    throw new HttpsError("invalid-argument", options.patternMessage ?? `${fieldName} has an invalid format.`);
  }
  return value;
}

/** Required, trimmed, length-bounded string (optionally format-constrained). */
export function requiredString(options: StringFieldOptions = {}): CallableField<string> {
  const maxLength = options.maxLength ?? DEFAULT_STRING_MAX_LENGTH;
  return {
    optional: false,
    parse(raw, fieldName) {
      return applyPattern(boundedTrimmedString(raw, fieldName, maxLength, true), fieldName, options);
    },
  };
}

/** Optional, trimmed, length-bounded string; absent / empty ⇒ `undefined`. */
export function optionalString(options: StringFieldOptions = {}): CallableField<string | undefined> {
  const maxLength = options.maxLength ?? DEFAULT_STRING_MAX_LENGTH;
  return {
    optional: true,
    parse(raw, fieldName) {
      const value = boundedTrimmedString(raw, fieldName, maxLength, false);
      return value === undefined ? undefined : applyPattern(value, fieldName, options);
    },
  };
}

interface EnumFieldOptions {
  readonly maxLength?: number;
  /** Override the rejection message (e.g. to match a legacy contract). */
  readonly message?: string;
}

function enumRejection(values: readonly string[], fieldName: string, options: EnumFieldOptions): never {
  throw new HttpsError("invalid-argument", options.message ?? `${fieldName} must be one of: ${values.join(", ")}.`);
}

/** Required string constrained to one of `values` (trimmed before matching). */
export function enumField(
  values: readonly string[],
  options: EnumFieldOptions = {},
): CallableField<string> {
  const maxLength = options.maxLength ?? DEFAULT_ENUM_MAX_LENGTH;
  const allowed = new Set<string>(values);
  return {
    optional: false,
    parse(raw, fieldName) {
      const value = boundedTrimmedString(raw, fieldName, maxLength, true);
      if (!allowed.has(value)) enumRejection(values, fieldName, options);
      return value;
    },
  };
}

/** Optional enum; absent / empty ⇒ `undefined`, else must be one of `values`. */
export function optionalEnumField(
  values: readonly string[],
  options: EnumFieldOptions = {},
): CallableField<string | undefined> {
  const maxLength = options.maxLength ?? DEFAULT_ENUM_MAX_LENGTH;
  const allowed = new Set<string>(values);
  return {
    optional: true,
    parse(raw, fieldName) {
      const value = boundedTrimmedString(raw, fieldName, maxLength, false);
      if (value === undefined) return undefined;
      if (!allowed.has(value)) enumRejection(values, fieldName, options);
      return value;
    },
  };
}

/** Required finite integer clamped to `[min, max]` (floored, like the helper). */
export function boundedInt(options: { min: number; max: number }): CallableField<number> {
  return {
    optional: false,
    parse(raw, fieldName) {
      return requireBoundedNumber(raw, fieldName, options.min, options.max);
    },
  };
}

/** Required boolean; anything non-boolean is rejected. */
export function booleanField(): CallableField<boolean> {
  return {
    optional: false,
    parse(raw, fieldName) {
      if (typeof raw !== "boolean") {
        throw new HttpsError("invalid-argument", `${fieldName} must be a boolean.`);
      }
      return raw;
    },
  };
}

/** Required HTTPS (or loopback) URL, credential-free — see `boundedHttpsURL`. */
export function httpsUrlField(): CallableField<string> {
  return {
    optional: false,
    parse(raw, fieldName) {
      return boundedHttpsURL(raw, fieldName);
    },
  };
}

/** Required lowercase hex digest (32–128 chars) — see `requireHexDigest`. */
export function hexDigestField(): CallableField<string> {
  return {
    optional: false,
    parse(raw, fieldName) {
      return requireHexDigest(raw, fieldName);
    },
  };
}

/** Required array of trimmed, length-bounded, de-duplicated strings. */
export function boundedStringArrayField(options: {
  maxLength: number;
  itemMaxLength: number;
}): CallableField<string[]> {
  return {
    optional: false,
    parse(raw, fieldName) {
      return requireBoundedStringArray(raw, fieldName, options.maxLength, options.itemMaxLength);
    },
  };
}

interface ParseCallableInputOptions {
  /**
   * Reject payloads that carry keys the schema does not declare. Defaults to
   * `false` (unknown keys are ignored and never forwarded) so hardening an
   * existing callable can never break a client that sends extra fields.
   */
  readonly rejectUnknownKeys?: boolean;
}

function coercePayloadObject(data: unknown): object {
  if (data === undefined || data === null) return {};
  if (typeof data !== "object" || Array.isArray(data)) {
    throw new HttpsError("invalid-argument", "Request payload must be a JSON object.");
  }
  return data;
}

function readPayloadField(data: object, fieldName: string): unknown {
  return Reflect.get(data, fieldName);
}

/**
 * Validate `data` against `schema` and return the typed payload.
 *
 * @param callableName Name of the callable, used only in the unknown-field
 *   rejection message so operators can locate the offending call site.
 * @throws HttpsError `invalid-argument` for a non-object payload, an unknown key
 *   (when `rejectUnknownKeys` is set), or any field that fails its validator.
 */
export function parseCallableInput(
  callableName: string,
  schema: CallableSchema,
  data: unknown,
  options: ParseCallableInputOptions = {},
): Record<string, CallableInputValue> {
  const payload = coercePayloadObject(data);
  if (options.rejectUnknownKeys) {
    for (const key of Object.keys(payload)) {
      if (!Object.prototype.hasOwnProperty.call(schema, key)) {
        throw new HttpsError("invalid-argument", `${callableName}: unexpected field "${key}".`);
      }
    }
  }
  const parsed: Record<string, CallableInputValue> = {};
  for (const [field, spec] of Object.entries(schema)) {
    parsed[field] = spec.parse(readPayloadField(payload, field), field);
  }
  return parsed;
}
