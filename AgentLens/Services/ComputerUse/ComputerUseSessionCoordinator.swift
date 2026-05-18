#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
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
    public struct Configuration: Sendable {
        public var userId: String
        public var macHostNodeId: String?
        public var entitlement: ComputerUseEntitlementSnapshot
        public var budgetEnvelope: ComputerUseBudgetEnvelope
        public var quotaUsage: ComputerUseQuotaUsage
        public var auditBaseDirectory: URL
        public var macAppVersion: String
        public var killSwitch: Bool

        public init(
            userId: String,
            macHostNodeId: String? = nil,
            entitlement: ComputerUseEntitlementSnapshot,
            budgetEnvelope: ComputerUseBudgetEnvelope = .initialNormal,
            quotaUsage: ComputerUseQuotaUsage,
            auditBaseDirectory: URL,
            macAppVersion: String,
            killSwitch: Bool = false
        ) {
            self.userId = userId
            self.macHostNodeId = macHostNodeId
            self.entitlement = entitlement
            self.budgetEnvelope = budgetEnvelope
            self.quotaUsage = quotaUsage
            self.auditBaseDirectory = auditBaseDirectory
            self.macAppVersion = macAppVersion
            self.killSwitch = killSwitch
        }
    }

    public enum CoordinatorError: Error, Sendable, Equatable {
        case sessionAlreadyActive
        case noActiveSession
        case invalidMode(String)
        case invalidTrustMode(String)
        case missingEntitlementProduct
        case missingBrowserDispatcher
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
    private let scopeMatcher: ComputerUseScopeMatcher
    private let scopeRulesProvider: @MainActor () -> [ComputerUseScopeRule]
    private let approvalPresenter: ApprovalPresenter
    private let browserDispatcher: BrowserDispatcher?
    private let displayBoundsProvider: PhoneControlReceiver.DisplayBoundsProvider
    private let screenshotService: MacScreenshotService?
    private let authorityProvider: PhoneControlAuthorityPublicKeyProviding

    private var phoneValidator = PhoneControlAuthorityValidator()
    private var phoneReceiver: PhoneControlReceiver?
    private var latestReplySender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)?
    private var activeSessionId: ComputerUseSessionID?
    private var auditLogger: ComputerUseAuditLogger?
    private var approvalContinuations: [String: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Never>] = [:]
    private var screenshotEvidenceDataByHash: [String: Data] = [:]
    private var latestControlUID: String?
    private var latestControlConnectionID: String?
    private nonisolated(unsafe) var remoteConfigObserver: NSObjectProtocol?

    public init(
        configuration: Configuration,
        gate: ComputerUseCapabilityGate = DefaultComputerUseCapabilityGate(),
        macDispatcher: MacActionDispatcher = MacActionDispatcher(),
        inputController: MacInputController = MacInputController(),
        scopeMatcher: ComputerUseScopeMatcher = ComputerUseScopeMatcher(),
        scopeRulesProvider: @escaping @MainActor () -> [ComputerUseScopeRule] = { [] },
        browserDispatcher: BrowserDispatcher? = nil,
        screenshotService: MacScreenshotService? = nil,
        authorityProvider: PhoneControlAuthorityPublicKeyProviding = FirestorePhoneControlAuthorityProvider.shared,
        displayBoundsProvider: @escaping PhoneControlReceiver.DisplayBoundsProvider = {
            let totalHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return NSScreen.screens.map { screen in
                let frame = screen.frame
                return MacInputCore.DisplayBounds(
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
    }

    public func updateBudgetEnvelope(_ envelope: ComputerUseBudgetEnvelope) {
        configuration.budgetEnvelope = envelope
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

    public func registerPhonePeer(nodeId: String, publicKey: Curve25519.Signing.PublicKey) {
        phoneValidator.registerPeer(nodeId: nodeId, publicKey: publicKey)
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

        phoneReceiver = PhoneControlReceiver(
            sessionId: sessionId,
            validator: phoneValidator,
            displayBoundsProvider: displayBoundsProvider,
            dispatchHandler: { [weak self] action, sessionId in
                await self?.handlePhoneAction(action, sessionId: sessionId)
            },
            denyFrameSink: { [weak self] frame in
                guard let self else { return }
                try await self.latestReplySender?(frame)
            }
        )

        appendTimeline(
            kind: "session.start",
            summary: "Computer Use session started",
            status: .planned
        )

        return ComputerUseSessionStartResponse(
            sessionId: sessionId.rawValue,
            manifestHashHex: logger.headHashHex,
            startedAt: manifest.startedAt,
            entitlementProductId: productId,
            actionCap: request.actionCap
        )
    }

    public func endSession(reason: ComputerUseEndReason = .completed) async {
        guard activeSessionId != nil else { return }
        cancelPendingApprovals(decision: .reject, note: "session ended")
        activeSessionId = nil
        phoneReceiver = nil
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
        }
        activeSessionId = nil
        phoneReceiver = nil
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

    public func setTrustMode(_ mode: ComputerUseTrustMode) {
        guard var current = state else { return }
        current.liveTrustMode = mode
        state = current
    }

    public func submitApprovalResponse(_ response: HermesRealtimeRelayApprovalResponse) {
        guard let continuation = approvalContinuations.removeValue(forKey: response.approvalId) else {
            return
        }
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
            originatedFromPhone: invocation.requestedBy.rawValue == "phone-control"
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
            if approvedByCandidate == .trustedScope || isReadOnlyInspect(action: action) {
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
                )
                currentState.actionsExecuted += 1
                currentState.lastActionAt = Date()
                currentState.auditChainHeadHashHex = logger.headHashHex
                state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .executed,
                    approvalId: approval.approvalId,
                    auditEntryIndex: entry?.entryIndex,
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
                )
                currentState.actionsRejected += 1
                currentState.auditChainHeadHashHex = logger.headHashHex
                state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .error,
                    approvalId: approval.approvalId,
                    denyReason: String(describing: error),
                    auditEntryIndex: entry?.entryIndex,
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
        emitControlFrame(
            type: .controlApprovalRequest,
            payload: HermesRealtimeRelayControlPayload(
                streamClass: "control.approval",
                sessionId: request.sessionId,
                approvalRequest: request
            )
        )

        let response = await withCheckedContinuation { continuation in
            approvalContinuations[request.approvalId] = continuation
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
            output = try macDispatcher.dispatch(input)
        case .macInspect(let inspect):
            output = try macDispatcher.inspect(inspect)
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

    private func handleControlFrame(
        _ frame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        latestReplySender = replySender
        latestControlUID = frame.uid
        latestControlConnectionID = frame.connectionId
        switch frame.type {
        case .controlClassify:
            guard let peerNodeId = frame.control?.authorityPeerNodeId else { return }
            do {
                let publicKey = try await authorityProvider.fetchPublicKey(
                    uid: frame.uid,
                    connectionId: frame.connectionId,
                    peerNodeId: peerNodeId
                )
                registerPhonePeer(nodeId: peerNodeId, publicKey: publicKey)
            } catch {
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
            await phoneReceiver?.ingest(frame)
        case .controlApprovalResponse:
            if let response = frame.control?.approvalResponse {
                submitApprovalResponse(response)
            }
        default:
            break
        }
    }

    private func handlePhoneAction(_ action: ComputerUseAction, sessionId: ComputerUseSessionID) async {
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
            await panicHalt(source: .phoneGesture)
            return
        }
        let invocation = invocationFromPhoneAction(action, sessionId: sessionId)
        _ = await invoke(invocation)
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
        case .macInput, .macInspect, .phoneIntent:
            return macDispatcher.currentScopeContext()
        }
    }

    private func accessibilityDeny(for action: ComputerUseAction) -> ComputerUseAccessibilityDenyReason? {
        guard case .macInput(let input) = action else { return nil }
        return macDispatcher.accessibilityDenyReason(at: input)
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
