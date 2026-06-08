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
import { isSignalEnvelope, sanitizeSignalEnvelope, } from "./index.js";
/**
 * Strict, fail-closed recognizer for an at-rest CloudVault Signal envelope.
 * Delegates to the canonical contract (`isSignalEnvelope(value, "at-rest")`) and
 * additionally requires the `cloudvault` scope, so a gateway transport envelope
 * can never be mistaken for a CloudVault one. Returns a precise type guard.
 */
export function isCloudVaultSignalEnvelope(value) {
    if (!isSignalEnvelope(value, "at-rest"))
        return false;
    const sanitized = sanitizeSignalEnvelope(value, "at-rest");
    return sanitized !== undefined && sanitized.binding.scope === "cloudvault";
}
/**
 * Validate + canonicalize an at-rest CloudVault Signal envelope, or `undefined`
 * if it is not a strict, `cloudvault`-scoped at-rest envelope. Thin wrapper over
 * the shared sanitizer; reuses every validation rule in the contract.
 */
export function sanitizeCloudVaultSignalEnvelope(value) {
    const sanitized = sanitizeSignalEnvelope(value, "at-rest");
    if (!sanitized || sanitized.binding.scope !== "cloudvault")
        return undefined;
    return sanitized;
}
