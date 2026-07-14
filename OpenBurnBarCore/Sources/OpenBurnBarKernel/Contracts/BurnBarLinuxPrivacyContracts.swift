import Foundation

public enum BurnBarLinuxPrivacyStoreID: String, Codable, CaseIterable, Hashable, Sendable {
    case proxyRouteLog = "proxy_route_log"
    case textExpansionStore = "text_expansion_store"
}

public enum BurnBarLinuxPrivacyStoreState: String, Codable, Hashable, Sendable {
    case absent
    case ready
    case blocked
}

public struct BurnBarLinuxPrivacyStoreInventory: Codable, Hashable, Sendable {
    public let store: BurnBarLinuxPrivacyStoreID
    public let state: BurnBarLinuxPrivacyStoreState
    public let bytes: Int64
    public let reason: String

    public init(
        store: BurnBarLinuxPrivacyStoreID,
        state: BurnBarLinuxPrivacyStoreState,
        bytes: Int64,
        reason: String
    ) {
        self.store = store
        self.state = state
        self.bytes = bytes
        self.reason = reason
    }
}

public struct BurnBarLinuxPrivacyInventoryRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarLinuxPrivacyInventoryResponse: Codable, Hashable, Sendable {
    public let stores: [BurnBarLinuxPrivacyStoreInventory]
    public let generatedAt: Date

    public init(stores: [BurnBarLinuxPrivacyStoreInventory], generatedAt: Date) {
        self.stores = stores
        self.generatedAt = generatedAt
    }
}

public struct BurnBarLinuxPrivacyDeletionPreviewRequest: Codable, Hashable, Sendable {
    public let stores: [BurnBarLinuxPrivacyStoreID]

    public init(stores: [BurnBarLinuxPrivacyStoreID]) {
        self.stores = stores
    }
}

public struct BurnBarLinuxPrivacyDeletionPreviewResponse: Codable, Hashable, Sendable {
    public let token: String
    public let stores: [BurnBarLinuxPrivacyStoreID]
    public let entries: [BurnBarLinuxPrivacyStoreInventory]
    public let expiresAt: Date
    public let confirmationPhrase: String

    public init(
        token: String,
        stores: [BurnBarLinuxPrivacyStoreID],
        entries: [BurnBarLinuxPrivacyStoreInventory],
        expiresAt: Date,
        confirmationPhrase: String
    ) {
        self.token = token
        self.stores = stores
        self.entries = entries
        self.expiresAt = expiresAt
        self.confirmationPhrase = confirmationPhrase
    }
}

public struct BurnBarLinuxPrivacyDeletionExecuteRequest: Codable, Hashable, Sendable {
    public let token: String
    public let stores: [BurnBarLinuxPrivacyStoreID]
    public let confirmation: String

    public init(
        token: String,
        stores: [BurnBarLinuxPrivacyStoreID],
        confirmation: String
    ) {
        self.token = token
        self.stores = stores
        self.confirmation = confirmation
    }
}

public struct BurnBarLinuxPrivacyDeletionExecuteResponse: Codable, Hashable, Sendable {
    public let stores: [BurnBarLinuxPrivacyStoreID]
    public let deleted: [BurnBarLinuxPrivacyStoreID]
    public let alreadyAbsent: [BurnBarLinuxPrivacyStoreID]
    public let bytesRemoved: Int64
    public let idempotent: Bool

    public init(
        stores: [BurnBarLinuxPrivacyStoreID],
        deleted: [BurnBarLinuxPrivacyStoreID],
        alreadyAbsent: [BurnBarLinuxPrivacyStoreID],
        bytesRemoved: Int64,
        idempotent: Bool
    ) {
        self.stores = stores
        self.deleted = deleted
        self.alreadyAbsent = alreadyAbsent
        self.bytesRemoved = bytesRemoved
        self.idempotent = idempotent
    }
}

/// Daemon-owned encrypted export of the explicitly selected local privacy
/// stores. The path and passphrase are consumed by the native daemon only;
/// neither is persisted in the renderer or returned in diagnostics.
public struct BurnBarLinuxPrivacyExportRequest: Codable, Hashable, Sendable {
    public let stores: [BurnBarLinuxPrivacyStoreID]
    public let destinationPath: String
    public let passphrase: String

    public init(
        stores: [BurnBarLinuxPrivacyStoreID],
        destinationPath: String,
        passphrase: String
    ) {
        self.stores = stores
        self.destinationPath = destinationPath
        self.passphrase = passphrase
    }
}

public struct BurnBarLinuxPrivacyExportResponse: Codable, Hashable, Sendable {
    public let stores: [BurnBarLinuxPrivacyStoreID]
    public let destinationPath: String
    public let byteCount: Int64
    public let formatVersion: Int

    public init(
        stores: [BurnBarLinuxPrivacyStoreID],
        destinationPath: String,
        byteCount: Int64,
        formatVersion: Int
    ) {
        self.stores = stores
        self.destinationPath = destinationPath
        self.byteCount = byteCount
        self.formatVersion = formatVersion
    }
}
