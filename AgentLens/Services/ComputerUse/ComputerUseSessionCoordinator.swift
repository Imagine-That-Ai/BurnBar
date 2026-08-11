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
public final class ComputerUseSessionCoordinator: ObservableObject {
    nonisolated static let log = Logger(subsystem: "com.openburnbar.app", category: "ComputerUse")

    static let phoneControlActionCap = 10_000

    static func debugTrace(_ message: String) {
        NSLog("OpenBurnBarMercury \(message)")
    }

    public struct Configuration: Sendable {
        public var userId: String
        /// Resolves the signed-in identity at enqueue time. The coordinator is
        /// created before Firebase login can complete, so a launch-time
        /// fallback must not become the permanent metering UID.
        public var userIdProvider: (@MainActor @Sendable () -> String?)?
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
            userIdProvider: (@MainActor @Sendable () -> String?)? = nil,
            macHostNodeId: String? = nil,
            entitlement: ComputerUseEntitlementSnapshot,
            budgetEnvelope: ComputerUseBudgetEnvelope = .initialNormal,
            quotaUsage: ComputerUseQuotaUsage,
            auditBaseDirectory: URL,
            macAppVersion: String,
            killSwitch: Bool = false,
            phoneControlAttestationRequired: Bool = false,
            phoneControlRespectsDenyRegions: Bool = true, // F3: secure default — phone respects AX deny-regions
            clipboardConsentGranted: Bool = false
        ) {
            self.userId = userId
            self.userIdProvider = userIdProvider
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

        @MainActor var currentUserId: String {
            userIdProvider?() ?? userId
        }
    }

    public enum CoordinatorError: Error, Sendable, Equatable {
        case sessionAlreadyActive
        case noActiveSession
        case invalidMode(String)
        case invalidTrustMode(String)
        case missingEntitlementProduct
        case missingBrowserDispatcher
        case unsupportedExecutionSurface(String)
        case missingControlReplySender
        case dailySessionLimit
        case quotaAuthorityUnavailable
        case reservationReplay
    }

    public typealias ApprovalPresenter = @MainActor (
        _ request: HermesRealtimeRelayApprovalRequest,
        _ beforeScreenshotPNG: Data?
    ) async -> HermesRealtimeRelayApprovalResponse

    public typealias BrowserDispatcher = @MainActor (
        _ action: BrowserAction
    ) async throws -> BurnBarJSONValue

    @Published public internal(set) var state: ComputerUseSessionState?
    @Published public internal(set) var pendingApproval: HermesRealtimeRelayApprovalRequest?
    @Published public internal(set) var pendingApprovalScreenshotPNG: Data?
    @Published public internal(set) var actionTimeline: [HermesRealtimeRelayActionLogEntry] = []
    @Published public internal(set) var lastDeniedReason: ComputerUseDenyReason?
    var controlDispatcher: ControlFrameDispatcher {
        { @Sendable [weak self] frame, replySender in
            await self?.handleControlFrame(frame, replySender: replySender)
        }
    }

    var configuration: Configuration

    let gate: ComputerUseCapabilityGate

    let quotaLedger: ComputerUseLocalQuotaLedger

    let cloudMeteringRecorder: (any ComputerUseCloudMeteringRecording)?

    let macDispatcher: MacActionDispatcher

    let inputController: MacInputController

    let remoteClipboardController: RemoteClipboardController

    let remoteUnlockCredentialController: RemoteUnlockCredentialController

    let scopeMatcher: ComputerUseScopeMatcher

    let scopeRulesProvider: @MainActor () -> [ComputerUseScopeRule]

    let approvalPresenter: ApprovalPresenter

    let browserDispatcher: BrowserDispatcher?

    let displayBoundsProvider: PhoneControlReceiver.DisplayBoundsProvider

    let screenshotService: MacScreenshotService?

    let authorityProvider: PhoneControlAuthorityPublicKeyProviding

    var focusFollowController: AgentFocusFollowController?

    var focusFollowMode: AgentFocusFollowMode = .smart

    var phoneValidator = PhoneControlAuthorityValidator()

    var phoneReceiver: PhoneControlReceiver?

    /// F10 — per-connection control-seal sessions established at classify time
    /// (controller peerNodeId + derived AES-GCM key). Cleared with the session.
    var controlSealSessions: [String: (peerNodeId: String, key: SymmetricKey)] = [:]

    /// F10 test seams — production resolves the Mac relay private key from the
    /// keychain-backed store and the pinned sender key from the same Firestore
    /// trust resolver the chat opener uses.
    var controlSealRecipientPrivateKeyProvider: (@Sendable () throws -> HermesRelayPrivateKey)?

    var controlSealPinnedSenderKeyProvider: (@Sendable (_ uid: String, _ connectionId: String, _ envelope: HermesRealtimeRelayControlSealKeyEnvelope) async throws -> String)?

    var phoneControlAuthorizedPeerNodeProvider: (@MainActor @Sendable () -> String?)?

    var phoneControlKeyboardTargetWindowProvider: (@MainActor @Sendable () -> CGWindowID?)?

    var phoneControlKeyboardTargetFocuser: (@MainActor @Sendable (CGWindowID) throws -> Void)?

    var remoteUnlockResultHandler: (@MainActor @Sendable (HermesRealtimeRelayRemoteUnlockResult) async -> Void)?

    weak var chatController: ChatSessionController?
    var agentContextReceiver: AgentContextTargetReceiver?

    var systemPermissionReceiver: SystemPermissionReceiver?

    var latestReplySender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)?

    var activeSessionId: ComputerUseSessionID?

    var auditLogger: ComputerUseAuditLogger?

    var approvalContinuations: [String: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Never>] = [:]

    var approvalContexts: [String: ApprovalContext] = [:]

    var screenshotEvidenceDataByHash: [String: Data] = [:]

    var latestControlUID: String?

    var latestControlConnectionID: String?

    var phoneFirstActionConfirmedSessionKeys: Set<String> = []

    #if DEBUG
    var didStartE2EApprovalProbe = false

    #endif
    nonisolated(unsafe) var remoteConfigObserver: NSObjectProtocol?
    nonisolated(unsafe) var phoneControlAttestationObserver: NSObjectProtocol?

    struct ApprovalContext: Sendable {
        let uid: String?
        let connectionID: String?
        let sessionID: String
        let requestedAt: Date
        let requestHashBlake3: String
    }

    enum ApprovalResponseSource: Sendable {
        case localPresenter
        case remote(uid: String, connectionID: String, sessionID: String?)
    }
    func recordE2EProofEvent(_ fields: [String: String]) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF"] == "1" else { return }
        var record = fields
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        record["timestampMillis"] = String(Int(Date().timeIntervalSince1970 * 1000))
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), // try?-ok(debug proof encode, guarded)
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
        if let handle = try? FileHandle(forWritingTo: url) { // try?-ok(debug proof sidecar open)
            _ = try? handle.seekToEnd() // try?-ok(debug proof sidecar seek)
            try? handle.write(contentsOf: lineData) // try?-ok(debug proof sidecar write)
            try? handle.close() // try?-ok(handle teardown)
        }
        #endif
    }

    public init(
        configuration: Configuration,
        gate: ComputerUseCapabilityGate = DefaultComputerUseCapabilityGate(),
        quotaLedger: ComputerUseLocalQuotaLedger? = nil,
        cloudMeteringRecorder: (any ComputerUseCloudMeteringRecording)? = nil,
        macDispatcher: MacActionDispatcher = MacActionDispatcher(),
        inputController: MacInputController = MacInputController(),
        remoteClipboardController: RemoteClipboardController? = nil,
        scopeMatcher: ComputerUseScopeMatcher = ComputerUseScopeMatcher(),
        scopeRulesProvider: @escaping @MainActor () -> [ComputerUseScopeRule] = { [] },
        browserDispatcher: BrowserDispatcher? = nil,
        screenshotService: MacScreenshotService? = nil,
        authorityProvider: PhoneControlAuthorityPublicKeyProviding = FirestorePhoneControlAuthorityProvider.shared,
        phoneValidator: PhoneControlAuthorityValidator = PhoneControlAuthorityValidator(),
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
        self.quotaLedger = quotaLedger ?? ComputerUseLocalQuotaLedger(
            directory: configuration.auditBaseDirectory
                .appendingPathComponent(".quota-ledger", isDirectory: true)
        )
        self.cloudMeteringRecorder = cloudMeteringRecorder
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
        self.phoneValidator = phoneValidator
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
        self.phoneControlAttestationObserver = NotificationCenter.default.addObserver(
            forName: .phoneControlAttestationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let required = notification.userInfo?[
                ComputerUseRemoteConfigNotificationUserInfo.phoneControlAttestationRequired
            ] as? Bool else { return }
            Task { @MainActor in
                self?.updatePhoneControlAttestationRequired(required)
            }
        }
    }

    deinit {
        if let remoteConfigObserver {
            NotificationCenter.default.removeObserver(remoteConfigObserver)
        }
        if let phoneControlAttestationObserver {
            NotificationCenter.default.removeObserver(phoneControlAttestationObserver)
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
        do {
            configuration.quotaUsage = try quotaLedger.reconcile(usage)
        } catch {
            Self.log.error(
                "computer_use_quota_reconcile_failed reason=\(String(describing: error), privacy: .public)"
            )
        }
    }

    public func updateKillSwitch(_ enabled: Bool) {
        configuration.killSwitch = enabled
        if enabled {
            Task { await panicHalt(source: .remoteConfig) }
        }
    }

    public func updatePhoneControlAttestationRequired(_ required: Bool) {
        configuration.phoneControlAttestationRequired = required
    }

    @discardableResult
    public func registerPhonePeer(
        nodeId: String,
        publicKey: Curve25519.Signing.PublicKey,
        requiredAttestationHashBlake3: String? = nil
    ) -> Bool {
        registerPhonePeer(
            nodeId: nodeId,
            verifyingKey: .ed25519(publicKey),
            requiredAttestationHashBlake3: requiredAttestationHashBlake3
        )
    }

    @discardableResult
    public func registerPhonePeer(
        nodeId: String,
        verifyingKey: PhoneControlVerifyingKey,
        requiredAttestationHashBlake3: String? = nil
    ) -> Bool {
        // F1: scope the controller-key pin to this account so the Mac refuses a
        // relay/Firestore-swapped signing key for an already-paired controller.
        phoneValidator.registerPeer(
            nodeId: nodeId,
            verifyingKey: verifyingKey,
            uid: configuration.userId,
            requiredAttestationHashBlake3: requiredAttestationHashBlake3
        )
    }

    func registerPhonePeerForControlClassify(
        nodeId: String,
        publicKey: PhoneControlVerifyingKey,
        requiredAttestationHashBlake3: String?,
        connectionID: String
    ) async -> (admitted: Bool, denialDetail: String?) {
        switch phoneValidator.registerPeerDetailed(
            nodeId: nodeId,
            verifyingKey: publicKey,
            uid: configuration.userId,
            requiredAttestationHashBlake3: requiredAttestationHashBlake3
        ) {
        case .admitted:
            return (true, nil)
        case .pendingConfirmation(let safetyCode):
            recordE2EProofEvent([
                "event": "mac_control_classify_pending_controller_confirmation",
                "peerNodeId": nodeId,
                "connectionId": connectionID,
                "safetyCode": safetyCode ?? ""
            ])
            let codeLine = safetyCode.map { " Safety code: \($0)." } ?? ""
            let approval = await requestMacOnlyApproval(
                toolKind: "phone_control_pairing",
                title: "Approve phone controller",
                message: "A remote device wants to control this Mac.\(codeLine)",
                actionSummary: "Approve phone controller \(nodeId)"
            )
            guard approval.decision == .approve,
                  phoneValidator.confirmPeerPin(nodeId: nodeId, verifyingKey: publicKey, uid: configuration.userId)
            else {
                return (false, "controller_confirmation_rejected")
            }
            switch phoneValidator.registerPeerDetailed(
                nodeId: nodeId,
                verifyingKey: publicKey,
                uid: configuration.userId,
                requiredAttestationHashBlake3: requiredAttestationHashBlake3
            ) {
            case .admitted:
                return (true, nil)
            case .pendingConfirmation:
                return (false, "controller_confirmation_required")
            case .refused(let refusal):
                return (false, Self.controllerRegistrationDenialDetail(for: refusal))
            }
        case .refused(let refusal):
            return (false, Self.controllerRegistrationDenialDetail(for: refusal))
        }
    }

    func phoneFirstActionConfirmationKey(peerNodeId: String? = nil) -> String? {
        guard let sessionId = activeSessionId?.rawValue else { return nil }
        let peer = peerNodeId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? state?.manifest.phoneViewerNodeId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? phoneControlAuthorizedPeerNodeProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "unknown-peer"
        return "\(sessionId)|\(peer)"
    }

    func isPhoneFirstActionConfirmed(peerNodeId: String? = nil) -> Bool {
        guard let key = phoneFirstActionConfirmationKey(peerNodeId: peerNodeId) else { return false }
        return phoneFirstActionConfirmedSessionKeys.contains(key)
    }

    func markPhoneFirstActionConfirmed(peerNodeId: String? = nil) {
        guard let key = phoneFirstActionConfirmationKey(peerNodeId: peerNodeId) else { return }
        phoneFirstActionConfirmedSessionKeys.insert(key)
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

        let quotaReservation: ComputerUseLocalQuotaLedger.Reservation
        do {
            quotaReservation = try quotaLedger.reserveSession(
                idempotencyKey: sessionId.rawValue,
                authoritativeUsage: configuration.quotaUsage,
                maximumSessions: configuration.budgetEnvelope.activeSessionsPerDay,
                startedAt: manifest.startedAt
            )
        } catch ComputerUseLocalQuotaLedger.LedgerError.quotaExceeded {
            throw CoordinatorError.dailySessionLimit
        } catch {
            throw CoordinatorError.quotaAuthorityUnavailable
        }
        guard quotaReservation.inserted else { throw CoordinatorError.reservationReplay }
        configuration.quotaUsage = quotaReservation.usage

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
        phoneReceiverInstance.attestationRequirementProvider = { [weak self] in
            guard let self else { return .none }
            return await self.phoneControlAttestationRequirement()
        }
        phoneReceiver = phoneReceiverInstance

        agentContextReceiver = AgentContextTargetReceiver(
            sessionId: sessionId,
            validator: phoneValidator,
            chatControllerProvider: { [weak self] in self?.chatController },
            displayBoundsProvider: displayBoundsProvider,
            authorizedPeerNodeProvider: { [weak self] in
                guard let self else { return nil }
                return self.phoneControlAuthorizedPeerNodeProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? self.state?.manifest.phoneViewerNodeId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            },
            replyFrameSink: { [weak self] frame in
                try await self?.latestReplySender?(frame)
            },
            auditLoggerProvider: { [weak self] in self?.auditLogger }
        )

        systemPermissionReceiver = SystemPermissionReceiver(
            sessionId: sessionId,
            validator: phoneValidator,
            monitor: .shared,
            authorizedPeerNodeProvider: { [weak self] in
                guard let self else { return nil }
                return self.phoneControlAuthorizedPeerNodeProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? self.state?.manifest.phoneViewerNodeId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            },
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
                try? await self?.latestReplySender?(frame) // try?-ok(fire-and-forget status frame)
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

        let response = ComputerUseSessionStartResponse(
            sessionId: sessionId.rawValue,
            manifestHashHex: logger.headHashHex,
            startedAt: manifest.startedAt,
            entitlementProductId: productId,
            actionCap: request.actionCap
        )
        enqueueCloudSessionStart(request: request, response: response)
        return response
    }

    private func enqueueCloudSessionStart(
        request: ComputerUseSessionStartRequest,
        response: ComputerUseSessionStartResponse
    ) {
        guard let cloudMeteringRecorder else { return }
        let userID = configuration.currentUserId
        let macAppVersion = configuration.macAppVersion
        Task { @MainActor in
            do {
                try await cloudMeteringRecorder.recordSessionStart(
                    userID: userID,
                    request: request,
                    response: response,
                    macAppVersion: macAppVersion
                )
            } catch {
                Self.log.error(
                    "computer_use_session_start_cloud_metering_failed reason=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    static func agentGrantReceipt(
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

    static func agentGrantDenialReason(
        for error: PhoneControlAuthorityValidator.ValidationError
    ) -> AgentGrantDenialReason {
        error.agentGrantDenialReason
    }

    static func controllerRegistrationDenialDetail(
        for refusal: PhoneControlAuthorityValidator.RegistrationRefusal
    ) -> String {
        switch refusal {
        case .revokedPeer:
            return "peer_revoked"
        case .pinMismatch:
            return "controller_key_mismatch"
        case .malformedAdvertisedKey:
            return "controller_key_malformed"
        case .keychainError:
            return "controller_pin_unavailable"
        }
    }

    nonisolated static func shouldRetargetPhoneKeyboardAction(_ action: ComputerUseAction) -> Bool {
        guard case .macInput(let input) = action else { return false }
        switch input.kind {
        case .type, .key, .shortcut:
            return true
        case .click, .dragDrop, .scroll, .pointerMove, .pointerClick:
            return false
        }
    }

    /// Sentinel `denyReason` marking a pre-dispatch reservation entry; the
    /// paired post-dispatch completion entry carries the real outcome.
    static let auditReservationSentinel = "audit_reserved_pending"

}

struct ApprovalDecision {
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
#endif
