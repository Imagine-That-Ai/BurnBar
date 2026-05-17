import CryptoKit
import Foundation
import OpenBurnBarCore

/// Pairing record published by the Mac host to `hermes_connections/{id}`.
/// iOS reads it, verifies the Ed25519 signature, then dials the iroh NodeAddr.
///
/// The signed payload is a single canonical string —
/// `"openburnbar.iroh.pairing.v1|<uid>|<connectionId>|<nodeId>|<relayURL>|<directAddresses>|<publishedAtMs>"` —
/// because that's the smallest surface we can canonicalize across Swift,
/// Kotlin (Android), and TypeScript (Cloud Functions) without leaning on a
/// JSON canonical-form library. The fields are bounded, ascii-safe, and the
/// version prefix lets us evolve the payload format without ambiguity.
public struct IrohPairingRecord: Codable, Sendable, Equatable {
    public let uid: String
    public let connectionId: String
    public let nodeId: String
    public let relayURL: String?
    public let directAddresses: [String]
    public let publishedAtMillis: Int64
    public let protocolVersion: Int
    public let signature: String

    public init(
        uid: String,
        connectionId: String,
        nodeId: String,
        relayURL: String? = nil,
        directAddresses: [String] = [],
        publishedAtMillis: Int64,
        protocolVersion: Int = IrohRelayProtocol.frameProtocolVersion,
        signature: String
    ) {
        self.uid = uid
        self.connectionId = connectionId
        self.nodeId = nodeId
        self.relayURL = Self.normalizedRelayURL(relayURL)
        self.directAddresses = Self.normalizedDirectAddresses(directAddresses)
        self.publishedAtMillis = publishedAtMillis
        self.protocolVersion = protocolVersion
        self.signature = signature
    }

    public var dialTarget: IrohDialTarget {
        IrohDialTarget(nodeId: nodeId, relayURL: relayURL, directAddresses: directAddresses)
    }

    static func normalizedRelayURL(_ relayURL: String?) -> String? {
        let normalized = relayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedDirectAddresses(_ directAddresses: [String]) -> [String] {
        Array(Set(directAddresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted()
    }
}

public enum IrohPairingError: Error, Equatable, Sendable {
    case invalidPublicKey
    case invalidSignature
    case expired
    case unsupportedProtocolVersion(Int)
    case malformed
}

/// Defaults used when iOS verifies an inbound pairing record.
public enum IrohPairingFreshness {
    /// Reject records older than this when verifying. Mirrors the heartbeat
    /// cadence on the Mac side (30s) plus generous slack for clock skew and
    /// momentary background stalls. Older records describe a Mac endpoint that
    /// may no longer own the advertised NodeAddr and must not be dialed.
    public static let maximumAgeSeconds: TimeInterval = 3 * 60
}

/// Signer + verifier. Mac owns a signing identity persisted in Keychain by
/// `IrohRelayKeyStore`; iOS only verifies. Ed25519 is the right primitive —
/// fast, deterministic, no need for a randomized signing key cache.
public enum IrohPairingSignature {
    /// Build the canonical bytes that are signed and verified.
    public static func canonicalPayload(
        uid: String,
        connectionId: String,
        nodeId: String,
        relayURL: String?,
        directAddresses: [String],
        publishedAtMillis: Int64,
        protocolVersion: Int
    ) -> Data {
        let relayURL = IrohPairingRecord.normalizedRelayURL(relayURL) ?? ""
        let directAddresses = IrohPairingRecord
            .normalizedDirectAddresses(directAddresses)
            .joined(separator: ",")
        let payload =
            "openburnbar.iroh.pairing.v\(protocolVersion)|" +
            "\(uid)|\(connectionId)|\(nodeId)|\(relayURL)|\(directAddresses)|\(publishedAtMillis)"
        return Data(payload.utf8)
    }

    public static func sign(
        uid: String,
        connectionId: String,
        nodeId: String,
        relayURL: String? = nil,
        directAddresses: [String] = [],
        publishedAtMillis: Int64,
        protocolVersion: Int = IrohRelayProtocol.frameProtocolVersion,
        with signingKey: Curve25519.Signing.PrivateKey
    ) throws -> IrohPairingRecord {
        let payload = canonicalPayload(
            uid: uid,
            connectionId: connectionId,
            nodeId: nodeId,
            relayURL: relayURL,
            directAddresses: directAddresses,
            publishedAtMillis: publishedAtMillis,
            protocolVersion: protocolVersion
        )
        let signature = try signingKey.signature(for: payload)
        return IrohPairingRecord(
            uid: uid,
            connectionId: connectionId,
            nodeId: nodeId,
            relayURL: relayURL,
            directAddresses: directAddresses,
            publishedAtMillis: publishedAtMillis,
            protocolVersion: protocolVersion,
            signature: signature.base64EncodedString()
        )
    }

    public static func verify(
        _ record: IrohPairingRecord,
        publicKey rawPublicKey: Data,
        now: Date = Date(),
        maximumAge: TimeInterval = IrohPairingFreshness.maximumAgeSeconds
    ) throws {
        guard record.protocolVersion == IrohRelayProtocol.frameProtocolVersion else {
            throw IrohPairingError.unsupportedProtocolVersion(record.protocolVersion)
        }
        guard let signatureBytes = Data(base64Encoded: record.signature) else {
            throw IrohPairingError.malformed
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        } catch {
            throw IrohPairingError.invalidPublicKey
        }
        let payload = canonicalPayload(
            uid: record.uid,
            connectionId: record.connectionId,
            nodeId: record.nodeId,
            relayURL: record.relayURL,
            directAddresses: record.directAddresses,
            publishedAtMillis: record.publishedAtMillis,
            protocolVersion: record.protocolVersion
        )
        guard publicKey.isValidSignature(signatureBytes, for: payload) else {
            throw IrohPairingError.invalidSignature
        }
        let publishedAt = Date(timeIntervalSince1970: Double(record.publishedAtMillis) / 1000.0)
        let ageSeconds = now.timeIntervalSince(publishedAt)
        if ageSeconds > maximumAge {
            throw IrohPairingError.expired
        }
    }
}

/// Convenience wrapper for tests and dev tooling that keeps the keypair
/// material in memory. Production callers go through `IrohRelayKeyStore`
/// which lives in `AgentLens/Services/IrohRelay/` and persists in Keychain.
public struct IrohPairingKeypair: Sendable {
    public let signingKey: Curve25519.Signing.PrivateKey
    public var publicKeyRaw: Data { signingKey.publicKey.rawRepresentation }
    public var publicKeyBase64: String { publicKeyRaw.base64EncodedString() }

    public init(signingKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) {
        self.signingKey = signingKey
    }
}
