/**
 * @fileoverview Seal-aware export helpers for future official-libsignal envelopes.
 *
 * The server never decrypts Signal envelopes. These helpers only verify the
 * strict shape and strip any nested plaintext-adjacent junk before data export.
 */

import { recordOrUndefined } from "./guards.js";
import { sanitizeGatewaySignalEnvelope } from "./hermesGateway.js";

const SIGNAL_ENVELOPE_FIELDS = new Set([
  "signalEnvelopeFormatVersion",
  "mode",
  "relayKeyVersion",
  "relayEncryption",
  "ciphertextLayer",
  "keyDelivery",
  "binding",
]);

const SIGNAL_CIPHERTEXT_LAYER_FIELDS = new Set(["payloadCiphertextB64", "payloadAADLabel", "schemaVersion"]);

const SIGNAL_BINDING_FIELDS = new Set([
  "uid",
  "scope",
  "clientId",
  "collection",
  "docId",
  "field",
  "slotId",
  "mode",
  "formatVersion",
]);

const SIGNAL_TRANSPORT_KEY_DELIVERY_FIELDS = new Set([
  "scheme",
  "signalMessageType",
  "signalMessageB64",
  "senderIdentityKeyId",
  "ratchetEpochHint",
]);

const SIGNAL_AT_REST_KEY_DELIVERY_FIELDS = new Set(["scheme", "wraps", "contentKeyLength"]);

const SIGNAL_AT_REST_WRAP_FIELDS = new Set([
  "recipientKind",
  "recipientIdentityKeyId",
  "recipientIdentityKeyB64",
  "sealedContentKeyB64",
]);

export function isGatewaySignalEnvelope(value: unknown): boolean {
  return sanitizeGatewaySignalEnvelope(value) !== undefined;
}

export function sanitizeSignalEnvelopeForExport(
  path: string,
  envelope: Record<string, unknown>,
): {
  out: unknown;
  dropped: string[];
} {
  const sanitized = sanitizeGatewaySignalEnvelope(envelope);
  if (!sanitized) return { out: envelope, dropped: [] };

  const dropped = collectDisallowedKeys(path, envelope, SIGNAL_ENVELOPE_FIELDS);
  collectNestedDrops(path, envelope, dropped);
  return { out: sanitized, dropped };
}

function collectNestedDrops(path: string, envelope: Record<string, unknown>, dropped: string[]): void {
  const ciphertextLayer = recordOrUndefined(envelope.ciphertextLayer);
  if (ciphertextLayer) {
    dropped.push(...collectDisallowedKeys(`${path}.ciphertextLayer`, ciphertextLayer, SIGNAL_CIPHERTEXT_LAYER_FIELDS));
  }
  const binding = recordOrUndefined(envelope.binding);
  if (binding) {
    dropped.push(...collectDisallowedKeys(`${path}.binding`, binding, SIGNAL_BINDING_FIELDS));
  }
  const keyDelivery = recordOrUndefined(envelope.keyDelivery);
  if (!keyDelivery) return;

  const allowed =
    keyDelivery.scheme === "signal-hpke-identity-seal-v1"
      ? SIGNAL_AT_REST_KEY_DELIVERY_FIELDS
      : SIGNAL_TRANSPORT_KEY_DELIVERY_FIELDS;
  dropped.push(...collectDisallowedKeys(`${path}.keyDelivery`, keyDelivery, allowed));
  if (Array.isArray(keyDelivery.wraps)) {
    for (let index = 0; index < keyDelivery.wraps.length; index += 1) {
      const wrap = recordOrUndefined(keyDelivery.wraps[index]);
      if (wrap) {
        dropped.push(...collectDisallowedKeys(`${path}.keyDelivery.wraps.${index}`, wrap, SIGNAL_AT_REST_WRAP_FIELDS));
      }
    }
  }
}

function collectDisallowedKeys(path: string, data: Record<string, unknown>, allowed: Set<string>): string[] {
  const dropped: string[] = [];
  for (const key of Object.keys(data)) {
    if (!allowed.has(key)) dropped.push(`${path}.${key}`);
  }
  return dropped;
}
