#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

/// Mac-side owner for a live Computer Use session.
///
/// This type deliberately lives in AgentLens, not the daemon package:
/// it touches AppKit/AX/CGEvent glue, owns the approval sheet futures,
/// and receives `control.*` frames from the paired phone. The pure data
/// contracts, scope matcher, capability gate, and audit chain stay in
/// `OpenBurnBarComputerUseCore`.
@MainActor
public final class ComputerUseSessionCoordinator: ObservableObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "ComputerUse")
    private static let phoneControlActionCap = 10_000
    private static func debugTrace(_ message: String) {
        NSLog("OpenBurnBarMercury \(message)")
    }

    public struct Configuration: Sendable {
        public var userId: String
        public var macHostNodeId: String?
        public var entitlement: ComputerUseEntitlementSnapshot
        public var budgetEnvelope: ComputerUseBudgetEnvelope
        public var quotaUsage: ComputerUseQuotaUsage
        public var auditBaseDirectory: URL
        public var macAppVersion: String
        public var killSwitch: Bool
        /// Remote Config `computer_use_phone_control_attestation_required`.
        public var phoneControlAttestationRequired: Bool
        /// Defense-in-depth: when `true`, phone-control intents are also checked
        /// against AX deny-regions. Remote Config
        /// `computer_use_phone_control_respects_deny_regions`. Default `false`.
        public var phoneControlRespectsDenyRegions: Bool
        /// Dedicated, short-lived consent for remote clipboard (phone↔Mac
        /// paste/grab). SEPARATE from `entitlement.allowsSystem`: the user can
        /// grant screen-share + input yet deny clipboard, and can revoke it
        /// mid-session by flipping this back to `false` (the next clipboard
        /// request is then denied without ending the session). Defaults OFF.
        public var clipboardConsentGranted: Bool

        public init(
            userId: String,
            macHostNodeId: String? = nil,
            entitlement: ComputerUseEntitlementSnapshot,
            budgetEnvelope: ComputerUseBudgetEnvelope = .initialNormal,
            quotaUsage: ComputerUseQuotaUsage,
            auditBaseDirectory: URL,
            macAppVersion: String,
            killSwitch: Bool = false,
            phoneControlAttestationRequired: Bool = false,
            phoneControlRespectsDenyRegions: Bool = false,
            clipboardConsentGranted: Bool = false
        ) {
            self.userId = userId
            self.macHostNodeId = macHostNodeId
            self.entitlement = entitlement
            self.budgetEnvelope = budgetEnvelope
            self.quotaUsage = quotaUsage
            self.auditBaseDirectory = auditBaseDirectory
            self.macAppVersion = macAppVersion
            self.killSwitch = killSwitch
            self.phoneControlAttestationRequired = phoneControlAttestationRequired
            self.phoneControlRespectsDenyRegions = phoneControlRespectsDenyRegions
            self.clipboardConsentGranted = clipboardConsentGranted
        }
    }

    public enum CoordinatorError: Error, Sendable, Equatable {
        case sessionAlreadyActive
        case noActiveSession
        case invalidMode(String)
        case invalidTrustMode(String)
        case missingEntitlementProduct
        case missingBrowserDispatcher
        case missingControlReplySender
    }

    public typealias ApprovalPresenter = @MainActor (
        _ request: HermesRealtimeRelayApprovalRequest,
        _ beforeScreenshotPNG: Data?
    ) async -> HermesRealtimeRelayApprovalResponse

    public typealias BrowserDispatcher = @MainActor (
        _ action: BrowserAction
    ) async throws -> BurnBarJSONValue

    @Published public private(set) var state: ComputerUseSessionState?
    @Published public private(set) var pendingApproval: HermesRealtimeRelayApprovalRequest?
    @Published public private(set) var pendingApprovalScreenshotPNG: Data?
    @Published public private(set) var actionTimeline: [HermesRealtimeRelayActionLogEntry] = []
    @Published public private(set) var lastDeniedReason: ComputerUseDenyReason?

    var controlDispatcher: ControlFrameDispatcher {
        { @Sendable [weak self] frame, replySender in
            await self?.handleControlFrame(frame, replySender: replySender)
        }
    }

    private var configuration: Configuration
    private let gate: ComputerUseCapabilityGate
    private let macDispatcher: MacActionDispatcher
    private let inputController: MacInputController
    private let remoteClipboardController: RemoteClipboardController
    private let remoteUnlockCredentialController: RemoteUnlockCredentialController
    private let scopeMatcher: ComputerUseScopeMatcher
    private let scopeRulesProvider: @MainActor () -> [ComputerUseScopeRule]
    private let approvalPresenter: ApprovalPresenter
    private let browserDispatcher: BrowserDispatcher?
    private let displayBoundsProvider: PhoneControlReceiver.DisplayBoundsProvider
    private let screenshotService: MacScreenshotService?
    private let authorityProvider: PhoneControlAuthorityPublicKeyProviding
    private var focusFollowController: AgentFocusFollowController?
    private var focusFollowMode: AgentFocusFollowMode = .smart

    private var phoneValidator = PhoneControlAuthorityValidator()
    private var phoneReceiver: PhoneControlReceiver?
    var phoneControlAuthorizedPeerNodeProvider: (@MainActor @Sendable () -> String?)?
    var phoneControlKeyboardTargetWindowProvider: (@MainActor @Sendable () -> CGWindowID?)?
    var phoneControlKeyboardTargetFocuser: (@MainActor @Sendable (CGWindowID) throws -> Void)?
    var remoteUnlockResultHandler: (@MainActor @Sendable (HermesRealtimeRelayRemoteUnlockResult) async -> Void)?
    weak var chatController: ChatSessionController?
    private var agentContextReceiver: AgentContextTargetReceiver?
    private var systemPermissionReceiver: SystemPermissionReceiver?
    private var latestReplySender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)?
    private var activeSessionId: ComputerUseSessionID?
    private var auditLogger: ComputerUseAuditLogger?
    private var approvalContinuations: [String: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Never>] = [:]
    private var approvalContexts: [String: ApprovalContext] = [:]
    private var screenshotEvidenceDataByHash: [String: Data] = [:]
    private var latestControlUID: String?
    private var latestControlConnectionID: String?
    #if DEBUG
    private var didStartE2EApprovalProbe = false
    #endif
    private nonisolated(unsafe) var remoteConfigObserver: NSObjectProtocol?

    private struct ApprovalContext: Sendable {
        let uid: String?
        let connectionID: String?
        let sessionID: String
        let requestedAt: Date
    }

    private enum ApprovalResponseSource: Sendable {
        case localPresenter
        case remote(uid: String, connectionID: String, sessionID: String?)
    }

    private func recordE2EProofEvent(_ fields: [String: String]) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF"] == "1" else { return }
        var record = fields
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        record["timestampMillis"] = String(Int(Date().timeIntervalSince1970 * 1000))
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print("OpenBurnBar ComputerUseE2E \(line)")
        guard let path = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF_OUTPUT"],
              !path.isEmpty,
              let lineData = "\(line)\n".data(using: .utf8)
        else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
            try? handle.close()
        }
        #endif
    }

    public init(
        configuration: Configuration,
        gate: ComputerUseCapabilityGate = DefaultComputerUseCapabilityGate(),
        macDispatcher: MacActionDispatcher = MacActionDispatcher(),
        inputController: MacInputController = MacInputController(),
        remoteClipboardController: RemoteClipboardController? = nil,
        scopeMatcher: ComputerUseScopeMatcher = ComputerUseScopeMatcher(),
        scopeRulesProvider: @escaping @MainActor () -> [ComputerUseScopeRule] = { [] },
        browserDispatcher: BrowserDispatcher? = nil,
        screenshotService: MacScreenshotService? = nil,
        authorityProvider: PhoneControlAuthorityPublicKeyProviding = FirestorePhoneControlAuthorityProvider.shared,
        displayBoundsProvider: @escaping PhoneControlReceiver.DisplayBoundsProvider = {
            let totalHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return NSScreen.screens.map { screen in
                let frame = screen.frame
                let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                    .map { String($0.uint32Value) }
                return MacInputCore.DisplayBounds(
                    displayId: displayId,
                    originX: Int(frame.origin.x),
                    originY: Int(totalHeight - frame.maxY),
                    width: Int(frame.width),
                    height: Int(frame.height)
                )
            }
        },
        approvalPresenter: @escaping ApprovalPresenter
    ) {
        self.configuration = configuration
        self.gate = gate
        self.macDispatcher = macDispatcher
        self.inputController = inputController
        self.remoteClipboardController = remoteClipboardController ?? RemoteClipboardController(
            inputController: inputController,
            gate: gate,
            scopeMatcher: scopeMatcher
        )
        self.remoteUnlockCredentialController = RemoteUnlockCredentialController(inputController: inputController)
        self.scopeMatcher = scopeMatcher
        self.scopeRulesProvider = scopeRulesProvider
        self.browserDispatcher = browserDispatcher
        self.screenshotService = screenshotService ?? MacScreenshotService(
            baseDirectory: configuration.auditBaseDirectory
        )
        self.authorityProvider = authorityProvider
        self.displayBoundsProvider = displayBoundsProvider
        self.approvalPresenter = approvalPresenter
        self.remoteConfigObserver = NotificationCenter.default.addObserver(
            forName: .computerUseRemoteConfigKillSwitchDidFire,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateKillSwitch(true)
            }
        }
    }

    deinit {
        if let remoteConfigObserver {
            NotificationCenter.default.removeObserver(remoteConfigObserver)
        }
    }

    public func updateEntitlement(_ entitlement: ComputerUseEntitlementSnapshot) {
        configuration.entitlement = entitlement
        guard activeSessionId != nil else { return }
        if !entitlement.isActive ||
            !entitlement.allowsBrowser ||
            !entitlement.allowsSystem ||
            !entitlement.allowsPhoneControl {
            endSessionNow(reason: .entitlementLost)
        }
    }

    public func updateBudgetEnvelope(_ envelope: ComputerUseBudgetEnvelope) {
        configuration.budgetEnvelope = envelope
        if envelope.level == .hardCap, !activeSessionIsDirectPhoneControl {
            haltForBudgetHardCap()
        }
    }

    public func updateQuotaUsage(_ usage: ComputerUseQuotaUsage) {
        configuration.quotaUsage = usage
    }

    public func updateKillSwitch(_ enabled: Bool) {
        configuration.killSwitch = enabled
        if enabled {
            Task { await panicHalt(source: .remoteConfig) }
        }
    }

    @discardableResult
    public func registerPhonePeer(nodeId: String, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        phoneValidator.registerPeer(nodeId: nodeId, publicKey: publicKey)
    }

    /// Peer node id of the in-flight phone-control session, if any.
    public var activePhoneViewerNodeId: String? {
        guard activeSessionId != nil else { return nil }
        return state?.manifest.phoneViewerNodeId
    }

    /// Revoke an escrow device mid-session. Populates the validator's
    /// revocation sets (so all future validate() calls AND any reconnect
    /// registerPeer are refused) and, when the live session belongs to the
    /// revoked peer, actively tears it down via panicHalt. Idempotent.
    public func revokeEscrowDevice(deviceId: String, peerNodeId: String?) async {
        phoneValidator.revokeEscrowDevice(deviceId: deviceId)
        if let peerNodeId, !peerNodeId.isEmpty {
            phoneValidator.revokePeer(nodeId: peerNodeId)
        }
        guard activeSessionId != nil else { return }
        let activePeer = state?.manifest.phoneViewerNodeId
        if let peerNodeId, let activePeer, peerNodeId == activePeer {
            await panicHalt(source: .revoked)
        }
    }

    func attachFocusFollowController(_ controller: AgentFocusFollowController) {
        focusFollowController = controller
        if let activeSessionId {
            controller.start(sessionId: activeSessionId.rawValue, mode: focusFollowMode)
        }
    }

    func setFocusFollowMode(_ mode: AgentFocusFollowMode) {
        focusFollowMode = mode
        focusFollowController?.setMode(mode)
    }

    @discardableResult
    public func startSession(
        request: ComputerUseSessionStartRequest
    ) async throws -> ComputerUseSessionStartResponse {
        guard activeSessionId == nil else { throw CoordinatorError.sessionAlreadyActive }
        guard let mode = ComputerUseMode(rawValue: request.mode) else {
            throw CoordinatorError.invalidMode(request.mode)
        }
        guard let trustMode = ComputerUseTrustMode(rawValue: request.trustMode) else {
            throw CoordinatorError.invalidTrustMode(request.trustMode)
        }
        guard let productId = configuration.entitlement.productId else {
            throw CoordinatorError.missingEntitlementProduct
        }
        if mode == .browser, browserDispatcher == nil {
            throw CoordinatorError.missingBrowserDispatcher
        }

        let sessionId = ComputerUseSessionID.newRandom()
        let manifest = ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: mode,
            trustMode: trustMode,
            startedAt: Date(),
            userId: configuration.userId,
            macHostNodeId: request.macHostNodeId ?? configuration.macHostNodeId,
            phoneViewerNodeId: request.phoneViewerNodeId,
            scopeRuleIds: request.scopeRuleIds,
            entitlementProductId: productId,
            actionCap: request.actionCap,
            sessionTimeoutSeconds: request.sessionTimeoutSeconds
        )

        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: configuration.auditBaseDirectory,
            macAppVersion: configuration.macAppVersion
        )
        try logger.beginSession(manifest: manifest)

        activeSessionId = sessionId
        auditLogger = logger
        state = ComputerUseSessionState(
            sessionId: sessionId,
            manifest: manifest,
            liveTrustMode: trustMode,
            auditChainHeadHashHex: logger.headHashHex
        )

        let phoneReceiverInstance = PhoneControlReceiver(
            sessionId: sessionId,
            validator: phoneValidator,
            displayBoundsProvider: displayBoundsProvider,
            authorizedPeerNodeProvider: phoneControlAuthorizedPeerNodeProvider,
            dispatchHandler: { [weak self] action, sessionId, counter in
                await self?.handlePhoneAction(action, sessionId: sessionId, counter: counter)
            },
            denyFrameSink: { [weak self] frame in
                guard let self else { return }
                await self.recordE2EProofEvent([
                    "event": "mac_control_denied",
                    "connectionId": frame.connectionId,
                    "reason": frame.control?.denied?.reason.rawValue ?? "unknown",
                    "detail": frame.control?.denied?.detail ?? ""
                ])
                try await self.latestReplySender?(frame)
            }
        )
        phoneReceiverInstance.attestationRequirementProvider = {
            let strict = await MainActor.run {
                SettingsManager.shared.computerUsePhoneControlAttestationRequired
            }
            return await MacAppCheckAttestationReader.attestationRequirement(strictMode: strict)
        }
        phoneReceiver = phoneReceiverInstance

        agentContextReceiver = AgentContextTargetReceiver(
            sessionId: sessionId,
            validator: phoneValidator,
            chatControllerProvider: { [weak self] in self?.chatController },
            displayBoundsProvider: displayBoundsProvider,
            replyFrameSink: { [weak self] frame in
                try await self?.latestReplySender?(frame)
            },
            auditLoggerProvider: { [weak self] in self?.auditLogger }
        )

        systemPermissionReceiver = SystemPermissionReceiver(
            validator: phoneValidator,
            monitor: .shared,
            denyFrameSink: { [weak self] frame in
                try await self?.latestReplySender?(frame)
            },
            statusFrameSink: { [weak self] frame in
                try await self?.latestReplySender?(frame)
                await SystemPermissionRetryDispatcher.shared.observe(statusFrame: frame)
            }
        )

        SystemPermissionMonitor.shared.attach(
            frameSink: { [weak self] frame in
                try? await self?.latestReplySender?(frame)
                await SystemPermissionRetryDispatcher.shared.observe(statusFrame: frame)
            },
            uidProvider: { [weak self] in
                guard let self else { return nil }
                guard let uid = self.latestControlUID,
                      let connectionID = self.latestControlConnectionID else { return nil }
                return (uid: uid, connectionId: connectionID, sessionId: self.activeSessionId?.rawValue)
            }
        )
        SystemPermissionMonitor.shared.start()

        appendTimeline(
            kind: "session.start",
            summary: "Computer Use session started",
            status: .planned
        )
        focusFollowController?.start(sessionId: sessionId.rawValue, mode: focusFollowMode)

        return ComputerUseSessionStartResponse(
            sessionId: sessionId.rawValue,
            manifestHashHex: logger.headHashHex,
            startedAt: manifest.startedAt,
            entitlementProductId: productId,
            actionCap: request.actionCap
        )
    }

    public func endSession(reason: ComputerUseEndReason = .completed) async {
        endSessionNow(reason: reason)
    }

    private func endSessionNow(reason: ComputerUseEndReason = .completed) {
        guard activeSessionId != nil else { return }
        cancelPendingApprovals(decision: .reject, note: "session ended")
        finalizeAuditSignedHeadIfPossible()
        activeSessionId = nil
        phoneReceiver = nil
        systemPermissionReceiver = nil
        SystemPermissionMonitor.shared.detach()
        focusFollowController?.stop()
        auditLogger = nil
        screenshotEvidenceDataByHash.removeAll()
        pendingApproval = nil
        pendingApprovalScreenshotPNG = nil
        state?.endReason = reason
        state?.endedAt = Date()
        appendTimeline(
            kind: "session.end",
            summary: "Computer Use session ended: \(reason.rawValue)",
            status: .completed
        )
    }

    public func panicHalt(source: ComputerUsePanicSource) async {
        guard let sessionId = activeSessionId else { return }
        PrivilegedInputKillSwitch.activate(reason: source.rawValue)
        cancelPendingApprovals(decision: .rejectAndHalt, note: "panic halt")
        if let logger = auditLogger {
            let action: ComputerUseAction = .macInspect(MacInspectAction(kind: .accessibility))
            if let entry = try? logger.makeEntry(
                for: action,
                approvedBy: .panic,
                denyReason: source.rawValue,
                macHostNodeId: configuration.macHostNodeId,
                scopeContext: macDispatcher.currentScopeContext()
            ) {
                _ = try? logger.append(entry)
                state?.auditChainHeadHashHex = logger.headHashHex
            }
            finalizeAuditSignedHeadIfPossible()
        }
        activeSessionId = nil
        phoneReceiver = nil
        systemPermissionReceiver = nil
        SystemPermissionMonitor.shared.detach()
        focusFollowController?.stop()
        auditLogger = nil
        screenshotEvidenceDataByHash.removeAll()
        pendingApproval = nil
        pendingApprovalScreenshotPNG = nil
        state?.endReason = endReason(for: source)
        state?.endedAt = Date()
        appendTimeline(
            kind: "panic.\(source.rawValue)",
            summary: "Panic halt: \(source.rawValue)",
            status: .panicHalted
        )
        _ = sessionId
    }

    private func finalizeAuditSignedHeadIfPossible() {
        guard let logger = auditLogger else { return }
        let legacyKey = OpenBurnBarAppPaths.live().supportDirectory
            .appendingPathComponent("computer-use-audit", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("audit-export-ed25519.raw", isDirectory: false)
        guard let signer = try? ComputerUseKeychainAuditExportSignerProvider(legacyRawKeyURL: legacyKey).signer() else {
            return
        }
        try? ComputerUseAuditHeadFinalizer.finalize(logger: logger, signer: signer)
    }

    private func haltForBudgetHardCap() {
        guard activeSessionId != nil else { return }
        PrivilegedInputKillSwitch.activate(reason: ComputerUseDenyReason.hardCap.rawValue)
        cancelPendingApprovals(decision: .rejectAndHalt, note: "budget hard cap")
        if let logger = auditLogger {
            let action: ComputerUseAction = .macInspect(MacInspectAction(kind: .accessibility))
            if let entry = try? logger.makeEntry(
                for: action,
                approvedBy: .panic,
                denyReason: ComputerUseDenyReason.hardCap.rawValue,
                macHostNodeId: configuration.macHostNodeId,
                scopeContext: macDispatcher.currentScopeContext()
            ) {
                _ = try? logger.append(entry)
                state?.auditChainHeadHashHex = logger.headHashHex
            }
        }
        activeSessionId = nil
        phoneReceiver = nil
        focusFollowController?.stop()
        auditLogger = nil
        screenshotEvidenceDataByHash.removeAll()
        pendingApproval = nil
        pendingApprovalScreenshotPNG = nil
        approvalContexts.removeAll()
        lastDeniedReason = .hardCap
        state?.endReason = .budgetHardCap
        state?.endedAt = Date()
        appendTimeline(
            kind: "budget.hard_cap",
            summary: "Budget hard cap reached",
            status: .panicHalted
        )
    }

    public func setTrustMode(_ mode: ComputerUseTrustMode) {
        guard var current = state else { return }
        current.liveTrustMode = mode
        state = current
    }

    func setRemoteUnlockResultHandler(
        _ handler: (@MainActor @Sendable (HermesRealtimeRelayRemoteUnlockResult) async -> Void)?
    ) {
        remoteUnlockResultHandler = handler
    }

    public func submitApprovalResponse(_ response: HermesRealtimeRelayApprovalResponse) {
        submitApprovalResponse(response, source: .localPresenter)
    }

    private func submitApprovalResponse(
        _ response: HermesRealtimeRelayApprovalResponse,
        source: ApprovalResponseSource
    ) {
        guard let context = approvalContexts[response.approvalId] else {
            return
        }
        switch source {
        case .localPresenter:
            break
        case .remote(let uid, let connectionID, let sessionID):
            guard response.respondedBy == "phone",
                  context.uid == uid,
                  context.connectionID == connectionID,
                  sessionID == nil || sessionID == context.sessionID
            else {
                Self.log.warning("Rejected remote approval response that did not match the pending requester.")
                return
            }
        }
        guard let continuation = approvalContinuations.removeValue(forKey: response.approvalId) else {
            approvalContexts.removeValue(forKey: response.approvalId)
            return
        }
        approvalContexts.removeValue(forKey: response.approvalId)
        if pendingApproval?.approvalId == response.approvalId {
            pendingApproval = nil
            pendingApprovalScreenshotPNG = nil
        }
        continuation.resume(returning: response)
    }

    public func invoke(_ invocation: BurnBarToolInvocation) async -> ComputerUseInvokeResponse {
        guard let sessionId = activeSessionId, var currentState = state, let logger = auditLogger else {
            return ComputerUseInvokeResponse(
                sessionId: activeSessionId?.rawValue ?? "",
                callID: invocation.callID,
                status: .error,
                denyReason: "no_active_session"
            )
        }

        let action: ComputerUseAction
        do {
            action = try decodeAction(invocation: invocation)
        } catch {
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .error,
                denyReason: "invalid_arguments: \(String(describing: error))"
            )
        }

        let beforeCapture = captureEvidence(
            label: "before-\(action.auditKind)",
            sessionId: sessionId,
            logger: logger
        )
        let scopeContext = scopeContext(for: action)
        let scopeOutcome = scopeMatcher.evaluate(
            rules: scopeRulesProvider(),
            context: scopeContext
        )
        let accessibilityDeny = accessibilityDeny(for: action)
        let capability = ComputerUseCapabilityContext(
            entitlement: configuration.entitlement,
            envelope: configuration.budgetEnvelope,
            usage: configuration.quotaUsage,
            session: currentState,
            concurrentSessionActive: false,
            killSwitch: configuration.killSwitch,
            accessibilityTrusted: inputController.isAccessibilityTrusted(),
            originatedFromPhone: invocation.requestedBy.rawValue == "phone-control",
            phoneControlRespectsDenyRegions: configuration.phoneControlRespectsDenyRegions
        )

        switch gate.check(
            action: action,
            scopeOutcome: scopeOutcome,
            accessibilityDeny: accessibilityDeny,
            context: capability
        ) {
        case .denied(let reason):
            lastDeniedReason = reason
            let entry = appendAuditEntry(
                logger: logger,
                action: action,
                approvedBy: .denied,
                scopeRuleId: scopeRuleIfDenied(outcome: scopeOutcome),
                denyReason: reason.rawValue,
                scopeContext: scopeContext,
                beforeScreenshotHashHex: beforeCapture?.sha256Hex
            )
            currentState.actionsRejected += 1
            currentState.auditChainHeadHashHex = logger.headHashHex
            state = currentState
            let response = ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .denied,
                denyReason: reason.rawValue,
                auditEntryIndex: entry?.entryIndex,
                auditHeadHashHex: logger.headHashHex
            )
            appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
            return response

        case .allowed(let approvedByCandidate):
            let approval: ApprovalDecision
            if approvedByCandidate == .trustedScope ||
                approvedByCandidate == .phone ||
                isReadOnlyInspect(action: action) {
                approval = ApprovalDecision(approvedBy: approvedByCandidate, approvalId: nil)
            } else {
                approval = await requestApproval(
                    invocation: invocation,
                    action: action,
                    scopeContext: scopeContext,
                    beforeScreenshotHashHex: beforeCapture?.sha256Hex
                )
                switch approval.decision {
                case .approve:
                    break
                case .reject, .rejectAndHalt:
                    lastDeniedReason = .userRejected
                    let entry = appendAuditEntry(
                        logger: logger,
                        action: action,
                        approvalId: approval.approvalId,
                        approvedBy: .denied,
                        denyReason: ComputerUseDenyReason.userRejected.rawValue,
                        scopeContext: scopeContext,
                        beforeScreenshotHashHex: beforeCapture?.sha256Hex
                    )
                    currentState.actionsRejected += 1
                    currentState.auditChainHeadHashHex = logger.headHashHex
                    state = currentState
                    if approval.decision == .rejectAndHalt {
                        await panicHalt(source: .stalled)
                    }
                    let response = ComputerUseInvokeResponse(
                        sessionId: sessionId.rawValue,
                        callID: invocation.callID,
                        status: .denied,
                        approvalId: approval.approvalId,
                        denyReason: ComputerUseDenyReason.userRejected.rawValue,
                        auditEntryIndex: entry?.entryIndex,
                        auditHeadHashHex: logger.headHashHex
                    )
                    appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                    return response
                }
            }

            // AUDIT-BEFORE-ACTION (fail-closed): reserve a pending audit
            // entry on the chain BEFORE dispatch. If the reservation append
            // throws we must NOT execute the action.
            let reservation: ComputerUseAuditEntry
            do {
                reservation = try reserveAuditEntry(
                    logger: logger,
                    action: action,
                    approvalId: approval.approvalId,
                    approvedBy: approval.approvedBy,
                    scopeRuleId: scopeRuleIfAllowed(outcome: scopeOutcome),
                    scopeContext: scopeContext,
                    beforeScreenshotHashHex: beforeCapture?.sha256Hex
                )
                currentState.auditChainHeadHashHex = logger.headHashHex
                state = currentState
            } catch {
                lastDeniedReason = .auditFailure
                currentState.actionsRejected += 1
                currentState.auditChainHeadHashHex = logger.headHashHex
                state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .denied,
                    approvalId: approval.approvalId,
                    denyReason: ComputerUseDenyReason.auditFailure.rawValue,
                    auditHeadHashHex: logger.headHashHex
                )
                appendTimeline(for: action, invocation: invocation, response: response, auditEntry: nil)
                return response
            }

            do {
                let result = try await dispatch(action: action, invocation: invocation)
                let afterCapture = captureEvidence(
                    label: "after-\(action.auditKind)",
                    sessionId: sessionId,
                    logger: logger
                )
                let entry = appendAuditEntry(
                    logger: logger,
                    action: action,
                    approvalId: approval.approvalId,
                    approvedBy: approval.approvedBy,
                    scopeRuleId: scopeRuleIfAllowed(outcome: scopeOutcome),
                    scopeContext: scopeContext,
                    beforeScreenshotHashHex: beforeCapture?.sha256Hex,
                    afterScreenshotHashHex: afterCapture?.sha256Hex
                ) ?? reservation
                currentState.actionsExecuted += 1
                currentState.lastActionAt = Date()
                currentState.auditChainHeadHashHex = logger.headHashHex
                state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .executed,
                    approvalId: approval.approvalId,
                    auditEntryIndex: entry.entryIndex,
                    auditHeadHashHex: logger.headHashHex,
                    result: result
                )
                appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                return response
            } catch {
                let afterCapture = captureEvidence(
                    label: "error-\(action.auditKind)",
                    sessionId: sessionId,
                    logger: logger
                )
                let entry = appendAuditEntry(
                    logger: logger,
                    action: action,
                    approvalId: approval.approvalId,
                    approvedBy: approval.approvedBy,
                    denyReason: String(describing: error),
                    scopeContext: scopeContext,
                    beforeScreenshotHashHex: beforeCapture?.sha256Hex,
                    afterScreenshotHashHex: afterCapture?.sha256Hex
                ) ?? reservation
                currentState.actionsRejected += 1
                currentState.auditChainHeadHashHex = logger.headHashHex
                state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .error,
                    approvalId: approval.approvalId,
                    denyReason: String(describing: error),
                    auditEntryIndex: entry.entryIndex,
                    auditHeadHashHex: logger.headHashHex
                )
                appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                return response
            }
        }
    }

    private func requestApproval(
        invocation: BurnBarToolInvocation,
        action: ComputerUseAction,
        scopeContext: ComputerUseScopeContext,
        beforeScreenshotHashHex: String?
    ) async -> ApprovalDecision {
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: UUID().uuidString,
            runId: invocation.runID.rawValue,
            sessionId: activeSessionId?.rawValue ?? "",
            toolKind: invocation.tool.rawValue,
            title: action.executableSummary(forApproval: scopeContext),
            message: action.executableSummary(forApproval: scopeContext),
            beforeScreenshotBlake3: beforeScreenshotHashHex,
            actionSummary: action.executableSummary(forApproval: scopeContext),
            requestedAt: Date(),
            trustMode: (state?.liveTrustMode ?? .manual).rawValue
        )
        pendingApproval = request
        pendingApprovalScreenshotPNG = captureData(forHash: beforeScreenshotHashHex)
        appendTimeline(
            kind: invocation.tool.rawValue,
            summary: request.actionSummary,
            status: .awaitingApproval
        )

        let response = await withCheckedContinuation { continuation in
            approvalContinuations[request.approvalId] = continuation
            approvalContexts[request.approvalId] = ApprovalContext(
                uid: latestControlUID,
                connectionID: latestControlConnectionID,
                sessionID: request.sessionId,
                requestedAt: request.requestedAt
            )
            emitControlFrame(
                type: .controlApprovalRequest,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.approval",
                    sessionId: request.sessionId,
                    approvalRequest: request
                )
            )
            Task { @MainActor in
                let presenterResponse = await approvalPresenter(request, pendingApprovalScreenshotPNG)
                submitApprovalResponse(presenterResponse)
            }
        }
        let approvedBy: ComputerUseAuditEntry.ApprovedBy =
            response.respondedBy == "phone" ? .phone : .mac
        return ApprovalDecision(
            decision: response.decision,
            approvedBy: approvedBy,
            approvalId: response.approvalId
        )
    }

    private func dispatch(
        action: ComputerUseAction,
        invocation: BurnBarToolInvocation
    ) async throws -> BurnBarToolResult {
        let output: BurnBarJSONValue
        switch action {
        case .browser(let browser):
            guard let browserDispatcher else { throw CoordinatorError.missingBrowserDispatcher }
            output = try await browserDispatcher(browser)
        case .macInput(let input):
            if shouldUseVirtualHIDForLockedInput() {
                Self.log.info("mac_phone_action_virtual_hid_dispatch kind=\(input.kind.rawValue, privacy: .public)")
                Self.debugTrace("mac_phone_action_virtual_hid_dispatch kind=\(input.kind.rawValue)")
                let token = try await mintVirtualHIDCapabilityToken(actionKind: input.kind.rawValue)
                output = try await RemoteUnlockVirtualHIDInputClient().dispatch(input, capabilityToken: token)
            } else {
                output = try macDispatcher.dispatch(input)
            }
        case .macInspect(let inspect):
            output = try macDispatcher.inspect(inspect)
        case .remoteClipboard:
            throw CoordinatorError.noActiveSession
        case .phoneIntent(let intent):
            if intent.kind == .panic {
                await panicHalt(source: .phoneGesture)
                output = .object(["ok": .bool(true), "kind": .string("panic")])
            } else {
                throw CoordinatorError.noActiveSession
            }
        }
        return BurnBarToolResult(
            callID: invocation.callID,
            runID: invocation.runID,
            succeeded: true,
            output: output,
            completedAt: Date()
        )
    }

    private func shouldUseVirtualHIDForLockedInput() -> Bool {
        let readiness = MacRemoteUnlockReadinessService.shared
        let snapshot = readiness.snapshot()
        guard snapshot.virtualHIDDriverActive else { return false }
        switch readiness.currentState(sessionId: nil, controlOwnerViewerId: nil).lockState {
        case .unlocked, .unknown:
            return false
        default:
            return true
        }
    }

    private func mintVirtualHIDCapabilityToken(actionKind: String) async throws -> CapabilityToken {
        let peerNodeId = phoneControlAuthorizedPeerNodeProvider?()
        let sessionId = activeSessionId?.rawValue ?? latestControlConnectionID
        let scopeHash = SHA256.hash(data: Data("remote_unlock:\(sessionId ?? "none")".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard let token = try await RemoteUnlockCapabilityTokenBroker.shared.mintInputToken(
            actionKind: actionKind,
            scopeHash: scopeHash,
            attestationHashBlake3: nil,
            sessionId: sessionId,
            peerNodeId: peerNodeId
        ) else {
            throw CoordinatorError.noActiveSession
        }
        return token
    }

    private func handleControlFrame(
        _ frame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        latestReplySender = replySender
        latestControlUID = frame.uid
        latestControlConnectionID = frame.connectionId
        Self.debugTrace("computer_use_control_frame_received type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "") connectionID=\(frame.connectionId)")
        switch frame.type {
        case .controlClassify:
            guard let peerNodeId = frame.control?.authorityPeerNodeId else { return }
            // FAIL-CLOSED reconnect rejection: a revoked peer cannot
            // re-admit itself via a fresh classify, even before the
            // escrow_devices listener has fired.
            if phoneValidator.isPeerRevoked(nodeId: peerNodeId) {
                recordE2EProofEvent([
                    "event": "mac_control_classify_revoked_peer",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId
                ])
                emitControlFrame(
                    type: .controlDenied,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "control.input",
                        sessionId: activeSessionId?.rawValue,
                        denied: HermesRealtimeRelayControlDenied(reason: .signatureFailure, detail: "peer_revoked")
                    )
                )
                return
            }
            do {
                let publicKey = try await authorityProvider.fetchPublicKey(
                    uid: frame.uid,
                    connectionId: frame.connectionId,
                    peerNodeId: peerNodeId
                )
                guard registerPhonePeer(nodeId: peerNodeId, publicKey: publicKey) else {
                    recordE2EProofEvent([
                        "event": "mac_control_classify_revoked_peer",
                        "peerNodeId": peerNodeId,
                        "connectionId": frame.connectionId
                    ])
                    emitControlFrame(
                        type: .controlDenied,
                        payload: HermesRealtimeRelayControlPayload(
                            streamClass: "control.input",
                            sessionId: activeSessionId?.rawValue,
                            denied: HermesRealtimeRelayControlDenied(reason: .signatureFailure, detail: "peer_revoked")
                        )
                    )
                    return
                }
                if activeSessionId == nil {
                    _ = try await startSession(request: ComputerUseSessionStartRequest(
                        mode: ComputerUseMode.system.rawValue,
                        trustMode: ComputerUseTrustMode.manual.rawValue,
                        phoneViewerNodeId: peerNodeId,
                        macHostNodeId: configuration.macHostNodeId,
                        actionCap: Self.phoneControlActionCap,
                        sessionTimeoutSeconds: 1800,
                        clientID: BurnBarClientID(rawValue: "phone-control-\(peerNodeId)")
                    ))
                }
                recordE2EProofEvent([
                    "event": "mac_control_classified",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId
                ])
                #if DEBUG
                startE2EApprovalProbeIfRequested()
                #endif
            } catch {
                recordE2EProofEvent([
                    "event": "mac_control_classify_failed",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId,
                    "error": error.localizedDescription
                ])
                emitControlFrame(
                    type: .controlDenied,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "control.input",
                        sessionId: activeSessionId?.rawValue,
                        denied: HermesRealtimeRelayControlDenied(reason: .signatureFailure)
                    )
                )
            }
        case .controlInputIntent:
            recordE2EProofEvent([
                "event": "mac_control_input_received",
                "kind": frame.control?.inputIntent?.kind.rawValue ?? "unknown",
                "connectionId": frame.connectionId,
                "counter": String(frame.control?.inputIntent?.authority.counter ?? 0)
            ])
            guard let phoneReceiver else {
                recordE2EProofEvent([
                    "event": "mac_control_input_missing_receiver",
                    "connectionId": frame.connectionId
                ])
                return
            }
            await phoneReceiver.ingest(frame)
        case .controlClipboardRequest:
            guard let request = frame.control?.clipboardRequest else { return }
            recordE2EProofEvent([
                "event": "mac_control_clipboard_received",
                "action": request.action.rawValue,
                "connectionId": frame.connectionId,
                "counter": String(request.authority.counter)
            ])
            let result = remoteClipboardController.handle(
                request: request,
                context: RemoteClipboardController.RuntimeContext(
                    activeSessionId: activeSessionId,
                    state: state,
                    configuration: configuration,
                    auditLogger: auditLogger,
                    scopeRules: scopeRulesProvider(),
                    validator: phoneValidator,
                    isDirectPhoneControl: activeSessionIsDirectPhoneControl,
                    attestation: await phoneControlAttestationRequirement()
                )
            )
            applyRemoteClipboardResult(result)
            emitControlFrame(
                type: .controlClipboardResponse,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.clipboard",
                    sessionId: activeSessionId?.rawValue,
                    clipboardResponse: result.response
                )
            )
        case .controlAgentContextTarget:
            guard let receiver = agentContextReceiver else { return }
            await receiver.ingest(frame)
        case .controlApprovalResponse:
            if let response = frame.control?.approvalResponse {
                submitApprovalResponse(
                    response,
                    source: .remote(
                        uid: frame.uid,
                        connectionID: frame.connectionId,
                        sessionID: frame.control?.sessionId
                    )
                )
            }
        case .controlAgentGrantRequest:
            guard let wireRequest = frame.control?.agentGrantRequest else { return }
            let receipt: AgentCapabilityGrantReceipt
            do {
                let attestation = await MacAppCheckAttestationReader.attestationRequirement(
                    strictMode: SettingsManager.shared.computerUsePhoneControlAttestationRequired
                )
                _ = try phoneValidator.validate(
                    envelope: wireRequest.authority,
                    grantRequest: wireRequest,
                    attestation: attestation,
                    now: Date()
                )
                let request = try AgentCapabilityGrantRequest(wire: wireRequest)
                receipt = AgentCapabilityGrantStore.shared.apply(request)
            } catch let error as PhoneControlAuthorityValidator.ValidationError {
                receipt = Self.agentGrantReceipt(
                    for: wireRequest,
                    status: .denied,
                    denialReason: Self.agentGrantDenialReason(for: error),
                    message: "Grant signature failed: \(error)"
                )
            } catch let error as AgentCapabilityGrantWireError {
                receipt = Self.agentGrantReceipt(
                    for: wireRequest,
                    status: .denied,
                    denialReason: .malformedRequest,
                    message: "Grant request could not be decoded: \(error)"
                )
            } catch {
                receipt = Self.agentGrantReceipt(
                    for: wireRequest,
                    status: .denied,
                    denialReason: .unknown,
                    message: error.localizedDescription
                )
            }
            emitControlFrame(
                type: .controlAgentGrantReceipt,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.agent.grant",
                    sessionId: activeSessionId?.rawValue,
                    agentGrantReceipt: receipt.wire()
                )
            )
        case .controlSystemPermissionRequest:
            guard let receiver = systemPermissionReceiver else { return }
            await receiver.ingest(frame)
        case .controlSystemPermissionStatus:
            // The Mac is the source of truth for system-permission
            // status frames. We still allow phone-side reflections
            // (e.g. tests) to flow through the retry dispatcher.
            await SystemPermissionRetryDispatcher.shared.observe(statusFrame: frame)
        case .remoteUnlockCredential:
            guard let credential = frame.control?.remoteUnlockCredential else { return }
            let credentialPeerNodeId = credential.authority.peerNodeId
            Self.log.info(
                "remote_unlock_credential_frame_received requestID=\(credential.requestId, privacy: .public) sessionID=\(credential.sessionId, privacy: .public) peerNodeID=\(credentialPeerNodeId, privacy: .public) connectionID=\(frame.connectionId, privacy: .public)"
            )
            Self.debugTrace("remote_unlock_credential_frame_received requestID=\(credential.requestId) sessionID=\(credential.sessionId) peerNodeID=\(credentialPeerNodeId) connectionID=\(frame.connectionId)")
            do {
                let receivedResult = HermesRealtimeRelayRemoteUnlockResult(
                    requestId: credential.requestId,
                    sessionId: credential.sessionId,
                    status: .accepted,
                    detail: "credential_received",
                    completedAt: Date()
                )
                try await sendControlFrame(
                    type: .remoteUnlockResult,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "remote_unlock",
                        sessionId: credential.sessionId,
                        remoteUnlockResult: receivedResult
                    )
                )
                Self.log.info(
                    "remote_unlock_credential_received_ack_sent requestID=\(credential.requestId, privacy: .public)"
                )
                Self.debugTrace("remote_unlock_credential_received_ack_sent requestID=\(credential.requestId)")
            } catch {
                Self.log.error(
                    "remote_unlock_credential_received_ack_failed requestID=\(credential.requestId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                Self.debugTrace("remote_unlock_credential_received_ack_failed requestID=\(credential.requestId) error=\(error.localizedDescription)")
            }
            if !phoneValidator.hasPeer(nodeId: credentialPeerNodeId) {
                do {
                    let publicKey = try await authorityProvider.fetchPublicKey(
                        uid: frame.uid,
                        connectionId: frame.connectionId,
                        peerNodeId: credentialPeerNodeId
                    )
                    registerPhonePeer(nodeId: credentialPeerNodeId, publicKey: publicKey)
                    recordE2EProofEvent([
                        "event": "remote_unlock_peer_registered",
                        "peerNodeId": credentialPeerNodeId,
                        "connectionId": frame.connectionId
                    ])
                } catch {
                    recordE2EProofEvent([
                        "event": "remote_unlock_peer_registration_failed",
                        "peerNodeId": credentialPeerNodeId,
                        "connectionId": frame.connectionId,
                        "error": error.localizedDescription
                    ])
                }
            }
            let authorizedPeerNode = await MainActor.run { phoneControlAuthorizedPeerNodeProvider?() }
            let result = await remoteUnlockCredentialController.handle(
                credential: credential,
                context: RemoteUnlockCredentialController.RuntimeContext(
                    validator: phoneValidator,
                    activeSessionId: activeSessionId,
                    state: state,
                    isDirectPhoneControl: activeSessionIsDirectPhoneControl,
                    authorizedPeerNodeId: authorizedPeerNode,
                    attestation: await phoneControlAttestationRequirement()
                )
            )
            Self.log.info(
                "remote_unlock_credential_result requestID=\(credential.requestId, privacy: .public) status=\(result.status.rawValue, privacy: .public) detail=\(result.detail ?? "", privacy: .public) lockState=\(result.lockState?.rawValue ?? "", privacy: .public)"
            )
            Self.debugTrace("remote_unlock_credential_result requestID=\(credential.requestId) status=\(result.status.rawValue) detail=\(result.detail ?? "") lockState=\(result.lockState?.rawValue ?? "")")
            do {
                try await sendControlFrame(
                    type: result.status == .denied ? .remoteUnlockDenied : .remoteUnlockResult,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "remote_unlock",
                        sessionId: credential.sessionId,
                        remoteUnlockResult: result
                    )
                )
                Self.log.info(
                    "remote_unlock_credential_result_sent requestID=\(credential.requestId, privacy: .public) status=\(result.status.rawValue, privacy: .public)"
                )
                Self.debugTrace("remote_unlock_credential_result_sent requestID=\(credential.requestId) status=\(result.status.rawValue)")
            } catch {
                Self.log.error(
                    "remote_unlock_credential_result_send_failed requestID=\(credential.requestId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                Self.debugTrace("remote_unlock_credential_result_send_failed requestID=\(credential.requestId) error=\(error.localizedDescription)")
            }
            await remoteUnlockResultHandler?(result)
        case .remoteUnlockSession,
             .remoteUnlockInput:
            let requestId = frame.requestId
                ?? frame.control?.remoteUnlockSession?.requestId
                ?? frame.control?.remoteUnlockInput?.requestId
                ?? frame.control?.remoteUnlockCredential?.requestId
                ?? UUID().uuidString
            emitControlFrame(
                type: .remoteUnlockDenied,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "remote_unlock",
                    sessionId: frame.control?.sessionId,
                    remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult(
                        requestId: requestId,
                        sessionId: frame.control?.sessionId,
                        status: .denied,
                        detail: "remote_unlock_daemon_unavailable",
                        completedAt: Date()
                    )
                )
            )
        case .remoteUnlockState,
             .remoteUnlockResult,
             .remoteUnlockDenied:
            break
        default:
            break
        }
    }

    private static func agentGrantReceipt(
        for request: HermesRealtimeRelayAgentGrantRequest,
        status: AgentGrantDecisionStatus,
        denialReason: AgentGrantDenialReason?,
        message: String
    ) -> AgentCapabilityGrantReceipt {
        let runtime = AssistantRuntimeID(rawValue: request.runtime) ?? .hermes
        let trustMode = ComputerUseTrustMode(rawValue: request.trustMode) ?? .manual
        let capabilities = Set(request.capabilities.compactMap(AgentDesktopCapability.init(rawValue:)))
        return AgentCapabilityGrantReceipt(
            requestID: request.requestId,
            runtimeID: runtime,
            threadID: request.threadId,
            status: status,
            capabilities: capabilities,
            trustMode: trustMode,
            receivedAt: Date(),
            sourceDeviceID: request.sourceDeviceId,
            denialReason: denialReason,
            message: message
        )
    }

    private static func agentGrantDenialReason(
        for error: PhoneControlAuthorityValidator.ValidationError
    ) -> AgentGrantDenialReason {
        error.agentGrantDenialReason
    }

    #if DEBUG
    private func startE2EApprovalProbeIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENBURNBAR_E2E_COMPUTER_USE_APPROVAL_PROOF"] == "1" else { return }
        guard !didStartE2EApprovalProbe else { return }
        guard let sessionId = activeSessionId?.rawValue else { return }
        didStartE2EApprovalProbe = true
        Task { @MainActor in
            recordE2EProofEvent([
                "event": "mac_approval_probe_started",
                "sessionId": sessionId
            ])
            let response = await invoke(BurnBarToolInvocation(
                callID: "e2e-approval-\(UUID().uuidString)",
                runID: BurnBarRunID(rawValue: "e2e-approval-\(sessionId)"),
                tool: .macInputScroll,
                arguments: .object([
                    "displayX": .number(500),
                    "displayY": .number(500),
                    "dragEndX": .number(500),
                    "dragEndY": .number(420)
                ]),
                requestedBy: BurnBarClientID(rawValue: "e2e-approval-agent"),
                requestedAt: Date()
            ))
            var fields: [String: String] = [
                "event": "mac_approval_probe_completed",
                "sessionId": response.sessionId,
                "status": response.status.rawValue
            ]
            if let approvalId = response.approvalId {
                fields["approvalId"] = approvalId
            }
            if let auditEntryIndex = response.auditEntryIndex {
                fields["auditEntryIndex"] = String(auditEntryIndex)
            }
            if let auditHeadHashHex = response.auditHeadHashHex {
                fields["auditHead"] = auditHeadHashHex
            }
            if let denyReason = response.denyReason {
                fields["denyReason"] = denyReason
            }
            recordE2EProofEvent(fields)
        }
    }
    #endif

    private func handlePhoneAction(_ action: ComputerUseAction, sessionId: ComputerUseSessionID, counter: UInt64) async {
        guard activeSessionId == sessionId else { return }
        guard configuration.entitlement.allowsPhoneControl else {
            emitControlFrame(
                type: .controlDenied,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.input",
                    sessionId: sessionId.rawValue,
                    denied: HermesRealtimeRelayControlDenied(reason: .entitlement)
                )
            )
            return
        }
        if case .phoneIntent(let intent) = action, intent.kind == .panic {
            recordE2EProofEvent([
                "event": "mac_phone_panic_received",
                "sessionId": sessionId.rawValue,
                "counter": String(counter)
            ])
            await panicHalt(source: .phoneGesture)
            return
        }
        let invocation = invocationFromPhoneAction(action, sessionId: sessionId)
        refocusPhoneKeyboardTargetIfNeeded(for: action)
        recordE2EProofEvent([
            "event": "mac_phone_action_dispatching",
            "tool": invocation.tool.rawValue,
            "sessionId": sessionId.rawValue,
            "counter": String(counter)
        ])
        let response = await invoke(invocation)
        var fields: [String: String] = [
            "event": "mac_phone_action_dispatched",
            "tool": invocation.tool.rawValue,
            "sessionId": response.sessionId,
            "status": response.status.rawValue,
            "counter": String(counter)
        ]
        if let auditEntryIndex = response.auditEntryIndex {
            fields["auditEntryIndex"] = String(auditEntryIndex)
        }
        if let auditHeadHashHex = response.auditHeadHashHex {
            fields["auditHead"] = auditHeadHashHex
        }
        if let denyReason = response.denyReason {
            fields["denyReason"] = denyReason
            Self.log.warning(
                "mac_phone_action_denied tool=\(invocation.tool.rawValue, privacy: .public) reason=\(denyReason, privacy: .public) status=\(response.status.rawValue, privacy: .public)"
            )
        }
        recordE2EProofEvent(fields)
        emitPhoneControlDeniedFrameIfNeeded(response)
    }

    private var activeSessionIsDirectPhoneControl: Bool {
        guard let manifest = state?.manifest else { return false }
        return manifest.mode == .system && manifest.phoneViewerNodeId?.isEmpty == false
    }

    nonisolated static func shouldRetargetPhoneKeyboardAction(_ action: ComputerUseAction) -> Bool {
        guard case .macInput(let input) = action else { return false }
        switch input.kind {
        case .type, .key, .shortcut:
            return true
        case .click, .dragDrop, .scroll, .pointerMove:
            return false
        }
    }

    private func refocusPhoneKeyboardTargetIfNeeded(for action: ComputerUseAction) {
        guard Self.shouldRetargetPhoneKeyboardAction(action),
              let windowID = phoneControlKeyboardTargetWindowProvider?() else { return }
        do {
            if let phoneControlKeyboardTargetFocuser {
                try phoneControlKeyboardTargetFocuser(windowID)
            } else {
                try inputController.focusWindow(windowID: windowID)
            }
            recordE2EProofEvent([
                "event": "mac_phone_keyboard_target_refocused",
                "windowId": String(windowID)
            ])
        } catch {
            recordE2EProofEvent([
                "event": "mac_phone_keyboard_target_refocus_failed",
                "windowId": String(windowID),
                "error": String(describing: error)
            ])
            Self.log.warning("mac_phone_keyboard_target_refocus_failed windowID=\(windowID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func emitPhoneControlDeniedFrameIfNeeded(_ response: ComputerUseInvokeResponse) {
        guard response.status != .executed,
              let denyReason = response.denyReason else { return }
        let denied = HermesRealtimeRelayControlDenied(
            reason: controlDeniedReason(for: denyReason),
            detail: denyReason
        )
        emitControlFrame(
            type: .controlDenied,
            payload: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                sessionId: response.sessionId,
                denied: denied
            )
        )
    }

    private func applyRemoteClipboardResult(_ result: RemoteClipboardController.Result) {
        if var currentState = state {
            if result.executed {
                currentState.actionsExecuted += 1
                currentState.lastActionAt = Date()
            } else if result.rejected {
                currentState.actionsRejected += 1
            }
            if let logger = auditLogger {
                currentState.auditChainHeadHashHex = logger.headHashHex
            }
            state = currentState
        }
        if let denyReason = result.denyReason {
            lastDeniedReason = denyReason
        }
        guard let action = result.action else { return }
        let timelineStatus: HermesRealtimeRelayActionLogEntry.Status
        switch result.response.status {
        case .accepted:
            timelineStatus = .completed
        case .denied, .empty, .tooLarge, .unsupported:
            timelineStatus = .rejected
        case .error:
            timelineStatus = .failed
        }
        appendTimeline(
            kind: action.auditKind,
            summary: remoteClipboardTimelineSummary(for: result.response, action: action),
            status: timelineStatus,
            entryIndex: result.auditEntry?.entryIndex,
            parentEntryBlake3: result.auditEntry?.parentEntryHashHex,
            errorCategory: result.response.status == .error ? "dispatch_error" : nil
        )
        emitControlFrame(
            type: .controlActionLogEntry,
            payload: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: state?.sessionId.rawValue,
                actionLogEntry: actionTimeline.last
            )
        )
    }

    private func remoteClipboardTimelineSummary(
        for response: HermesRealtimeRelayClipboardResponse,
        action: ComputerUseAction
    ) -> String {
        switch response.status {
        case .accepted:
            switch response.action {
            case .pasteToMac: return "Pasted phone clipboard text into Mac"
            case .grabFromMac: return "Copied Mac clipboard text to phone"
            }
        case .empty:
            return "Clipboard empty"
        case .tooLarge:
            return "Clipboard too large"
        case .denied:
            return response.detail ?? "Mac denied clipboard"
        case .unsupported:
            return "Unsupported clipboard content"
        case .error:
            return response.detail ?? action.executableSummary(forApproval: macDispatcher.currentScopeContext())
        }
    }

    private func phoneControlAttestationRequirement() async -> PhoneControlAttestationRequirement {
        let strict = SettingsManager.shared.computerUsePhoneControlAttestationRequired
        return await MacAppCheckAttestationReader.attestationRequirement(strictMode: strict)
    }

    private func controlDeniedReason(for denyReason: String) -> HermesRealtimeRelayControlDenied.Reason {
        switch ComputerUseDenyReason(rawValue: denyReason) {
        case .entitlement:
            return .entitlement
        case .sessionLimit:
            return .sessionLimit
        case .dailyLimit:
            return .dailyLimit
        case .softCap:
            return .softCap
        case .hardCap:
            return .hardCap
        case .scopeDenied, .scopeNotMatched:
            return .scope
        case .denyRegion:
            return .denyRegion
        case .killSwitch:
            return .killSwitch
        case .signatureFailure:
            return .signatureFailure
        case .counterReplay:
            return .counterReplay
        case .staleTimestamp:
            return .staleTimestamp
        case .dailySpendCeiling,
             .concurrentSession,
             .accessibilityRevoked,
             .userRejected,
             .auditFailure,
             .clipboardConsentRequired,
             nil:
            return .unknown
        }
    }

    private func invocationFromPhoneAction(
        _ action: ComputerUseAction,
        sessionId: ComputerUseSessionID
    ) -> BurnBarToolInvocation {
        let tool: BurnBarToolKind
        let args: BurnBarJSONValue
        switch action {
        case .macInput(let mac):
            switch mac.kind {
            case .click: tool = .macInputClick
            case .type: tool = .macInputType
            case .key: tool = .macInputKey
            case .shortcut: tool = .macInputShortcut
            case .dragDrop: tool = .macInputDragDrop
            case .scroll: tool = .macInputScroll
            case .pointerMove: tool = .macInputPointerMove
            }
            args = macInputArguments(mac)
        default:
            tool = .macInspectAccessibility
            args = .object([:])
        }
        return BurnBarToolInvocation(
            callID: "phone-\(UUID().uuidString)",
            runID: BurnBarRunID(rawValue: "phone-control-\(sessionId.rawValue)"),
            tool: tool,
            arguments: args,
            requestedBy: BurnBarClientID(rawValue: "phone-control"),
            requestedAt: Date()
        )
    }

    private func decodeAction(invocation: BurnBarToolInvocation) throws -> ComputerUseAction {
        switch invocation.tool {
        case .browserClick:
            let args = try invocation.arguments.decode(BurnBarBrowserActionArguments.self)
            return .browser(BrowserAction(
                kind: .click,
                selector: args.selector,
                positionX: args.positionX,
                positionY: args.positionY,
                timeoutMillis: args.timeoutMillis ?? 10_000
            ))
        case .browserFill:
            let args = try invocation.arguments.decode(BurnBarBrowserActionArguments.self)
            return .browser(BrowserAction(
                kind: .fill,
                selector: args.selector,
                text: args.text,
                timeoutMillis: args.timeoutMillis ?? 10_000
            ))
        case .browserGoto:
            let args = try invocation.arguments.decode(BurnBarBrowserActionArguments.self)
            return .browser(BrowserAction(kind: .goto, url: args.url, timeoutMillis: args.timeoutMillis ?? 10_000))
        case .browserKey:
            let args = try invocation.arguments.decode(BurnBarBrowserActionArguments.self)
            return .browser(BrowserAction(kind: .key, key: args.key))
        case .browserSelect:
            let args = try invocation.arguments.decode(BurnBarBrowserActionArguments.self)
            return .browser(BrowserAction(kind: .select, selector: args.selector, value: args.value))
        case .browserScreenshot:
            return .browser(BrowserAction(kind: .screenshot))
        case .browserExtract:
            let args = try invocation.arguments.decode(BurnBarBrowserActionArguments.self)
            return .browser(BrowserAction(kind: .extract, selector: args.selector))
        case .macInputClick:
            return .macInput(try decodeMacInput(invocation: invocation, kind: .click))
        case .macInputType:
            return .macInput(try decodeMacInput(invocation: invocation, kind: .type))
        case .macInputKey:
            return .macInput(try decodeMacInput(invocation: invocation, kind: .key))
        case .macInputShortcut:
            return .macInput(try decodeMacInput(invocation: invocation, kind: .shortcut))
        case .macInputDragDrop:
            return .macInput(try decodeMacInput(invocation: invocation, kind: .dragDrop))
        case .macInputScroll:
            return .macInput(try decodeMacInput(invocation: invocation, kind: .scroll))
        case .macInputPointerMove:
            return .macInput(try decodeMacInput(invocation: invocation, kind: .pointerMove))
        case .macInspectAccessibility:
            guard case let .object(arguments) = invocation.arguments else {
                return .macInspect(MacInspectAction(kind: .accessibility))
            }
            return .macInspect(MacInspectAction(
                kind: .accessibility,
                displayX: arguments.intValue(forKey: "displayX"),
                displayY: arguments.intValue(forKey: "displayY")
            ))
        default:
            throw CoordinatorError.noActiveSession
        }
    }

    private func decodeMacInput(
        invocation: BurnBarToolInvocation,
        kind: MacInputAction.Kind
    ) throws -> MacInputAction {
        guard case let .object(arguments) = invocation.arguments else {
            return MacInputAction(kind: kind)
        }
        return MacInputAction(
            kind: kind,
            displayX: arguments.intValue(forKey: "displayX"),
            displayY: arguments.intValue(forKey: "displayY"),
            dragEndX: arguments.intValue(forKey: "dragEndX"),
            dragEndY: arguments.intValue(forKey: "dragEndY"),
            deltaX: arguments.intValue(forKey: "deltaX"),
            deltaY: arguments.intValue(forKey: "deltaY"),
            mouseButton: arguments.intValue(forKey: "mouseButton") ?? 0,
            text: arguments.stringValue(forKey: "text"),
            key: arguments.stringValue(forKey: "key"),
            modifiers: arguments.stringArrayValue(forKey: "modifiers")
        )
    }

    private func scopeContext(for action: ComputerUseAction) -> ComputerUseScopeContext {
        switch action {
        case .browser(let browser):
            if let url = browser.url { return ComputerUseScopeContext(url: url) }
            return macDispatcher.currentScopeContext()
        case .macInput, .macInspect, .phoneIntent, .remoteClipboard:
            return macDispatcher.currentScopeContext()
        }
    }

    private func accessibilityDeny(for action: ComputerUseAction) -> ComputerUseAccessibilityDenyReason? {
        guard case .macInput(let input) = action else { return nil }
        return macDispatcher.accessibilityDenyReason(at: input)
    }

    /// Sentinel `denyReason` marking a pre-dispatch reservation entry; the
    /// paired post-dispatch completion entry carries the real outcome.
    static let auditReservationSentinel = "audit_reserved_pending"

    /// Reserve a pending audit entry on the chain BEFORE the action runs.
    /// Throws if the chain append fails so the caller can fail closed and
    /// abort dispatch. The reservation is marked with the
    /// `audit_reserved_pending` sentinel denyReason; the post-dispatch
    /// completion entry carries the real outcome.
    private func reserveAuditEntry(
        logger: ComputerUseAuditLogger,
        action: ComputerUseAction,
        approvalId: String?,
        approvedBy: ComputerUseAuditEntry.ApprovedBy,
        scopeRuleId: String?,
        scopeContext: ComputerUseScopeContext?,
        beforeScreenshotHashHex: String?
    ) throws -> ComputerUseAuditEntry {
        let entry = try logger.makeEntry(
            for: action,
            approvalId: approvalId,
            approvedBy: approvedBy,
            scopeRuleId: scopeRuleId,
            denyReason: Self.auditReservationSentinel,
            beforeScreenshotHashHex: beforeScreenshotHashHex,
            macHostNodeId: configuration.macHostNodeId,
            scopeContext: scopeContext
        )
        try logger.append(entry)
        return entry
    }

    private func appendAuditEntry(
        logger: ComputerUseAuditLogger,
        action: ComputerUseAction,
        approvalId: String? = nil,
        approvedBy: ComputerUseAuditEntry.ApprovedBy,
        scopeRuleId: String? = nil,
        denyReason: String? = nil,
        scopeContext: ComputerUseScopeContext? = nil,
        beforeScreenshotHashHex: String? = nil,
        afterScreenshotHashHex: String? = nil
    ) -> ComputerUseAuditEntry? {
        do {
            let entry = try logger.makeEntry(
                for: action,
                approvalId: approvalId,
                approvedBy: approvedBy,
                scopeRuleId: scopeRuleId,
                denyReason: denyReason,
                beforeScreenshotHashHex: beforeScreenshotHashHex,
                afterScreenshotHashHex: afterScreenshotHashHex,
                macHostNodeId: configuration.macHostNodeId,
                scopeContext: scopeContext
            )
            try logger.append(entry)
            return entry
        } catch {
            return nil
        }
    }

    private func captureEvidence(
        label: String,
        sessionId: ComputerUseSessionID,
        logger: ComputerUseAuditLogger
    ) -> MacScreenshotService.Capture? {
        guard let screenshotService else { return nil }
        do {
            let capture = try screenshotService.captureMainDisplay(
                label: label,
                sessionId: sessionId,
                entryIndexHint: logger.nextEntryIndex
            )
            screenshotEvidenceDataByHash[capture.sha256Hex] = capture.pngData
            return capture
        } catch {
            appendTimeline(
                kind: "screenshot.capture",
                summary: "Screenshot capture failed: \(String(describing: error))",
                status: .failed
            )
            return nil
        }
    }

    private func captureData(forHash hash: String?) -> Data? {
        guard let hash else { return nil }
        return screenshotEvidenceDataByHash[hash]
    }

    private func macInputArguments(_ action: MacInputAction) -> BurnBarJSONValue {
        var object: [String: BurnBarJSONValue] = [:]
        if let displayX = action.displayX { object["displayX"] = .number(Double(displayX)) }
        if let displayY = action.displayY { object["displayY"] = .number(Double(displayY)) }
        if let dragEndX = action.dragEndX { object["dragEndX"] = .number(Double(dragEndX)) }
        if let dragEndY = action.dragEndY { object["dragEndY"] = .number(Double(dragEndY)) }
        if let deltaX = action.deltaX { object["deltaX"] = .number(Double(deltaX)) }
        if let deltaY = action.deltaY { object["deltaY"] = .number(Double(deltaY)) }
        object["mouseButton"] = .number(Double(action.mouseButton))
        if let text = action.text { object["text"] = .string(text) }
        if let key = action.key { object["key"] = .string(key) }
        if let modifiers = action.modifiers { object["modifiers"] = .array(modifiers.map { .string($0) }) }
        return .object(object)
    }

    private func scopeRuleIfAllowed(outcome: ComputerUseScopeOutcome) -> String? {
        if case let .allowed(rule) = outcome { return rule.rawValue }
        return nil
    }

    private func scopeRuleIfDenied(outcome: ComputerUseScopeOutcome) -> String? {
        if case let .denied(rule) = outcome { return rule.rawValue }
        return nil
    }

    private func isReadOnlyInspect(action: ComputerUseAction) -> Bool {
        if case .macInspect = action { return true }
        return false
    }

    private func endReason(for source: ComputerUsePanicSource) -> ComputerUseEndReason {
        switch source {
        case .hotkey: return .panicHotkey
        case .phoneGesture: return .panicPhoneGesture
        case .macLock: return .panicMacLock
        case .remoteConfig: return .panicRemoteConfig
        case .accessibilityRevoked: return .panicAccessibilityRevoked
        case .stalled: return .timeout
        // Device/session trust revoked: tear the session down as an
        // authorization loss. The panic source ("revoked") is preserved in
        // the audit chain for forensics.
        case .revoked: return .entitlementLost
        }
    }

    private func appendTimeline(
        for action: ComputerUseAction,
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse,
        auditEntry: ComputerUseAuditEntry?
    ) {
        let status: HermesRealtimeRelayActionLogEntry.Status
        switch response.status {
        case .executed: status = .completed
        case .denied: status = .rejected
        case .awaitingApproval: status = .awaitingApproval
        case .error: status = .failed
        }
        appendTimeline(
            kind: action.auditKind,
            summary: response.denyReason ?? action.executableSummary(forApproval: scopeContext(for: action)),
            status: status,
            entryIndex: response.auditEntryIndex,
            screenshotHashBlake3: auditEntry?.afterScreenshotHashHex ?? auditEntry?.beforeScreenshotHashHex,
            parentEntryBlake3: auditEntry?.parentEntryHashHex,
            errorCategory: response.status == .error ? "dispatch_error" : nil
        )
        emitControlFrame(
            type: .controlActionLogEntry,
            payload: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: response.sessionId,
                actionLogEntry: actionTimeline.last
            )
        )
        _ = invocation
    }

    private func appendTimeline(
        kind: String,
        summary: String,
        status: HermesRealtimeRelayActionLogEntry.Status,
        entryIndex: Int? = nil,
        screenshotHashBlake3: String? = nil,
        parentEntryBlake3: String? = nil,
        errorCategory: String? = nil
    ) {
        let entry = HermesRealtimeRelayActionLogEntry(
            entryIndex: entryIndex ?? actionTimeline.count,
            timestamp: Date(),
            actionKind: kind,
            summary: summary,
            status: status,
            screenshotHashBlake3: screenshotHashBlake3,
            parentEntryBlake3: parentEntryBlake3,
            errorCategory: errorCategory
        )
        actionTimeline.append(entry)
        if actionTimeline.count > 50 {
            actionTimeline.removeFirst(actionTimeline.count - 50)
        }
    }

    private func emitControlFrame(
        type: HermesRealtimeRelayFrameType,
        payload: HermesRealtimeRelayControlPayload
    ) {
        guard let latestReplySender,
              let latestControlUID,
              let latestControlConnectionID else { return }
        let frame = HermesRealtimeRelayFrame(
            type: type,
            uid: latestControlUID,
            connectionId: latestControlConnectionID,
            control: payload
        )
        Task {
            try? await latestReplySender(frame)
        }
    }

    private func sendControlFrame(
        type: HermesRealtimeRelayFrameType,
        payload: HermesRealtimeRelayControlPayload
    ) async throws {
        guard let latestReplySender,
              let latestControlUID,
              let latestControlConnectionID else {
            throw CoordinatorError.missingControlReplySender
        }
        let frame = HermesRealtimeRelayFrame(
            type: type,
            uid: latestControlUID,
            connectionId: latestControlConnectionID,
            control: payload
        )
        try await latestReplySender(frame)
    }

    func emitFocusContext(_ context: HermesRealtimeRelayFocusContext) {
        guard let latestReplySender,
              let latestControlUID,
              let latestControlConnectionID else { return }
        let frame = HermesRealtimeRelayFrame(
            type: .mediaStreamFrame,
            uid: latestControlUID,
            connectionId: latestControlConnectionID,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.screenVideo.rawValue,
                focusContext: context
            )
        )
        Task {
            try? await latestReplySender(frame)
        }
    }

    private func cancelPendingApprovals(
        decision: HermesRealtimeRelayApprovalResponse.Decision,
        note: String
    ) {
        for (approvalId, continuation) in approvalContinuations {
            continuation.resume(returning: HermesRealtimeRelayApprovalResponse(
                approvalId: approvalId,
                decision: decision,
                respondedBy: "mac",
                respondedAt: Date(),
                note: note
            ))
        }
        approvalContinuations.removeAll()
        approvalContexts.removeAll()
    }
}

private struct ApprovalDecision {
    var decision: HermesRealtimeRelayApprovalResponse.Decision = .approve
    var approvedBy: ComputerUseAuditEntry.ApprovedBy
    var approvalId: String?
}

private extension Dictionary where Key == String, Value == BurnBarJSONValue {
    func stringArrayValue(forKey key: String) -> [String]? {
        guard case let .array(values)? = self[key] else { return nil }
        return values.compactMap { value in
            if case let .string(string) = value { return string }
            return nil
        }
    }
}
#endif
