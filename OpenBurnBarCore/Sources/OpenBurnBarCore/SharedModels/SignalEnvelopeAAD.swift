import Foundation

/// Cross-language canonical serialization of a Signal-envelope **binding** into
/// the v4 associated-data / HPKE-info string.
///
/// This is the Swift half of the byte-parity seam first defined in TypeScript at
/// `packages/signal-envelope-contracts/src/index.ts` (`bindingToAAD`). Both
/// languages MUST emit the EXACT same UTF-8 string for the same binding, because
/// the at-rest seal/open path derives BOTH the HPKE `info`
/// (`AT_REST_INFO_PREFIX + bindingToAAD(binding)`) and the AEAD
/// `associatedData` (`utf8(bindingToAAD(binding))`) from it. A one-byte
/// divergence makes a Swift-opened ciphertext that a Node-sealed (or vice-versa)
/// fail closed — so the shared fixture
/// `Tests/OpenBurnBarCoreTests/Fixtures/SignalBindingAADVectors.json` (a copy of
/// `packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json`) is the
/// byte-parity proof exercised by `SignalEnvelopeAADTests`.
///
/// IMPORTANT — this is NEW v4-only code and is **inert / flag-off**: nothing in
/// the shipping app calls it yet, and legacy HPKE / CloudVault envelopes keep
/// their own AAD via their own openers. Introducing it changes no production
/// behavior.
///
/// The structured binding does NOT carry `schemaVersion`/`purpose`, so this is a
/// distinct grammar from the legacy pipe format rather than a reuse of it:
///
///   `SignalEnvelopeAAD.prefix` + `[mode, scope, uid, clientId, collection,
///   docId, field, slotId, formatVersion].joined(separator: "|")`
///
/// Field order is fixed; absent optionals serialize as EMPTY segments so the
/// positions stay stable (a transport binding can never be confused with an
/// at-rest one under a shared AAD).
///
/// Unicode normalization: every segment is normalized to NFC
/// (`precomposedStringWithCanonicalMapping`) BEFORE the reserved-char guard and
/// the join, byte-for-byte matching the TypeScript side's `.normalize("NFC")`. A
/// non-ASCII value supplied decomposed (NFD) and the same value supplied
/// precomposed (NFC) therefore canonicalize to the byte-identical AAD; without
/// this, a Swift-sealed ciphertext and a Node-sealed one for the same logical
/// string could carry divergent UTF-8 AAD and fail to open. ASCII values are
/// NFC-stable, so existing fixtures are unaffected.
///
/// Every value is already guaranteed pipe/CRLF free by the TypeScript contract's
/// `boundedText` validator; this Swift side RE-ASSERTS that invariant (on the
/// NORMALIZED segment) and throws ``SignalEnvelopeAADError`` rather than emitting
/// an ambiguous AAD. This is production E2EE code — never silently weaken domain
/// separation.
public enum SignalEnvelopeAAD {
    /// Domain-separation prefix for the v4 binding canonicalization. Byte-identical
    /// to `SIGNAL_BINDING_AAD_PREFIX` in the TypeScript contract.
    public static let prefix = "OpenBurnBar-Signal-AAD-v1|"

    /// Mode discriminator. Mirrors `SignalEnvelopeMode` in the TS contract.
    public enum Mode: String, Sendable, Hashable {
        case transport
        case atRest = "at-rest"
    }

    /// Scope discriminator. Mirrors `SignalEnvelopeScope` in the TS contract.
    public enum Scope: String, Sendable, Hashable {
        case gateway
        case cloudvault
    }

    /// The structured binding, mirroring `SignalBinding` in the TS contract.
    /// Optionals serialize as empty segments in fixed positions.
    public struct Binding: Sendable, Hashable {
        public var uid: String
        public var scope: Scope
        public var clientId: String?
        public var collection: String?
        public var docId: String?
        public var field: String?
        public var slotId: String?
        public var mode: Mode
        public var formatVersion: Int

        public init(
            uid: String,
            scope: Scope,
            clientId: String? = nil,
            collection: String? = nil,
            docId: String? = nil,
            field: String? = nil,
            slotId: String? = nil,
            mode: Mode,
            formatVersion: Int
        ) {
            self.uid = uid
            self.scope = scope
            self.clientId = clientId
            self.collection = collection
            self.docId = docId
            self.field = field
            self.slotId = slotId
            self.mode = mode
            self.formatVersion = formatVersion
        }
    }

    /// Thrown fail-closed when a binding segment carries a reserved `|`, CR, or
    /// LF — never silently dropped, never silently joined.
    public enum SignalEnvelopeAADError: Error, Equatable {
        case reservedCharacterInSegment
    }
}

/// Produce the deterministic v4 canonical AAD/info string for `binding`,
/// byte-identical to the TypeScript `bindingToAAD`.
///
/// - Throws: ``SignalEnvelopeAAD/SignalEnvelopeAADError/reservedCharacterInSegment``
///   if any segment contains `|`, CR, or LF.
public func signalEnvelopeBindingToAAD(_ binding: SignalEnvelopeAAD.Binding) throws -> String {
    let segments: [String] = [
        binding.mode.rawValue,
        binding.scope.rawValue,
        binding.uid,
        binding.clientId ?? "",
        binding.collection ?? "",
        binding.docId ?? "",
        binding.field ?? "",
        binding.slotId ?? "",
        String(binding.formatVersion),
    ].map { $0.precomposedStringWithCanonicalMapping }
    for segment in segments where segment.unicodeScalars.contains(where: { $0 == "|" || $0 == "\r" || $0 == "\n" }) {
        throw SignalEnvelopeAAD.SignalEnvelopeAADError.reservedCharacterInSegment
    }
    return SignalEnvelopeAAD.prefix + segments.joined(separator: "|")
}
