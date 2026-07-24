#if os(Linux)
import Foundation
import OpenBurnBarKernel

/// The renderer-facing shape for a remote read. The request carries the
/// already-bound Iroh session tuple; it never carries Firebase credentials,
/// vault keys, or a trusted-device signing key.
public struct LinuxIrohRemoteReadRequest: Codable, Equatable, Sendable {
    public static let maximumLifetimeMillis: Int64 = 60_000

    public let requestID: String
    public let sessionID: String
    public let connectionID: String
    public let transportPeerNodeID: String
    public let authorityPeerNodeID: String
    public let routeGeneration: Int64
    public let domain: String
    public let recordID: String
    public let requestedAtMillis: Int64
    public let expiresAtMillis: Int64

    public init(
        requestID: String,
        sessionID: String,
        connectionID: String,
        transportPeerNodeID: String,
        authorityPeerNodeID: String,
        routeGeneration: Int64,
        domain: String,
        recordID: String,
        requestedAtMillis: Int64,
        expiresAtMillis: Int64
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.transportPeerNodeID = transportPeerNodeID
        self.authorityPeerNodeID = authorityPeerNodeID
        self.routeGeneration = routeGeneration
        self.domain = domain
        self.recordID = recordID
        self.requestedAtMillis = requestedAtMillis
        self.expiresAtMillis = expiresAtMillis
    }

    func isWellFormed(nowMillis: Int64) -> Bool {
        guard Self.identifier(requestID, maximum: 160),
              Self.identifier(sessionID, maximum: 160),
              Self.identifier(connectionID, maximum: 160),
              Self.identifier(transportPeerNodeID, maximum: 160),
              Self.identifier(authorityPeerNodeID, maximum: 160),
              Self.identifier(domain, maximum: 64),
              Self.identifier(recordID, maximum: 160),
              routeGeneration > 0,
              requestedAtMillis > 0,
              expiresAtMillis > requestedAtMillis,
              expiresAtMillis - requestedAtMillis <= Self.maximumLifetimeMillis else {
            return false
        }
        return abs(nowMillis - requestedAtMillis) <= 5 * 60_000
            && expiresAtMillis > nowMillis
    }

    static func identifier(_ value: String, maximum: Int) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= maximum
            && value.contains("\0") == false
            && value.contains("\n") == false
            && value.contains("\r") == false
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) }
    }
}

public struct LinuxIrohRemoteReadAuthorization: Codable, Equatable, Sendable {
    public let requestID: String
    public let trustedDeviceID: String
    public let nonce: String
    public let proof: String
    public let expiresAtMillis: Int64

    public init(
        requestID: String,
        trustedDeviceID: String,
        nonce: String,
        proof: String,
        expiresAtMillis: Int64
    ) {
        self.requestID = requestID
        self.trustedDeviceID = trustedDeviceID
        self.nonce = nonce
        self.proof = proof
        self.expiresAtMillis = expiresAtMillis
    }

    func isWellFormed(for request: LinuxIrohRemoteReadRequest, nowMillis: Int64) -> Bool {
        LinuxIrohRemoteReadRequest.identifier(requestID, maximum: 160)
            && requestID == request.requestID
            && LinuxIrohRemoteReadRequest.identifier(trustedDeviceID, maximum: 160)
            && LinuxIrohRemoteReadRequest.identifier(nonce, maximum: 256)
            && proof.utf8.count >= 16
            && proof.utf8.count <= 16_384
            && proof.contains("\0") == false
            && proof.contains("\n") == false
            && proof.contains("\r") == false
            && expiresAtMillis >= request.expiresAtMillis
            && expiresAtMillis > nowMillis
    }
}

public struct BurnBarLinuxIrohRemoteReadResponse: Codable, Equatable, Sendable {
    public let requestID: String
    public let expiresAtMillis: Int64
    public let payload: Data?

    public init(requestID: String, expiresAtMillis: Int64, payload: Data?) {
        self.requestID = requestID
        self.expiresAtMillis = expiresAtMillis
        self.payload = payload
    }
}

public enum LinuxIrohRemoteReadError: Error, Equatable, Sendable {
    case invalidRequest
    case routeUnavailable
    case authorizationUnavailable
    case authorizationRejected
    case authorizationInvalid
    case readUnavailable
    case responseTooLarge
}

/// The existing Iroh runtime conforms to this route gate. Keeping this seam
/// typed prevents a future RPC handler from accepting a caller-supplied peer
/// tuple without asking the live runtime to validate the bound session.
public protocol LinuxIrohRemoteReadRouteAuthorizing: Sendable {
    func authorizesRemoteRead(_ request: LinuxIrohRemoteReadRequest) async -> Bool
}

public protocol LinuxIrohRemoteReadAuthorizing: Sendable {
    func authorizeRemoteRead(
        _ request: LinuxIrohRemoteReadRequest
    ) async throws -> LinuxIrohRemoteReadAuthorization
}

/// Daemon RPC boundary for authorized remote reads. The reader closure is
/// intentionally daemon-owned; production composition should call
/// `LinuxCloudReplicaEngine.readForRemoteAccess` after the route and trusted
/// device grant have both passed.
public actor LinuxIrohRemoteReadRPCBridge {
    public static let maximumResponseBytes = 512 * 1_024

    public typealias Reader = @Sendable (
        LinuxIrohRemoteReadRequest
    ) async throws -> Data?

    private let routeAuthorizer: any LinuxIrohRemoteReadRouteAuthorizing
    private let trustedDeviceAuthorizer: any LinuxIrohRemoteReadAuthorizing
    private let reader: Reader
    private let nowMillis: @Sendable () -> Int64

    public init(
        routeAuthorizer: any LinuxIrohRemoteReadRouteAuthorizing,
        trustedDeviceAuthorizer: any LinuxIrohRemoteReadAuthorizing,
        reader: @escaping Reader,
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.routeAuthorizer = routeAuthorizer
        self.trustedDeviceAuthorizer = trustedDeviceAuthorizer
        self.reader = reader
        self.nowMillis = nowMillis
    }

    public func read(
        _ request: LinuxIrohRemoteReadRequest
    ) async throws -> BurnBarLinuxIrohRemoteReadResponse {
        let currentMillis = nowMillis()
        guard request.isWellFormed(nowMillis: currentMillis) else {
            throw LinuxIrohRemoteReadError.invalidRequest
        }
        guard await routeAuthorizer.authorizesRemoteRead(request) else {
            throw LinuxIrohRemoteReadError.routeUnavailable
        }

        let authorization: LinuxIrohRemoteReadAuthorization
        do {
            authorization = try await trustedDeviceAuthorizer.authorizeRemoteRead(request)
        } catch is LinuxIrohRemoteReadError {
            throw LinuxIrohRemoteReadError.authorizationRejected
        } catch {
            throw LinuxIrohRemoteReadError.authorizationUnavailable
        }
        guard authorization.isWellFormed(for: request, nowMillis: currentMillis) else {
            throw LinuxIrohRemoteReadError.authorizationInvalid
        }

        let payload: Data?
        do {
            payload = try await reader(request)
        } catch {
            throw LinuxIrohRemoteReadError.readUnavailable
        }
        guard payload?.count ?? 0 <= Self.maximumResponseBytes else {
            throw LinuxIrohRemoteReadError.responseTooLarge
        }
        return BurnBarLinuxIrohRemoteReadResponse(
            requestID: request.requestID,
            expiresAtMillis: min(request.expiresAtMillis, authorization.expiresAtMillis),
            payload: payload
        )
    }
}

public struct LinuxIrohCredentialEscrowRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let grantID: String
    public let targetDeviceID: String
    public let targetPublicKeyBase64: String
    public let targetPublicKeyFingerprint: String
    public let targetKeyVersion: Int
    public let providerID: String
    public let slotID: String
    public let accountLabel: String?
    public let credentialKind: EscrowCredentialKind
    public let requestedAtMillis: Int64
    public let expiresAtMillis: Int64

    public init(
        requestID: String,
        grantID: String,
        targetDeviceID: String,
        targetPublicKeyBase64: String,
        targetPublicKeyFingerprint: String,
        targetKeyVersion: Int,
        providerID: String,
        slotID: String,
        accountLabel: String? = nil,
        credentialKind: EscrowCredentialKind,
        requestedAtMillis: Int64,
        expiresAtMillis: Int64
    ) {
        self.requestID = requestID
        self.grantID = grantID
        self.targetDeviceID = targetDeviceID
        self.targetPublicKeyBase64 = targetPublicKeyBase64
        self.targetPublicKeyFingerprint = targetPublicKeyFingerprint
        self.targetKeyVersion = targetKeyVersion
        self.providerID = providerID
        self.slotID = slotID
        self.accountLabel = accountLabel
        self.credentialKind = credentialKind
        self.requestedAtMillis = requestedAtMillis
        self.expiresAtMillis = expiresAtMillis
    }

    func decodedTargetPublicKey(nowMillis: Int64) throws -> Data {
        guard LinuxIrohRemoteReadRequest.identifier(requestID, maximum: 160),
              LinuxIrohRemoteReadRequest.identifier(grantID, maximum: 160),
              LinuxIrohRemoteReadRequest.identifier(targetDeviceID, maximum: 160),
              LinuxIrohRemoteReadRequest.identifier(providerID, maximum: 160),
              LinuxIrohRemoteReadRequest.identifier(slotID, maximum: 160),
              credentialKind != .unknown,
              (1...128).contains(targetKeyVersion),
              requestedAtMillis > 0,
              expiresAtMillis > requestedAtMillis,
              expiresAtMillis - requestedAtMillis <= 10 * 60_000,
              abs(nowMillis - requestedAtMillis) <= 5 * 60_000,
              expiresAtMillis > nowMillis,
              accountLabel.map(Self.validAccountLabel) ?? true,
              let publicKey = Data(base64Encoded: targetPublicKeyBase64),
              publicKey.count == 65,
              publicKey.first == 0x04,
              targetPublicKeyFingerprint == PlatformCrypto.sha256(publicKey).base64EncodedString() else {
            throw LinuxIrohCredentialEscrowError.invalidRequest
        }
        return publicKey
    }

    private static func validAccountLabel(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 320
            && value.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0) == false
            }
    }
}

public struct LinuxIrohCredentialEscrowAuthorization: Codable, Equatable, Sendable {
    public let requestID: String
    public let grantID: String
    public let trustedDeviceID: String
    public let nonce: String
    public let proof: String
    public let expiresAtMillis: Int64

    public init(
        requestID: String,
        grantID: String,
        trustedDeviceID: String,
        nonce: String,
        proof: String,
        expiresAtMillis: Int64
    ) {
        self.requestID = requestID
        self.grantID = grantID
        self.trustedDeviceID = trustedDeviceID
        self.nonce = nonce
        self.proof = proof
        self.expiresAtMillis = expiresAtMillis
    }
}

public enum LinuxIrohCredentialEscrowError: Error, Equatable, Sendable {
    case invalidRequest
    case authorizationUnavailable
    case authorizationRejected
    case authorizationInvalid
    case credentialUnavailable
    case sourceIdentityUnavailable
    case encryptionFailed
    case envelopeTooLarge
}

public protocol LinuxIrohCredentialEscrowAuthorizing: Sendable {
    func authorizeCredentialEscrow(
        _ request: LinuxIrohCredentialEscrowRequest
    ) async throws -> LinuxIrohCredentialEscrowAuthorization
}

/// The Linux host is a credential source, never a credential authority. It
/// reads one provider slot through a daemon-owned secret-store adapter, then
/// emits only an ECIES ciphertext envelope for a trusted target device. The
/// envelope is not persisted locally and plaintext never crosses the RPC
/// boundary.
public actor LinuxIrohCredentialEscrowBridge {
    public typealias CredentialSource = @Sendable (
        _ providerID: String,
        _ slotID: String
    ) async throws -> String?
    public typealias SourceIdentityProvider = @Sendable () async throws -> String

    private let sourceIdentityProvider: SourceIdentityProvider
    private let credentialSource: CredentialSource
    private let trustedDeviceAuthorizer: any LinuxIrohCredentialEscrowAuthorizing
    private let nowMillis: @Sendable () -> Int64

    public init(
        sourceIdentityProvider: @escaping SourceIdentityProvider,
        credentialSource: @escaping CredentialSource,
        trustedDeviceAuthorizer: any LinuxIrohCredentialEscrowAuthorizing,
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.sourceIdentityProvider = sourceIdentityProvider
        self.credentialSource = credentialSource
        self.trustedDeviceAuthorizer = trustedDeviceAuthorizer
        self.nowMillis = nowMillis
    }

    /// Production composition hook. Firebase/App Check credentials remain in
    /// the authority actor; this bridge only borrows its redacted installation
    /// identity while the envelope is being assembled.
    ///
    /// Actors cannot use `convenience` initializers; this is a second
    /// designated entry that forwards into the primary init.
    public init(
        authority: LinuxDaemonCloudCredentialAuthority,
        credentialSource: @escaping CredentialSource,
        trustedDeviceAuthorizer: any LinuxIrohCredentialEscrowAuthorizing,
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.init(
            sourceIdentityProvider: {
                try await authority.credentialContext().deviceID
            },
            credentialSource: credentialSource,
            trustedDeviceAuthorizer: trustedDeviceAuthorizer,
            nowMillis: nowMillis
        )
    }

    public func createEnvelope(
        _ request: LinuxIrohCredentialEscrowRequest
    ) async throws -> EscrowSecretEnvelope {
        let currentMillis = nowMillis()
        let publicKey: Data
        do {
            publicKey = try request.decodedTargetPublicKey(nowMillis: currentMillis)
        } catch {
            throw LinuxIrohCredentialEscrowError.invalidRequest
        }
        let sourceDeviceID: String
        do {
            sourceDeviceID = try await sourceIdentityProvider()
        } catch {
            throw LinuxIrohCredentialEscrowError.sourceIdentityUnavailable
        }
        guard LinuxIrohRemoteReadRequest.identifier(sourceDeviceID, maximum: 160),
              sourceDeviceID != request.targetDeviceID else {
            throw LinuxIrohCredentialEscrowError.sourceIdentityUnavailable
        }

        let authorization: LinuxIrohCredentialEscrowAuthorization
        do {
            authorization = try await trustedDeviceAuthorizer.authorizeCredentialEscrow(request)
        } catch is LinuxIrohCredentialEscrowError {
            throw LinuxIrohCredentialEscrowError.authorizationRejected
        } catch {
            throw LinuxIrohCredentialEscrowError.authorizationUnavailable
        }
        guard authorization.requestID == request.requestID,
              authorization.grantID == request.grantID,
              LinuxIrohRemoteReadRequest.identifier(authorization.trustedDeviceID, maximum: 160),
              LinuxIrohRemoteReadRequest.identifier(authorization.nonce, maximum: 256),
              authorization.proof.utf8.count >= 16,
              authorization.proof.utf8.count <= 16_384,
              authorization.proof.contains("\0") == false,
              authorization.expiresAtMillis >= request.expiresAtMillis,
              authorization.expiresAtMillis > currentMillis else {
            throw LinuxIrohCredentialEscrowError.authorizationInvalid
        }

        let credential: String
        do {
            guard let value = try await credentialSource(request.providerID, request.slotID),
                  value.isEmpty == false,
                  value.utf8.count <= 16_384,
                  value.contains("\0") == false,
                  value.contains("\n") == false,
                  value.contains("\r") == false else {
                throw LinuxIrohCredentialEscrowError.credentialUnavailable
            }
            credential = value
        } catch let error as LinuxIrohCredentialEscrowError {
            throw error
        } catch {
            throw LinuxIrohCredentialEscrowError.credentialUnavailable
        }

        let binding = EscrowCredentialMetadataBinding(
            grantId: request.grantID,
            sourceDeviceId: sourceDeviceID,
            targetDeviceId: request.targetDeviceID,
            providerId: request.providerID,
            credentialKind: request.credentialKind,
            accountLabel: request.accountLabel,
            keyVersion: request.targetKeyVersion
        )
        let ciphertext: Data
        do {
            ciphertext = try CloudVaultCrypto.sealEscrowPayload(
                Data(credential.utf8),
                recipientPublicKey: publicKey,
                authenticating: binding.associatedData
            )
        } catch {
            throw LinuxIrohCredentialEscrowError.encryptionFailed
        }
        guard ciphertext.count <= 64 * 1_024 else {
            throw LinuxIrohCredentialEscrowError.envelopeTooLarge
        }
        return EscrowSecretEnvelope(
            grantId: request.grantID,
            sourceDeviceId: sourceDeviceID,
            targetDeviceId: request.targetDeviceID,
            providerId: request.providerID,
            credentialKind: request.credentialKind,
            accountLabel: request.accountLabel,
            ciphertext: ciphertext.base64EncodedString(),
            keyVersion: request.targetKeyVersion,
            envelopeVersion: EscrowCredentialMetadataBinding.envelopeVersion,
            createdAt: Date(timeIntervalSince1970: Double(currentMillis) / 1_000)
        )
    }
}

extension LinuxIrohControllerRuntime: LinuxIrohRemoteReadRouteAuthorizing {
    public func authorizesRemoteRead(_ request: LinuxIrohRemoteReadRequest) async -> Bool {
        await authorizesSessionAuthority(
            sessionID: request.sessionID,
            authorityPeerNodeID: request.authorityPeerNodeID,
            transportPeerNodeID: request.transportPeerNodeID,
            routeGeneration: request.routeGeneration,
            now: Date(timeIntervalSince1970: Double(request.requestedAtMillis) / 1_000)
        )
    }
}
#endif
