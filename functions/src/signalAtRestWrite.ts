/**
 * @fileoverview Admin-SDK structural validator for at-rest CloudVault Signal
 * envelopes written through callables.
 *
 * The Firebase Admin SDK BYPASSES Firestore security rules, so any callable that
 * persists a `signalEnvelope` field cannot rely on `validSignalAtRestEnvelope` in
 * `firestore.rules` — it MUST run the value through
 * {@link validateSignalAtRestEnvelopeForWrite} with the caller-derived EXPECTED
 * path coordinates BEFORE the admin write. This is the server half of L23 + L37.
 *
 * Firestore rules intentionally reject direct client `signalEnvelope` writes because
 * rules cannot iterate a list and deep-validate every recipient wrap
 * (recipientKind/id + base64 identity key + sealed content key). This validator is
 * the only server-side path allowed to persist at-rest Signal envelopes, and it does
 * that deep validation via the shared {@link sanitizeCloudVaultSignalEnvelope}
 * sanitizer before the Admin SDK write.
 *
 * The server NEVER decrypts. It only proves (a) the strict at-rest CloudVault
 * shape and (b) that the binding is pinned to the EXACT doc path
 * (uid/collection/docId/field) — never trusting `envelope.binding` — so a relay or
 * a compromised/ buggy server cannot move a sealed value between users, docs,
 * fields, or modes (relocation). Plaintext, wrong shape, and a relocated binding
 * all fail closed.
 */

import {
  bindingToAAD,
  sanitizeCloudVaultSignalEnvelope,
  type CloudVaultSignalEnvelope,
} from "@openburnbar/signal-envelope-contracts";

/**
 * Nominal "this value came out of the validator" brand (Remediation R7). A raw
 * `CloudVaultSignalEnvelope` — or unknown user input — is NOT assignable to
 * `SanitizedSignalEnvelope`; only {@link validateSignalAtRestEnvelopeForWrite} mints
 * one, via the single cast at its success return. A future producer that types the
 * value it persists as `SanitizedSignalEnvelope` therefore CANNOT accidentally write
 * the raw input (that becomes a compile error), closing the "persist `result.envelope`,
 * not the raw value" hole that was previously enforced only by this doc comment.
 */
declare const SANITIZED_SIGNAL_ENVELOPE_BRAND: unique symbol;
export type SanitizedSignalEnvelope = CloudVaultSignalEnvelope & {
  readonly [SANITIZED_SIGNAL_ENVELOPE_BRAND]: true;
};

/** Caller-derived expected path coordinates the envelope binding must equal. */
export interface SignalAtRestExpectedBinding {
  uid: string;
  collection: string;
  docId: string;
  field: string;
}

export type SignalAtRestWriteRejectReason =
  | "not-an-object"
  | "invalid-envelope-shape"
  | "binding-uid-mismatch"
  | "binding-collection-mismatch"
  | "binding-docid-mismatch"
  | "binding-field-mismatch";

export type SignalAtRestWriteValidation =
  | { ok: true; envelope: SanitizedSignalEnvelope; aad: string }
  | { ok: false; reason: SignalAtRestWriteRejectReason };

/**
 * Validate an at-rest CloudVault Signal envelope for an Admin-SDK write. Returns a
 * discriminated result (pure, no throwing) so call-sites can map a rejection to the
 * appropriate `HttpsError` and log the reason. On success it also returns the
 * canonical AAD derived from the (now path-verified) binding.
 */
export function validateSignalAtRestEnvelopeForWrite(
  value: unknown,
  expected: SignalAtRestExpectedBinding,
): SignalAtRestWriteValidation {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, reason: "not-an-object" };
  }

  // Deep structural validation incl. per-wrap base64/kind/id — the part Firestore
  // rules cannot do. Returns undefined for any non-strict-at-rest shape (plaintext,
  // transport, polluted keys, oversize, bad base64, gateway binding, …).
  const envelope = sanitizeCloudVaultSignalEnvelope(value);
  if (!envelope) return { ok: false, reason: "invalid-envelope-shape" };

  // Path-binding (L37): compare the binding against caller-derived EXPECTED
  // coordinates, never trusting the envelope's self-declared location. scope/mode
  // are already pinned to cloudvault/at-rest by the sanitizer.
  if (envelope.binding.uid !== expected.uid) {
    return { ok: false, reason: "binding-uid-mismatch" };
  }
  if (envelope.binding.collection !== expected.collection) {
    return { ok: false, reason: "binding-collection-mismatch" };
  }
  if (envelope.binding.docId !== expected.docId) {
    return { ok: false, reason: "binding-docid-mismatch" };
  }
  if (envelope.binding.field !== expected.field) {
    return { ok: false, reason: "binding-field-mismatch" };
  }

  // Derive the canonical AAD from the (path-verified) binding. Identical to the
  // value a trusted device recomputes from its own expected path when re-opening.
  const aad = bindingToAAD(envelope.binding);
  // The single trusted boundary that mints the brand: `envelope` is the
  // reconstructed/sanitized object (known keys only), not the raw caller input.
  return { ok: true, envelope: envelope as SanitizedSignalEnvelope, aad };
}

/** Stable error thrown by {@link assertSignalAtRestEnvelopeForWrite}. */
export class SignalAtRestWriteError extends Error {
  readonly reason: SignalAtRestWriteRejectReason;

  constructor(reason: SignalAtRestWriteRejectReason) {
    super(`Signal at-rest envelope rejected before admin write: ${reason}`);
    this.name = "SignalAtRestWriteError";
    this.reason = reason;
  }
}

/**
 * Throwing wrapper for callables: returns the sanitized envelope + canonical AAD,
 * or throws {@link SignalAtRestWriteError}. Call-sites map this to an
 * `invalid-argument` HttpsError; the server never writes an unvalidated or
 * relocated envelope.
 */
export function assertSignalAtRestEnvelopeForWrite(
  value: unknown,
  expected: SignalAtRestExpectedBinding,
): { envelope: SanitizedSignalEnvelope; aad: string } {
  const result = validateSignalAtRestEnvelopeForWrite(value, expected);
  if (!result.ok) {
    throw new SignalAtRestWriteError(result.reason);
  }
  return { envelope: result.envelope, aad: result.aad };
}
