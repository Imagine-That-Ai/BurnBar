import Foundation
import OpenBurnBarCore

/// Signed, short-lived presenter context for Remote Unlock Virtual HID leaves.
///
/// The privileged input helper must not trust request-carried presenter fields.
/// Instead, the app publishes this signed local snapshot at token-mint time,
/// and the helper verifies it offline with the same issuer trust material used
/// for capability tokens.
public struct RemoteUnlockSessionContextSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionId: String
    public var peerNodeId: String
    public var scopeHash: String
    public var escrowDeviceId: String?
    public var attestationHashBlake3: String?
    public var issuedAt: Date
    public var expiresAt: Date
    public var issuerKeyId: String
    public var signatureEd25519Base64: String?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionId: String,
        peerNodeId: String,
        scopeHash: String,
        escrowDeviceId: String? = nil,
        attestationHashBlake3: String? = nil,
        issuedAt: Date,
        expiresAt: Date,
        issuerKeyId: String,
        signatureEd25519Base64: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.peerNodeId = peerNodeId
        self.scopeHash = scopeHash
        self.escrowDeviceId = escrowDeviceId
        self.attestationHashBlake3 = attestationHashBlake3
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.issuerKeyId = issuerKeyId
        self.signatureEd25519Base64 = signatureEd25519Base64
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

public enum RemoteUnlockSessionContextFailure: String, Sendable, Error, Equatable {
    case issuerKeyUnavailable = "session_context_issuer_key_unavailable"
    case issuerRevoked = "session_context_issuer_revoked"
    case issuerKeyMismatch = "session_context_issuer_key_mismatch"
    case signatureMissing = "session_context_signature_missing"
    case signatureInvalid = "session_context_signature_invalid"
}

public struct RemoteUnlockSessionContextSnapshotSigner: Sendable {
    public init() {}

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CapabilityToken.canonicalDateString(date))
        }
        return encoder
    }()

    private struct SignableBody: Codable, Sendable, Equatable {
        var schemaVersion: Int
        var sessionId: String
        var peerNodeId: String
        var scopeHash: String
        var escrowDeviceId: String?
        var attestationHashBlake3: String?
        var issuedAt: Date
        var expiresAt: Date
        var issuerKeyId: String

        init(snapshot: RemoteUnlockSessionContextSnapshot) {
            schemaVersion = snapshot.schemaVersion
            sessionId = snapshot.sessionId
            peerNodeId = snapshot.peerNodeId
            scopeHash = snapshot.scopeHash
            escrowDeviceId = snapshot.escrowDeviceId
            attestationHashBlake3 = snapshot.attestationHashBlake3
            issuedAt = snapshot.issuedAt
            expiresAt = snapshot.expiresAt
            issuerKeyId = snapshot.issuerKeyId
        }
    }

    public func canonicalSignableBytes(snapshot: RemoteUnlockSessionContextSnapshot) throws -> Data {
        try Self.canonicalEncoder.encode(SignableBody(snapshot: snapshot))
    }

    public func sign(
        snapshot: RemoteUnlockSessionContextSnapshot,
        privateKey: PlatformEd25519PrivateKey
    ) throws -> RemoteUnlockSessionContextSnapshot {
        var signed = snapshot
        let payload = try canonicalSignableBytes(snapshot: snapshot)
        let signature = try PlatformCrypto.ed25519Signature(message: payload, privateKey: privateKey)
        signed.signatureEd25519Base64 = signature.base64EncodedString()
        return signed
    }

    public func verify(
        snapshot: RemoteUnlockSessionContextSnapshot,
        publicKey: PlatformEd25519PublicKey
    ) throws -> Bool {
        guard let signatureBase64 = snapshot.signatureEd25519Base64 else {
            throw RemoteUnlockSessionContextFailure.signatureMissing
        }
        guard let signature = Data(base64Encoded: signatureBase64) else {
            return false
        }
        let payload = try canonicalSignableBytes(snapshot: snapshot)
        return try PlatformCrypto.verifyEd25519Signature(signature, message: payload, publicKey: publicKey)
    }
}

public struct RemoteUnlockSessionContextSnapshotStore: Sendable {
    public struct Ledger: Codable, Sendable, Equatable {
        public var snapshots: [RemoteUnlockSessionContextSnapshot]

        public init(snapshots: [RemoteUnlockSessionContextSnapshot] = []) {
            self.snapshots = snapshots
        }
    }

    private let path: String
    private let signer: RemoteUnlockSessionContextSnapshotSigner

    public init(
        path: String = RemoteUnlockSetupProbe.sessionContextSnapshotLedgerPath,
        signer: RemoteUnlockSessionContextSnapshotSigner = RemoteUnlockSessionContextSnapshotSigner()
    ) {
        self.path = path
        self.signer = signer
    }

    public func save(_ snapshot: RemoteUnlockSessionContextSnapshot, now: Date = Date()) throws {
        var ledger = loadLedger()
        ledger.snapshots = ledger.snapshots.filter {
            !$0.isExpired(at: now) && $0.scopeHash != snapshot.scopeHash
        }
        ledger.snapshots.append(snapshot)
        try persistLedger(ledger)
    }

    public func loadVerified(
        scopeHash: String?,
        now: Date = Date(),
        issuerTrust: CapabilityTokenIssuerTrust?
    ) throws -> RemoteUnlockSessionContextSnapshot? {
        guard let scopeHash = normalized(scopeHash) else { return nil }
        guard let issuerTrust else {
            throw RemoteUnlockSessionContextFailure.issuerKeyUnavailable
        }
        guard !issuerTrust.revoked else {
            throw RemoteUnlockSessionContextFailure.issuerRevoked
        }
        let ledger = loadLedger()
        for snapshot in ledger.snapshots where snapshot.scopeHash == scopeHash {
            guard !snapshot.isExpired(at: now) else { continue }
            guard snapshot.issuerKeyId == issuerTrust.keyId else {
                throw RemoteUnlockSessionContextFailure.issuerKeyMismatch
            }
            guard (try? signer.verify(snapshot: snapshot, publicKey: issuerTrust.publicKey)) == true else {
                throw RemoteUnlockSessionContextFailure.signatureInvalid
            }
            return snapshot
        }
        return nil
    }

    private func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let ledger = try? Self.decoder.decode(Ledger.self, from: data) else {
            return Ledger()
        }
        return ledger
    }

    private func persistLedger(_ ledger: Ledger) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(ledger)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CapabilityToken.canonicalDateString(date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 date")
                )
            }
            return date
        }
        return decoder
    }()

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
