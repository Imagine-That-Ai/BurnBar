export {
  type CloudVaultSignalBinding,
  type CloudVaultSignalEnvelope,
  isCloudVaultSignalEnvelope,
  sanitizeCloudVaultSignalEnvelope,
} from "./cloudVaultSignalEnvelope.js";

export const SIGNAL_ENVELOPE_FORMAT_VERSION = 1;
export const SIGNAL_RELAY_KEY_VERSION = 4;
export const SIGNAL_TRANSPORT_ENCRYPTION = "signal-doubleratchet-pqxdh-v1";
export const SIGNAL_AT_REST_ENCRYPTION = "signal-hpke-identity-seal-v1";
export const SIGNAL_MAX_MESSAGE_B64 = 1_100_000;
export const SIGNAL_MAX_KEY_WRAP_B64 = 16_384;
export const SIGNAL_MAX_RECIPIENT_WRAPS = 32;
export const SIGNAL_MAX_ID = 160;
export const SIGNAL_MAX_LABEL = 120;
export const SIGNAL_MAX_COUNTER = 9_007_199_254_740_991;

export type SignalEnvelopeMode = "transport" | "at-rest";
export type SignalEnvelopeScope = "gateway" | "cloudvault";
export type SignalMessageType = 2 | 3;
export type SignalRecipientKind = "device" | "escrow" | "recovery";

export interface SignalCiphertextLayer {
  payloadCiphertextB64: string;
  payloadAADLabel: string;
  schemaVersion: number;
}

export interface SignalBinding {
  uid: string;
  scope: SignalEnvelopeScope;
  clientId?: string;
  collection?: string;
  docId?: string;
  field?: string;
  slotId?: string;
  mode: SignalEnvelopeMode;
  formatVersion: number;
}

export interface SignalTransportKeyDelivery {
  scheme: typeof SIGNAL_TRANSPORT_ENCRYPTION;
  signalMessageType: SignalMessageType;
  signalMessageB64: string;
  senderIdentityKeyId: string;
  ratchetEpochHint?: number;
}

export interface SignalAtRestWrap {
  recipientKind: SignalRecipientKind;
  recipientIdentityKeyId: string;
  recipientIdentityKeyB64: string;
  sealedContentKeyB64: string;
}

export interface SignalAtRestKeyDelivery {
  scheme: typeof SIGNAL_AT_REST_ENCRYPTION;
  wraps: SignalAtRestWrap[];
  contentKeyLength: 32;
}

export interface SignalEnvelope {
  signalEnvelopeFormatVersion: number;
  mode: SignalEnvelopeMode;
  relayKeyVersion?: number;
  relayEncryption: typeof SIGNAL_TRANSPORT_ENCRYPTION | typeof SIGNAL_AT_REST_ENCRYPTION;
  ciphertextLayer: SignalCiphertextLayer;
  keyDelivery: SignalTransportKeyDelivery | SignalAtRestKeyDelivery;
  binding: SignalBinding;
}

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

function recordOrUndefined(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function stripUndefined<T extends Record<string, unknown>>(record: T): T {
  return Object.fromEntries(Object.entries(record).filter(([, value]) => value !== undefined)) as T;
}

function boundedText(raw: unknown, maxLength: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > maxLength || /[\r\n|]/u.test(value)) return undefined;
  return value;
}

function counter(raw: unknown): number | undefined {
  const value = typeof raw === "number" ? Math.floor(raw) : Number(raw);
  if (!Number.isSafeInteger(value) || value < 0 || value > SIGNAL_MAX_COUNTER) return undefined;
  return value;
}

function base64Within(raw: unknown, maxLength: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (
    !value ||
    value.length > maxLength ||
    value.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value)
  ) {
    return undefined;
  }
  try {
    if (Buffer.from(value, "base64").toString("base64") !== value) return undefined;
  } catch {
    return undefined;
  }
  return value;
}

function sanitizeCiphertextLayer(raw: unknown): SignalCiphertextLayer | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const payloadCiphertextB64 = base64Within(record.payloadCiphertextB64, SIGNAL_MAX_MESSAGE_B64);
  const payloadAADLabel = boundedText(record.payloadAADLabel, SIGNAL_MAX_LABEL);
  const schemaVersion = counter(record.schemaVersion);
  if (!payloadCiphertextB64 || !payloadAADLabel || schemaVersion === undefined) return undefined;
  return { payloadCiphertextB64, payloadAADLabel, schemaVersion };
}

function sanitizeBinding(
  raw: unknown,
  expected: { mode: SignalEnvelopeMode; scope?: SignalEnvelopeScope },
): SignalBinding | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const uid = boundedText(record.uid, SIGNAL_MAX_ID);
  const scope = record.scope === "gateway" || record.scope === "cloudvault" ? record.scope : undefined;
  const mode = record.mode === "transport" || record.mode === "at-rest" ? record.mode : undefined;
  const formatVersion = counter(record.formatVersion);
  if (
    !uid ||
    !scope ||
    !mode ||
    mode !== expected.mode ||
    (expected.scope !== undefined && scope !== expected.scope) ||
    formatVersion !== SIGNAL_ENVELOPE_FORMAT_VERSION
  ) {
    return undefined;
  }

  if (scope === "gateway") {
    if (mode !== "transport") return undefined;
    const clientId = boundedText(record.clientId, SIGNAL_MAX_ID);
    const slotId = boundedText(record.slotId, SIGNAL_MAX_ID);
    if (
      !clientId ||
      !slotId ||
      record.collection !== undefined ||
      record.docId !== undefined ||
      record.field !== undefined
    ) {
      return undefined;
    }
    return { uid, scope, clientId, slotId, mode, formatVersion };
  }

  const collection = boundedText(record.collection, SIGNAL_MAX_ID);
  const docId = boundedText(record.docId, SIGNAL_MAX_ID);
  const field = boundedText(record.field, SIGNAL_MAX_ID);
  if (!collection || !docId || !field || record.clientId !== undefined || record.slotId !== undefined) {
    return undefined;
  }
  return { uid, scope, collection, docId, field, mode, formatVersion };
}

function sanitizeTransportDelivery(raw: unknown): SignalTransportKeyDelivery | undefined {
  const record = recordOrUndefined(raw);
  if (!record || record.scheme !== SIGNAL_TRANSPORT_ENCRYPTION) return undefined;
  const signalMessageType =
    record.signalMessageType === 2 || record.signalMessageType === 3 ? record.signalMessageType : undefined;
  const signalMessageB64 = base64Within(record.signalMessageB64, SIGNAL_MAX_MESSAGE_B64);
  const senderIdentityKeyId = boundedText(record.senderIdentityKeyId, SIGNAL_MAX_ID);
  const ratchetEpochHint = record.ratchetEpochHint === undefined ? undefined : counter(record.ratchetEpochHint);
  if (
    !signalMessageType ||
    !signalMessageB64 ||
    !senderIdentityKeyId ||
    (ratchetEpochHint === undefined && record.ratchetEpochHint !== undefined)
  ) {
    return undefined;
  }
  return stripUndefined({
    scheme: SIGNAL_TRANSPORT_ENCRYPTION,
    signalMessageType,
    signalMessageB64,
    senderIdentityKeyId,
    ratchetEpochHint,
  }) as SignalTransportKeyDelivery;
}

function sanitizeAtRestDelivery(raw: unknown): SignalAtRestKeyDelivery | undefined {
  const record = recordOrUndefined(raw);
  if (!record || record.scheme !== SIGNAL_AT_REST_ENCRYPTION) return undefined;
  if (record.contentKeyLength !== 32 || !Array.isArray(record.wraps)) return undefined;
  if (record.wraps.length < 1 || record.wraps.length > SIGNAL_MAX_RECIPIENT_WRAPS) return undefined;
  const wraps = record.wraps.flatMap((item): SignalAtRestWrap[] => {
    const wrap = recordOrUndefined(item);
    if (!wrap) return [];
    const recipientKind =
      wrap.recipientKind === "device" || wrap.recipientKind === "escrow" || wrap.recipientKind === "recovery"
        ? wrap.recipientKind
        : undefined;
    const recipientIdentityKeyId = boundedText(wrap.recipientIdentityKeyId, SIGNAL_MAX_ID);
    const recipientIdentityKeyB64 = base64Within(wrap.recipientIdentityKeyB64, SIGNAL_MAX_KEY_WRAP_B64);
    const sealedContentKeyB64 = base64Within(wrap.sealedContentKeyB64, SIGNAL_MAX_KEY_WRAP_B64);
    if (!recipientKind || !recipientIdentityKeyId || !recipientIdentityKeyB64 || !sealedContentKeyB64) return [];
    return [{ recipientKind, recipientIdentityKeyId, recipientIdentityKeyB64, sealedContentKeyB64 }];
  });
  if (wraps.length !== record.wraps.length) return undefined;
  return { scheme: SIGNAL_AT_REST_ENCRYPTION, wraps, contentKeyLength: 32 };
}

export function sanitizeSignalEnvelope(raw: unknown, expectedMode?: SignalEnvelopeMode): SignalEnvelope | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const signalEnvelopeFormatVersion = counter(record.signalEnvelopeFormatVersion);
  const mode = record.mode === "transport" || record.mode === "at-rest" ? record.mode : undefined;
  if (
    signalEnvelopeFormatVersion !== SIGNAL_ENVELOPE_FORMAT_VERSION ||
    !mode ||
    (expectedMode !== undefined && mode !== expectedMode)
  ) {
    return undefined;
  }

  const expectedEncryption = mode === "transport" ? SIGNAL_TRANSPORT_ENCRYPTION : SIGNAL_AT_REST_ENCRYPTION;
  if (record.relayEncryption !== expectedEncryption) return undefined;

  const rawRelayKeyVersion =
    record.relayKeyVersion === undefined
      ? undefined
      : typeof record.relayKeyVersion === "number"
        ? Math.floor(record.relayKeyVersion)
        : Number(record.relayKeyVersion);
  if (mode === "transport") {
    if (rawRelayKeyVersion !== SIGNAL_RELAY_KEY_VERSION) return undefined;
  } else if (record.relayKeyVersion !== undefined) {
    return undefined;
  }

  const ciphertextLayer = sanitizeCiphertextLayer(record.ciphertextLayer);
  const keyDelivery =
    mode === "transport" ? sanitizeTransportDelivery(record.keyDelivery) : sanitizeAtRestDelivery(record.keyDelivery);
  const binding = sanitizeBinding(record.binding, { mode, scope: mode === "transport" ? "gateway" : undefined });
  if (!ciphertextLayer || !keyDelivery || !binding) return undefined;
  return stripUndefined({
    signalEnvelopeFormatVersion,
    mode,
    relayKeyVersion: mode === "transport" ? SIGNAL_RELAY_KEY_VERSION : undefined,
    relayEncryption: expectedEncryption,
    ciphertextLayer,
    keyDelivery,
    binding,
  }) as SignalEnvelope;
}

export function isSignalEnvelope(value: unknown, expectedMode?: SignalEnvelopeMode): value is SignalEnvelope {
  return sanitizeSignalEnvelope(value, expectedMode) !== undefined;
}

/**
 * Domain-separation prefix for the v4 Signal-envelope binding canonicalization.
 * This is a NEW, v4-only format (see {@link bindingToAAD}); legacy HPKE /
 * CloudVault envelopes keep their own AAD via their own openers and MUST NOT be
 * routed through this serializer.
 */
export const SIGNAL_BINDING_AAD_PREFIX = "OpenBurnBar-Signal-AAD-v1|";

const SIGNAL_BINDING_AAD_FORBIDDEN = /[|\r\n]/u;

/**
 * Deterministic, cross-language canonical serialization of a {@link SignalBinding}
 * for use as the HPKE `info` suffix AND the AEAD `associatedData` in the v4
 * Signal at-rest seal/open path.
 *
 * The structured binding object does NOT carry `schemaVersion`/`purpose`, so this
 * is a NEW grammar rather than a reuse of the legacy pipe format. The layout is a
 * fixed field order joined by `|`, with absent optionals serialized as EMPTY
 * segments so positions stay stable:
 *
 *   SIGNAL_BINDING_AAD_PREFIX + [mode, scope, uid, clientId, collection, docId,
 *   field, slotId, formatVersion].join("|")
 *
 * Every BurnBar language (TypeScript here, Swift in
 * `OpenBurnBarCore/.../SignalEnvelopeAAD.swift`) MUST produce the byte-identical
 * UTF-8 string; the shared fixture `fixtures/binding-aad-vectors.json` is the
 * byte-parity proof consumed by both test suites.
 *
 * Unicode normalization: every segment is normalized to NFC (`String#normalize`)
 * BEFORE the reserved-char guard and the join, so a non-ASCII value supplied as
 * NFD (decomposed) and the same value supplied as NFC (precomposed) produce the
 * byte-identical AAD. Swift seals with `precomposedStringWithCanonicalMapping`
 * (also NFC); without this both sides could otherwise emit divergent UTF-8 for
 * the same logical string and fail to open each other's ciphertext. ASCII values
 * are NFC-stable, so existing fixtures are unaffected.
 *
 * Fail-closed: although the contract's `boundedText` validator already rejects
 * any segment containing `|`, CR, or LF, this function re-asserts that invariant
 * (on the NORMALIZED segment) and THROWS on a violating segment rather than
 * emitting an ambiguous AAD. This is production E2EE code — never silently weaken
 * domain separation.
 */
export function bindingToAAD(binding: SignalBinding): string {
  const segments = [
    binding.mode,
    binding.scope,
    binding.uid,
    binding.clientId ?? "",
    binding.collection ?? "",
    binding.docId ?? "",
    binding.field ?? "",
    binding.slotId ?? "",
    String(binding.formatVersion),
  ].map((segment) => segment.normalize("NFC"));
  for (const segment of segments) {
    if (SIGNAL_BINDING_AAD_FORBIDDEN.test(segment)) {
      throw new Error("signal binding segment contains a reserved '|' or CR/LF character");
    }
  }
  return SIGNAL_BINDING_AAD_PREFIX + segments.join("|");
}

export function sanitizeSignalEnvelopeForExport(
  path: string,
  envelope: Record<string, unknown>,
): {
  out: SignalEnvelope | Record<string, unknown>;
  dropped: string[];
} {
  const sanitized = sanitizeSignalEnvelope(envelope);
  if (!sanitized) {
    // FAIL CLOSED (export redaction default-deny / L25). The caller only routes a
    // value here once it is signal-SHAPED (a numeric `signalEnvelopeFormatVersion`),
    // so a value that then fails strict validation is a malformed/polluted envelope
    // that may carry plaintext-adjacent junk. Re-emitting it raw would leak that
    // plaintext into the export with an empty `dropped` (a redaction-integrity lie).
    // Instead drop EVERY key: export nothing, report all keys redacted.
    return { out: {}, dropped: Object.keys(envelope).map((key) => `${path}.${key}`) };
  }

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
    keyDelivery.scheme === SIGNAL_AT_REST_ENCRYPTION
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
