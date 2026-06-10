#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

public protocol PhoneControlAuthorityPublicKeyProviding: Sendable {
    /// F2: returns a key-kind-aware verifying key (legacy Ed25519 or
    /// Secure-Enclave P-256, per the record's `signingKeyKind`).
    func fetchPublicKey(uid: String, connectionId: String, peerNodeId: String) async throws -> PhoneControlVerifyingKey
}

public enum PhoneControlAuthorityProviderError: Error, Sendable, Equatable {
    case notFound
    case untrustedDevice
    case unsupportedPlatform(String)
    case expired
    case unsupportedProtocolVersion(Int)
    case malformed
}

/// Fetches the phone-control authority key from Firestore.
///
/// The key is written by the paired phone under
/// `users/{uid}/iroh_pairing/{connectionId}/controllers/{peerNodeId}` before
/// opening the control stream. Firestore rules require the authority to name a
/// trusted escrow device and an existing pairing record, so the Mac can reject
/// in-band public-key injection and stale keys from a different connection.
public final class FirestorePhoneControlAuthorityProvider: PhoneControlAuthorityPublicKeyProviding, @unchecked Sendable {
    public static let shared = FirestorePhoneControlAuthorityProvider()

    private let firestoreProvider: @Sendable () -> Firestore
    private let maximumAge: TimeInterval
    private let allowedPlatforms: Set<String>

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        maximumAge: TimeInterval = 10 * 60,
        allowedPlatforms: Set<String> = ["iOS", "iPadOS", "Android"]
    ) {
        self.firestoreProvider = firestoreProvider
        self.maximumAge = maximumAge
        self.allowedPlatforms = allowedPlatforms
    }

    /// F2: `signingKeyKind` selects the custody class. Absent ⇒ legacy
    /// Ed25519 (32-byte raw). A PRESENT-but-unrecognized kind fails closed —
    /// never silently downgrade a record that claims a stronger key. SE-P256
    /// keys must be 65-byte X9.63 (0x04‖X‖Y) — the exact bytes the SE
    /// peerNodeId derivation and the server's schemaVersion-3 publish path use.
    static func validatedSigningKeyKind(
        signingKeyKindRaw: String?,
        publicKeyRaw raw: Data
    ) throws -> PhoneControlSigningKeyKind {
        let keyKind: PhoneControlSigningKeyKind
        if let kindRaw = signingKeyKindRaw {
            guard let parsed = PhoneControlSigningKeyKind(rawValue: kindRaw) else {
                throw PhoneControlAuthorityProviderError.malformed
            }
            keyKind = parsed
        } else {
            keyKind = .ed25519
        }
        switch keyKind {
        case .ed25519:
            guard raw.count == 32 else { throw PhoneControlAuthorityProviderError.malformed }
        case .secureEnclaveP256:
            guard raw.count == 65 else { throw PhoneControlAuthorityProviderError.malformed }
        }
        return keyKind
    }

    public func fetchPublicKey(
        uid: String,
        connectionId: String,
        peerNodeId: String
    ) async throws -> PhoneControlVerifyingKey {
        let db = firestoreProvider()
        let snapshot = try await db
            .collection("users")
            .document(uid)
            .collection("iroh_pairing")
            .document(connectionId)
            .collection("controllers")
            .document(peerNodeId)
            .getDocument()
        guard snapshot.exists, let data = snapshot.data() else {
            throw PhoneControlAuthorityProviderError.notFound
        }
        guard let deviceId = data["deviceId"] as? String,
              (data["id"] as? String) == peerNodeId,
              (data["connectionId"] as? String) == connectionId,
              (data["peerNodeId"] as? String) == peerNodeId,
              let protocolVersion = data["protocolVersion"] as? Int
                ?? (data["protocolVersion"] as? NSNumber)?.intValue,
              protocolVersion == HermesRealtimeRelayProtocol.version,
              let schemaVersion = data["schemaVersion"] as? Int
                ?? (data["schemaVersion"] as? NSNumber)?.intValue,
              schemaVersion >= 1,
              let publishedAtMillis = data["publishedAtMillis"] as? Int64
                ?? (data["publishedAtMillis"] as? NSNumber)?.int64Value,
              let base64 = data["publicKeyBase64"] as? String,
              let raw = Data(base64Encoded: base64) else {
            throw PhoneControlAuthorityProviderError.malformed
        }
        let keyKind = try Self.validatedSigningKeyKind(signingKeyKindRaw: data["signingKeyKind"] as? String, publicKeyRaw: raw)
        guard Date().timeIntervalSince1970 - (Double(publishedAtMillis) / 1000.0) <= maximumAge else {
            throw PhoneControlAuthorityProviderError.expired
        }

        let deviceSnapshot = try await db
            .collection("users")
            .document(uid)
            .collection("escrow_devices")
            .document(deviceId)
            .getDocument()
        guard deviceSnapshot.exists, let device = deviceSnapshot.data(),
              (device["trustState"] as? String) == "trusted" else {
            throw PhoneControlAuthorityProviderError.untrustedDevice
        }
        let platform = device["platform"] as? String ?? ""
        guard allowedPlatforms.contains(platform) else {
            throw PhoneControlAuthorityProviderError.unsupportedPlatform(platform)
        }
        do {
            return try PhoneControlVerifyingKey(kind: keyKind, publicKeyRepresentation: raw)
        } catch {
            throw PhoneControlAuthorityProviderError.malformed
        }
    }
}
#endif
