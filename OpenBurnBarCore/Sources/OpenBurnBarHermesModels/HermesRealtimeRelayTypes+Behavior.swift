// Hand-written companion to the generated Hermes relay payload types.
//
// Holds the pieces a schema does not own: the protocol-constants namespace, the
// shared ISO-8601 date codec (used by the generated Codable conformances), and
// every behavior member (computed properties, factories) as an extension on its
// generated type. The data shapes themselves are generated from
// packages/hermes-wire-protocol/relay-message-types.json.

import Foundation

// The HermesRealtimeRelayProtocol constants namespace and the frame-type enum live
// in the parity-gated HermesRealtimeRelayFrameType.swift (frame/protocol layer).

// Widened from `private` to module-`internal` during the schema migration so the
// generated payload types (in Generated/) can share one date (de)serializer.
enum HermesRealtimeRelayDateCodec {
    static func decode<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Date {
        if let date = try? container.decode(Date.self, forKey: key) {
            return date
        }
        if let raw = try? container.decode(String.self, forKey: key) {
            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso8601Basic = ISO8601DateFormatter()
            iso8601Basic.formatOptions = [.withInternetDateTime]
            if let date = iso8601.date(from: raw) ?? iso8601Basic.date(from: raw) {
                return date
            }
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected Swift JSONEncoder Date number or ISO-8601 date string."
        )
    }

    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension PhoneControlSigningKeyKind {
    /// The value to assume when an envelope omits `keyKind` entirely — every
    /// controller paired before F2 signs with the software Ed25519 key.
    public static let legacyDefault: PhoneControlSigningKeyKind = .ed25519
}
extension HermesRealtimeRelayAuthorityEnvelope {
    /// The effective signing key kind, resolving an absent wire field to the
    /// legacy Ed25519 default so receivers can branch on a non-optional value.
    public var resolvedKeyKind: PhoneControlSigningKeyKind {
        keyKind ?? .legacyDefault
    }
}
extension HermesRealtimeRelayRemoteUnlockCapabilities {
    public static let unavailable = HermesRealtimeRelayRemoteUnlockCapabilities(
        enabled: false,
        certificationStatus: .uncertified,
        activeBackend: .unavailable,
        blockers: ["remote_unlock_not_certified"]
    )
}
extension HermesRealtimeRelayErrorCode {
    public var publicMessage: String {
        switch self {
        case .requestFailed:
            return "The remote Hermes relay could not complete the request."
        case .transportFailed:
            return "The remote Hermes relay connection failed."
        }
    }

    public static func publicMessage(for rawCode: String?) -> String {
        guard let rawCode,
              let code = HermesRealtimeRelayErrorCode(rawValue: rawCode) else {
            return "The remote Hermes relay could not complete the request."
        }
        return code.publicMessage
    }
}
