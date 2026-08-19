import Foundation

/// The Safari surface is versioned independently from the daemon's socket
/// protocol. The native appex and WebExtension negotiate this value before
/// exchanging commands so an older installed extension fails closed instead of
/// interpreting a newer action shape.
public enum BurnBarSafariProtocol {
    public static let currentVersion = 1
    public static let maximumInlinePayloadBytes = 384 * 1024
    public static let maximumChunkedPayloadBytes = 12 * 1024 * 1024
    public static let defaultCommandTimeoutMillis = 30_000
}

public enum BurnBarSafariActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case pageContext = "page_context"
    case screenshot
    case fullPageScreenshot = "full_page_screenshot"
    case click
    case type
    case pressKey = "press_key"
    case scroll
    case hover
    case focus
    case selectOption = "select_option"
    case navigate
    case openTab = "open_tab"
    case closeTab = "close_tab"
    case listTabs = "list_tabs"
    case waitFor = "wait_for"
    case runJavaScript = "run_javascript"
    case extract
    case abort

    public var isReadOnly: Bool {
        switch self {
        case .pageContext, .screenshot, .fullPageScreenshot, .listTabs, .waitFor, .extract:
            return true
        case .click, .type, .pressKey, .scroll, .hover, .focus, .selectOption,
             .navigate, .openTab, .closeTab, .runJavaScript, .abort:
            return false
        }
    }

    public var modifiesPageOrSession: Bool { !isReadOnly }
}

/// The exact history/navigation operation requested by `safari.navigate`.
///
/// Keeping this separate from `BurnBarSafariActionKind` prevents the URL-only
/// shape from becoming an implicit default: callers must say whether they are
/// loading a URL, moving through history, or reloading the current page.
public enum BurnBarSafariNavigationOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case url
    case back
    case forward
    case reload
}

public struct BurnBarSafariViewport: Codable, Hashable, Sendable {
    public let width: Double
    public let height: Double
    public let devicePixelRatio: Double
    public let visualOffsetX: Double
    public let visualOffsetY: Double
    public let scrollX: Double
    public let scrollY: Double
    public let pageWidth: Double
    public let pageHeight: Double

    public init(
        width: Double,
        height: Double,
        devicePixelRatio: Double,
        visualOffsetX: Double = 0,
        visualOffsetY: Double = 0,
        scrollX: Double = 0,
        scrollY: Double = 0,
        pageWidth: Double,
        pageHeight: Double
    ) {
        self.width = width
        self.height = height
        self.devicePixelRatio = devicePixelRatio
        self.visualOffsetX = visualOffsetX
        self.visualOffsetY = visualOffsetY
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
    }
}

public struct BurnBarSafariPageState: Codable, Hashable, Sendable {
    public let tabId: Int
    public let windowId: Int?
    public let url: String
    public let title: String
    /// Monotonically increasing value assigned by the content script whenever
    /// top-frame navigation invalidates selectors and viewport coordinates.
    public let navigationEpoch: Int
    public let isActive: Bool
    public let isTopFrame: Bool
    public let capturedAt: Date

    public init(
        tabId: Int,
        windowId: Int? = nil,
        url: String,
        title: String,
        navigationEpoch: Int,
        isActive: Bool,
        isTopFrame: Bool = true,
        capturedAt: Date = Date()
    ) {
        self.tabId = tabId
        self.windowId = windowId
        self.url = url
        self.title = title
        self.navigationEpoch = navigationEpoch
        self.isActive = isActive
        self.isTopFrame = isTopFrame
        self.capturedAt = capturedAt
    }
}

public struct BurnBarSafariPageContext: Codable, Hashable, Sendable {
    public let pageState: BurnBarSafariPageState
    public let viewport: BurnBarSafariViewport
    public let readableMarkdown: String
    public let accessibilitySnapshot: String
    public let truncated: Bool
    public let sourceCharacterCount: Int

    public init(
        pageState: BurnBarSafariPageState,
        viewport: BurnBarSafariViewport,
        readableMarkdown: String,
        accessibilitySnapshot: String,
        truncated: Bool,
        sourceCharacterCount: Int
    ) {
        self.pageState = pageState
        self.viewport = viewport
        self.readableMarkdown = readableMarkdown
        self.accessibilitySnapshot = accessibilitySnapshot
        self.truncated = truncated
        self.sourceCharacterCount = sourceCharacterCount
    }
}

public struct BurnBarSafariTabSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: Int { tabId }

    public let tabId: Int
    public let windowId: Int?
    public let url: String
    public let title: String
    public let isActive: Bool
    public let isOwned: Bool
    public let navigationEpoch: Int

    public init(
        tabId: Int,
        windowId: Int? = nil,
        url: String,
        title: String,
        isActive: Bool,
        isOwned: Bool,
        navigationEpoch: Int
    ) {
        self.tabId = tabId
        self.windowId = windowId
        self.url = url
        self.title = title
        self.isActive = isActive
        self.isOwned = isOwned
        self.navigationEpoch = navigationEpoch
    }
}

public struct BurnBarSafariExtensionCapabilities: Codable, Hashable, Sendable {
    public let captureVisibleTab: Bool
    public let scripting: Bool
    public let nativeMessaging: Bool
    public let activeTabPermission: Bool
    public let siteAccessGranted: Bool

    public init(
        captureVisibleTab: Bool,
        scripting: Bool,
        nativeMessaging: Bool,
        activeTabPermission: Bool,
        siteAccessGranted: Bool
    ) {
        self.captureVisibleTab = captureVisibleTab
        self.scripting = scripting
        self.nativeMessaging = nativeMessaging
        self.activeTabPermission = activeTabPermission
        self.siteAccessGranted = siteAccessGranted
    }
}

public struct BurnBarSafariSessionAttachRequest: Codable, Hashable, Sendable {
    public let extensionInstanceId: String
    public let clientName: String
    public let supportedProtocolVersions: [Int]
    public let activePage: BurnBarSafariPageState?
    public let capabilities: BurnBarSafariExtensionCapabilities

    public init(
        extensionInstanceId: String,
        clientName: String,
        supportedProtocolVersions: [Int] = [BurnBarSafariProtocol.currentVersion],
        activePage: BurnBarSafariPageState? = nil,
        capabilities: BurnBarSafariExtensionCapabilities
    ) {
        self.extensionInstanceId = extensionInstanceId
        self.clientName = clientName
        self.supportedProtocolVersions = supportedProtocolVersions
        self.activePage = activePage
        self.capabilities = capabilities
    }
}

public struct BurnBarSafariSessionAttachResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let protocolVersion: Int
    public let leaseExpiresAt: Date
    public let pollAfterMillis: Int

    public init(
        sessionId: String,
        protocolVersion: Int,
        leaseExpiresAt: Date,
        pollAfterMillis: Int = 200
    ) {
        self.sessionId = sessionId
        self.protocolVersion = protocolVersion
        self.leaseExpiresAt = leaseExpiresAt
        self.pollAfterMillis = pollAfterMillis
    }
}

public struct BurnBarSafariSessionDetachRequest: Codable, Hashable, Sendable {
    public let sessionId: String
    public let reason: String?

    public init(sessionId: String, reason: String? = nil) {
        self.sessionId = sessionId
        self.reason = reason
    }
}

public struct BurnBarSafariSessionStatusRequest: Codable, Hashable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct BurnBarSafariSessionStatusResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let attached: Bool
    public let leaseExpiresAt: Date?
    public let activePage: BurnBarSafariPageState?
    public let ownedTabIds: [Int]

    public init(
        sessionId: String,
        attached: Bool,
        leaseExpiresAt: Date? = nil,
        activePage: BurnBarSafariPageState? = nil,
        ownedTabIds: [Int] = []
    ) {
        self.sessionId = sessionId
        self.attached = attached
        self.leaseExpiresAt = leaseExpiresAt
        self.activePage = activePage
        self.ownedTabIds = ownedTabIds
    }
}

public struct BurnBarSafariCommand: Codable, Hashable, Identifiable, Sendable {
    public var id: String { commandId }

    public let commandId: String
    public let sessionId: String
    public let action: BurnBarSafariActionKind
    public let arguments: BurnBarJSONValue
    public let targetTabId: Int?
    public let expectedNavigationEpoch: Int?
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        commandId: String = UUID().uuidString,
        sessionId: String,
        action: BurnBarSafariActionKind,
        arguments: BurnBarJSONValue = .object([:]),
        targetTabId: Int? = nil,
        expectedNavigationEpoch: Int? = nil,
        issuedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.commandId = commandId
        self.sessionId = sessionId
        self.action = action
        self.arguments = arguments
        self.targetTabId = targetTabId
        self.expectedNavigationEpoch = expectedNavigationEpoch
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct BurnBarSafariCommandPollRequest: Codable, Hashable, Sendable {
    public let sessionId: String
    public let activePage: BurnBarSafariPageState?
    public let knownTabs: [BurnBarSafariTabSnapshot]

    public init(
        sessionId: String,
        activePage: BurnBarSafariPageState? = nil,
        knownTabs: [BurnBarSafariTabSnapshot] = []
    ) {
        self.sessionId = sessionId
        self.activePage = activePage
        self.knownTabs = knownTabs
    }
}

public struct BurnBarSafariCommandPollResponse: Codable, Hashable, Sendable {
    public let command: BurnBarSafariCommand?
    public let leaseExpiresAt: Date
    public let pollAfterMillis: Int

    public init(
        command: BurnBarSafariCommand?,
        leaseExpiresAt: Date,
        pollAfterMillis: Int = 200
    ) {
        self.command = command
        self.leaseExpiresAt = leaseExpiresAt
        self.pollAfterMillis = pollAfterMillis
    }
}

public struct BurnBarSafariCommandCompletionRequest: Codable, Hashable, Sendable {
    public let sessionId: String
    public let commandId: String
    public let ok: Bool
    public let result: BurnBarJSONValue?
    public let error: String?
    public let pageState: BurnBarSafariPageState
    public let tabs: [BurnBarSafariTabSnapshot]

    public init(
        sessionId: String,
        commandId: String,
        ok: Bool,
        result: BurnBarJSONValue? = nil,
        error: String? = nil,
        pageState: BurnBarSafariPageState,
        tabs: [BurnBarSafariTabSnapshot] = []
    ) {
        self.sessionId = sessionId
        self.commandId = commandId
        self.ok = ok
        self.result = result
        self.error = error
        self.pageState = pageState
        self.tabs = tabs
    }
}

public struct BurnBarSafariCommandCompletionResponse: Codable, Hashable, Sendable {
    public let accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

public struct BurnBarSafariToolRequest: Codable, Hashable, Sendable {
    public let safariSessionId: String
    public let computerUseSessionId: String?
    public let runId: String?
    public let tabId: Int?
    public let expectedNavigationEpoch: Int?
    public let timeoutMillis: Int
    public let arguments: BurnBarJSONValue

    public init(
        safariSessionId: String,
        computerUseSessionId: String? = nil,
        runId: String? = nil,
        tabId: Int? = nil,
        expectedNavigationEpoch: Int? = nil,
        timeoutMillis: Int = BurnBarSafariProtocol.defaultCommandTimeoutMillis,
        arguments: BurnBarJSONValue = .object([:])
    ) {
        self.safariSessionId = safariSessionId
        self.computerUseSessionId = computerUseSessionId
        self.runId = runId
        self.tabId = tabId
        self.expectedNavigationEpoch = expectedNavigationEpoch
        self.timeoutMillis = timeoutMillis
        self.arguments = arguments
    }
}

public struct BurnBarSafariToolResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let result: BurnBarJSONValue?
    public let error: String?
    public let pageState: BurnBarSafariPageState
    public let auditEntryIndex: Int?
    public let auditHeadHashHex: String?

    public init(
        ok: Bool,
        result: BurnBarJSONValue? = nil,
        error: String? = nil,
        pageState: BurnBarSafariPageState,
        auditEntryIndex: Int? = nil,
        auditHeadHashHex: String? = nil
    ) {
        self.ok = ok
        self.result = result
        self.error = error
        self.pageState = pageState
        self.auditEntryIndex = auditEntryIndex
        self.auditHeadHashHex = auditHeadHashHex
    }
}

public struct BurnBarSafariBootstrapRequest: Codable, Hashable, Sendable {
    public let sessionId: String?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

public struct BurnBarSafariBootstrapResponse: Codable, Hashable, Sendable {
    public let daemonVersion: String
    public let protocolVersion: Int
    public let gatewayBaseURL: String?
    /// This is the daemon's loopback bearer, never a provider credential. The
    /// WebExtension keeps it in the background worker's memory and never
    /// exposes it to content scripts or page-world code.
    public let gatewayBearerToken: String?
    /// Opaque, short-lived proof that the general loopback gateway request was
    /// initiated by the exact currently attached Safari extension session.
    /// This capability grants attribution only: it is not provider, page-action,
    /// or Computer Use authority.
    public let gatewayAvailable: Bool
    public let computerUseAvailable: Bool
    public let learningAvailable: Bool
    public let learningOptedIn: Bool
    public let tier: String

    public init(
        daemonVersion: String,
        protocolVersion: Int,
        gatewayBaseURL: String?,
        gatewayBearerToken: String?,
        gatewayAvailable: Bool,
        computerUseAvailable: Bool,
        learningAvailable: Bool,
        learningOptedIn: Bool,
        tier: String
    ) {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.gatewayBaseURL = gatewayBaseURL
        self.gatewayBearerToken = gatewayBearerToken
        self.gatewayAvailable = gatewayAvailable
        self.computerUseAvailable = computerUseAvailable
        self.learningAvailable = learningAvailable
        self.learningOptedIn = learningOptedIn
        self.tier = tier
    }
}

public struct BurnBarSafariUISnapshotRequest: Codable, Hashable, Sendable {
    public let safariSessionId: String?
    public let computerUseSessionId: String?
    public let runId: String?

    public init(
        safariSessionId: String? = nil,
        computerUseSessionId: String? = nil,
        runId: String? = nil
    ) {
        self.safariSessionId = safariSessionId
        self.computerUseSessionId = computerUseSessionId
        self.runId = runId
    }
}


public struct BurnBarSafariUISnapshotResponse: Codable, Sendable {
    public let bootstrap: BurnBarSafariBootstrapResponse
    public let catalog: BurnBarCatalogResponse
    public let membership: BurnBarMembershipStatusResponse
    public let safariSession: BurnBarSafariSessionStatusResponse?
    public let run: BurnBarRunStateSnapshot?
    public let approvals: ComputerUseApprovalPendingResponse

    private enum CodingKeys: String, CodingKey {
        case bootstrap
        case catalog
        case membership
        case safariSession
        case run
        case approvals
    }

    public init(
        bootstrap: BurnBarSafariBootstrapResponse,
        catalog: BurnBarCatalogResponse,
        membership: BurnBarMembershipStatusResponse,
        safariSession: BurnBarSafariSessionStatusResponse?,
        run: BurnBarRunStateSnapshot?,
        approvals: ComputerUseApprovalPendingResponse
    ) {
        self.bootstrap = bootstrap
        self.catalog = catalog
        self.membership = membership
        self.safariSession = safariSession
        self.run = run
        self.approvals = approvals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bootstrap = try container.decode(
            BurnBarSafariBootstrapResponse.self,
            forKey: .bootstrap
        )
        catalog = try container.decode(
            BurnBarCatalogResponse.self,
            forKey: .catalog
        )
        membership = try container.decode(
            BurnBarMembershipStatusResponse.self,
            forKey: .membership
        )
        safariSession = try container.decodeIfPresent(
            BurnBarSafariSessionStatusResponse.self,
            forKey: .safariSession
        )
        run = try container.decodeIfPresent(
            BurnBarRunStateSnapshot.self,
            forKey: .run
        )
        approvals = try container.decode(
            ComputerUseApprovalPendingResponse.self,
            forKey: .approvals
        )
    }
}



public enum BurnBarSafariApprovalDecision: String, Codable, CaseIterable, Hashable, Sendable {
    case allowOnce = "allow_once"
    case allowSession = "allow_session"
    case block
}

/// Authenticated Safari approval response. The request intentionally contains
/// no Computer Use session identifier: the daemon resolves that identity from
/// the live Safari session mapping and rejects stale or substituted approvals.
public struct BurnBarSafariApprovalRespondRequest: Codable, Hashable, Sendable {
    public let safariSessionId: String
    public let approvalId: String
    public let decision: BurnBarSafariApprovalDecision

    public init(
        safariSessionId: String,
        approvalId: String,
        decision: BurnBarSafariApprovalDecision
    ) {
        self.safariSessionId = safariSessionId
        self.approvalId = approvalId
        self.decision = decision
    }
}

public struct BurnBarSafariApprovalRespondResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let approvalId: String
    public let runId: String

    public init(accepted: Bool, approvalId: String, runId: String) {
        self.accepted = accepted
        self.approvalId = approvalId
        self.runId = runId
    }
}

public enum BurnBarSafariTrustDecision: String, Codable, CaseIterable, Hashable, Sendable {
    case allow
    case deny
    case remove
}

/// Updates the daemon-owned, future-session trust policy for one exact HTTPS
/// origin. Live Computer Use manifests stay immutable; a changed policy takes
/// effect when the popup starts the next Safari Computer Use session.
public struct BurnBarSafariTrustUpdateRequest: Codable, Hashable, Sendable {
    public let safariSessionId: String
    public let origin: String
    public let decision: BurnBarSafariTrustDecision
    public let trustMode: String
    public let actionBudget: Int?
    public let expiresAt: Date?
    public let killSwitchEnabled: Bool?

    public init(
        safariSessionId: String,
        origin: String,
        decision: BurnBarSafariTrustDecision,
        trustMode: String,
        actionBudget: Int? = nil,
        expiresAt: Date? = nil,
        killSwitchEnabled: Bool? = nil
    ) {
        self.safariSessionId = safariSessionId
        self.origin = origin
        self.decision = decision
        self.trustMode = trustMode
        self.actionBudget = actionBudget
        self.expiresAt = expiresAt
        self.killSwitchEnabled = killSwitchEnabled
    }
}

public struct BurnBarSafariTrustUpdateResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let ruleId: String?
    public let origin: String
    public let decision: BurnBarSafariTrustDecision
    public let killSwitchEnabled: Bool

    public init(
        accepted: Bool,
        ruleId: String?,
        origin: String,
        decision: BurnBarSafariTrustDecision,
        killSwitchEnabled: Bool
    ) {
        self.accepted = accepted
        self.ruleId = ruleId
        self.origin = origin
        self.decision = decision
        self.killSwitchEnabled = killSwitchEnabled
    }
}



















