/**
 * @fileoverview Seal-aware export helpers for future official-libsignal envelopes.
 *
 * The server never decrypts Signal envelopes. These helpers only verify the
 * strict shape and strip any nested plaintext-adjacent junk before data export.
 */

import * as signalEnvelopeContracts from "@openburnbar/signal-envelope-contracts";

const { isCloudVaultSignalEnvelope, isSignalEnvelope } = signalEnvelopeContracts;

/**
 * Recognize ANY strict Signal envelope (gateway transport OR CloudVault at-rest)
 * so the seal-aware exporter treats it as opaque-and-exportable. The shared
 * `isSignalEnvelope` with no `expectedMode` accepts both modes; both are pure
 * ciphertext to the server, so both export verbatim after nested default-deny.
 */
export function isGatewaySignalEnvelope(value: unknown): boolean {
  return isSignalEnvelope(value);
}

/**
 * Explicit recognizer for the at-rest CloudVault self/group seal
 * (`mode === "at-rest"`, `binding.scope === "cloudvault"`). Reuses the shared
 * contract via `isCloudVaultSignalEnvelope` — never reinvents envelope
 * validation. The server never decrypts it; this just confirms the strict shape
 * so the at-rest envelope is exported opaquely with its plaintext-adjacent keys
 * stripped (via `sanitizeSignalEnvelopeForExport`). Default-deny is preserved:
 * anything failing this guard still falls through to the field allowlist.
 */
export function isAtRestSignalEnvelope(value: unknown): boolean {
  return isCloudVaultSignalEnvelope(value);
}

export function sanitizeSignalEnvelopeForExport(
  path: string,
  envelope: Record<string, unknown>,
): {
  out: unknown;
  dropped: string[];
} {
  return signalEnvelopeContracts.sanitizeSignalEnvelopeForExport(path, envelope);
}
