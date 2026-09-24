import Foundation

// MARK: - Provider Connection Status

public enum ProviderConnectionStatus: String, Codable, Sendable {
    case connected
    case disconnected
    case error
    case stale
}

// MARK: - Credential Kind

public enum CredentialKind: String, Codable, Sendable {
    case token
    case bearer
    case session
    case cookie
    case plan
}

// MARK: - Provider Connection Document

public struct ProviderConnectionDoc: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let status: ProviderConnectionStatus
    public let lastValidatedAt: Date?
    public let lastRefreshAt: Date?
    public let lastErrorCode: String?
    public let credentialKind: CredentialKind
    public let redactedLabel: String
    public let schemaVersion: Int
    public let warningMessage: String?

    public init(
        provider: String,
        status: ProviderConnectionStatus,
        lastValidatedAt: Date? = nil,
        lastRefreshAt: Date? = nil,
        lastErrorCode: String? = nil,
        credentialKind: CredentialKind,
        redactedLabel: String,
        schemaVersion: Int = 1,
        warningMessage: String? = nil
    ) {
        self.id = provider
        self.provider = provider
        self.status = status
        self.lastValidatedAt = lastValidatedAt
        self.lastRefreshAt = lastRefreshAt
        self.lastErrorCode = lastErrorCode
        self.credentialKind = credentialKind
        self.redactedLabel = redactedLabel
        self.schemaVersion = schemaVersion
        self.warningMessage = warningMessage
    }
}
