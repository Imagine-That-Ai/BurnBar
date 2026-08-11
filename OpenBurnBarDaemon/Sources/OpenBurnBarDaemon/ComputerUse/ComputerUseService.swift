import Foundation
import OpenBurnBarEngine
import OpenBurnBarComputerUseCore

/// Daemon RPC facade for Computer Use session lifecycle.
///
/// The Mac app still owns interactive approval UI and Mac-wide CGEvent
/// dispatch. This service makes the wire contracts reachable, owns
/// browser-session Playwright drivers, and rejects app-owned modes at session
/// start on macOS so callers cannot create a daemon session that appears valid
/// but can never dispatch Path A/C. On Linux, the daemon owns system input via
/// Linux-native adapters because there is no AppKit host process to inject it.
public actor ComputerUseService {
    public typealias ApprovalPublisher = @Sendable (HermesRealtimeRelayApprovalRequest) async throws -> Void
    public typealias SessionEndedObserver = @Sendable (String) async -> Void
    public enum ServiceError: Error, LocalizedError, Sendable, Equatable {
        case invalidMode(String)
        case invalidTrustMode(String)
        case invalidSession(String)
        case invalidExecutionSurface(String)
        case safariSessionUnavailable(String)
        case safariSessionMismatch(expected: String, actual: String)
        case incompatibleToolForExecutionSurface(String)
        case browserRunRequired
        case runBindingUnsupportedMode(String)
        case runAlreadyBound(String)
        case runNotBound(String)
        case runIdentityMismatch(expected: String, actual: String)
        case clientIdentityMismatch(expected: String, actual: String)
        case authorizationExpired(String)
        case managedRunDispatchRequired
        case bridgeScriptMissing
        case unsupportedDaemonMode(String)
        case unsupportedDaemonApprovalPath
        case capabilityStateUnavailable(String)
        case capabilityDenied(String)

        public var errorDescription: String? {
            switch self {
            case .invalidMode(let mode):
                return "Unknown Computer Use mode: \(mode)."
            case .invalidTrustMode(let mode):
                return "Unknown Computer Use trust mode: \(mode)."
            case .invalidSession(let sessionID):
                return "Computer Use session is not active: \(sessionID)."
            case .invalidExecutionSurface(let detail):
                return "Computer Use execution surface is invalid: \(detail)."
            case .safariSessionUnavailable(let sessionID):
                return "Safari extension session is not attached: \(sessionID)."
            case .safariSessionMismatch(let expected, let actual):
                return "Computer Use is bound to Safari session \(expected), not \(actual)."
            case .incompatibleToolForExecutionSurface(let detail):
                return "Computer Use tool does not match its execution surface: \(detail)."
            case .browserRunRequired:
                return "Browser Computer Use must be bound to an active agent run."
            case .runBindingUnsupportedMode(let mode):
                return "Agent run binding is not supported for Computer Use mode: \(mode)."
            case .runAlreadyBound(let runID):
                return "Agent run already has an active Computer Use session: \(runID)."
            case .runNotBound(let runID):
                return "Start Browser Computer Use for agent run \(runID) before allowing browser actions."
            case .runIdentityMismatch(let expected, let actual):
                return "Computer Use session is bound to run \(expected), not \(actual)."
            case .clientIdentityMismatch(let expected, let actual):
                return "Computer Use session is bound to client \(expected), not \(actual)."
            case .authorizationExpired(let runID):
                return "Computer Use authorization expired for agent run \(runID); authenticate and start a new session."
            case .managedRunDispatchRequired:
                return "Browser Computer Use actions must be dispatched by the bound agent run."
            case .bridgeScriptMissing:
                return "The installed Playwright bridge is missing."
            case .unsupportedDaemonMode(let mode):
                return "Computer Use mode is not available through this daemon: \(mode)."
            case .unsupportedDaemonApprovalPath:
                return "The Computer Use approval path is unavailable."
            case .capabilityStateUnavailable(let reason):
                return "Computer Use capability state is unavailable: \(reason)."
            case .capabilityDenied(let reason):
                return "Computer Use capability denied the request: \(reason)."
            }
        }
    }

    private static let computerUseProductId = ComputerUseEntitlementSnapshot.hostedProductID

    private let coordinator: ComputerUseRunCoordinator
    private let safariSessionBroker: BurnBarSafariSessionBroker
    private let approvalBridge: ComputerUseApprovalBridge
    private let authorizationRegistry: ComputerUseAuthorizationRegistry
    private let auditBaseDirectory: URL
    private let macAppVersion: String
    private let locateExecutable: BurnBarExecutableLocator
    private let logger: BurnBarDaemonLogger
    private let bridgeScriptURL: URL
    private let auditExportSignerProvider: any ComputerUseAuditExportSignerProviding
    private let capabilityStateStore: ComputerUseCapabilityStateStore
    private let quotaLedger: ComputerUseLocalQuotaLedger
    private let leafKillSwitch: @Sendable () -> Bool
    private let playwrightDriverFactory: (@Sendable (ComputerUseSessionManifest) async throws -> OpenBurnBarPlaywrightDriver?)?
    private let systemInputAccessibilityTrusted: @Sendable (ComputerUseMode) -> Bool
    private let systemInputAccessibilityDeny: @Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason?
    private let computerUseKillSwitchEnabled: @Sendable () -> Bool
    private let privilegedInputKillSwitchActivator: @Sendable (String) -> Void
    private let requiresManagedBrowserRunAuthority: Bool
    private let approvalPublisher: ApprovalPublisher?
    private let sessionEndedObserver: SessionEndedObserver?
    private let systemCapabilityProvider: (@Sendable () async -> ComputerUseSystemCapabilitySnapshot)?
#if os(Linux)
    private let linuxInputSessionManager: LinuxComputerUseInputSessionManager
#endif
    private var manifests: [ComputerUseSessionID: ComputerUseSessionManifest] = [:]
    private var computerUseSessionIDBySafariSessionID: [String: ComputerUseSessionID] = [:]
    private var safariSessionIDByComputerUseSessionID: [ComputerUseSessionID: String] = [:]
    private var safariSessionIDByExtensionInstanceID: [String: String] = [:]
    private var pendingEndedSessions: [ComputerUseSessionEndRecord] = []
    private var sessionStartReserved = false
    private var timeoutTasks: [ComputerUseSessionID: Task<Void, Never>] = [:]
    // Multiple expiry paths can observe the same session while its cleanup
    // awaits another actor (for example, polling can race the timeout task).
    // Share one teardown task so callers that need the session gone do not
    // resume until the coordinator and run binding have both been released.
    private var haltTasks: [ComputerUseSessionID: Task<ComputerUseSessionEndRecord?, Never>] = [:]
    private var revokingSessionIDs: Set<ComputerUseSessionID> = []

    public init(
        auditBaseDirectory: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("computer-use-audit", isDirectory: true),
        macAppVersion: String = BurnBarDaemonVersion.current,
        bridgeScriptURL: URL? = nil,
        locateExecutable: BurnBarExecutableLocator? = nil,
        auditExportSignerProvider: (any ComputerUseAuditExportSignerProviding)? = nil,
        quotaLedger: ComputerUseLocalQuotaLedger = ComputerUseLocalQuotaLedger(
            directory: ComputerUseLocalQuotaLedger.defaultDirectory()
        ),
        systemInputDispatcher: ComputerUseRunCoordinator.MacInputDispatcher? = nil,
        systemInspectDispatcher: ComputerUseRunCoordinator.MacInspectDispatcher? = nil,
        systemInputAccessibilityTrusted: (@Sendable (ComputerUseMode) -> Bool)? = nil,
        systemInputAccessibilityDeny: (@Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason?)? = nil,
        computerUseKillSwitchEnabled: (@Sendable () -> Bool)? = nil,
        privilegedInputKillSwitchActivator: (@Sendable (String) -> Void)? = nil,
        safariSessionBroker: BurnBarSafariSessionBroker = BurnBarSafariSessionBroker(),
        playwrightDriverFactory: (@Sendable (ComputerUseSessionManifest) async throws -> OpenBurnBarPlaywrightDriver?)? = nil,
        authorizationRegistry: ComputerUseAuthorizationRegistry? = nil,
        preDispatchAuthorizer: ComputerUseRunCoordinator.PreDispatchAuthorizer? = nil,
        requiresManagedBrowserRunAuthority: Bool? = nil,
        approvalPublisher: ApprovalPublisher? = nil,
        sessionEndedObserver: SessionEndedObserver? = nil,
        systemCapabilityProvider: (@Sendable () async -> ComputerUseSystemCapabilitySnapshot)? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-service")
    ) {
        self.init(
            auditBaseDirectory: auditBaseDirectory,
            macAppVersion: macAppVersion,
            bridgeScriptURL: bridgeScriptURL,
            locateExecutable: locateExecutable,
            auditExportSignerProvider: auditExportSignerProvider,
            quotaLedger: quotaLedger,
            capabilityStateStore: ComputerUseCapabilityStateStore(),
            leafKillSwitch: {
                #if os(macOS)
                PrivilegedInputKillSwitch.isActive
                #else
                false
                #endif
            },
            playwrightDriverFactory: playwrightDriverFactory,
            systemInputDispatcher: systemInputDispatcher,
            systemInspectDispatcher: systemInspectDispatcher,
            systemInputAccessibilityTrusted: systemInputAccessibilityTrusted,
            systemInputAccessibilityDeny: systemInputAccessibilityDeny,
            computerUseKillSwitchEnabled: computerUseKillSwitchEnabled,
            privilegedInputKillSwitchActivator: privilegedInputKillSwitchActivator,
            safariSessionBroker: safariSessionBroker,
            authorizationRegistry: authorizationRegistry,
            preDispatchAuthorizer: preDispatchAuthorizer,
            requiresManagedBrowserRunAuthority: requiresManagedBrowserRunAuthority,
            approvalPublisher: approvalPublisher,
            sessionEndedObserver: sessionEndedObserver,
            systemCapabilityProvider: systemCapabilityProvider,
            logger: logger
        )
    }

    init(
        auditBaseDirectory: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("computer-use-audit", isDirectory: true),
        macAppVersion: String = BurnBarDaemonVersion.current,
        bridgeScriptURL: URL? = nil,
        locateExecutable: BurnBarExecutableLocator? = nil,
        auditExportSignerProvider: (any ComputerUseAuditExportSignerProviding)? = nil,
        quotaLedger: ComputerUseLocalQuotaLedger? = nil,
        capabilityStateStore: ComputerUseCapabilityStateStore,
        leafKillSwitch: @escaping @Sendable () -> Bool,
        playwrightDriverFactory: (@Sendable (ComputerUseSessionManifest) async throws -> OpenBurnBarPlaywrightDriver?)? = nil,
        systemInputDispatcher: ComputerUseRunCoordinator.MacInputDispatcher? = nil,
        systemInspectDispatcher: ComputerUseRunCoordinator.MacInspectDispatcher? = nil,
        systemInputAccessibilityTrusted: (@Sendable (ComputerUseMode) -> Bool)? = nil,
        systemInputAccessibilityDeny: (@Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason?)? = nil,
        computerUseKillSwitchEnabled: (@Sendable () -> Bool)? = nil,
        privilegedInputKillSwitchActivator: (@Sendable (String) -> Void)? = nil,
        safariSessionBroker: BurnBarSafariSessionBroker = BurnBarSafariSessionBroker(),
        authorizationRegistry: ComputerUseAuthorizationRegistry? = nil,
        preDispatchAuthorizer: ComputerUseRunCoordinator.PreDispatchAuthorizer? = nil,
        requiresManagedBrowserRunAuthority: Bool? = nil,
        approvalPublisher: ApprovalPublisher? = nil,
        sessionEndedObserver: SessionEndedObserver? = nil,
        systemCapabilityProvider: (@Sendable () async -> ComputerUseSystemCapabilitySnapshot)? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-service")
    ) {
        let approvalBridge = ComputerUseApprovalBridge()
        let authorizationRegistry = authorizationRegistry ?? ComputerUseAuthorizationRegistry(
            enforcementEnabled: false
        )
        self.approvalBridge = approvalBridge
        self.safariSessionBroker = safariSessionBroker
        self.authorizationRegistry = authorizationRegistry
        self.auditBaseDirectory = auditBaseDirectory
        self.macAppVersion = macAppVersion
        self.locateExecutable = locateExecutable ?? Self.defaultExecutableLocator
        self.logger = logger
        self.bridgeScriptURL = bridgeScriptURL ?? Self.defaultBridgeScriptURL()
        self.auditExportSignerProvider = auditExportSignerProvider ?? ComputerUseKeychainAuditExportSignerProvider(
            legacyRawKeyURL: Self.legacyRawAuditExportKeyURL(auditBaseDirectory: auditBaseDirectory)
        )
        let resolvedQuotaLedger = quotaLedger ?? ComputerUseLocalQuotaLedger(
            directory: auditBaseDirectory.appendingPathComponent(".quota-ledger", isDirectory: true)
        )
        self.quotaLedger = resolvedQuotaLedger
        self.capabilityStateStore = capabilityStateStore
        self.leafKillSwitch = leafKillSwitch
        self.playwrightDriverFactory = playwrightDriverFactory
        let defaultSystemInputDispatcher: ComputerUseRunCoordinator.MacInputDispatcher?
        let defaultSystemInspectDispatcher: ComputerUseRunCoordinator.MacInspectDispatcher?
        let defaultSystemAccessibilityTrusted: @Sendable (ComputerUseMode) -> Bool
        let defaultSystemAccessibilityDeny: @Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason?
        let defaultComputerUseKillSwitchEnabled: @Sendable () -> Bool
        let defaultPrivilegedInputKillSwitchActivator: @Sendable (String) -> Void
        #if os(Linux)
        let linuxInputAdapter = LinuxComputerUseInputAdapter()
        let linuxInputSessionManager = LinuxComputerUseInputSessionManager(adapter: linuxInputAdapter)
        self.linuxInputSessionManager = linuxInputSessionManager
        defaultSystemInputDispatcher = { sessionID, action in
            try await linuxInputSessionManager.dispatch(sessionID: sessionID, action: action)
        }
        defaultSystemInspectDispatcher = { _, action in
            try await linuxInputAdapter.inspectAccessibility(action)
        }
        defaultSystemAccessibilityTrusted = { mode in
            guard mode == .system else { return false }
            // X11/AT-SPI can be trusted immediately.  Wayland requires a
            // portal consent flow, but a probe-ready portal is still a valid
            // Linux system-input capability; the session manager obtains the
            // grant only after the normal Computer Use approval.
            return linuxInputAdapter.isAvailableForSystemInput()
                || linuxInputAdapter.waylandPortalCapability().isProbeReady
        }
        defaultSystemAccessibilityDeny = { action in
            linuxInputAdapter.accessibilityDenyReason(for: action)
        }
        defaultComputerUseKillSwitchEnabled = {
            LinuxPrivilegedInputKillFlag.isActive()
                || LinuxPrivilegedInputKillFlag.environmentKillSwitchActive()
        }
        defaultPrivilegedInputKillSwitchActivator = { reason in
            LinuxPrivilegedInputKillFlag.activate(reason: reason)
        }
        #else
        defaultSystemInputDispatcher = nil
        defaultSystemInspectDispatcher = nil
        defaultSystemAccessibilityTrusted = { _ in false }
        defaultSystemAccessibilityDeny = { _ in nil }
        defaultComputerUseKillSwitchEnabled = {
            PrivilegedInputKillSwitch.isActive
                || Self.environmentComputerUseKillSwitchEnabled()
                || leafKillSwitch()
        }
        defaultPrivilegedInputKillSwitchActivator = { reason in
            PrivilegedInputKillSwitch.activate(reason: reason)
        }
        #endif
        let resolvedComputerUseKillSwitchEnabled = computerUseKillSwitchEnabled
            ?? defaultComputerUseKillSwitchEnabled
        self.systemInputAccessibilityTrusted = systemInputAccessibilityTrusted ?? defaultSystemAccessibilityTrusted
        self.systemInputAccessibilityDeny = systemInputAccessibilityDeny ?? defaultSystemAccessibilityDeny
        self.computerUseKillSwitchEnabled = resolvedComputerUseKillSwitchEnabled
        self.privilegedInputKillSwitchActivator = privilegedInputKillSwitchActivator ?? defaultPrivilegedInputKillSwitchActivator
        let resolvedRequiresManagedBrowserRunAuthority = requiresManagedBrowserRunAuthority
            ?? Self.platformRequiresManagedBrowserRunAuthority
        self.requiresManagedBrowserRunAuthority = resolvedRequiresManagedBrowserRunAuthority
        self.approvalPublisher = approvalPublisher
        self.sessionEndedObserver = sessionEndedObserver
        let defaultSystemCapabilityProvider: (@Sendable () async -> ComputerUseSystemCapabilitySnapshot)?
#if os(Linux)
        let linuxSystemCapabilityProbe = LinuxComputerUseSystemCapabilityProbe()
        defaultSystemCapabilityProvider = {
            await linuxSystemCapabilityProbe.capability()
        }
#else
        defaultSystemCapabilityProvider = nil
#endif
        self.coordinator = ComputerUseRunCoordinator(
            approvalIssuer: { request in
                try await approvalBridge.issue(request, publisher: approvalPublisher)
            },
            macInputDispatcher: systemInputDispatcher ?? defaultSystemInputDispatcher,
            macInspectDispatcher: systemInspectDispatcher ?? defaultSystemInspectDispatcher,
            safariDispatcher: { _, action in
                try await safariSessionBroker.execute(action: action)
            },
            safariPageStateResolver: { safariSessionID in
                try await safariSessionBroker.activePage(sessionID: safariSessionID)
            },
            preDispatchAuthorizer: preDispatchAuthorizer ?? { sessionID, invocation in
                guard resolvedComputerUseKillSwitchEnabled() == false else { return false }
                guard invocation.tool.isBrowserComputerUse else { return true }
                guard resolvedRequiresManagedBrowserRunAuthority else { return true }
                return await authorizationRegistry.permits(sessionID: sessionID, invocation: invocation)
            },
            macAppVersion: macAppVersion,
            auditBaseDirectory: auditBaseDirectory,
            quotaLedger: resolvedQuotaLedger,
            logger: logger
        )
        // Assign this after the coordinator and every other stored property so
        // Swift's initialization rules are satisfied on Linux and macOS.
        self.systemCapabilityProvider = systemCapabilityProvider ?? defaultSystemCapabilityProvider
    }

    public func startSession(
        _ request: ComputerUseSessionStartRequest,
        boundClientID: BurnBarClientID? = nil,
        runGeneration: UInt64? = nil,
        scopeRules: [ComputerUseScopeRule] = []
    ) async throws -> ComputerUseSessionStartResponse {
        guard let mode = ComputerUseMode(rawValue: request.mode) else {
            throw ServiceError.invalidMode(request.mode)
        }
        guard let trustMode = ComputerUseTrustMode(rawValue: request.trustMode) else {
            throw ServiceError.invalidTrustMode(request.trustMode)
        }
        guard Self.supportsDaemonMode(mode) else {
            // Path A and Path C are app-owned on macOS because they depend on
            // the Mac app's live relay session, approval UI, AX trust state,
            // and CGEvent dispatcher. Linux allows `.system` because the
            // daemon wires Linux-native input adapters directly.
            throw ServiceError.unsupportedDaemonMode(mode.rawValue)
        }
        if mode != .browser, request.runID != nil {
            throw ServiceError.runBindingUnsupportedMode(mode.rawValue)
        }
        let isSafariSession = request.executionSurface == .safariExtension
        let normalizedSurfaceSessionID = request.executionSurfaceSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != .browser,
           request.executionSurface != nil || normalizedSurfaceSessionID != nil {
            throw ServiceError.invalidExecutionSurface(
                "Only browser-mode sessions may select a browser execution surface."
            )
        }
        if mode == .browser {
            switch request.executionSurface {
            case .safariExtension:
                #if !os(macOS)
                throw ServiceError.unsupportedDaemonMode("safari_extension")
                #else
                guard let safariSessionID = normalizedSurfaceSessionID,
                      safariSessionID.isEmpty == false,
                      safariSessionID.utf8.count <= 256 else {
                    throw ServiceError.invalidExecutionSurface(
                        "Safari requires an exact bounded executionSurfaceSessionId."
                    )
                }
                guard request.runID != nil else {
                    throw ServiceError.browserRunRequired
                }
                let expectedClientID = Self.safariClientID(sessionID: safariSessionID)
                guard request.clientID == expectedClientID,
                      boundClientID == nil || boundClientID == expectedClientID else {
                    throw ServiceError.clientIdentityMismatch(
                        expected: expectedClientID.rawValue,
                        actual: (boundClientID ?? request.clientID).rawValue
                    )
                }
                let status = try await safariSessionBroker.status(sessionID: safariSessionID)
                guard status.attached, let activePage = status.activePage else {
                    throw ServiceError.safariSessionUnavailable(safariSessionID)
                }
                try Self.validateSafeSafariLandedURL(activePage.url)
                guard computerUseSessionIDBySafariSessionID[safariSessionID] == nil else {
                    throw ServiceError.invalidExecutionSurface(
                        "Safari session \(safariSessionID) already owns a Computer Use session."
                    )
                }
                #endif
            case .managedBrowser, .none:
                guard normalizedSurfaceSessionID == nil else {
                    throw ServiceError.invalidExecutionSurface(
                        "Managed-browser sessions cannot carry a surface session identifier."
                    )
                }
            }
        }
        let requiresRunAuthority = mode == .browser
            && (requiresManagedBrowserRunAuthority || isSafariSession)
        if requiresRunAuthority, request.runID == nil {
            throw ServiceError.browserRunRequired
        }

        // A previous session may have already revoked its run binding while
        // its coordinator is still stopping. Wait for that shared teardown
        // before admission so a replacement cannot race the old coordinator.
        await waitForInFlightHalts()

        let capabilityState = try await currentCapabilityState()
        try await enforceSessionAdmission(capabilityState, mode: mode)
        guard !sessionStartReserved else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.concurrentSession.rawValue)
        }
        sessionStartReserved = true
        defer { sessionStartReserved = false }

        let reservedRunID = requiresRunAuthority ? request.runID : nil
        if let runID = reservedRunID {
            if let existing = await authorizationRegistry.binding(runID: runID),
               let expiresAt = existing.expiresAt,
               expiresAt <= Date() {
                _ = await haltSession(existing.sessionID, source: .stalled)
            }
            guard await authorizationRegistry.reserve(runID: runID) else {
                throw ServiceError.runAlreadyBound(runID.rawValue)
            }
        }

        let sessionId = ComputerUseSessionID.newRandom()
        let ownerClientID = boundClientID ?? request.clientID
        let effectiveActionCap = min(request.actionCap, capabilityState.budgetEnvelope.activeActionsPerRun)
        var manifest = ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: mode,
            trustMode: trustMode,
            startedAt: Date(),
            userId: ownerClientID.rawValue,
            runId: request.runID?.rawValue,
            executionSurface: request.executionSurface,
            executionSurfaceSessionId: normalizedSurfaceSessionID,
            macHostNodeId: request.macHostNodeId,
            phoneViewerNodeId: request.phoneViewerNodeId,
            scopeRuleIds: scopeRules.isEmpty ? request.scopeRuleIds : scopeRules.map(\.id.rawValue),
            scopeRules: scopeRules,
            entitlementProductId: Self.computerUseProductId,
            actionCap: effectiveActionCap,
            sessionTimeoutSeconds: request.sessionTimeoutSeconds
        )

        var driver: OpenBurnBarPlaywrightDriver?
        let head: String
        var didStartCoordinatorSession = false
        var didBindRun = false
        do {
            driver = try await makePlaywrightDriverIfNeeded(for: manifest)
            // Driver construction is an actor reentrancy point. Re-read the
            // authoritative state before starting it so a kill/revoke that
            // landed while construction was suspended wins the race.
            let refreshedCapabilityState = try await currentCapabilityState()
            try await enforceSessionAdmission(refreshedCapabilityState, mode: mode)
            let refreshedActionCap = min(
                request.actionCap,
                refreshedCapabilityState.budgetEnvelope.activeActionsPerRun
            )
            if refreshedActionCap != manifest.actionCap {
                manifest = ComputerUseSessionManifest(
                    sessionId: manifest.sessionId,
                    mode: manifest.mode,
                    trustMode: manifest.trustMode,
                    startedAt: manifest.startedAt,
                    userId: manifest.userId,
                    runId: manifest.runId,
                    executionSurface: manifest.executionSurface,
                    executionSurfaceSessionId: manifest.executionSurfaceSessionId,
                    macHostNodeId: manifest.macHostNodeId,
                    phoneViewerNodeId: manifest.phoneViewerNodeId,
                    scopeRuleIds: manifest.scopeRuleIds,
                    scopeRules: manifest.scopeRules,
                    entitlementProductId: manifest.entitlementProductId,
                    actionCap: refreshedActionCap,
                    sessionTimeoutSeconds: manifest.sessionTimeoutSeconds
                )
            }
            head = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)
            didStartCoordinatorSession = true
            guard await coordinator.session(sessionId) != nil else {
                throw ServiceError.invalidSession(sessionId.rawValue)
            }
            if requiresRunAuthority,
               let runID = request.runID {
                guard await authorizationRegistry.bind(
                    sessionID: sessionId,
                    runID: runID,
                    clientID: ownerClientID,
                    generation: runGeneration
                ) else {
                    throw ServiceError.runAlreadyBound(runID.rawValue)
                }
                didBindRun = true
            }
            let quotaReservation = try quotaLedger.reserveSession(
                idempotencyKey: sessionId.rawValue,
                authoritativeUsage: refreshedCapabilityState.quotaUsage,
                maximumSessions: refreshedCapabilityState.budgetEnvelope.activeSessionsPerDay,
                startedAt: manifest.startedAt
            )
            guard quotaReservation.inserted else {
                throw ServiceError.capabilityDenied(ComputerUseDenyReason.counterReplay.rawValue)
            }
        } catch {
            if didBindRun {
                await authorizationRegistry.revoke(sessionID: sessionId)
            }
            if didStartCoordinatorSession {
                _ = await coordinator.endSession(sessionId: sessionId, reason: .error)
            } else {
                await driver?.stop()
            }
            if let reservedRunID {
                await authorizationRegistry.releaseReservation(runID: reservedRunID)
            }
            throw error
        }
        manifests[sessionId] = manifest
        if let safariSessionID = manifest.executionSurfaceSessionId,
           manifest.executionSurface == .safariExtension {
            computerUseSessionIDBySafariSessionID[safariSessionID] = sessionId
            safariSessionIDByComputerUseSessionID[sessionId] = safariSessionID
        }
        scheduleTimeout(for: manifest)
        return ComputerUseSessionStartResponse(
            sessionId: sessionId.rawValue,
            manifestHashHex: head,
            startedAt: manifest.startedAt,
            entitlementProductId: Self.computerUseProductId,
            actionCap: manifest.actionCap
        )
    }

    // MARK: - Safari WebExtension session bridge

    public func attachSafariSession(
        _ request: BurnBarSafariSessionAttachRequest
    ) async throws -> BurnBarSafariSessionAttachResponse {
        let extensionInstanceID = request.extensionInstanceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let previousSafariSessionID = safariSessionIDByExtensionInstanceID[extensionInstanceID] {
            if let computerUseSessionID =
                computerUseSessionIDBySafariSessionID[previousSafariSessionID] {
                _ = await haltSession(computerUseSessionID, source: .revoked)
            }
            _ = await safariSessionBroker.detach(
                BurnBarSafariSessionDetachRequest(
                    sessionId: previousSafariSessionID,
                    reason: "extension_reconnected"
                )
            )
        }
        let response = try await safariSessionBroker.attach(request)
        safariSessionIDByExtensionInstanceID[extensionInstanceID] = response.sessionId
        return response
    }

    public func detachSafariSession(
        _ request: BurnBarSafariSessionDetachRequest
    ) async -> BurnBarSafariCommandCompletionResponse {
        if let computerUseSessionID = computerUseSessionIDBySafariSessionID[request.sessionId] {
            _ = await haltSession(computerUseSessionID, source: .revoked)
        }
        safariSessionIDByExtensionInstanceID = safariSessionIDByExtensionInstanceID.filter {
            $0.value != request.sessionId
        }
        return await safariSessionBroker.detach(request)
    }

    public func safariSessionStatus(
        sessionID: String
    ) async throws -> BurnBarSafariSessionStatusResponse {
        try await safariSessionBroker.status(sessionID: sessionID)
    }

    public func pollSafariCommand(
        _ request: BurnBarSafariCommandPollRequest
    ) async throws -> BurnBarSafariCommandPollResponse {
        try await safariSessionBroker.poll(request)
    }

    public func completeSafariCommand(
        _ request: BurnBarSafariCommandCompletionRequest
    ) async throws -> BurnBarSafariCommandCompletionResponse {
        try Self.validateSafeSafariLandedURL(request.pageState.url)
        return try await safariSessionBroker.complete(request)
    }

    public func safariActivePage(sessionID: String) async throws -> BurnBarSafariPageState {
        try await safariSessionBroker.activePage(sessionID: sessionID)
    }

    public func computerUseSessionID(
        forSafariSessionID safariSessionID: String
    ) -> ComputerUseSessionID? {
        computerUseSessionIDBySafariSessionID[safariSessionID]
    }

    public func computerUseManifest(
        sessionID: ComputerUseSessionID
    ) -> ComputerUseSessionManifest? {
        manifests[sessionID]
    }

    public func safariSessionID(
        forExtensionInstanceID extensionInstanceID: String
    ) -> String? {
        safariSessionIDByExtensionInstanceID[
            extensionInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
    }

    /// Returns the exact live Computer Use session for one immutable Safari run
    /// requirement. Every identity layer is checked: run, daemon client,
    /// client-session, tool call, generation, Safari surface session, manifest,
    /// and authorization-registry binding.
    public func safariRunBindingSessionID(
        _ requirement: BurnBarComputerUseRunRequirement
    ) async -> ComputerUseSessionID? {
        await safariRunBindingSessionID(
            requirement,
            requiresActiveAuthorization: true
        )
    }

    /// Dispatches a Safari run action without allowing a stale requirement to
    /// discover or reuse a replacement Computer Use session for the same run.
    public func invokeForSafariRun(
        _ requirement: BurnBarComputerUseRunRequirement
    ) async throws -> BurnBarComputerUseBrowserDispatchResult {
        guard let sessionID = await safariRunBindingSessionID(requirement) else {
            throw ServiceError.authorizationExpired(requirement.runID.rawValue)
        }
        let response = try await invoke(
            ComputerUseInvokeRequest(
                sessionId: sessionID.rawValue,
                invocation: requirement.invocation
            ),
            allowManagedRunDispatch: true
        )
        return BurnBarComputerUseBrowserDispatchResult(
            expectedSessionID: sessionID,
            response: response
        )
    }

    /// Revokes only the currently bound session that matches the complete
    /// Safari run requirement. A run ID or generation by itself is never
    /// sufficient authority for this path.
    public func revokeSafariRun(
        _ requirement: BurnBarComputerUseRunRequirement
    ) async {
        guard let sessionID = await safariRunBindingSessionID(
            requirement,
            requiresActiveAuthorization: false
        ) else {
            return
        }
        _ = await haltSession(sessionID, source: .revoked)
    }

    /// Panic-halts the exact Computer Use session currently attached to one
    /// Safari extension session. Optional expected identities make abort RPCs
    /// fail closed when the popup is holding stale run/session state.
    @discardableResult
    public func haltSafariComputerUseSession(
        safariSessionID: String,
        expectedComputerUseSessionID: ComputerUseSessionID? = nil,
        expectedRunID: BurnBarRunID? = nil,
        source: ComputerUsePanicSource = .revoked
    ) async -> Bool {
        let normalizedSafariSessionID = safariSessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSafariSessionID == safariSessionID,
              Self.isBoundedSafariSessionID(normalizedSafariSessionID),
              let sessionID =
                computerUseSessionIDBySafariSessionID[normalizedSafariSessionID],
              expectedComputerUseSessionID == nil
                || expectedComputerUseSessionID == sessionID,
              let manifest = manifests[sessionID],
              manifest.mode == .browser,
              manifest.executionSurface == .safariExtension,
              manifest.executionSurfaceSessionId == normalizedSafariSessionID,
              expectedRunID == nil
                || manifest.runId == expectedRunID?.rawValue else {
            return false
        }
        _ = await haltSession(sessionID, source: source)
        return true
    }

    public func updateCapabilityState(
        _ request: ComputerUseCapabilityStateUpdateRequest
    ) async throws -> ComputerUseCapabilityStateUpdateResponse {
        let response = try await capabilityStateStore.update(request.state)
        await terminateSessionsIfAuthorityRevoked(request.state)
        let endedSessions = pendingEndedSessions
        pendingEndedSessions.removeAll()
        return ComputerUseCapabilityStateUpdateResponse(
            accepted: response.accepted,
            publisherInstanceID: response.publisherInstanceID,
            revision: response.revision,
            expiresAt: response.expiresAt,
            endedSessions: endedSessions
        )
    }

    /// Routes daemon-managed agent browser tools through the same session,
    /// approval, scope, panic, and audit authority used by explicit CU RPCs.
    public func invokeForRun(_ invocation: BurnBarToolInvocation) async throws -> ComputerUseInvokeResponse {
        guard let sessionID = await liveSessionID(for: invocation.runID) else {
            throw ServiceError.runNotBound(invocation.runID.rawValue)
        }
        return try await invoke(ComputerUseInvokeRequest(
            sessionId: sessionID.rawValue,
            invocation: invocation
        ), allowManagedRunDispatch: true)
    }

    public func sessionID(for runID: BurnBarRunID) async -> ComputerUseSessionID? {
        await liveSessionID(for: runID)
    }

    private func liveSessionID(for runID: BurnBarRunID) async -> ComputerUseSessionID? {
        guard let authorization = await authorizationRegistry.binding(runID: runID) else {
            return nil
        }
        let sessionID = authorization.sessionID
        if revokingSessionIDs.contains(sessionID) {
            await waitForHalt(sessionID)
            return nil
        }
        if let expiresAt = authorization.expiresAt, expiresAt <= Date() {
            await haltSession(sessionID, source: .stalled)
            return nil
        }
        guard let manifest = manifests[sessionID],
              await coordinator.session(sessionID) != nil else {
            if manifests.removeValue(forKey: sessionID) != nil {
                let directory = auditBaseDirectory.appendingPathComponent(sessionID.rawValue, isDirectory: true)
                finalizeAuditHeadIfPossible(sessionDirectory: directory)
            }
            await releaseSafariBinding(for: sessionID)
            timeoutTasks.removeValue(forKey: sessionID)?.cancel()
            await authorizationRegistry.revoke(sessionID: sessionID)
            return nil
        }
        if manifest.sessionTimeoutSeconds > 0,
           Date().timeIntervalSince(manifest.startedAt) >= Double(manifest.sessionTimeoutSeconds) {
            await haltSession(sessionID, source: .stalled)
            return nil
        }
        return sessionID
    }

    private func safariRunBindingSessionID(
        _ requirement: BurnBarComputerUseRunRequirement,
        requiresActiveAuthorization: Bool
    ) async -> ComputerUseSessionID? {
        let invocation = requirement.invocation
        guard requirement.runID == invocation.runID,
              requirement.clientID == invocation.requestedBy,
              requirement.sessionID.rawValue.utf8.count <= 256,
              invocation.tool.isSafariComputerUse,
              Self.isBoundedCallID(invocation.callID),
              let safariSessionID = Self.safariSessionID(from: invocation),
              safariSessionID == requirement.sessionID.rawValue,
              requirement.clientID == Self.safariClientID(sessionID: safariSessionID),
              let mappedSessionID =
                computerUseSessionIDBySafariSessionID[safariSessionID],
              safariSessionIDByComputerUseSessionID[mappedSessionID]
                == safariSessionID,
              let manifest = manifests[mappedSessionID],
              manifest.sessionId == mappedSessionID,
              manifest.mode == .browser,
              manifest.executionSurface == .safariExtension,
              manifest.executionSurfaceSessionId == safariSessionID,
              manifest.runId == requirement.runID.rawValue,
              manifest.userId == requirement.clientID.rawValue else {
            return nil
        }

        if requiresActiveAuthorization {
            guard let liveSessionID = await liveSessionID(for: requirement.runID),
                  liveSessionID == mappedSessionID,
                  await authorizationRegistry.hasActiveBinding(
                    sessionID: mappedSessionID,
                    runID: requirement.runID,
                    clientID: requirement.clientID,
                    generation: requirement.generation
                  ) else {
                return nil
            }
        } else {
            guard let authorization =
                    await authorizationRegistry.binding(sessionID: mappedSessionID),
                  authorization.sessionID == mappedSessionID,
                  authorization.runID == requirement.runID,
                  authorization.clientID == requirement.clientID,
                  authorization.generation == requirement.generation else {
                return nil
            }
        }
        return mappedSessionID
    }

    private func scheduleTimeout(for manifest: ComputerUseSessionManifest) {
        guard manifest.sessionTimeoutSeconds > 0 else { return }
        let sessionID = manifest.sessionId
        timeoutTasks.removeValue(forKey: sessionID)?.cancel()
        timeoutTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(manifest.sessionTimeoutSeconds))
            guard Task.isCancelled == false else { return }
            await self?.expireSessionIfCurrent(sessionID)
        }
    }

    func constrainSessionExpiry(
        sessionID: ComputerUseSessionID,
        expiresAt: Date,
        now: Date = Date()
    ) {
        guard let manifest = manifests[sessionID] else { return }
        let manifestExpiry = manifest.sessionTimeoutSeconds > 0
            ? manifest.startedAt.addingTimeInterval(TimeInterval(manifest.sessionTimeoutSeconds))
            : .distantFuture
        let effectiveExpiry = min(expiresAt, manifestExpiry)
        let delay = max(0, effectiveExpiry.timeIntervalSince(now))
        timeoutTasks.removeValue(forKey: sessionID)?.cancel()
        timeoutTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            await self?.expireSessionIfCurrent(sessionID)
        }
    }

    private func expireSessionIfCurrent(_ sessionID: ComputerUseSessionID) async {
        guard manifests[sessionID] != nil else { return }
        await haltSession(sessionID, source: .stalled)
    }

    private func waitForInFlightHalts() async {
        let tasks = Array(haltTasks.values)
        for task in tasks {
            _ = await task.value
        }
    }

    private func waitForHalt(_ sessionID: ComputerUseSessionID) async {
        guard let task = haltTasks[sessionID] else { return }
        _ = await task.value
    }

    @discardableResult
    private func haltSession(
        _ sessionID: ComputerUseSessionID,
        source: ComputerUsePanicSource,
        closedAt: Date = Date()
    ) async -> ComputerUseSessionEndRecord? {
        if let existingTask = haltTasks[sessionID] {
            return await existingTask.value
        }

        timeoutTasks.removeValue(forKey: sessionID)?.cancel()
        revokingSessionIDs.insert(sessionID)

        let haltTask = Task<ComputerUseSessionEndRecord?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.finishHaltSession(
                sessionID,
                source: source,
                closedAt: closedAt
            )
        }
        haltTasks[sessionID] = haltTask
        let ended = await haltTask.value
        haltTasks.removeValue(forKey: sessionID)
        return ended
    }

    private func finishHaltSession(
        _ sessionID: ComputerUseSessionID,
        source: ComputerUsePanicSource,
        closedAt: Date
    ) async -> ComputerUseSessionEndRecord? {
        // Revoke authority before any cleanup await. Late approvals and
        // concurrent invokes must fail closed while the driver is stopping.
        await authorizationRegistry.revoke(sessionID: sessionID)
        if let sessionEndedObserver {
            await sessionEndedObserver(sessionID.rawValue)
        }
        await approvalBridge.cancel(sessionId: sessionID.rawValue)
        let ended = await coordinator.panicHalt(sessionId: sessionID, source: source)
#if os(Linux)
        await linuxInputSessionManager.stop(sessionID: sessionID)
#endif
        let directory = auditBaseDirectory.appendingPathComponent(sessionID.rawValue, isDirectory: true)
        finalizeAuditHeadIfPossible(sessionDirectory: directory, closedAt: ended?.endedAt ?? closedAt)
        manifests.removeValue(forKey: sessionID)
        await releaseSafariBinding(for: sessionID)
        revokingSessionIDs.remove(sessionID)
        return ended
    }

    public func invoke(_ request: ComputerUseInvokeRequest) async throws -> ComputerUseInvokeResponse {
        try await invoke(request, allowManagedRunDispatch: false)
    }

    private func invoke(
        _ request: ComputerUseInvokeRequest,
        allowManagedRunDispatch: Bool
    ) async throws -> ComputerUseInvokeResponse {
        let sessionId = ComputerUseSessionID(request.sessionId)
        guard revokingSessionIDs.contains(sessionId) == false else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        guard let manifest = manifests[sessionId],
              let state = await coordinator.session(sessionId) else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        let decodedAction = try await coordinator.actionDescriptor(invocation: request.invocation)
        try await validateExecutionSurface(
            manifest: manifest,
            action: decodedAction,
            invocation: request.invocation
        )
        if sessionRequiresRunAuthority(manifest) {
            guard allowManagedRunDispatch else {
                throw ServiceError.managedRunDispatchRequired
            }
            guard let expectedRunID = manifest.runId else {
                throw ServiceError.browserRunRequired
            }
            guard expectedRunID == request.invocation.runID.rawValue else {
                throw ServiceError.runIdentityMismatch(
                    expected: expectedRunID,
                    actual: request.invocation.runID.rawValue
                )
            }
            guard manifest.userId == request.invocation.requestedBy.rawValue else {
                throw ServiceError.clientIdentityMismatch(
                    expected: manifest.userId,
                    actual: request.invocation.requestedBy.rawValue
                )
            }
            guard await authorizationRegistry.permits(
                sessionID: sessionId,
                invocation: request.invocation
            ) else {
                await haltSession(sessionId, source: .revoked)
                throw ServiceError.authorizationExpired(request.invocation.runID.rawValue)
            }
        }

        let capabilityState: ComputerUseCapabilityStateSnapshot
        do {
            capabilityState = try await currentCapabilityState()
        } catch {
            await terminateAllSessions(reason: .error)
            return deniedResponse(request, reason: "capability_state_unavailable")
        }
        if effectiveKillSwitchEnabled(capabilityState) {
            await terminateAllSessions(source: .remoteConfig)
            return deniedResponse(request, reason: ComputerUseDenyReason.killSwitch.rawValue)
        }
        if capabilityState.authorizationRevoked ||
            !Self.entitlementIsActive(capabilityState.entitlement) ||
            capabilityState.entitlement.productId != Self.computerUseProductId ||
            !Self.entitlementAllowsMode(capabilityState.entitlement, mode: manifest.mode) {
            await terminateAllSessions(source: .revoked)
            return deniedResponse(request, reason: ComputerUseDenyReason.entitlement.rawValue)
        }

        let anotherDaemonSession = await coordinator.hasActiveSession(excluding: sessionId)
        let accessibilityDeny = await accessibilityDenyReason(
            for: decodedAction,
            mode: manifest.mode
        )
        let capability = ComputerUseCapabilityContext(
            entitlement: capabilityState.entitlement,
            envelope: capabilityState.budgetEnvelope,
            usage: capabilityState.quotaUsage,
            session: state,
            concurrentSessionActive: capabilityState.concurrentSessionActive || anotherDaemonSession,
            killSwitch: effectiveKillSwitchEnabled(capabilityState),
            accessibilityTrusted: systemInputAccessibilityTrusted(manifest.mode)
        )

        // CU-021 fix: resolve scope rules against the browser action URL.
        // When the manifest carries scope rules (populated by the Mac app at
        // session start), the daemon evaluates them here instead of hardcoding
        // `.notMatched`. Empty rules → `.notMatched` → Manual approval (same
        // as before this fix).
        let scopeContext = Self.resolveScopeContext(from: request.invocation)
        let scopeOutcome: ComputerUseScopeOutcome
        if manifest.scopeRules.isEmpty {
            scopeOutcome = .notMatched
        } else {
            let matcher = ComputerUseScopeMatcher()
            scopeOutcome = matcher.evaluate(rules: manifest.scopeRules, context: scopeContext)
        }

        return await coordinator.invoke(
            sessionId: sessionId,
            invocation: request.invocation,
            scopeContext: scopeContext,
            scopeOutcome: scopeOutcome,
            accessibilityDeny: accessibilityDeny,
            capability: capability
        )
    }

    func hasActiveSession() async -> Bool {
        await coordinator.hasActiveSession()
    }

    private static var platformRequiresManagedBrowserRunAuthority: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    public func pendingApprovals(
        _ request: ComputerUseApprovalPendingRequest
    ) async -> ComputerUseApprovalPendingResponse {
        let normalizedSessionID = request.sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredSessionID = normalizedSessionID?.isEmpty == false
            ? normalizedSessionID
            : nil
        let sessionActive: Bool?
        if let filteredSessionID {
            sessionActive = await isSessionActiveForPolling(
                ComputerUseSessionID(filteredSessionID)
            )
        } else {
            sessionActive = nil
        }
        let systemCapability = await systemCapabilityProvider?()
        return ComputerUseApprovalPendingResponse(
            requests: await approvalBridge.pendingApprovals(sessionId: filteredSessionID),
            sessionActive: sessionActive,
            systemCapability: systemCapability
        )
    }

    private func isSessionActiveForPolling(_ sessionID: ComputerUseSessionID) async -> Bool {
        if revokingSessionIDs.contains(sessionID) {
            await waitForHalt(sessionID)
            return false
        }
        guard let manifest = manifests[sessionID] else {
            return false
        }
        if manifest.sessionTimeoutSeconds > 0,
           Date().timeIntervalSince(manifest.startedAt) >= Double(manifest.sessionTimeoutSeconds) {
            await haltSession(sessionID, source: .stalled)
            return false
        }
        guard await coordinator.session(sessionID) != nil else {
            await haltSession(sessionID, source: .stalled)
            return false
        }
        // The coordinator lookup crosses actors. Recheck service-owned state
        // after that suspension so a concurrent halt cannot yield a stale true.
        return revokingSessionIDs.contains(sessionID) == false
            && manifests[sessionID] != nil
    }

    public func respondToApproval(
        _ request: ComputerUseApprovalRespondRequest
    ) async -> ComputerUseApprovalRespondResponse {
        ComputerUseApprovalRespondResponse(
            accepted: await approvalBridge.respond(
                sessionId: request.sessionId,
                response: request.response
            )
        )
    }

    /// Internal composition seam used by daemon-owned presenters and gateway
    /// integration tests. The request remains pending until the exact approval
    /// RPC response resolves it through the same bridge used by the coordinator.
    func awaitApprovalResponse(
        _ request: HermesRealtimeRelayApprovalRequest
    ) async throws -> HermesRealtimeRelayApprovalResponse {
        try await approvalBridge.issue(request)
    }

    public func panicHalt(_ request: ComputerUsePanicHaltRequest) async throws -> ComputerUsePanicHaltResponse {
        guard let source = ComputerUsePanicSource(rawValue: request.source) else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        if request.sessionId == "*" {
            privilegedInputKillSwitchActivator(source.rawValue)
            let endedAt = Date()
            let manifestedSessionIDs = await revokeAllSessionAuthority()
            let haltedSessions = await coordinator.panicHaltAllWithRecords(source: source)
            let haltedSessionIDs = Set(haltedSessions.map { ComputerUseSessionID($0.sessionId) })
            let recordsBySessionID = Dictionary(
                uniqueKeysWithValues: haltedSessions.map { (ComputerUseSessionID($0.sessionId), $0) }
            )
            for sessionId in manifestedSessionIDs.union(haltedSessionIDs) {
                let sessionDirectory = auditBaseDirectory.appendingPathComponent(sessionId.rawValue, isDirectory: true)
                finalizeAuditHeadIfPossible(
                    sessionDirectory: sessionDirectory,
                    closedAt: recordsBySessionID[sessionId]?.endedAt ?? endedAt
                )
                manifests.removeValue(forKey: sessionId)
                revokingSessionIDs.remove(sessionId)
            }
            return ComputerUsePanicHaltResponse(
                sessionId: request.sessionId,
                endedAt: endedAt,
                auditHeadHashHex: ""
            )
        }

        let sessionId = ComputerUseSessionID(request.sessionId)
        guard manifests[sessionId] != nil,
              let state = await coordinator.session(sessionId) else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        privilegedInputKillSwitchActivator(source.rawValue)
        let ended = await haltSession(sessionId, source: source)
        let endedAt = ended?.endedAt ?? Date()
        return ComputerUsePanicHaltResponse(
            sessionId: sessionId.rawValue,
            endedAt: endedAt,
            auditHeadHashHex: ended?.auditHeadHashHex ?? state.auditChainHeadHashHex ?? ""
        )
    }

    public func exportAudit(_ request: ComputerUseAuditExportRequest) async throws -> ComputerUseAuditExportResponse {
        let sessionId = ComputerUseSessionID(request.sessionId)
        let sessionDirectory = auditBaseDirectory.appendingPathComponent(sessionId.rawValue, isDirectory: true)
        let destination = auditBaseDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(sessionId.rawValue).tar.gz", isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let chainURL = sessionDirectory.appendingPathComponent("chain.jsonl")
        let signer = try deviceAuditExportSigner()
        let signedHead = try ComputerUseAuditHeadFinalizer.finalizeSessionDirectory(
            sessionDirectory,
            signer: signer
        )
        if request.anchorOpenTimestamps {
            try await anchorOpenTimestampsProof(forChainAt: chainURL, signedHead: signedHead)
        }
        let result = try ComputerUseAuditExportWriter().export(
            sessionDirectory: sessionDirectory,
            destinationURL: destination,
            includeScreenshots: request.includeScreenshots,
            signer: signer
        )
        return ComputerUseAuditExportResponse(
            sessionId: sessionId.rawValue,
            archiveURL: result.archiveURL.path,
            signatureURL: result.signatureURL?.path,
            archiveSizeBytes: result.archiveSizeBytes,
            entryCount: result.entryCount,
            headHashHex: result.headHashHex,
            archiveSHA256Hex: result.archiveSHA256Hex,
            signatureAlgorithm: result.signature?.algorithm,
            signatureSignerIdentifier: result.signature?.signerIdentifier,
            signatureSignerKind: result.signature?.signerKind,
            signatureTrustRoot: result.signature?.trustRoot,
            signaturePublicKeyBase64: result.signature?.publicKeyBase64,
            signaturePublicKeySHA256Hex: result.signature?.publicKeySHA256Hex,
            openTimestampsProofBase64: openTimestampsProofBase64(
                forChainAt: sessionDirectory.appendingPathComponent("chain.jsonl")
            )
        )
    }

    private func deviceAuditExportSigner() throws -> ComputerUseEd25519AuditExportSigner {
        try auditExportSignerProvider.signer()
    }

    private func anchorOpenTimestampsProof(
        forChainAt chainURL: URL,
        signedHead: ComputerUseAuditSignedHead
    ) async throws {
        let client = ComputerUseOpenTimestampsClient()
        let proof = try await client.notarize(chainFileAt: chainURL)
        _ = try ComputerUseOpenTimestampsArchive.writeProof(
            proofBytes: proof,
            sourceChainURL: chainURL,
            calendarURL: client.configuration.calendarURL,
            auditHeadHashHex: signedHead.headHashHex,
            sessionId: signedHead.sessionId
        )
    }

    private func openTimestampsProofBase64(forChainAt chainURL: URL) -> String? {
        let proofURL = ComputerUseOpenTimestampsClient.proofFilename(forChainAt: chainURL)
        guard let proof = try? Data(contentsOf: proofURL), proof.isEmpty == false else {
            return nil
        }
        return proof.base64EncodedString()
    }

    private func finalizeAuditHeadIfPossible(sessionDirectory: URL, closedAt: Date = Date()) {
        guard let signer = try? deviceAuditExportSigner() else { return }
        _ = try? ComputerUseAuditHeadFinalizer.finalizeSessionDirectory(
            sessionDirectory,
            closedAt: closedAt,
            signer: signer
        )
    }

    private func makePlaywrightDriverIfNeeded(
        for manifest: ComputerUseSessionManifest
    ) async throws -> OpenBurnBarPlaywrightDriver? {
        guard manifest.executionSurface != .safariExtension else { return nil }
        if let playwrightDriverFactory {
            return try await playwrightDriverFactory(manifest)
        }
        guard manifest.mode == .browser else { return nil }
        guard FileManager.default.fileExists(atPath: bridgeScriptURL.path) else {
            throw ServiceError.bridgeScriptMissing
        }
        let lifecycle = OpenBurnBarPlaywrightLifecycle(
            bridgeScriptURL: bridgeScriptURL,
            logger: logger,
            locateExecutable: locateExecutable
        )
        let readiness = try await lifecycle.ensureReady(performInstallIfMissing: false)
        let userDataDirectory = auditBaseDirectory
            .appendingPathComponent(manifest.sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("playwright-profile", isDirectory: true)
        return OpenBurnBarPlaywrightDriver(
            configuration: OpenBurnBarPlaywrightDriver.Configuration(
                nodeExecutablePath: readiness.nodePath,
                bridgeScriptPath: readiness.bridgeScriptURL,
                userDataDirectory: userDataDirectory,
                headless: false
            ),
            sessionId: manifest.sessionId,
            logger: logger
        )
    }

    private func currentCapabilityState() async throws -> ComputerUseCapabilityStateSnapshot {
        do {
            return try await capabilityStateStore.currentState()
        } catch {
            throw ServiceError.capabilityStateUnavailable(String(describing: error))
        }
    }

    private func enforceSessionAdmission(
        _ state: ComputerUseCapabilityStateSnapshot,
        mode: ComputerUseMode
    ) async throws {
        if effectiveKillSwitchEnabled(state) {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.killSwitch.rawValue)
        }
        guard !state.authorizationRevoked,
              Self.entitlementIsActive(state.entitlement),
              state.entitlement.productId == Self.computerUseProductId,
              Self.entitlementAllowsMode(state.entitlement, mode: mode) else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.entitlement.rawValue)
        }
        let daemonSessionActive = await coordinator.hasActiveSession()
        guard !state.concurrentSessionActive, !daemonSessionActive else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.concurrentSession.rawValue)
        }
        guard state.budgetEnvelope.level != .hardCap else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.hardCap.rawValue)
        }
        guard state.quotaUsage.totalMeteredActionsExecuted < state.budgetEnvelope.activeActionsPerDay else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.dailyLimit.rawValue)
        }
        guard state.quotaUsage.sessionsStarted < state.budgetEnvelope.activeSessionsPerDay else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.dailyLimit.rawValue)
        }
        guard state.quotaUsage.visionModelSpendUSD < state.budgetEnvelope.perUserDailySpendCeilingUSD else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.dailySpendCeiling.rawValue)
        }
        guard state.budgetEnvelope.activeActionsPerRun > 0 else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.hardCap.rawValue)
        }
    }

    private func terminateSessionsIfAuthorityRevoked(
        _ state: ComputerUseCapabilityStateSnapshot
    ) async {
        if !state.isComplete {
            await terminateAllSessions(reason: .error)
        } else if effectiveKillSwitchEnabled(state) {
            await terminateAllSessions(source: .remoteConfig)
        } else if state.authorizationRevoked ||
                    !Self.entitlementIsActive(state.entitlement) ||
                    state.entitlement.productId != Self.computerUseProductId ||
                    !manifests.values.allSatisfy({ Self.entitlementAllowsMode(state.entitlement, mode: $0.mode) }) {
            await terminateAllSessions(source: .revoked)
        } else if state.budgetEnvelope.level == .hardCap ||
                    state.quotaUsage.totalMeteredActionsExecuted >= state.budgetEnvelope.activeActionsPerDay ||
                    state.quotaUsage.sessionsStarted >= state.budgetEnvelope.activeSessionsPerDay ||
                    state.quotaUsage.visionModelSpendUSD >= state.budgetEnvelope.perUserDailySpendCeilingUSD {
            await terminateAllSessions(reason: .budgetHardCap)
        } else if state.concurrentSessionActive {
            await terminateAllSessions(reason: .error)
        }
    }

    private func terminateAllSessions(source: ComputerUsePanicSource) async {
        let manifestedSessionIDs = await revokeAllSessionAuthority()
        let terminated = await coordinator.panicHaltAllWithRecords(source: source)
        recordEndedSessions(terminated, including: manifestedSessionIDs)
    }

    private func terminateAllSessions(reason: ComputerUseEndReason) async {
        let manifestedSessionIDs = await revokeAllSessionAuthority()
        let terminated = await coordinator.endAllWithRecords(reason: reason)
        recordEndedSessions(terminated, including: manifestedSessionIDs)
    }

    private func revokeAllSessionAuthority() async -> Set<ComputerUseSessionID> {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        let manifestedSessionIDs = Set(manifests.keys)
        revokingSessionIDs.formUnion(manifestedSessionIDs)
        await authorizationRegistry.revokeAll()
#if os(Linux)
        await linuxInputSessionManager.stopAll()
#endif
        if let sessionEndedObserver {
            for sessionID in manifestedSessionIDs {
                await sessionEndedObserver(sessionID.rawValue)
            }
        }
        await approvalBridge.cancelAll()
        for sessionID in manifestedSessionIDs {
            await releaseSafariBinding(for: sessionID)
        }
        return manifestedSessionIDs
    }

    private func recordEndedSessions(
        _ ended: [ComputerUseSessionEndRecord],
        including manifestedSessionIDs: Set<ComputerUseSessionID>
    ) {
        let recordsBySessionID = Dictionary(
            uniqueKeysWithValues: ended.map { (ComputerUseSessionID($0.sessionId), $0) }
        )
        let endedSessionIDs = Set(recordsBySessionID.keys)
        for sessionID in manifestedSessionIDs.union(endedSessionIDs) {
            let sessionDirectory = auditBaseDirectory.appendingPathComponent(sessionID.rawValue, isDirectory: true)
            finalizeAuditHeadIfPossible(
                sessionDirectory: sessionDirectory,
                closedAt: recordsBySessionID[sessionID]?.endedAt ?? Date()
            )
            manifests.removeValue(forKey: sessionID)
            revokingSessionIDs.remove(sessionID)
        }
        pendingEndedSessions.append(contentsOf: ended)
    }

    private func deniedResponse(
        _ request: ComputerUseInvokeRequest,
        reason: String
    ) -> ComputerUseInvokeResponse {
        ComputerUseInvokeResponse(
            sessionId: request.sessionId,
            callID: request.invocation.callID,
            status: .denied,
            denyReason: reason
        )
    }

    private static func entitlementIsActive(
        _ entitlement: ComputerUseEntitlementSnapshot,
        now: Date = Date()
    ) -> Bool {
        entitlement.isActive && (entitlement.expireAt.map { $0 > now } ?? true)
    }

    private static func entitlementAllowsMode(
        _ entitlement: ComputerUseEntitlementSnapshot,
        mode: ComputerUseMode
    ) -> Bool {
        switch mode {
        case .browser:
            return entitlement.allowsBrowser
        case .system:
            return entitlement.allowsSystem
        case .agentWatch:
            return false
        }
    }

    private func effectiveKillSwitchEnabled(_ state: ComputerUseCapabilityStateSnapshot) -> Bool {
        state.killSwitch || leafKillSwitch() || computerUseKillSwitchEnabled()
    }

    private static func supportsDaemonMode(_ mode: ComputerUseMode) -> Bool {
        #if os(Linux)
        return mode == .browser || mode == .system
        #else
        return mode == .browser
        #endif
    }

    private static func safariClientID(sessionID: String) -> BurnBarClientID {
        BurnBarClientID(rawValue: "safari-extension:\(sessionID)")
    }

    private static func safariSessionID(
        from invocation: BurnBarToolInvocation
    ) -> String? {
        guard case .object(let arguments) = invocation.arguments,
              case .string(let rawSessionID)? = arguments["safariSessionId"] else {
            return nil
        }
        let sessionID = rawSessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionID == rawSessionID,
              isBoundedSafariSessionID(sessionID) else {
            return nil
        }
        return sessionID
    }

    private static func isBoundedSafariSessionID(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 256
    }

    private static func isBoundedCallID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value
            && trimmed.isEmpty == false
            && trimmed.utf8.count <= 512
    }

    private func sessionRequiresRunAuthority(
        _ manifest: ComputerUseSessionManifest
    ) -> Bool {
        guard manifest.mode == .browser else { return false }
        return requiresManagedBrowserRunAuthority
            || manifest.executionSurface == .safariExtension
    }

    private func validateExecutionSurface(
        manifest: ComputerUseSessionManifest,
        action: ComputerUseAction,
        invocation: BurnBarToolInvocation
    ) async throws {
        guard manifest.mode == .browser else {
            if case .browser = action {
                throw ServiceError.incompatibleToolForExecutionSurface(
                    "Browser tools require a browser-mode Computer Use session."
                )
            }
            if case .safari = action {
                throw ServiceError.incompatibleToolForExecutionSurface(
                    "Safari tools require a browser-mode Safari Computer Use session."
                )
            }
            return
        }

        switch manifest.executionSurface {
        case .safariExtension:
            guard invocation.tool.isSafariComputerUse,
                  case .safari(let safariAction) = action else {
                throw ServiceError.incompatibleToolForExecutionSurface(
                    "A Safari-extension session accepts only safari_* tools."
                )
            }
            guard let expectedSessionID = manifest.executionSurfaceSessionId,
                  expectedSessionID.isEmpty == false else {
                throw ServiceError.invalidExecutionSurface(
                    "The Safari execution-surface session identifier is missing from the immutable manifest."
                )
            }
            guard safariAction.safariSessionId == expectedSessionID else {
                throw ServiceError.safariSessionMismatch(
                    expected: expectedSessionID,
                    actual: safariAction.safariSessionId
                )
            }
            let expectedClientID = Self.safariClientID(sessionID: expectedSessionID)
            guard invocation.requestedBy == expectedClientID else {
                throw ServiceError.clientIdentityMismatch(
                    expected: expectedClientID.rawValue,
                    actual: invocation.requestedBy.rawValue
                )
            }
            let status = try await safariSessionBroker.status(sessionID: expectedSessionID)
            guard status.attached, let activePage = status.activePage else {
                throw ServiceError.safariSessionUnavailable(expectedSessionID)
            }
            try Self.validateSafeSafariLandedURL(activePage.url)

        case .managedBrowser, .none:
            guard invocation.tool.isSafariComputerUse == false,
                  case .browser = action else {
                throw ServiceError.incompatibleToolForExecutionSurface(
                    "A managed-browser session accepts only browser_* tools."
                )
            }
            guard manifest.executionSurfaceSessionId == nil else {
                throw ServiceError.invalidExecutionSurface(
                    "A managed-browser manifest cannot carry a surface session identifier."
                )
            }
        }
    }

    private static func validateSafeSafariLandedURL(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host?.isEmpty == false else {
            throw ServiceError.invalidExecutionSurface(
                "Safari reported a malformed or non-HTTP(S) top-frame URL."
            )
        }
        do {
            _ = try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(trimmed)
        } catch {
            throw ServiceError.invalidExecutionSurface(
                "Safari reported an unsafe top-frame URL: \(error.localizedDescription)"
            )
        }
    }

    private func releaseSafariBinding(for sessionID: ComputerUseSessionID) async {
        guard let safariSessionID =
                safariSessionIDByComputerUseSessionID.removeValue(forKey: sessionID)
                ?? manifests[sessionID]?.executionSurfaceSessionId else {
            return
        }
        computerUseSessionIDBySafariSessionID.removeValue(forKey: safariSessionID)
        await safariSessionBroker.abort(sessionID: safariSessionID)
    }

    private func accessibilityDenyReason(
        for action: ComputerUseAction?,
        mode: ComputerUseMode
    ) async -> ComputerUseAccessibilityDenyReason? {
        guard mode == .system,
              case .macInput(let inputAction) = action else {
            return nil
        }
        return await systemInputAccessibilityDeny(inputAction)
    }

    private static func environmentComputerUseKillSwitchEnabled() -> Bool {
        [
            "OPENBURNBAR_COMPUTER_USE_KILL_SWITCH",
            "COMPUTER_USE_KILL_SWITCH",
            "computer_use_kill_switch"
        ].contains { name in
            guard let value = ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !value.isEmpty else {
                return false
            }
            return ["1", "true", "yes", "on"].contains(value)
        }
    }

    /// Extracts a scope context from a tool invocation for browser-mode scope
    /// resolution. Browser actions carry an optional `url` in their arguments;
    /// we extract it here so `ComputerUseScopeMatcher` can evaluate allow/deny
    /// rules against the target URL.
    private static func resolveScopeContext(from invocation: BurnBarToolInvocation) -> ComputerUseScopeContext {
        // Extract URL from the invocation arguments JSON.
        // Only `browserGoto` carries a URL today, but other browser actions
        // may also be constrained by URL-prefix rules (the URL is the *current*
        // page, not just the navigation target). For now, extract the explicit
        // URL from arguments; a future iteration should track the current page URL.
        let url: String? = {
            switch invocation.arguments {
            case .object(let dict):
                if case .string(let u) = dict["url"] { return u }
                return nil
            default:
                return nil
            }
        }()
        return ComputerUseScopeContext(url: url)
    }

    private static func todayKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private static func defaultBridgeScriptURL() -> URL {
        OpenBurnBarPlaywrightBridgeResource.resolve()
    }

    private static func legacyRawAuditExportKeyURL(auditBaseDirectory: URL) -> URL {
        auditBaseDirectory
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("audit-export-ed25519.raw", isDirectory: false)
    }

    private static let defaultExecutableLocator: BurnBarExecutableLocator = { name in
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/\(name)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.nvm/versions/node/v20.20.2/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        if let direct = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

actor ComputerUseApprovalBridge {
    private struct PendingApproval {
        var publicationID: UUID
        var request: HermesRealtimeRelayApprovalRequest
        var continuation: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Error>
        var publicationTask: Task<Void, Never>?
    }

    private var pendingByApprovalId: [String: PendingApproval] = [:]

    func issue(
        _ request: HermesRealtimeRelayApprovalRequest,
        publisher: ComputerUseService.ApprovalPublisher? = nil
    ) async throws -> HermesRealtimeRelayApprovalResponse {
        let publicationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let replaced = pendingByApprovalId.removeValue(forKey: request.approvalId) {
                    replaced.publicationTask?.cancel()
                    replaced.continuation.resume(throwing: CancellationError())
                }
                pendingByApprovalId[request.approvalId] = PendingApproval(
                    publicationID: publicationID,
                    request: request,
                    continuation: continuation,
                    publicationTask: nil
                )
                if let publisher {
                    let publicationTask = Task {
                        await self.publish(
                            request,
                            publicationID: publicationID,
                            using: publisher
                        )
                    }
                    pendingByApprovalId[request.approvalId]?.publicationTask = publicationTask
                }
            }
        } onCancel: {
            Task {
                await self.cancel(
                    approvalId: request.approvalId,
                    publicationID: publicationID
                )
            }
        }
    }

    func pendingApprovals(sessionId: String?) -> [HermesRealtimeRelayApprovalRequest] {
        pendingByApprovalId.values
            .map(\.request)
            .filter { request in
                guard let sessionId else { return true }
                return request.sessionId == sessionId
            }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    func respond(
        sessionId: String?,
        response: HermesRealtimeRelayApprovalResponse
    ) -> Bool {
        guard let pending = pendingByApprovalId[response.approvalId] else { return false }
        if let sessionId, pending.request.sessionId != sessionId { return false }
        pendingByApprovalId.removeValue(forKey: response.approvalId)
        pending.publicationTask?.cancel()
        pending.continuation.resume(returning: response)
        return true
    }

    func cancel(sessionId: String) {
        let approvalIds = pendingByApprovalId.values
            .filter { $0.request.sessionId == sessionId }
            .map { $0.request.approvalId }
        for approvalId in approvalIds {
            cancel(approvalId: approvalId)
        }
    }

    func cancelAll() {
        let pending = pendingByApprovalId
        pendingByApprovalId.removeAll()
        for (_, approval) in pending {
            approval.publicationTask?.cancel()
            approval.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(approvalId: String) {
        guard let pending = pendingByApprovalId.removeValue(forKey: approvalId) else { return }
        pending.publicationTask?.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func cancel(approvalId: String, publicationID: UUID) {
        guard pendingByApprovalId[approvalId]?.publicationID == publicationID else { return }
        cancel(approvalId: approvalId)
    }

    private func publish(
        _ request: HermesRealtimeRelayApprovalRequest,
        publicationID: UUID,
        using publisher: ComputerUseService.ApprovalPublisher
    ) async {
        guard pendingByApprovalId[request.approvalId]?.publicationID == publicationID else { return }
        do {
            try Task.checkCancellation()
            try await publisher(request)
            if pendingByApprovalId[request.approvalId]?.publicationID == publicationID {
                pendingByApprovalId[request.approvalId]?.publicationTask = nil
            }
        } catch is CancellationError {
            return
        } catch {
            fail(approvalId: request.approvalId, publicationID: publicationID, error: error)
        }
    }

    private func fail(approvalId: String, publicationID: UUID, error: Error) {
        guard let pending = pendingByApprovalId[approvalId],
              pending.publicationID == publicationID else {
            return
        }
        pendingByApprovalId.removeValue(forKey: approvalId)
        pending.continuation.resume(throwing: error)
    }
}
