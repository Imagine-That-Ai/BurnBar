import Foundation
import OpenBurnBarCore

// MARK: - Auth

public enum MobileAuthProviderID: String, Sendable, Equatable, CaseIterable {
    case email, apple, google
}

public struct MobileAuthIdentity: Sendable, Equatable {
    public let uid: String
    public let email: String?
    public let displayName: String?
    public let photoURL: URL?

    public init(uid: String, email: String?, displayName: String?, photoURL: URL? = nil) {
        self.uid = uid
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
    }
}

@MainActor
public protocol AuthGateway: AnyObject {
    var availableProviders: [MobileAuthProviderID] { get }
    var isFirebaseAvailable: Bool { get }
    var currentIdentity: MobileAuthIdentity? { get }
    func observe(onChange: @escaping @MainActor (MobileAuthIdentity?) -> Void)
    func signIn(provider: MobileAuthProviderID) async throws
    func createEmailAccount(email: String, password: String) async throws
    func signInWithEmail(email: String, password: String) async throws
    func signOut() throws
}

// MARK: - Cloud reader

public struct CloudPublisherDevice: Sendable, Equatable {
    public let deviceID: String
    public let displayName: String
    public let platform: String
    public let lastSeen: Date
    public init(deviceID: String, displayName: String, platform: String, lastSeen: Date) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.lastSeen = lastSeen
    }
}

public struct CloudSyncStatusSnapshot: Sendable, Equatable {
    public let lastPublishedAt: Date?
    public let lastReadAt: Date?
    public let publisher: CloudPublisherDevice?
    public let lastErrorClassification: CloudErrorClassification?
    public init(lastPublishedAt: Date? = nil, lastReadAt: Date? = nil, publisher: CloudPublisherDevice? = nil, lastErrorClassification: CloudErrorClassification? = nil) {
        self.lastPublishedAt = lastPublishedAt
        self.lastReadAt = lastReadAt
        self.publisher = publisher
        self.lastErrorClassification = lastErrorClassification
    }
}

@MainActor
public protocol CloudReader: AnyObject {
    func loadSyncStatus() async throws -> CloudSyncStatusSnapshot
    func loadProviderSummaries() async throws -> [ProviderConnectionDoc]
    func loadDevices() async throws -> [DeviceRecord]
    func loadAvailableEnvelopes() async throws -> [AvailableEnvelope]
    func loadUnsupportedEnvelopes() async throws -> [UnsupportedEnvelope]
    func loadImportHistory() async throws -> [ImportHistoryEntry]
}

// MARK: - Devices / trust

public enum DeviceTrustState: String, Sendable, Equatable {
    case current, trusted, pending, revoked
}

public struct DeviceRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let platform: String
    public let appVersion: String?
    public let lastSeen: Date?
    public let trustState: DeviceTrustState
    public let approvedAt: Date?
    public let keyVersion: Int?
    public let isCurrentDevice: Bool

    public init(id: String, displayName: String, platform: String, appVersion: String? = nil, lastSeen: Date? = nil, trustState: DeviceTrustState, approvedAt: Date? = nil, keyVersion: Int? = nil, isCurrentDevice: Bool = false) {
        self.id = id; self.displayName = displayName; self.platform = platform
        self.appVersion = appVersion; self.lastSeen = lastSeen
        self.trustState = trustState; self.approvedAt = approvedAt
        self.keyVersion = keyVersion; self.isCurrentDevice = isCurrentDevice
    }
}

@MainActor
public protocol DeviceTrustGateway: AnyObject {
    func bootstrapApproveSelf() async throws
    func renameSelf(_ newName: String) async throws
    func revoke(deviceID: String) async throws
}

// MARK: - Credential transfer

// EscrowCredentialKind is defined in OpenBurnBarCore/EscrowModels.swift
public typealias EscrowCredentialKind = OpenBurnBarCore.EscrowCredentialKind

public struct AvailableEnvelope: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: AgentProvider
    public let accountLabel: String
    public let credentialKind: EscrowCredentialKind
    public let sourceDeviceID: String
    public let sourceDeviceName: String
    public let createdAt: Date

    public init(id: String, provider: AgentProvider, accountLabel: String, credentialKind: EscrowCredentialKind, sourceDeviceID: String, sourceDeviceName: String, createdAt: Date) {
        self.id = id; self.provider = provider; self.accountLabel = accountLabel
        self.credentialKind = credentialKind; self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName; self.createdAt = createdAt
    }
}

public struct UnsupportedEnvelope: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: AgentProvider
    public let accountLabel: String
    public let reason: EscrowUnsupportedReason
    public init(id: String, provider: AgentProvider, accountLabel: String, reason: EscrowUnsupportedReason) {
        self.id = id; self.provider = provider; self.accountLabel = accountLabel; self.reason = reason
    }
}

public enum EscrowUnsupportedReason: Sendable, Equatable {
    case browserSession, providerDoesNotAllowPortableCredentials, credentialKindUnsupported, noTransferableExportFromSource
}

public enum ImportHistoryStatus: String, Sendable, Equatable {
    case validated, revoked, failed
}

public struct ImportHistoryEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: AgentProvider
    public let accountLabel: String
    public let status: ImportHistoryStatus
    public let occurredAt: Date
    public let detail: String?
    public init(id: String, provider: AgentProvider, accountLabel: String, status: ImportHistoryStatus, occurredAt: Date, detail: String? = nil) {
        self.id = id; self.provider = provider; self.accountLabel = accountLabel
        self.status = status; self.occurredAt = occurredAt; self.detail = detail
    }
}

public enum CredentialImportFailure: Sendable, Equatable {
    case grantRevoked, wrongDevice, missingPrivateKey, decryptionFailed
    case providerValidationFailed(providerLabel: String)
    case permissionDenied, appCheckBlocked
    case other(message: String)

    public var isRetryable: Bool {
        switch self {
        case .grantRevoked, .wrongDevice, .missingPrivateKey: return false
        default: return true
        }
    }
}

public enum ImportStage: Sendable, Equatable {
    case idle, downloading, decrypting, storing, validating, validated
    case failed(CredentialImportFailure)
    public var stepIndex: Int {
        switch self {
        case .idle, .downloading: return 0
        case .decrypting: return 1
        case .storing: return 2
        case .validating: return 3
        case .validated: return 4
        case .failed: return 0
        }
    }
}

@MainActor
public protocol EscrowGateway: AnyObject {
    func observeEnvelopes(_ onChange: @escaping @MainActor () -> Void)
    func runImport(envelope: AvailableEnvelope, onStage: @escaping @MainActor (ImportStage) -> Void) async
}
