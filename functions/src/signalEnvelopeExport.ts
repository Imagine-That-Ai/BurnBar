/**
 * @fileoverview Seal-aware export helpers for future official-libsignal envelopes.
 *
 * The server never decrypts Signal envelopes. These helpers only verify the
 * strict shape and strip any nested plaintext-adjacent junk before data export.
 */

import {
  isSignalEnvelope,
  sanitizeSignalEnvelopeForExport as sanitizeSharedSignalEnvelopeForExport,
} from "@openburnbar/signal-envelope-contracts";

export function isGatewaySignalEnvelope(value: unknown): boolean {
  return isSignalEnvelope(value);
}

export function sanitizeSignalEnvelopeForExport(
  path: string,
  envelope: Record<string, unknown>,
): {
  out: unknown;
  dropped: string[];
} {
  return sanitizeSharedSignalEnvelopeForExport(path, envelope);
}
