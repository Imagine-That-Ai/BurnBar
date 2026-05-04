import Foundation

/// Platform-agnostic crypto abstraction for device keypair operations.
/// Each platform provides its own conformance (macOS Keychain, iOS Keychain).
/// Uses P-256 ECIES (AES-GCM) via Apple's CryptoKit.
public protocol DeviceKeypairProtocol {
    /// The device's public key as raw x9.63 format bytes (65 bytes: 0x04 || x || y).
    var publicKeyData: Data { get }

    /// Base64-encoded SHA-256 fingerprint of public key for Firestore storage.
    var publicKeyFingerprint: String { get }

    /// Monotonically increasing key version for rotation support.
    var keyVersion: Int { get }

    /// Encrypt plaintext data for a recipient's public key.
    func encrypt(_ plaintext: Data, for recipientPublicKey: Data) throws -> Data

    /// Decrypt ciphertext encrypted with this device's public key.
    func decrypt(_ ciphertext: Data) throws -> Data
}

// MARK: - Escrow Models

public enum EscrowDeviceTrustState: String, Codable, Sendable {
    case pending
    case trusted
    case revoked
}

public struct EscrowDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public var deviceName: String
    public let platform: String
    public var trustState: EscrowDeviceTrustState
    public var approvedAt: Date?
    public var publicKeyFingerprint: String?
    public var keyVersion: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        deviceId: String,
        deviceName: String,
        platform: String,
        trustState: EscrowDeviceTrustState = .pending,
        approvedAt: Date? = nil,
        publicKeyFingerprint: String? = nil,
        keyVersion: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.trustState = trustState
        self.approvedAt = approvedAt
        self.publicKeyFingerprint = publicKeyFingerprint
        self.keyVersion = keyVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct EscrowPublicKey: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(deviceId)_\(keyVersion)" }
    public let deviceId: String
    public let publicKeyData: String // base64
    public let keyVersion: Int
    public let algorithm: String
    public var createdAt: Date

    public init(
        deviceId: String,
        publicKeyData: String,
        keyVersion: Int = 1,
        algorithm: String = "ECIES-P256-AESGCM",
        createdAt: Date = Date()
    ) {
        self.deviceId = deviceId
        self.publicKeyData = publicKeyData
        self.keyVersion = keyVersion
        self.algorithm = algorithm
        self.createdAt = createdAt
    }
}

public enum EscrowGrantStatus: String, Codable, Sendable {
    case granted
    case revoked
}

public struct EscrowGrant: Codable, Sendable, Equatable, Identifiable {
    public let id: String // UUID
    public let sourceDeviceId: String
    public let targetDeviceId: String
    public let providerId: String
    public let credentialKind: EscrowCredentialKind
    public var status: EscrowGrantStatus
    public var grantedAt: Date
    public var revokedAt: Date?

    public init(
        id: String = UUID().uuidString,
        sourceDeviceId: String,
        targetDeviceId: String,
        providerId: String,
        credentialKind: EscrowCredentialKind,
        status: EscrowGrantStatus = .granted,
        grantedAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.sourceDeviceId = sourceDeviceId
        self.targetDeviceId = targetDeviceId
        self.providerId = providerId
        self.credentialKind = credentialKind
        self.status = status
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }
}

public enum EscrowCredentialKind: String, Codable, Sendable {
    case apiKey = "api_key"
    case oauthToken = "oauth_token"
    case bearerToken = "bearer_token"
    case unknown = "unknown"

    public var displayLabel: String {
        switch self {
        case .apiKey: return "API key"
        case .oauthToken: return "OAuth token"
        case .bearerToken: return "Bearer token"
        case .unknown: return "Credential"
        }
    }
}

public struct EscrowSecretMetadata: Codable, Sendable, Equatable {
    public let providerId: String
    public let accountLabel: String?
    public let credentialKind: EscrowCredentialKind
    public let sourceDeviceId: String
    public let destinationDeviceId: String

    public init(
        providerId: String,
        accountLabel: String? = nil,
        credentialKind: EscrowCredentialKind,
        sourceDeviceId: String,
        destinationDeviceId: String
    ) {
        self.providerId = providerId
        self.accountLabel = accountLabel
        self.credentialKind = credentialKind
        self.sourceDeviceId = sourceDeviceId
        self.destinationDeviceId = destinationDeviceId
    }
}

public struct EscrowSecretEnvelope: Codable, Sendable, Equatable, Identifiable {
    public let id: String // envelopeId UUID
    public let grantId: String
    public let sourceDeviceId: String
    public let targetDeviceId: String
    public let providerId: String
    public let credentialKind: EscrowCredentialKind
    public let accountLabel: String?
    public let ciphertext: String // base64 of encrypted payload
    public let keyVersion: Int
    public let envelopeVersion: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        grantId: String,
        sourceDeviceId: String,
        targetDeviceId: String,
        providerId: String,
        credentialKind: EscrowCredentialKind = .apiKey,
        accountLabel: String? = nil,
        ciphertext: String,
        keyVersion: Int = 1,
        envelopeVersion: Int = 1,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.grantId = grantId
        self.sourceDeviceId = sourceDeviceId
        self.targetDeviceId = targetDeviceId
        self.providerId = providerId
        self.credentialKind = credentialKind
        self.accountLabel = accountLabel
        self.ciphertext = ciphertext
        self.keyVersion = keyVersion
        self.envelopeVersion = envelopeVersion
        self.createdAt = createdAt
    }
}

public enum EscrowAuditEventType: String, Codable, Sendable {
    case envelopeCreated
    case envelopeImported
    case grantCreated
    case grantRevoked
    case importFailed
    case envelopeReadbackVerified
    case importValidationSucceeded
}

public struct EscrowAuditEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String // UUID
    public let eventType: EscrowAuditEventType
    public let actorDeviceId: String
    public let targetDeviceId: String?
    public let providerId: String?
    public let grantId: String?
    public let envelopeId: String?
    public var timestamp: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        eventType: EscrowAuditEventType,
        actorDeviceId: String,
        targetDeviceId: String? = nil,
        providerId: String? = nil,
        grantId: String? = nil,
        envelopeId: String? = nil,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.eventType = eventType
        self.actorDeviceId = actorDeviceId
        self.targetDeviceId = targetDeviceId
        self.providerId = providerId
        self.grantId = grantId
        self.envelopeId = envelopeId
        self.timestamp = timestamp
        self.metadata = metadata
    }
}
