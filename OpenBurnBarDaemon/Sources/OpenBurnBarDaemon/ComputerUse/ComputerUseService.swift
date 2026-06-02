import Foundation
import CryptoKit
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
    }

    private static let computerUseProductId = "com.openburnbar.hostedComputerUseSync.monthly"

    private let coordinator: ComputerUseRunCoordinator
    private let approvalBridge: ComputerUseApprovalBridge
    private let auditBaseDirectory: URL
    private let macAppVersion: String
    private let locateExecutable: BurnBarExecutableLocator
    private let logger: BurnBarDaemonLogger
    private let bridgeScriptURL: URL
    private let auditExportSignerProvider: any ComputerUseAuditExportSignerProviding
    private var manifests: [ComputerUseSessionID: ComputerUseSessionManifest] = [:]

    public init(
        auditBaseDirectory: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("computer-use-audit", isDirectory: true),
        macAppVersion: String = BurnBarDaemonVersion.current,
        bridgeScriptURL: URL? = nil,
        locateExecutable: BurnBarExecutableLocator? = nil,
        auditExportSignerProvider: (any ComputerUseAuditExportSignerProviding)? = nil,
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
        self.coordinator = ComputerUseRunCoordinator(
            approvalIssuer: { request in
                try await approvalBridge.issue(request)
            },
            macAppVersion: macAppVersion,
            auditBaseDirectory: auditBaseDirectory,
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

        let sessionId = ComputerUseSessionID.newRandom()
        let manifest = ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: mode,
            trustMode: trustMode,
            startedAt: Date(),
            userId: request.clientID.rawValue,
            macHostNodeId: request.macHostNodeId,
            phoneViewerNodeId: request.phoneViewerNodeId,
            scopeRuleIds: request.scopeRuleIds,
            entitlementProductId: Self.computerUseProductId,
            actionCap: request.actionCap,
            sessionTimeoutSeconds: request.sessionTimeoutSeconds
        )

        let driver = try await makePlaywrightDriverIfNeeded(for: manifest)
        let head = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)
        manifests[sessionId] = manifest
        return ComputerUseSessionStartResponse(
            sessionId: sessionId.rawValue,
            manifestHashHex: head,
            startedAt: manifest.startedAt,
            entitlementProductId: Self.computerUseProductId,
            actionCap: request.actionCap
        )
    }

    public func invoke(_ request: ComputerUseInvokeRequest) async throws -> ComputerUseInvokeResponse {
        let sessionId = ComputerUseSessionID(request.sessionId)
        guard let manifest = manifests[sessionId],
              let state = await coordinator.session(sessionId) else {
            throw ServiceError.invalidSession(request.sessionId)
        }
        // TODO: Wire `phoneControlRespectsDenyRegions` from Remote Config when
        // the config infrastructure is extended to the daemon. Currently the
        // daemon only supports browser (Path B) sessions which do not involve
        // phone control, so the default `false` is safe.
        let capability = ComputerUseCapabilityContext(
            entitlement: entitlement(for: manifest.mode),
            envelope: .initialNormal,
            usage: ComputerUseQuotaUsage(dayKey: Self.todayKey()),
            session: state,
            concurrentSessionActive: false,
            killSwitch: false,
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
        let lastHead = state.auditChainHeadHashHex ?? ""
        let sessionDirectory = auditBaseDirectory.appendingPathComponent(sessionId.rawValue, isDirectory: true)
        await coordinator.panicHalt(sessionId: sessionId, source: source)
        finalizeAuditHeadIfPossible(sessionDirectory: sessionDirectory, closedAt: Date())
        manifests.removeValue(forKey: sessionId)
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
        if request.anchorOpenTimestamps {
            try await anchorOpenTimestampsProof(forChainAt: chainURL)
        }
        let signer = try deviceAuditExportSigner()
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

    private func anchorOpenTimestampsProof(forChainAt chainURL: URL) async throws {
        let client = ComputerUseOpenTimestampsClient()
        let proof = try await client.notarize(chainFileAt: chainURL)
        _ = try ComputerUseOpenTimestampsArchive.writeProof(
            proofBytes: proof,
            sourceChainURL: chainURL,
            calendarURL: client.configuration.calendarURL
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
