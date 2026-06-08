/**
 * @fileoverview TS mirror of the at-rest CloudVault Signal envelope TYPE.
 *
 * This is the TypeScript counterpart of the Swift `CloudVaultSignalEnvelope`
 * cluster in `OpenBurnBarCore/.../CloudVaultCrypto.swift`. It does NOT redefine
 * envelope validation — it REUSES the canonical contract in `./index.ts`
 * (`isSignalEnvelope` / `sanitizeSignalEnvelope`) and only narrows the generic
 * `SignalEnvelope` to its **at-rest** shape (`mode === "at-rest"`,
 * `binding.scope === "cloudvault"`, `keyDelivery` = per-recipient wraps).
 *
 * TYPE + RECOGNIZER ONLY, additive and flag-OFF. There is no sealing here:
 * producing the ciphertext + per-recipient `sealedContentKeyB64` wraps requires
 * the official libsignal binding (not yet vendored). The server/exporter treats
 * the envelope as OPAQUE-AND-EXPORTABLE via the shared sanitizers; this module
 * just gives callers a precise at-rest type and a thin recognizer.
 */

import {
  isSignalEnvelope,
  sanitizeSignalEnvelope,
  SIGNAL_AT_REST_ENCRYPTION,
  type SignalAtRestKeyDelivery,
  type SignalBinding,
  type SignalCiphertextLayer,
  type SignalEnvelope,
} from "./index.js";

/**
 * The CloudVault at-rest binding: a `SignalBinding` pinned to the `cloudvault`
 * scope + `at-rest` mode. The document coordinates are present and the
 * gateway-only `clientId`/`slotId` are absent (enforced by `sanitizeBinding`).
 */
export type CloudVaultSignalBinding = SignalBinding & {
  scope: "cloudvault";
  mode: "at-rest";
  collection: string;
  docId: string;
  field: string;
};

/**
 * The at-rest CloudVault Signal envelope. A `SignalEnvelope` narrowed to its
 * at-rest variant: the at-rest `relayEncryption` scheme, the per-recipient
 * `wraps` key delivery, and a `cloudvault`-scoped binding. `relayKeyVersion` is
 * intentionally absent for at-rest (the contract rejects it on `at-rest`).
 */
export interface CloudVaultSignalEnvelope extends SignalEnvelope {
  mode: "at-rest";
  relayEncryption: typeof SIGNAL_AT_REST_ENCRYPTION;
  ciphertextLayer: SignalCiphertextLayer;
  keyDelivery: SignalAtRestKeyDelivery;
  binding: CloudVaultSignalBinding;
}

/**
 * Strict, fail-closed recognizer for an at-rest CloudVault Signal envelope.
 * Delegates to the canonical contract (`isSignalEnvelope(value, "at-rest")`) and
 * additionally requires the `cloudvault` scope, so a gateway transport envelope
 * can never be mistaken for a CloudVault one. Returns a precise type guard.
 */
export function isCloudVaultSignalEnvelope(value: unknown): value is CloudVaultSignalEnvelope {
  if (!isSignalEnvelope(value, "at-rest")) return false;
  const sanitized = sanitizeSignalEnvelope(value, "at-rest");
  return sanitized !== undefined && sanitized.binding.scope === "cloudvault";
}

/**
 * Validate + canonicalize an at-rest CloudVault Signal envelope, or `undefined`
 * if it is not a strict, `cloudvault`-scoped at-rest envelope. Thin wrapper over
 * the shared sanitizer; reuses every validation rule in the contract.
 */
export function sanitizeCloudVaultSignalEnvelope(value: unknown): CloudVaultSignalEnvelope | undefined {
  const sanitized = sanitizeSignalEnvelope(value, "at-rest");
  if (!sanitized || sanitized.binding.scope !== "cloudvault") return undefined;
  return sanitized as CloudVaultSignalEnvelope;
}
