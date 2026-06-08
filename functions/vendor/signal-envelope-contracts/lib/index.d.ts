export { type CloudVaultSignalBinding, type CloudVaultSignalEnvelope, isCloudVaultSignalEnvelope, sanitizeCloudVaultSignalEnvelope, } from "./cloudVaultSignalEnvelope.js";
export declare const SIGNAL_ENVELOPE_FORMAT_VERSION = 1;
export declare const SIGNAL_RELAY_KEY_VERSION = 4;
export declare const SIGNAL_TRANSPORT_ENCRYPTION = "signal-doubleratchet-pqxdh-v1";
export declare const SIGNAL_AT_REST_ENCRYPTION = "signal-hpke-identity-seal-v1";
export declare const SIGNAL_MAX_MESSAGE_B64 = 1100000;
export declare const SIGNAL_MAX_KEY_WRAP_B64 = 16384;
export declare const SIGNAL_MAX_RECIPIENT_WRAPS = 32;
export declare const SIGNAL_MAX_ID = 160;
export declare const SIGNAL_MAX_LABEL = 120;
export declare const SIGNAL_MAX_COUNTER = 9007199254740991;
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
export declare function sanitizeSignalEnvelope(raw: unknown, expectedMode?: SignalEnvelopeMode): SignalEnvelope | undefined;
export declare function isSignalEnvelope(value: unknown, expectedMode?: SignalEnvelopeMode): value is SignalEnvelope;
/**
 * Domain-separation prefix for the v4 Signal-envelope binding canonicalization.
 * This is a NEW, v4-only format (see {@link bindingToAAD}); legacy HPKE /
 * CloudVault envelopes keep their own AAD via their own openers and MUST NOT be
 * routed through this serializer.
 */
export declare const SIGNAL_BINDING_AAD_PREFIX = "OpenBurnBar-Signal-AAD-v1|";
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
export declare function bindingToAAD(binding: SignalBinding): string;
export declare function sanitizeSignalEnvelopeForExport(path: string, envelope: Record<string, unknown>): {
    out: SignalEnvelope | Record<string, unknown>;
    dropped: string[];
};
//# sourceMappingURL=index.d.ts.map