import Foundation

// MARK: - Provider Account Device Link
//
// Persisted at: users/{uid}/provider_account_device_links/{accountID}_{deviceID}
//
// Three capabilities:
//   • owner — the device that originally adopted this account (matches
//     `ProviderAccountDoc.sourceDeviceID`).
//   • use   — a device that holds an active credential or quota-read link.
//   • add   — a device flagged by the user as the place to attach new
//     credentials for this account.

public enum DeviceLinkCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case owner
    case use
    case add
}

public enum DeviceLinkStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case revoked
}

public struct ProviderAccountDeviceLinkDoc: Codable, Identifiable, Hashable, Sendable {
    /// Composite identifier `{accountID}_{deviceID}`, matching the Firestore
    /// document id in the canonical top-level collection.
    public var id: String

    public let accountID: String
    public let deviceID: String
    public let deviceDisplayName: String
    public let capability: DeviceLinkCapability
    public let status: DeviceLinkStatus
    public let lastObservedAt: Date
    public let createdAt: Date
    public let updatedAt: Date
    public let schemaVersion: Int

    public init(
        id: String? = nil,
        accountID: String,
        deviceID: String,
        deviceDisplayName: String,
        capability: DeviceLinkCapability,
        status: DeviceLinkStatus = .active,
        lastObservedAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.id = id ?? "\(accountID)_\(deviceID)"
        self.accountID = accountID
        self.deviceID = deviceID
        self.deviceDisplayName = deviceDisplayName
        self.capability = capability
        self.status = status
        self.lastObservedAt = lastObservedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}
