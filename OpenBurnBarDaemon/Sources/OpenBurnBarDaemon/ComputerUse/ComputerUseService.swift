import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Daemon RPC facade for Computer Use session lifecycle.
///
/// The Mac app still owns interactive approval UI and Mac-wide CGEvent
/// dispatch. This service makes the wire contracts reachable, owns
/// browser-session Playwright drivers, and rejects app-owned modes
/// (`agent_watch` and `system`) at session start so callers cannot create
/// a daemon session that appears valid but can never dispatch Path A/C.
public actor ComputerUseService {
    public enum ServiceError: Error, Sendable, Equatable {
        case invalidMode(String)
        case invalidTrustMode(String)
        case invalidSession(String)
        case bridgeScriptMissing
        case unsupportedDaemonMode(String)
        case unsupportedDaemonApprovalPath
        case capabilityStateUnavailable(String)
        case capabilityDenied(String)
    }

    private static let computerUseProductId = ComputerUseEntitlementSnapshot.hostedProductID

    private let coordinator: ComputerUseRunCoordinator
    private let approvalBridge: ComputerUseApprovalBridge
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
    private var manifests: [ComputerUseSessionID: ComputerUseSessionManifest] = [:]
    private var pendingEndedSessions: [ComputerUseSessionEndRecord] = []
    private var sessionStartReserved = false

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
            playwrightDriverFactory: nil,
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
        playwrightDriverFactory: (@Sendable (ComputerUseSessionManifest) async throws -> OpenBurnBarPlaywrightDriver?)?,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-service")
    ) {
        let approvalBridge = ComputerUseApprovalBridge()
        self.approvalBridge = approvalBridge
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
        self.coordinator = ComputerUseRunCoordinator(
            approvalIssuer: { request in
                try await approvalBridge.issue(request)
            },
            macAppVersion: macAppVersion,
            auditBaseDirectory: auditBaseDirectory,
            quotaLedger: resolvedQuotaLedger,
            logger: logger
        )
    }

    public func startSession(_ request: ComputerUseSessionStartRequest) async throws -> ComputerUseSessionStartResponse {
        guard let mode = ComputerUseMode(rawValue: request.mode) else {
            throw ServiceError.invalidMode(request.mode)
        }
        guard let trustMode = ComputerUseTrustMode(rawValue: request.trustMode) else {
            throw ServiceError.invalidTrustMode(request.trustMode)
        }
        guard mode == .browser else {
            // Path A and Path C are app-owned because they depend on the
            // Mac app's live relay session, approval UI, AX trust state,
            // and CGEvent dispatcher. The daemon owns only Path B browser
            // Playwright sessions; fail early instead of starting a session
            // that would later deny every System-mode action through a fake
            // `accessibilityTrusted: false` capability.
            throw ServiceError.unsupportedDaemonMode(mode.rawValue)
        }

        let capabilityState = try await currentCapabilityState()
        try await enforceSessionAdmission(capabilityState, mode: mode)
        guard !sessionStartReserved else {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.concurrentSession.rawValue)
        }
        sessionStartReserved = true
        defer { sessionStartReserved = false }

        let sessionId = ComputerUseSessionID.newRandom()
        let effectiveActionCap = min(request.actionCap, capabilityState.budgetEnvelope.activeActionsPerRun)
        var manifest = ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: mode,
            trustMode: trustMode,
            startedAt: Date(),
            userId: request.clientID.rawValue,
            macHostNodeId: request.macHostNodeId,
            phoneViewerNodeId: request.phoneViewerNodeId,
            scopeRuleIds: request.scopeRuleIds,
            entitlementProductId: Self.computerUseProductId,
            actionCap: effectiveActionCap,
            sessionTimeoutSeconds: request.sessionTimeoutSeconds
        )

        let driver = try await makePlaywrightDriverIfNeeded(for: manifest)
        let head: String
        var didStartCoordinatorSession = false
        do {
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
                    macHostNodeId: manifest.macHostNodeId,
                    phoneViewerNodeId: manifest.phoneViewerNodeId,
                    scopeRuleIds: manifest.scopeRuleIds,
                    entitlementProductId: manifest.entitlementProductId,
                    actionCap: refreshedActionCap,
                    sessionTimeoutSeconds: manifest.sessionTimeoutSeconds
                )
            }
            head = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)
            didStartCoordinatorSession = true
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
            if didStartCoordinatorSession {
                await coordinator.endSession(sessionId: sessionId, reason: .error)
            } else {
                await driver?.stop()
            }
            throw error
        }
        manifests[sessionId] = manifest
        return ComputerUseSessionStartResponse(
            sessionId: sessionId.rawValue,
            manifestHashHex: head,
            startedAt: manifest.startedAt,
            entitlementProductId: Self.computerUseProductId,
            actionCap: manifest.actionCap
        )
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

    public func invoke(_ request: ComputerUseInvokeRequest) async throws -> ComputerUseInvokeResponse {
        let sessionId = ComputerUseSessionID(request.sessionId)
        guard let manifest = manifests[sessionId],
              let state = await coordinator.session(sessionId) else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        let capabilityState: ComputerUseCapabilityStateSnapshot
        do {
            capabilityState = try await currentCapabilityState()
        } catch {
            await terminateAllSessions(reason: .error)
            return deniedResponse(request, reason: "capability_state_unavailable")
        }
        if capabilityState.killSwitch || leafKillSwitch() {
            await terminateAllSessions(source: .remoteConfig)
            return deniedResponse(request, reason: ComputerUseDenyReason.killSwitch.rawValue)
        }
        if capabilityState.authorizationRevoked ||
            !Self.entitlementIsActive(capabilityState.entitlement) ||
            capabilityState.entitlement.productId != Self.computerUseProductId ||
            !capabilityState.entitlement.allowsBrowser {
            await terminateAllSessions(source: .revoked)
            return deniedResponse(request, reason: ComputerUseDenyReason.entitlement.rawValue)
        }

        let anotherDaemonSession = await coordinator.hasActiveSession(excluding: sessionId)
        let capability = ComputerUseCapabilityContext(
            entitlement: capabilityState.entitlement,
            envelope: capabilityState.budgetEnvelope,
            usage: capabilityState.quotaUsage,
            session: state,
            concurrentSessionActive: capabilityState.concurrentSessionActive || anotherDaemonSession,
            killSwitch: capabilityState.killSwitch || leafKillSwitch(),
            accessibilityTrusted: false
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
            accessibilityDeny: nil,
            capability: capability
        )
    }

    func hasActiveSession() async -> Bool {
        await coordinator.hasActiveSession()
    }

    public func pendingApprovals(
        _ request: ComputerUseApprovalPendingRequest
    ) async -> ComputerUseApprovalPendingResponse {
        ComputerUseApprovalPendingResponse(
            requests: await approvalBridge.pendingApprovals(sessionId: request.sessionId)
        )
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

    public func panicHalt(_ request: ComputerUsePanicHaltRequest) async throws -> ComputerUsePanicHaltResponse {
        let sessionId = ComputerUseSessionID(request.sessionId)
        guard let source = ComputerUsePanicSource(rawValue: request.source),
              let state = await coordinator.session(sessionId) else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        let sessionDirectory = auditBaseDirectory.appendingPathComponent(sessionId.rawValue, isDirectory: true)
        let ended = await coordinator.panicHalt(sessionId: sessionId, source: source)
        let endedAt = ended?.endedAt ?? Date()
        finalizeAuditHeadIfPossible(sessionDirectory: sessionDirectory, closedAt: endedAt)
        manifests.removeValue(forKey: sessionId)
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
        try? ComputerUseAuditHeadFinalizer.finalizeSessionDirectory(sessionDirectory, closedAt: closedAt, signer: signer)
    }

    private func makePlaywrightDriverIfNeeded(
        for manifest: ComputerUseSessionManifest
    ) async throws -> OpenBurnBarPlaywrightDriver? {
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
        if state.killSwitch || leafKillSwitch() {
            throw ServiceError.capabilityDenied(ComputerUseDenyReason.killSwitch.rawValue)
        }
        guard !state.authorizationRevoked,
              Self.entitlementIsActive(state.entitlement),
              state.entitlement.productId == Self.computerUseProductId,
              mode != .browser || state.entitlement.allowsBrowser else {
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
        } else if state.killSwitch || leafKillSwitch() {
            await terminateAllSessions(source: .remoteConfig)
        } else if state.authorizationRevoked ||
                    !Self.entitlementIsActive(state.entitlement) ||
                    state.entitlement.productId != Self.computerUseProductId ||
                    !state.entitlement.allowsBrowser {
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
        let terminated = await coordinator.panicHaltAllWithRecords(source: source)
        recordEndedSessions(terminated)
    }

    private func terminateAllSessions(reason: ComputerUseEndReason) async {
        let terminated = await coordinator.endAllWithRecords(reason: reason)
        recordEndedSessions(terminated)
    }

    private func recordEndedSessions(_ ended: [ComputerUseSessionEndRecord]) {
        for record in ended {
            manifests.removeValue(forKey: ComputerUseSessionID(record.sessionId))
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

    private func cancel(approvalId: String) {
        guard let pending = pendingByApprovalId.removeValue(forKey: approvalId) else { return }
        pending.continuation.resume(throwing: CancellationError())
    }
}
