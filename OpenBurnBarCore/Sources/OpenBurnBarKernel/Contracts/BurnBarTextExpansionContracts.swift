import Foundation

/// Wire representation shared by the Linux shell and daemon. Dates stay
/// canonical ISO-8601 strings so the renderer never has to interpret Swift's
/// platform-specific Date encoding.
public struct BurnBarTextExpansionScope: Codable, Hashable, Sendable {
    public let surfaces: [String]
    public let bundleIdentifiers: [String]
    public let threadIDs: [String]

    public init(
        surfaces: [String],
        bundleIdentifiers: [String] = [],
        threadIDs: [String] = []
    ) {
        self.surfaces = surfaces
        self.bundleIdentifiers = bundleIdentifiers
        self.threadIDs = threadIDs
    }
}

public struct BurnBarTextExpansionWireSnippet: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let trigger: String
    public let body: String
    public let mode: String
    public let isEnabled: Bool
    public let scope: BurnBarTextExpansionScope
    public let revision: Int
    public let createdAt: String
    public let updatedAt: String
    public let deletedAt: String?
    public let syncedAt: String?
    public let sourceDeviceID: String?

    public init(
        id: String,
        title: String,
        trigger: String,
        body: String,
        mode: String,
        isEnabled: Bool,
        scope: BurnBarTextExpansionScope,
        revision: Int,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil,
        syncedAt: String? = nil,
        sourceDeviceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.trigger = trigger
        self.body = body
        self.mode = mode
        self.isEnabled = isEnabled
        self.scope = scope
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncedAt = syncedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

public struct BurnBarTextExpansionConsent: Codable, Hashable, Sendable {
    public let inAppOnly: Bool
    public let acknowledgedAt: String
    public let declinedGlobalCapture: Bool

    public init(inAppOnly: Bool, acknowledgedAt: String, declinedGlobalCapture: Bool) {
        self.inAppOnly = inAppOnly
        self.acknowledgedAt = acknowledgedAt
        self.declinedGlobalCapture = declinedGlobalCapture
    }
}

public struct BurnBarTextExpansionSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: String
    public let snippets: [BurnBarTextExpansionWireSnippet]
    public let consent: BurnBarTextExpansionConsent?

    public init(
        schemaVersion: Int = 1,
        exportedAt: String,
        snippets: [BurnBarTextExpansionWireSnippet],
        consent: BurnBarTextExpansionConsent? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.snippets = snippets
        self.consent = consent
    }
}

public struct BurnBarTextExpansionUpsertRequest: Codable, Hashable, Sendable {
    public let snippet: BurnBarTextExpansionWireSnippet

    public init(snippet: BurnBarTextExpansionWireSnippet) {
        self.snippet = snippet
    }
}

public struct BurnBarTextExpansionDeleteRequest: Codable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct BurnBarTextExpansionConsentUpdateRequest: Codable, Hashable, Sendable {
    public let inAppOnly: Bool
    public let declinedGlobalCapture: Bool

    public init(inAppOnly: Bool, declinedGlobalCapture: Bool) {
        self.inAppOnly = inAppOnly
        self.declinedGlobalCapture = declinedGlobalCapture
    }
}

public struct BurnBarTextExpansionConsentResponse: Codable, Hashable, Sendable {
    public let consent: BurnBarTextExpansionConsent

    public init(consent: BurnBarTextExpansionConsent) {
        self.consent = consent
    }
}
