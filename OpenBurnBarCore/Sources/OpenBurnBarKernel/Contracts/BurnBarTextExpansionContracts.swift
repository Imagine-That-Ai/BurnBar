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

/// Native Linux text-expansion capability information.
///
/// This is deliberately diagnostic rather than an enablement claim.  The
/// daemon may discover an IBus/Fcitx session, but it must not advertise global
/// expansion until a packaged input-method engine is registered and its
/// secure-field contract is proven.  Keeping this optional preserves wire
/// compatibility with older daemons and keeps the in-app Composer usable when
/// no desktop input method is available.
public struct BurnBarTextExpansionNativeStatus: Codable, Hashable, Sendable {
    public let status: String
    public let backend: String?
    public let backendPath: String?
    public let sessionType: String
    public let registration: String
    public let supportsExternalExpansion: Bool
    public let secureFieldPolicy: String
    public let noGlobalCapture: Bool
    public let detail: String
    public let checkedAt: String

    public init(
        status: String,
        backend: String? = nil,
        backendPath: String? = nil,
        sessionType: String,
        registration: String,
        supportsExternalExpansion: Bool,
        secureFieldPolicy: String,
        noGlobalCapture: Bool = true,
        detail: String,
        checkedAt: String
    ) {
        self.status = status
        self.backend = backend
        self.backendPath = backendPath
        self.sessionType = sessionType
        self.registration = registration
        self.supportsExternalExpansion = supportsExternalExpansion
        self.secureFieldPolicy = secureFieldPolicy
        self.noGlobalCapture = noGlobalCapture
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public struct BurnBarTextExpansionSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: String
    public let snippets: [BurnBarTextExpansionWireSnippet]
    public let consent: BurnBarTextExpansionConsent?
    public let nativeStatus: BurnBarTextExpansionNativeStatus?

    public init(
        schemaVersion: Int = 1,
        exportedAt: String,
        snippets: [BurnBarTextExpansionWireSnippet],
        consent: BurnBarTextExpansionConsent? = nil,
        nativeStatus: BurnBarTextExpansionNativeStatus? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.snippets = snippets
        self.consent = consent
        self.nativeStatus = nativeStatus
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

/// Daemon-owned lifecycle status for a packaged Linux text-expansion engine.
/// The status is deliberately text-free: it contains no clipboard, keyboard,
/// surrounding-text, or field contents.
public struct BurnBarTextExpansionEngineRuntimeStatus: Codable, Hashable, Sendable {
    public let state: String
    public let engineID: String?
    public let executablePath: String?
    public let registration: String
    public let supportsExternalExpansion: Bool
    public let detail: String
    public let checkedAt: String

    public init(
        state: String,
        engineID: String? = nil,
        executablePath: String? = nil,
        registration: String,
        supportsExternalExpansion: Bool,
        detail: String,
        checkedAt: String
    ) {
        self.state = state
        self.engineID = engineID
        self.executablePath = executablePath
        self.registration = registration
        self.supportsExternalExpansion = supportsExternalExpansion
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public struct BurnBarTextExpansionEngineStartRequest: Codable, Hashable, Sendable {
    /// This must be true in addition to the daemon's persisted consent record;
    /// the renderer cannot elevate a previously declined global-capture policy.
    public let consentAcknowledged: Bool
    public let timeoutMillis: Int

    public init(consentAcknowledged: Bool, timeoutMillis: Int = 1_000) {
        self.consentAcknowledged = consentAcknowledged
        self.timeoutMillis = timeoutMillis
    }
}

public struct BurnBarTextExpansionEngineStopRequest: Codable, Hashable, Sendable {
    public let timeoutMillis: Int

    public init(timeoutMillis: Int = 500) {
        self.timeoutMillis = timeoutMillis
    }
}
