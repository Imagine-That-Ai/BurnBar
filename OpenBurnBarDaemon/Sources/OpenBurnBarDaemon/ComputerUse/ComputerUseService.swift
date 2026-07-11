import Foundation
import OpenBurnBarCore
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
    public enum ServiceError: Error, LocalizedError, Sendable, Equatable {
        case invalidMode(String)
        case invalidTrustMode(String)
        case invalidSession(String)
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

        public var errorDescription: String? {
            switch self {
            case .invalidMode(let mode):
                return "Unknown Computer Use mode: \(mode)."
            case .invalidTrustMode(let mode):
                return "Unknown Computer Use trust mode: \(mode)."
            case .invalidSession(let sessionID):
                return "Computer Use session is not active: \(sessionID)."
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
            }
        }
    }

    private static let computerUseProductId = "com.openburnbar.hostedComputerUseSync.monthly"

    private let coordinator: ComputerUseRunCoordinator
    private let approvalBridge: ComputerUseApprovalBridge
    private let authorizationRegistry: ComputerUseAuthorizationRegistry
    private let auditBaseDirectory: URL
    private let macAppVersion: String
    private let locateExecutable: BurnBarExecutableLocator
    private let logger: BurnBarDaemonLogger
    private let bridgeScriptURL: URL
    private let auditExportSignerProvider: any ComputerUseAuditExportSignerProviding
    private let systemInputAccessibilityTrusted: @Sendable (ComputerUseMode) -> Bool
    private let systemInputAccessibilityDeny: @Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason?
    private let computerUseKillSwitchEnabled: @Sendable () -> Bool
    private let privilegedInputKillSwitchActivator: @Sendable (String) -> Void
    private let playwrightDriverFactory: (@Sendable (ComputerUseSessionManifest) async throws -> OpenBurnBarPlaywrightDriver?)?
    private let requiresManagedBrowserRunAuthority: Bool
    private var manifests: [ComputerUseSessionID: ComputerUseSessionManifest] = [:]
    private var timeoutTasks: [ComputerUseSessionID: Task<Void, Never>] = [:]
    private var revokingSessionIDs: Set<ComputerUseSessionID> = []

    public init(
        auditBaseDirectory: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("computer-use-audit", isDirectory: true),
        macAppVersion: String = BurnBarDaemonVersion.current,
        bridgeScriptURL: URL? = nil,
        locateExecutable: BurnBarExecutableLocator? = nil,
        auditExportSignerProvider: (any ComputerUseAuditExportSignerProviding)? = nil,
        systemInputDispatcher: ComputerUseRunCoordinator.MacInputDispatcher? = nil,
        systemInspectDispatcher: ComputerUseRunCoordinator.MacInspectDispatcher? = nil,
        systemInputAccessibilityTrusted: (@Sendable (ComputerUseMode) -> Bool)? = nil,
        systemInputAccessibilityDeny: (@Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason?)? = nil,
        computerUseKillSwitchEnabled: (@Sendable () -> Bool)? = nil,
        privilegedInputKillSwitchActivator: (@Sendable (String) -> Void)? = nil,
        playwrightDriverFactory: (@Sendable (ComputerUseSessionManifest) async throws -> OpenBurnBarPlaywrightDriver?)? = nil,
        authorizationRegistry: ComputerUseAuthorizationRegistry? = nil,
        preDispatchAuthorizer: ComputerUseRunCoordinator.PreDispatchAuthorizer? = nil,
        requiresManagedBrowserRunAuthority: Bool? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-service")
    ) {
        let approvalBridge = ComputerUseApprovalBridge()
        let authorizationRegistry = authorizationRegistry ?? ComputerUseAuthorizationRegistry(
            enforcementEnabled: false
        )
        self.approvalBridge = approvalBridge
        self.authorizationRegistry = authorizationRegistry
        self.auditBaseDirectory = auditBaseDirectory
        self.macAppVersion = macAppVersion
        self.locateExecutable = locateExecutable ?? Self.defaultExecutableLocator
        self.logger = logger
        self.bridgeScriptURL = bridgeScriptURL ?? Self.defaultBridgeScriptURL()
        self.auditExportSignerProvider = auditExportSignerProvider ?? ComputerUseKeychainAuditExportSignerProvider(
            legacyRawKeyURL: Self.legacyRawAuditExportKeyURL(auditBaseDirectory: auditBaseDirectory)
        )
        let defaultSystemInputDispatcher: ComputerUseRunCoordinator.MacInputDispatcher?
        let defaultSystemInspectDispatcher: ComputerUseRunCoordinator.MacInspectDispatcher?
        let defaultSystemAccessibilityTrusted: @Sendable (ComputerUseMode) -> Bool
        let defaultSystemAccessibilityDeny: @Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason?
        let defaultComputerUseKillSwitchEnabled: @Sendable () -> Bool
        let defaultPrivilegedInputKillSwitchActivator: @Sendable (String) -> Void
        #if os(Linux)
        let linuxInputAdapter = LinuxComputerUseInputAdapter()
        defaultSystemInputDispatcher = { _, action in
            try await linuxInputAdapter.dispatch(action)
        }
        defaultSystemInspectDispatcher = { _, action in
            try await linuxInputAdapter.inspectAccessibility(action)
        }
        defaultSystemAccessibilityTrusted = { mode in
            mode == .system && linuxInputAdapter.isAvailableForSystemInput()
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
        self.playwrightDriverFactory = playwrightDriverFactory
        let resolvedRequiresManagedBrowserRunAuthority = requiresManagedBrowserRunAuthority
            ?? Self.platformRequiresManagedBrowserRunAuthority
        self.requiresManagedBrowserRunAuthority = resolvedRequiresManagedBrowserRunAuthority
        self.coordinator = ComputerUseRunCoordinator(
            approvalIssuer: { request in
                try await approvalBridge.issue(request)
            },
            macInputDispatcher: systemInputDispatcher ?? defaultSystemInputDispatcher,
            macInspectDispatcher: systemInspectDispatcher ?? defaultSystemInspectDispatcher,
            preDispatchAuthorizer: preDispatchAuthorizer ?? { sessionID, invocation in
                guard resolvedComputerUseKillSwitchEnabled() == false else { return false }
                guard invocation.tool.isBrowserComputerUse else { return true }
                guard resolvedRequiresManagedBrowserRunAuthority else { return true }
                return await authorizationRegistry.permits(sessionID: sessionID, invocation: invocation)
            },
            macAppVersion: macAppVersion,
            auditBaseDirectory: auditBaseDirectory,
            logger: logger
        )
    }

    public func startSession(
        _ request: ComputerUseSessionStartRequest,
        boundClientID: BurnBarClientID? = nil,
        runGeneration: UInt64? = nil
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
        if mode == .browser, requiresManagedBrowserRunAuthority, request.runID == nil {
            throw ServiceError.browserRunRequired
        }

        let reservedRunID = requiresManagedBrowserRunAuthority ? request.runID : nil
        if let runID = reservedRunID {
            if let existing = await authorizationRegistry.binding(runID: runID),
               let expiresAt = existing.expiresAt,
               expiresAt <= Date() {
                await haltSession(existing.sessionID, source: .stalled)
            }
            guard await authorizationRegistry.reserve(runID: runID) else {
                throw ServiceError.runAlreadyBound(runID.rawValue)
            }
        }
        do {
            let sessionId = ComputerUseSessionID.newRandom()
            let ownerClientID = boundClientID ?? request.clientID
            let manifest = ComputerUseSessionManifest(
                sessionId: sessionId,
                mode: mode,
                trustMode: trustMode,
                startedAt: Date(),
                userId: ownerClientID.rawValue,
                runId: request.runID?.rawValue,
                macHostNodeId: request.macHostNodeId,
                phoneViewerNodeId: request.phoneViewerNodeId,
                scopeRuleIds: request.scopeRuleIds,
                entitlementProductId: Self.computerUseProductId,
                actionCap: request.actionCap,
                sessionTimeoutSeconds: request.sessionTimeoutSeconds
            )

            let driver: OpenBurnBarPlaywrightDriver?
            if let playwrightDriverFactory {
                driver = try await playwrightDriverFactory(manifest)
            } else {
                driver = try await makePlaywrightDriverIfNeeded(for: manifest)
            }
            let head = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)
            guard await coordinator.session(sessionId) != nil else {
                throw ServiceError.invalidSession(sessionId.rawValue)
            }
            manifests[sessionId] = manifest
            if requiresManagedBrowserRunAuthority,
               let runID = request.runID,
               await authorizationRegistry.bind(
                sessionID: sessionId,
                runID: runID,
                clientID: ownerClientID,
                generation: runGeneration
               ) == false {
                await coordinator.panicHalt(sessionId: sessionId, source: .revoked)
                manifests.removeValue(forKey: sessionId)
                throw ServiceError.runAlreadyBound(runID.rawValue)
            }
            scheduleTimeout(for: manifest)
            return ComputerUseSessionStartResponse(
                sessionId: sessionId.rawValue,
                manifestHashHex: head,
                startedAt: manifest.startedAt,
                entitlementProductId: Self.computerUseProductId,
                actionCap: request.actionCap
            )
        } catch {
            if let reservedRunID {
                await authorizationRegistry.releaseReservation(runID: reservedRunID)
            }
            throw error
        }
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
        guard revokingSessionIDs.contains(sessionID) == false else { return nil }
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

    private func haltSession(
        _ sessionID: ComputerUseSessionID,
        source: ComputerUsePanicSource,
        closedAt: Date = Date()
    ) async {
        timeoutTasks.removeValue(forKey: sessionID)?.cancel()
        revokingSessionIDs.insert(sessionID)
        // Revoke authority before any cleanup await. Late approvals and
        // concurrent invokes must fail closed while the driver is stopping.
        await authorizationRegistry.revoke(sessionID: sessionID)
        await approvalBridge.cancel(sessionId: sessionID.rawValue)
        await coordinator.panicHalt(sessionId: sessionID, source: source)
        let directory = auditBaseDirectory.appendingPathComponent(sessionID.rawValue, isDirectory: true)
        finalizeAuditHeadIfPossible(sessionDirectory: directory, closedAt: closedAt)
        manifests.removeValue(forKey: sessionID)
        revokingSessionIDs.remove(sessionID)
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
        if manifest.mode == .browser, requiresManagedBrowserRunAuthority {
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
        let action = try? await coordinator.actionDescriptor(invocation: request.invocation)
        let accessibilityDeny = await accessibilityDenyReason(for: action, mode: manifest.mode)
        let capability = ComputerUseCapabilityContext(
            entitlement: entitlement(for: manifest.mode),
            envelope: .initialNormal,
            usage: ComputerUseQuotaUsage(dayKey: Self.todayKey()),
            session: state,
            concurrentSessionActive: await coordinator.hasActiveSession(excluding: sessionId),
            killSwitch: computerUseKillSwitchEnabled(),
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
        return ComputerUseApprovalPendingResponse(
            requests: await approvalBridge.pendingApprovals(sessionId: filteredSessionID),
            sessionActive: sessionActive
        )
    }

    private func isSessionActiveForPolling(_ sessionID: ComputerUseSessionID) async -> Bool {
        guard revokingSessionIDs.contains(sessionID) == false,
              let manifest = manifests[sessionID] else {
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
            timeoutTasks.values.forEach { $0.cancel() }
            timeoutTasks.removeAll()
            let manifestedSessionIDs = Set(manifests.keys)
            revokingSessionIDs.formUnion(manifestedSessionIDs)
            await authorizationRegistry.revokeAll()
            await approvalBridge.cancelAll()
            let haltedSessionIds = await coordinator.panicHaltAll(source: source)
            for sessionId in manifestedSessionIDs.union(haltedSessionIds) {
                let sessionDirectory = auditBaseDirectory.appendingPathComponent(sessionId.rawValue, isDirectory: true)
                finalizeAuditHeadIfPossible(sessionDirectory: sessionDirectory, closedAt: endedAt)
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
        guard manifests[sessionId] != nil else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        privilegedInputKillSwitchActivator(source.rawValue)
        await authorizationRegistry.revoke(sessionID: sessionId)
        guard let state = await coordinator.session(sessionId) else {
            await haltSession(sessionId, source: source)
            throw ServiceError.invalidSession(request.sessionId)
        }
        let lastHead = state.auditChainHeadHashHex ?? ""
        await haltSession(sessionId, source: source)
        return ComputerUsePanicHaltResponse(
            sessionId: sessionId.rawValue,
            endedAt: Date(),
            auditHeadHashHex: lastHead
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

    /// Builds an entitlement snapshot for the given mode.
    ///
    /// - Note: Phone control bypasses AX deny-region and scope-rule checks
    ///   by design. The phone user is the authenticated human operator
    ///   (Ed25519-signed authority via `PhoneControlAuthorityValidator`).
    ///   The capability gate in `DefaultComputerUseCapabilityGate` short-circuits
    ///   deny-region evaluation for direct phone-control intents. If the threat
    ///   model changes, enable `computerUse_phoneControlRespectsDenyRegions` in
    ///   Remote Config (requires wiring Remote Config into the daemon path;
    ///   see TODO below).
    ///
    /// - Important: The `allows*` booleans are feature bits for the bundled
    ///   single-SKU model. The real enforcement gate is `isActive`. When active,
    ///   all features are enabled. See `ComputerUseRuntimeController.refreshEntitlement()`
    ///   for the app-side counterpart and the full rationale.
    private func entitlement(for mode: ComputerUseMode) -> ComputerUseEntitlementSnapshot {
        ComputerUseEntitlementSnapshot(
            isActive: true,
            productId: Self.computerUseProductId,
            allowsBrowser: mode == .browser,
            allowsSystem: mode == .system,
            // Single-SKU model: all features enabled when entitlement is active.
            allowsPhoneControl: true,     // SKU default: on
            allowsTrustedScopes: true,    // SKU default: on
            allowsAuditExport: true       // SKU default: on
        )
    }

    private static func supportsDaemonMode(_ mode: ComputerUseMode) -> Bool {
        #if os(Linux)
        return mode == .browser || mode == .system
        #else
        return mode == .browser
        #endif
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
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_PLAYWRIGHT_BRIDGE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("PlaywrightBridge", isDirectory: true)
                .appendingPathComponent("openburnbar-playwright-bridge.js", isDirectory: false),
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js"),
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/PlaywrightBridge/openburnbar-playwright-bridge.js")
        ].compactMap { $0 }
        return candidates.first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates[0]
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
        var request: HermesRealtimeRelayApprovalRequest
        var continuation: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Error>
    }

    private var pendingByApprovalId: [String: PendingApproval] = [:]

    func issue(_ request: HermesRealtimeRelayApprovalRequest) async throws -> HermesRealtimeRelayApprovalResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingByApprovalId[request.approvalId] = PendingApproval(
                    request: request,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(approvalId: request.approvalId) }
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
            approval.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(approvalId: String) {
        guard let pending = pendingByApprovalId.removeValue(forKey: approvalId) else { return }
        pending.continuation.resume(throwing: CancellationError())
    }
}
