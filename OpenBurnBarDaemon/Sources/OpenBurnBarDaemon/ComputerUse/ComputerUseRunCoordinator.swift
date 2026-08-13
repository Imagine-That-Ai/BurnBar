import Foundation
import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
import OpenBurnBarKernel

/// Routes a `BurnBarToolInvocation` whose `tool` is a Computer Use
/// kind through the in-daemon dispatch flow:
///   1. Validate session exists and is alive.
///   2. Decode arguments → typed `ComputerUseAction`.
///   3. Run capability gate (entitlement, scope, deny, budget).
///   4. If `.allowed`, dispatch directly. If `.allowed` but trust mode
///      is `.manual` or `.step` with a fresh action class, raise an
///      approval request and wait for resolution.
///   5. On success, append an audit entry; on rejection, append a
///      rejection entry.
///   6. Return a `ComputerUseInvokeResponse` to the caller.
///
/// Pure dispatch — no AppKit, no AVFoundation. The Playwright driver
/// lives in this module too; Mac System dispatch lives in the
/// AgentLens module (which imports CGEvent).
public actor ComputerUseRunCoordinator {
    public enum DispatchError: Error, Sendable, Equatable {
        case unknownSession
        case duplicateSession
        case sessionEnded
        case missingDriver
        case unsupportedTool(String)
        case invalidArguments(String)
        case approvalTimeout
        case gateDenied(ComputerUseDenyReason)
    }

    /// Closure the run coordinator invokes to surface an approval
    /// request to the Mac UI + phone overlay. The Mac UI's responder
    /// closes the future with the user's decision.
    public typealias ApprovalIssuer = @Sendable (
        _ request: HermesRealtimeRelayApprovalRequest
    ) async throws -> HermesRealtimeRelayApprovalResponse

    /// Closure injected by the Mac app to dispatch a `mac.input.*`
    /// action — kept abstract here so the daemon module does not need
    /// to import AppKit / CGEvent.
    public typealias MacInputDispatcher = @Sendable (
        _ sessionId: ComputerUseSessionID,
        _ action: MacInputAction
    ) async throws -> BurnBarJSONValue

    public typealias MacInspectDispatcher = @Sendable (
        _ sessionId: ComputerUseSessionID,
        _ action: MacInspectAction
    ) async throws -> BurnBarJSONValue

    public typealias SafariDispatcher = @Sendable (
        _ computerUseSessionId: ComputerUseSessionID,
        _ action: SafariActionDescriptor
    ) async throws -> BurnBarSafariToolResponse

    public typealias SafariPageStateResolver = @Sendable (
        _ safariSessionId: String
    ) async throws -> BurnBarSafariPageState

    public typealias BrowserHostResolver = @Sendable (_ host: String) -> [String]

    public typealias PreDispatchAuthorizer = @Sendable (
        _ sessionId: ComputerUseSessionID,
        _ invocation: BurnBarToolInvocation
    ) async -> Bool

    private struct ActiveSession {
        let generation: UUID
        var state: ComputerUseSessionState
        var logger: ComputerUseAuditLogger
        var driver: OpenBurnBarPlaywrightDriver?
        var stepBurstApproval: StepBurstApproval?
        var isReady = false
        var inFlightInvocationId: UUID?
        var cancelInFlight: (@Sendable () -> Void)?
    }

    private struct StepBurstApproval {
        var actionSignature: String
        var approvedBy: ComputerUseAuditEntry.ApprovedBy
        var approvalId: String
        var remainingActions: Int
        var expiresAt: Date

        func covers(signature: String, now: Date) -> Bool {
            actionSignature == signature && remainingActions > 0 && now <= expiresAt
        }
    }

    private let gate: ComputerUseCapabilityGate
    private let approvalIssuer: ApprovalIssuer
    private let macInputDispatcher: MacInputDispatcher?
    private let macInspectDispatcher: MacInspectDispatcher?
    private let safariDispatcher: SafariDispatcher?
    private let safariPageStateResolver: SafariPageStateResolver?
    private let browserHostResolver: BrowserHostResolver
    private let preDispatchAuthorizer: PreDispatchAuthorizer?
    private let macAppVersion: String
    private let auditBaseDirectory: URL
    private let quotaLedger: ComputerUseLocalQuotaLedger
    private let logger: BurnBarDaemonLogger
    private var sessions: [ComputerUseSessionID: ActiveSession] = [:]
    private var inFlightDispatches: [
        ComputerUseSessionID: [UUID: Task<BurnBarToolResult, Error>]
    ] = [:]

    /// Sentinel `denyReason` marking a pre-dispatch reservation entry; the
    /// paired post-dispatch entry carries the real outcome.
    static let auditReservationSentinel = "audit_reserved_pending"

    public init(
        gate: ComputerUseCapabilityGate = DefaultComputerUseCapabilityGate(),
        approvalIssuer: @escaping ApprovalIssuer,
        macInputDispatcher: MacInputDispatcher? = nil,
        macInspectDispatcher: MacInspectDispatcher? = nil,
        safariDispatcher: SafariDispatcher? = nil,
        safariPageStateResolver: SafariPageStateResolver? = nil,
        browserHostResolver: BrowserHostResolver? = nil,
        preDispatchAuthorizer: PreDispatchAuthorizer? = nil,
        macAppVersion: String,
        auditBaseDirectory: URL,
        quotaLedger: ComputerUseLocalQuotaLedger? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-coordinator")
    ) {
        self.gate = gate
        self.approvalIssuer = approvalIssuer
        self.macInputDispatcher = macInputDispatcher
        self.macInspectDispatcher = macInspectDispatcher
        self.safariDispatcher = safariDispatcher
        self.safariPageStateResolver = safariPageStateResolver
        self.browserHostResolver = browserHostResolver ?? OpenBurnBarBrowserTargetPolicy.systemResolvedAddresses
        self.preDispatchAuthorizer = preDispatchAuthorizer
        self.macAppVersion = macAppVersion
        self.auditBaseDirectory = auditBaseDirectory
        self.quotaLedger = quotaLedger ?? ComputerUseLocalQuotaLedger(
            directory: auditBaseDirectory.appendingPathComponent(".quota-ledger", isDirectory: true)
        )
        self.logger = logger
    }

    // MARK: Session lifecycle

    public func startSession(
        manifest: ComputerUseSessionManifest,
        playwrightDriver: OpenBurnBarPlaywrightDriver? = nil
    ) async throws -> String {
        guard sessions[manifest.sessionId] == nil else {
            throw DispatchError.duplicateSession
        }
        let auditLogger = try ComputerUseAuditLogger(
            sessionId: manifest.sessionId,
            baseDirectory: auditBaseDirectory,
            macAppVersion: macAppVersion
        )
        try auditLogger.beginSession(manifest: manifest)

        let state = ComputerUseSessionState(
            sessionId: manifest.sessionId,
            manifest: manifest,
            liveTrustMode: manifest.trustMode,
            auditChainHeadHashHex: auditLogger.headHashHex
        )
        let generation = UUID()
        let startTask = Task {
            try await playwrightDriver?.start()
        }
        sessions[manifest.sessionId] = ActiveSession(
            generation: generation,
            state: state,
            logger: auditLogger,
            driver: playwrightDriver,
            cancelInFlight: { startTask.cancel() }
        )
        do {
            try await startTask.value
        } catch {
            if sessions[manifest.sessionId]?.generation == generation {
                sessions.removeValue(forKey: manifest.sessionId)
            }
            await playwrightDriver?.stop()
            throw error
        }
        guard var active = sessions[manifest.sessionId], active.generation == generation else {
            await playwrightDriver?.stop()
            throw DispatchError.sessionEnded
        }
        active.isReady = true
        active.cancelInFlight = nil
        sessions[manifest.sessionId] = active
        return auditLogger.headHashHex
    }

    public func endSession(
        sessionId: ComputerUseSessionID,
        reason: ComputerUseEndReason
    ) async -> ComputerUseSessionEndRecord? {
        // Revoke authority before yielding to driver shutdown. Any invocation
        // already suspended in approval or dispatch will fail its generation
        // check when it resumes and cannot restore this session.
        guard var active = sessions.removeValue(forKey: sessionId) else { return nil }
        active.cancelInFlight?()
        active.state.endReason = reason
        let endedAt = Date()
        active.state.endedAt = endedAt
        await active.driver?.stop()
        do {
            _ = try quotaLedger.completeSession(
                idempotencyKey: sessionId.rawValue,
                startedAt: active.state.manifest.startedAt,
                endedAt: endedAt
            )
        } catch {
            logger.warning("computer_use_session_completion_metering_failed", metadata: [
                "session": sessionId.rawValue,
                "error": String(describing: error)
            ])
        }
        return ComputerUseSessionEndRecord(
            sessionId: sessionId.rawValue,
            endedAt: endedAt,
            reason: reason,
            auditHeadHashHex: active.logger.headHashHex
        )
    }

    public func panicHalt(
        sessionId: ComputerUseSessionID,
        source: ComputerUsePanicSource
    ) async -> ComputerUseSessionEndRecord? {
        guard var active = sessions[sessionId] else { return nil }
        active.cancelInFlight?()
        let endReason: ComputerUseEndReason
        switch source {
        case .hotkey: endReason = .panicHotkey
        case .phoneGesture: endReason = .panicPhoneGesture
        case .macLock: endReason = .panicMacLock
        case .remoteConfig: endReason = .panicRemoteConfig
        case .accessibilityRevoked: endReason = .panicAccessibilityRevoked
        case .stalled: endReason = .timeout
        // Device/session trust revoked: torn down as an authorization loss;
        // the panic source ("revoked") is preserved in the audit chain.
        case .revoked: endReason = .entitlementLost
        }
        active.state.endReason = endReason
        active.state.endedAt = Date()
        let panicAction: ComputerUseAction = .macInspect(MacInspectAction(kind: .accessibility))
        do {
            let entry = try active.logger.makeEntry(
                for: panicAction,
                approvedBy: .panic,
                denyReason: source.rawValue
            )
            try active.logger.append(entry)
        } catch {
            logger.warning("panic_halt_log_failed", metadata: [
                "session": sessionId.rawValue,
                "error": String(describing: error)
            ])
        }
        return await endSession(sessionId: sessionId, reason: endReason)
    }

    @discardableResult
    public func panicHaltAll(source: ComputerUsePanicSource) async -> [ComputerUseSessionID] {
        let records = await panicHaltAllWithRecords(source: source)
        return records.map { ComputerUseSessionID(rawValue: $0.sessionId) }
    }

    public func panicHaltAllWithRecords(
        source: ComputerUsePanicSource
    ) async -> [ComputerUseSessionEndRecord] {
        let activeSessionIds = Array(sessions.keys)
        var records: [ComputerUseSessionEndRecord] = []
        for sessionId in activeSessionIds {
            if let record = await panicHalt(sessionId: sessionId, source: source) {
                records.append(record)
            }
        }
        return records
    }

    public func session(_ id: ComputerUseSessionID) -> ComputerUseSessionState? {
        guard let active = sessions[id], active.isReady else { return nil }
        return active.state
    }

    public func hasActiveSession(excluding sessionId: ComputerUseSessionID? = nil) async -> Bool {
        await expireStaleSessions()
        return sessions.keys.contains { $0 != sessionId }
    }

    @discardableResult
    public func expireStaleSessions(now: Date = Date()) async -> [ComputerUseSessionID] {
        let expired = sessions.compactMap { sessionId, active in
            sessionIsExpired(active, now: now) ? sessionId : nil
        }
        for sessionId in expired {
            _ = await endSession(sessionId: sessionId, reason: .timeout)
        }
        return expired
    }

    @discardableResult
    public func endAll(reason: ComputerUseEndReason) async -> [ComputerUseSessionID] {
        let records = await endAllWithRecords(reason: reason)
        return records.map { ComputerUseSessionID(rawValue: $0.sessionId) }
    }

    public func endAllWithRecords(reason: ComputerUseEndReason) async -> [ComputerUseSessionEndRecord] {
        let activeSessionIds = Array(sessions.keys)
        var records: [ComputerUseSessionEndRecord] = []
        for sessionId in activeSessionIds {
            if let record = await endSession(sessionId: sessionId, reason: reason) {
                records.append(record)
            }
        }
        return records
    }

    private func sessionIsExpired(_ active: ActiveSession, now: Date) -> Bool {
        active.state.manifest.sessionTimeoutSeconds > 0
            && now.timeIntervalSince(active.state.manifest.startedAt)
                >= TimeInterval(active.state.manifest.sessionTimeoutSeconds)
    }

    private func isCurrent(sessionId: ComputerUseSessionID, generation: UUID) -> Bool {
        sessions[sessionId]?.generation == generation
    }

    @discardableResult
    private func storeIfCurrent(
        _ active: ActiveSession,
        sessionId: ComputerUseSessionID,
        generation: UUID
    ) -> Bool {
        guard isCurrent(sessionId: sessionId, generation: generation) else { return false }
        sessions[sessionId] = active
        return true
    }

    private func endedResponse(
        sessionId: ComputerUseSessionID,
        invocation: BurnBarToolInvocation,
        reason: String = "session_revoked"
    ) -> ComputerUseInvokeResponse {
        ComputerUseInvokeResponse(
            sessionId: sessionId.rawValue,
            callID: invocation.callID,
            status: .denied,
            denyReason: reason
        )
    }

    public func actionDescriptor(invocation: BurnBarToolInvocation) throws -> ComputerUseAction {
        try decodeAction(invocation: invocation)
    }

    private func removeInFlightDispatch(sessionId: ComputerUseSessionID, dispatchId: UUID) {
        inFlightDispatches[sessionId]?.removeValue(forKey: dispatchId)
        if inFlightDispatches[sessionId]?.isEmpty == true {
            inFlightDispatches.removeValue(forKey: sessionId)
        }
    }

    // MARK: Dispatch

    public func invoke(
        sessionId: ComputerUseSessionID,
        invocation: BurnBarToolInvocation,
        scopeContext: ComputerUseScopeContext,
        scopeOutcome: ComputerUseScopeOutcome,
        accessibilityDeny: ComputerUseAccessibilityDenyReason?,
        capability: ComputerUseCapabilityContext
    ) async -> ComputerUseInvokeResponse {
        guard var active = sessions[sessionId], active.isReady else {
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .error,
                denyReason: "unknown_session"
            )
        }
        if sessionIsExpired(active, now: Date()) {
            _ = await endSession(sessionId: sessionId, reason: .timeout)
            return endedResponse(
                sessionId: sessionId,
                invocation: invocation,
                reason: "session_expired"
            )
        }
        guard active.inFlightInvocationId == nil else {
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .denied,
                denyReason: "session_action_in_flight"
            )
        }
        let generation = active.generation
        let invocationId = UUID()
        active.inFlightInvocationId = invocationId
        sessions[sessionId] = active
        defer {
            releaseInvocation(
                sessionId: sessionId,
                generation: generation,
                invocationId: invocationId
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
                denyReason: String(describing: error)
            )
        }
        var effectiveScopeContext = scopeContext
        var effectiveScopeOutcome = scopeOutcome
        if case .safari(let safariAction) = action {
            do {
                let resolved = try await resolveSafariScope(
                    action: safariAction,
                    active: active
                )
                effectiveScopeContext = resolved.context
                effectiveScopeOutcome = resolved.outcome
            } catch {
                return deniedResponse(
                    sessionId: sessionId.rawValue,
                    invocation: invocation,
                    action: action,
                    scopeContext: scopeContext,
                    scopeRuleId: nil,
                    reason: "safari_page_state_unavailable",
                    generation: generation,
                    invocationId: invocationId
                )
            }
        }

        let effectiveUsage: ComputerUseQuotaUsage
        do {
            effectiveUsage = try quotaLedger.reconcile(capability.usage)
        } catch {
            logger.warning("computer_use_quota_reconcile_failed", metadata: [
                "session": sessionId.rawValue,
                "error": String(describing: error)
            ])
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .denied,
                denyReason: ComputerUseDenyReason.auditFailure.rawValue
            )
        }
        let effectiveCapability = ComputerUseCapabilityContext(
            entitlement: capability.entitlement,
            envelope: capability.envelope,
            usage: effectiveUsage,
            session: capability.session,
            concurrentSessionActive: capability.concurrentSessionActive,
            killSwitch: capability.killSwitch,
            accessibilityTrusted: capability.accessibilityTrusted,
            originatedFromPhone: capability.originatedFromPhone,
            phoneControlRespectsDenyRegions: capability.phoneControlRespectsDenyRegions,
            phoneSessionFirstActionConfirmed: capability.phoneSessionFirstActionConfirmed,
            clipboardConsentGranted: capability.clipboardConsentGranted
        )
        let gateOutcome = gate.check(
            action: action,
            scopeOutcome: effectiveScopeOutcome,
            accessibilityDeny: accessibilityDeny,
            context: refreshedCapabilityContext(effectiveCapability, active: active, sessionId: sessionId)
        )

        switch gateOutcome {
        case .denied(let reason):
            return deniedResponse(
                sessionId: sessionId.rawValue,
                invocation: invocation,
                action: action,
                scopeContext: effectiveScopeContext,
                scopeRuleId: scopeRuleIfDenied(outcome: effectiveScopeOutcome),
                reason: reason.rawValue,
                generation: generation,
                invocationId: invocationId
            )

        case .allowed(let approvedByCandidate):
            // Trusted-scope rules grant automatic approval — no sheet.
            // Manual / Step modes need an explicit approval unless the
            // action is purely read-only (mac.inspect).
            let approvedBy: ComputerUseAuditEntry.ApprovedBy
            var approvalId: String?
            if approvedByCandidate == .trustedScope {
                approvedBy = .trustedScope
            } else if isReadOnlyAction(action: action) {
                approvedBy = .mac
            } else if let burst = consumeStepBurstApproval(
                for: action,
                scopeContext: effectiveScopeContext,
                active: &active,
                now: Date()
            ) {
                approvedBy = burst.approvedBy
                approvalId = burst.approvalId
                sessions[sessionId] = active
            } else {
                // Raise the approval. Wait for resolution.
                let evidence: ApprovalEvidence?
                do {
                    evidence = try await performCancellableOperation(
                        sessionId: sessionId,
                        generation: generation,
                        invocationId: invocationId
                    ) { [self, activeDriver = active.driver] in
                        await approvalEvidence(
                            for: action,
                            computerUseSessionId: sessionId,
                            activeDriver: activeDriver
                        )
                    }
                } catch {
                    return revokedResponse(sessionId: sessionId, invocation: invocation)
                }
                guard let current = currentActiveSession(
                    sessionId: sessionId,
                    generation: generation,
                    invocationId: invocationId
                ) else {
                    return revokedResponse(sessionId: sessionId, invocation: invocation)
                }
                active = current
                guard await authorize(
                    sessionId: sessionId,
                    invocation: invocation,
                    generation: generation,
                    invocationId: invocationId
                ) else {
                    return authorizationDeniedResponse(
                        sessionId: sessionId,
                        invocation: invocation,
                        action: action,
                        scopeContext: effectiveScopeContext,
                        generation: generation,
                        invocationId: invocationId
                    )
                }
                let request = HermesRealtimeRelayApprovalRequest(
                    approvalId: UUID().uuidString,
                    runId: invocation.runID.rawValue,
                    sessionId: sessionId.rawValue,
                    toolKind: invocation.tool.rawValue,
                    title: action.executableSummary(forApproval: effectiveScopeContext),
                    message: action.executableSummary(forApproval: effectiveScopeContext),
                    beforeScreenshotBlake3: evidence?.hashHex,
                    beforeScreenshotPNGBase64: evidence?.pngBase64,
                    beforeScreenshotMimeType: evidence?.mimeType,
                    beforeScreenshotSizeBytes: evidence?.sizeBytes,
                    actionSummary: action.executableSummary(forApproval: effectiveScopeContext),
                    requestedAt: Date(),
                    trustMode: active.state.liveTrustMode.rawValue
                )
                do {
                    let response = try await performCancellableOperation(
                        sessionId: sessionId,
                        generation: generation,
                        invocationId: invocationId
                    ) { [approvalIssuer] in
                        try await approvalIssuer(request)
                    }
                    guard let current = currentActiveSession(
                        sessionId: sessionId,
                        generation: generation,
                        invocationId: invocationId
                    ) else {
                        return revokedResponse(sessionId: sessionId, invocation: invocation)
                    }
                    active = current
                    switch response.decision {
                    case .approve:
                        guard await authorize(
                            sessionId: sessionId,
                            invocation: invocation,
                            generation: generation,
                            invocationId: invocationId
                        ) else {
                            return authorizationDeniedResponse(
                                sessionId: sessionId,
                                invocation: invocation,
                                action: action,
                                scopeContext: effectiveScopeContext,
                                generation: generation,
                                invocationId: invocationId
                            )
                        }
                        guard let authorized = currentActiveSession(
                            sessionId: sessionId,
                            generation: generation,
                            invocationId: invocationId
                        ) else {
                            return revokedResponse(sessionId: sessionId, invocation: invocation)
                        }
                        active = authorized
                        approvedBy = response.authority != nil || response.respondedBy == "phone" ? .phone : .mac
                        approvalId = response.approvalId
                        if shouldOpenStepBurst(from: response, active: active) {
                            active.stepBurstApproval = StepBurstApproval(
                                actionSignature: stepBurstSignature(
                                    for: action,
                                    scopeContext: effectiveScopeContext
                                ),
                                approvedBy: approvedBy,
                                approvalId: response.approvalId,
                                remainingActions: 9,
                                expiresAt: Date().addingTimeInterval(30)
                            )
                        }
                        sessions[sessionId] = active
                    case .reject, .rejectAndHalt:
                        let entry = try? active.logger.makeEntry(
                            for: action,
                            approvedBy: .denied,
                            denyReason: ComputerUseDenyReason.userRejected.rawValue,
                            scopeContext: effectiveScopeContext
                        )
                        if let entry { _ = try? active.logger.append(entry) }
                        active.state.actionsRejected += 1
                        guard storeIfCurrent(active, sessionId: sessionId, generation: generation) else {
                            return endedResponse(sessionId: sessionId, invocation: invocation)
                        }
                        if response.decision == .rejectAndHalt {
                            _ = await panicHalt(sessionId: sessionId, source: .stalled)
                        }
                        return ComputerUseInvokeResponse(
                            sessionId: sessionId.rawValue,
                            callID: invocation.callID,
                            status: .denied,
                            denyReason: ComputerUseDenyReason.userRejected.rawValue,
                            auditEntryIndex: entry?.entryIndex,
                            auditHeadHashHex: active.logger.headHashHex,
                            meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                        )
                    }
                } catch {
                    guard currentActiveSession(
                        sessionId: sessionId,
                        generation: generation,
                        invocationId: invocationId
                    ) != nil else {
                        return revokedResponse(sessionId: sessionId, invocation: invocation)
                    }
                    return ComputerUseInvokeResponse(
                        sessionId: sessionId.rawValue,
                        callID: invocation.callID,
                        status: .error,
                        denyReason: "approval_failed: \(error.localizedDescription)"
                    )
                }
            }

            guard let current = currentActiveSession(
                sessionId: sessionId,
                generation: generation,
                invocationId: invocationId
            ) else {
                return revokedResponse(sessionId: sessionId, invocation: invocation)
            }
            active = current
            sessions[sessionId] = active

            let currentGateOutcome = gate.check(
                action: action,
                scopeOutcome: effectiveScopeOutcome,
                accessibilityDeny: accessibilityDeny,
                context: refreshedCapabilityContext(effectiveCapability, active: active, sessionId: sessionId)
            )
            if case .denied(let reason) = currentGateOutcome {
                return deniedResponse(
                    sessionId: sessionId.rawValue,
                    invocation: invocation,
                    action: action,
                    scopeContext: effectiveScopeContext,
                    scopeRuleId: scopeRuleIfDenied(outcome: effectiveScopeOutcome),
                    reason: reason.rawValue,
                    generation: generation,
                    invocationId: invocationId
                )
            }

            guard await authorize(
                sessionId: sessionId,
                invocation: invocation,
                generation: generation,
                invocationId: invocationId
            ) else {
                return authorizationDeniedResponse(
                    sessionId: sessionId,
                    invocation: invocation,
                    action: action,
                    scopeContext: effectiveScopeContext,
                    generation: generation,
                    invocationId: invocationId
                )
            }
            guard let authorizedActive = currentActiveSession(
                sessionId: sessionId,
                generation: generation,
                invocationId: invocationId
            ) else {
                return revokedResponse(sessionId: sessionId, invocation: invocation)
            }
            active = authorizedActive

            // AUDIT-BEFORE-ACTION (fail-closed): reserve a pending audit
            // entry on the chain BEFORE dispatch. If the reservation append
            // throws, do NOT execute the action.
            do {
                let reservation = try active.logger.makeEntry(
                    for: action,
                    approvalId: approvalId,
                    approvedBy: approvedBy,
                    scopeRuleId: scopeRuleIfAllowed(outcome: effectiveScopeOutcome),
                    denyReason: Self.auditReservationSentinel,
                    scopeContext: effectiveScopeContext
                )
                try active.logger.append(reservation)
                guard storeIfCurrent(active, sessionId: sessionId, generation: generation) else {
                    return endedResponse(sessionId: sessionId, invocation: invocation)
                }
            } catch {
                logger.warning("audit_reservation_failed", metadata: [
                    "session": sessionId.rawValue,
                    "error": String(describing: error)
                ])
                active.state.actionsRejected += 1
                guard storeIfCurrent(active, sessionId: sessionId, generation: generation) else {
                    return endedResponse(sessionId: sessionId, invocation: invocation)
                }
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .denied,
                    approvalId: approvalId,
                    denyReason: ComputerUseDenyReason.auditFailure.rawValue,
                    auditHeadHashHex: active.logger.headHashHex
                )
            }

            let actionClass: ComputerUseLocalQuotaLedger.ActionClass
            switch action {
            case .browser, .safari:
                actionClass = .browser
            case .macInput, .macInspect, .phoneIntent, .remoteClipboard:
                actionClass = .system
            }
            let exemptsMeteredCap = effectiveCapability.originatedFromPhone && {
                switch action {
                case .macInput, .phoneIntent, .remoteClipboard: return true
                case .browser, .safari, .macInspect: return false
                }
            }()
            var quotaReservationInserted = false
            do {
                let quotaReservation = try quotaLedger.reserveAction(
                    idempotencyKey: "\(sessionId.rawValue)|\(invocation.callID)",
                    actionClass: actionClass,
                    originatedFromPhone: effectiveCapability.originatedFromPhone,
                    exemptFromMeteredCap: exemptsMeteredCap,
                    authoritativeUsage: effectiveUsage,
                    maximumMeteredActions: effectiveCapability.envelope.activeActionsPerDay
                )
                guard quotaReservation.inserted else {
                    let entry = try? active.logger.makeEntry(
                        for: action,
                        approvalId: approvalId,
                        approvedBy: .denied,
                        scopeRuleId: scopeRuleIfAllowed(outcome: effectiveScopeOutcome),
                        denyReason: ComputerUseDenyReason.counterReplay.rawValue,
                        scopeContext: effectiveScopeContext
                    )
                    if let entry { _ = try? active.logger.append(entry) }
                    active.state.actionsRejected += 1
                    _ = storeIfCurrent(active, sessionId: sessionId, generation: generation)
                    return ComputerUseInvokeResponse(
                        sessionId: sessionId.rawValue,
                        callID: invocation.callID,
                        status: .denied,
                        approvalId: approvalId,
                        denyReason: ComputerUseDenyReason.counterReplay.rawValue,
                        auditEntryIndex: entry?.entryIndex,
                        auditHeadHashHex: active.logger.headHashHex,
                        meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                    )
                }
                quotaReservationInserted = true
            } catch {
                let reason: ComputerUseDenyReason = error as? ComputerUseLocalQuotaLedger.LedgerError == .quotaExceeded
                    ? .dailyLimit
                    : .auditFailure
                let entry = try? active.logger.makeEntry(
                    for: action,
                    approvalId: approvalId,
                    approvedBy: .denied,
                    scopeRuleId: scopeRuleIfAllowed(outcome: effectiveScopeOutcome),
                    denyReason: reason.rawValue,
                    scopeContext: effectiveScopeContext
                )
                if let entry { _ = try? active.logger.append(entry) }
                active.state.actionsRejected += 1
                _ = storeIfCurrent(active, sessionId: sessionId, generation: generation)
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .denied,
                    approvalId: approvalId,
                    denyReason: reason.rawValue,
                    auditEntryIndex: entry?.entryIndex,
                    auditHeadHashHex: active.logger.headHashHex,
                    meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                )
            }

            // Dispatch.
            let result: BurnBarToolResult
            do {
                result = try await performCancellableOperation(
                    sessionId: sessionId,
                    generation: generation,
                    invocationId: invocationId
                ) { [self, activeDriver = active.driver] in
                    try await dispatch(
                        sessionId: sessionId,
                        invocation: invocation,
                        action: action,
                        activeDriver: activeDriver
                    )
                }
            } catch {
                if quotaReservationInserted {
                    _ = try? quotaLedger.rollbackAction(
                        idempotencyKey: "\(sessionId.rawValue)|\(invocation.callID)",
                        actionClass: actionClass,
                        exemptFromMeteredCap: exemptsMeteredCap
                    )
                }
                guard let current = currentActiveSession(
                    sessionId: sessionId,
                    generation: generation,
                    invocationId: invocationId
                ) else {
                    return revokedResponse(sessionId: sessionId, invocation: invocation)
                }
                active = current
                let failureEntry = try? active.logger.makeEntry(
                    for: action,
                    approvalId: approvalId,
                    approvedBy: approvedBy,
                    scopeRuleId: scopeRuleIfAllowed(outcome: effectiveScopeOutcome),
                    denyReason: String(describing: error),
                    scopeContext: effectiveScopeContext
                )
                if let failureEntry { _ = try? active.logger.append(failureEntry) }
                active.state.actionsRejected += 1
                guard storeIfCurrent(active, sessionId: sessionId, generation: generation) else {
                    return endedResponse(sessionId: sessionId, invocation: invocation)
                }
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .error,
                    approvalId: approvalId,
                    denyReason: String(describing: error),
                    auditEntryIndex: failureEntry?.entryIndex,
                    auditHeadHashHex: active.logger.headHashHex,
                    meteringHeader: failureEntry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                )
            }

            guard let current = currentActiveSession(
                sessionId: sessionId,
                generation: generation,
                invocationId: invocationId
            ) else {
                return revokedResponse(sessionId: sessionId, invocation: invocation)
            }
            active = current
            do {
                let entry = try active.logger.makeEntry(
                    for: action,
                    approvalId: approvalId,
                    approvedBy: approvedBy,
                    scopeRuleId: scopeRuleIfAllowed(outcome: effectiveScopeOutcome),
                    scopeContext: effectiveScopeContext
                )
                try active.logger.append(entry)
                active.state.actionsExecuted += 1
                active.state.lastActionAt = Date()
                guard storeIfCurrent(active, sessionId: sessionId, generation: generation) else {
                    return endedResponse(sessionId: sessionId, invocation: invocation)
                }
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .executed,
                    approvalId: approvalId,
                    auditEntryIndex: entry.entryIndex,
                    auditHeadHashHex: active.logger.headHashHex,
                    meteringHeader: ComputerUseActionMeteringHeader(auditEntry: entry),
                    result: result
                )
            } catch {
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .error,
                    approvalId: approvalId,
                    denyReason: String(describing: error)
                )
            }
        }
    }

    private func currentActiveSession(
        sessionId: ComputerUseSessionID,
        generation: UUID,
        invocationId: UUID
    ) -> ActiveSession? {
        guard let active = sessions[sessionId],
              active.isReady,
              active.generation == generation,
              active.inFlightInvocationId == invocationId else {
            return nil
        }
        return active
    }

    private func releaseInvocation(
        sessionId: ComputerUseSessionID,
        generation: UUID,
        invocationId: UUID
    ) {
        guard var active = currentActiveSession(
            sessionId: sessionId,
            generation: generation,
            invocationId: invocationId
        ) else { return }
        active.inFlightInvocationId = nil
        active.cancelInFlight = nil
        sessions[sessionId] = active
    }

    private func performCancellableOperation<T: Sendable>(
        sessionId: ComputerUseSessionID,
        generation: UUID,
        invocationId: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        guard var active = currentActiveSession(
            sessionId: sessionId,
            generation: generation,
            invocationId: invocationId
        ) else {
            task.cancel()
            throw DispatchError.unknownSession
        }
        active.cancelInFlight = { task.cancel() }
        sessions[sessionId] = active
        defer {
            if var current = currentActiveSession(
                sessionId: sessionId,
                generation: generation,
                invocationId: invocationId
            ) {
                current.cancelInFlight = nil
                sessions[sessionId] = current
            }
        }
        return try await task.value
    }

    private func authorize(
        sessionId: ComputerUseSessionID,
        invocation: BurnBarToolInvocation,
        generation: UUID,
        invocationId: UUID
    ) async -> Bool {
        guard let preDispatchAuthorizer else {
            return currentActiveSession(
                sessionId: sessionId,
                generation: generation,
                invocationId: invocationId
            ) != nil
        }
        let allowed: Bool
        do {
            allowed = try await performCancellableOperation(
                sessionId: sessionId,
                generation: generation,
                invocationId: invocationId
            ) {
                await preDispatchAuthorizer(sessionId, invocation)
            }
        } catch {
            return false
        }
        return allowed && currentActiveSession(
            sessionId: sessionId,
            generation: generation,
            invocationId: invocationId
        ) != nil
    }

    private func refreshedCapabilityContext(
        _ capability: ComputerUseCapabilityContext,
        active: ActiveSession,
        sessionId: ComputerUseSessionID
    ) -> ComputerUseCapabilityContext {
        ComputerUseCapabilityContext(
            entitlement: capability.entitlement,
            envelope: capability.envelope,
            usage: capability.usage,
            session: active.state,
            concurrentSessionActive: sessions.keys.contains { $0 != sessionId },
            killSwitch: capability.killSwitch,
            accessibilityTrusted: capability.accessibilityTrusted,
            originatedFromPhone: capability.originatedFromPhone,
            phoneControlRespectsDenyRegions: capability.phoneControlRespectsDenyRegions,
            phoneSessionFirstActionConfirmed: capability.phoneSessionFirstActionConfirmed,
            clipboardConsentGranted: capability.clipboardConsentGranted
        )
    }

    private func revokedResponse(
        sessionId: ComputerUseSessionID,
        invocation: BurnBarToolInvocation
    ) -> ComputerUseInvokeResponse {
        ComputerUseInvokeResponse(
            sessionId: sessionId.rawValue,
            callID: invocation.callID,
            status: .denied,
            denyReason: "session_revoked"
        )
    }

    private func authorizationDeniedResponse(
        sessionId: ComputerUseSessionID,
        invocation: BurnBarToolInvocation,
        action: ComputerUseAction,
        scopeContext: ComputerUseScopeContext,
        generation: UUID,
        invocationId: UUID
    ) -> ComputerUseInvokeResponse {
        guard currentActiveSession(
            sessionId: sessionId,
            generation: generation,
            invocationId: invocationId
        ) != nil else {
            return revokedResponse(sessionId: sessionId, invocation: invocation)
        }
        return deniedResponse(
            sessionId: sessionId.rawValue,
            invocation: invocation,
            action: action,
            scopeContext: scopeContext,
            scopeRuleId: nil,
            reason: "pre_dispatch_authorization_denied",
            generation: generation,
            invocationId: invocationId
        )
    }

    private func deniedResponse(
        sessionId: String,
        invocation: BurnBarToolInvocation,
        action: ComputerUseAction,
        scopeContext: ComputerUseScopeContext,
        scopeRuleId: String?,
        reason: String,
        generation: UUID,
        invocationId: UUID
    ) -> ComputerUseInvokeResponse {
        let typedSessionId = ComputerUseSessionID(sessionId)
        guard var active = currentActiveSession(
            sessionId: typedSessionId,
            generation: generation,
            invocationId: invocationId
        ) else {
            return revokedResponse(sessionId: typedSessionId, invocation: invocation)
        }
        do {
            let entry = try active.logger.makeEntry(
                for: action,
                approvedBy: .denied,
                scopeRuleId: scopeRuleId,
                denyReason: reason,
                scopeContext: scopeContext
            )
            try active.logger.append(entry)
            active.state.actionsRejected += 1
            sessions[typedSessionId] = active
            return ComputerUseInvokeResponse(
                sessionId: sessionId,
                callID: invocation.callID,
                status: .denied,
                denyReason: reason,
                auditEntryIndex: entry.entryIndex,
                auditHeadHashHex: active.logger.headHashHex
            )
        } catch {
            logger.warning("audit_append_failed", metadata: [
                "session": sessionId,
                "error": String(describing: error)
            ])
            return ComputerUseInvokeResponse(
                sessionId: sessionId,
                callID: invocation.callID,
                status: .error,
                denyReason: reason
            )
        }
    }

    // MARK: Decode

    private func decodeAction(invocation: BurnBarToolInvocation) throws -> ComputerUseAction {
        switch invocation.tool {
        case .browserClick:
            let args = try decodeBrowserArgs(invocation: invocation)
            return .browser(BrowserAction(
                kind: .click,
                selector: args.selector,
                positionX: args.positionX,
                positionY: args.positionY,
                timeoutMillis: args.timeoutMillis ?? 10_000
            ))
        case .browserFill:
            let args = try decodeBrowserArgs(invocation: invocation)
            return .browser(BrowserAction(
                kind: .fill,
                selector: args.selector,
                text: args.text,
                timeoutMillis: args.timeoutMillis ?? 10_000
            ))
        case .browserGoto:
            let args = try decodeBrowserArgs(invocation: invocation)
            return .browser(BrowserAction(
                kind: .goto,
                url: args.url,
                timeoutMillis: args.timeoutMillis ?? 10_000
            ))
        case .browserKey:
            let args = try decodeBrowserArgs(invocation: invocation)
            return .browser(BrowserAction(kind: .key, key: args.key))
        case .browserSelect:
            let args = try decodeBrowserArgs(invocation: invocation)
            return .browser(BrowserAction(
                kind: .select,
                selector: args.selector,
                value: args.value
            ))
        case .browserScreenshot:
            return .browser(BrowserAction(kind: .screenshot))
        case .browserExtract:
            let args = try decodeBrowserArgs(invocation: invocation)
            return .browser(BrowserAction(kind: .extract, selector: args.selector))
        case .safariPageContext, .safariScreenshot, .safariFullPageScreenshot,
             .safariClick, .safariType, .safariPressKey, .safariScroll,
             .safariHover, .safariFocus, .safariSelectOption, .safariNavigate,
             .safariOpenTab, .safariCloseTab, .safariListTabs, .safariWaitFor,
             .safariRunJavaScript, .safariExtract, .safariAbort:
            return .safari(try decodeSafariAction(invocation: invocation))
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
            return .macInspect(MacInspectAction(
                kind: .accessibility,
                displayX: intArgument(invocation, key: "displayX"),
                displayY: intArgument(invocation, key: "displayY")
            ))
        default:
            throw DispatchError.unsupportedTool(invocation.tool.rawValue)
        }
    }

    private func decodeBrowserArgs(invocation: BurnBarToolInvocation) throws -> BurnBarBrowserActionArguments {
        let encoded = try JSONEncoder().encode(invocation.arguments)
        return try JSONDecoder().decode(BurnBarBrowserActionArguments.self, from: encoded)
    }

    private func decodeSafariAction(
        invocation: BurnBarToolInvocation
    ) throws -> SafariActionDescriptor {
        let kind: BurnBarSafariActionKind
        switch invocation.tool {
        case .safariPageContext: kind = .pageContext
        case .safariScreenshot: kind = .screenshot
        case .safariFullPageScreenshot: kind = .fullPageScreenshot
        case .safariClick: kind = .click
        case .safariType: kind = .type
        case .safariPressKey: kind = .pressKey
        case .safariScroll: kind = .scroll
        case .safariHover: kind = .hover
        case .safariFocus: kind = .focus
        case .safariSelectOption: kind = .selectOption
        case .safariNavigate: kind = .navigate
        case .safariOpenTab: kind = .openTab
        case .safariCloseTab: kind = .closeTab
        case .safariListTabs: kind = .listTabs
        case .safariWaitFor: kind = .waitFor
        case .safariRunJavaScript: kind = .runJavaScript
        case .safariExtract: kind = .extract
        case .safariAbort: kind = .abort
        default:
            throw DispatchError.unsupportedTool(invocation.tool.rawValue)
        }

        guard let safariSessionID = stringArgument(invocation, key: "safariSessionId")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            safariSessionID.isEmpty == false,
            safariSessionID.utf8.count <= 256 else {
            throw DispatchError.invalidArguments("Safari tools require a bounded safariSessionId.")
        }
        let selector = stringArgument(invocation, key: "selector")
        let text = stringArgument(invocation, key: "text")
        let url = stringArgument(invocation, key: "url")
        let navigationOperation: BurnBarSafariNavigationOperation?
        if kind == .navigate {
            guard let rawOperation = stringArgument(invocation, key: "operation"),
                  let parsedOperation = BurnBarSafariNavigationOperation(rawValue: rawOperation) else {
                throw DispatchError.invalidArguments(
                    "Safari navigate requires operation url, back, forward, or reload."
                )
            }
            navigationOperation = parsedOperation
        } else {
            navigationOperation = nil
        }
        let key = stringArgument(invocation, key: "key")
        let value = stringArgument(invocation, key: "value")
        let script = stringArgument(invocation, key: "script")
        let positionX = doubleArgument(invocation, key: "positionX")
        let positionY = doubleArgument(invocation, key: "positionY")
        let timeoutMillis = min(
            max(
                1_000,
                intArgument(invocation, key: "timeoutMillis")
                    ?? BurnBarSafariProtocol.defaultCommandTimeoutMillis
            ),
            120_000
        )

        switch kind {
        case .click:
            guard selector?.isEmpty == false
                    || (positionX != nil && positionY != nil) else {
                throw DispatchError.invalidArguments(
                    "Safari click requires a selector or both viewport coordinates."
                )
            }
        case .type:
            guard text != nil else {
                throw DispatchError.invalidArguments("Safari type requires text.")
            }
        case .pressKey:
            guard key?.isEmpty == false else {
                throw DispatchError.invalidArguments("Safari press_key requires key.")
            }
        case .hover, .focus:
            guard selector?.isEmpty == false else {
                throw DispatchError.invalidArguments(
                    "Safari \(kind.rawValue) requires a selector."
                )
            }
        case .selectOption:
            guard selector?.isEmpty == false, value != nil else {
                throw DispatchError.invalidArguments(
                    "Safari select_option requires selector and value."
                )
            }
        case .navigate:
            if navigationOperation == .url, url?.isEmpty != false {
                throw DispatchError.invalidArguments(
                    "Safari navigate operation url requires a URL."
                )
            }
        case .openTab:
            guard url?.isEmpty == false else {
                throw DispatchError.invalidArguments("Safari open_tab requires url.")
            }
        case .closeTab:
            guard intArgument(invocation, key: "tabId") != nil else {
                throw DispatchError.invalidArguments("Safari close_tab requires tabId.")
            }
        case .runJavaScript:
            guard let script, script.isEmpty == false, script.utf8.count <= 32 * 1024 else {
                throw DispatchError.invalidArguments(
                    "Safari run_javascript requires a non-empty script of at most 32 KiB."
                )
            }
        case .pageContext, .screenshot, .fullPageScreenshot, .scroll,
             .listTabs, .waitFor, .extract, .abort:
            break
        }

        return SafariActionDescriptor(
            kind: kind,
            safariSessionId: safariSessionID,
            tabId: intArgument(invocation, key: "tabId"),
            expectedNavigationEpoch: intArgument(
                invocation,
                key: "expectedNavigationEpoch"
            ),
            selector: selector,
            text: text,
            url: url,
            navigationOperation: navigationOperation,
            key: key,
            value: value,
            positionX: positionX,
            positionY: positionY,
            deltaX: doubleArgument(invocation, key: "deltaX"),
            deltaY: doubleArgument(invocation, key: "deltaY"),
            script: script,
            timeoutMillis: timeoutMillis
        )
    }

    private func decodeMacInput(invocation: BurnBarToolInvocation, kind: MacInputAction.Kind) throws -> MacInputAction {
        MacInputAction(
            kind: kind,
            displayX: intArgument(invocation, key: "displayX"),
            displayY: intArgument(invocation, key: "displayY"),
            dragEndX: intArgument(invocation, key: "dragEndX"),
            dragEndY: intArgument(invocation, key: "dragEndY"),
            deltaX: intArgument(invocation, key: "deltaX"),
            deltaY: intArgument(invocation, key: "deltaY"),
            mouseButton: intArgument(invocation, key: "mouseButton") ?? 0,
            text: stringArgument(invocation, key: "text"),
            key: stringArgument(invocation, key: "key"),
            modifiers: stringArrayArgument(invocation, key: "modifiers")
        )
    }

    private func intArgument(_ invocation: BurnBarToolInvocation, key: String) -> Int? {
        guard case let .object(dict) = invocation.arguments, let value = dict[key] else { return nil }
        if case let .number(n) = value { return Int(n) }
        return nil
    }
    private func doubleArgument(_ invocation: BurnBarToolInvocation, key: String) -> Double? {
        guard case let .object(dict) = invocation.arguments, let value = dict[key] else { return nil }
        if case let .number(number) = value, number.isFinite { return number }
        return nil
    }
    private func stringArgument(_ invocation: BurnBarToolInvocation, key: String) -> String? {
        guard case let .object(dict) = invocation.arguments, let value = dict[key] else { return nil }
        if case let .string(s) = value { return s }
        return nil
    }
    private func stringArrayArgument(_ invocation: BurnBarToolInvocation, key: String) -> [String]? {
        guard case let .object(dict) = invocation.arguments, let value = dict[key] else { return nil }
        if case let .array(arr) = value {
            return arr.compactMap { v in
                if case let .string(s) = v { return s }
                return nil
            }
        }
        return nil
    }

    private func scopeRuleIfAllowed(outcome: ComputerUseScopeOutcome) -> String? {
        if case let .allowed(rule) = outcome { return rule.rawValue }
        return nil
    }

    private func scopeRuleIfDenied(outcome: ComputerUseScopeOutcome) -> String? {
        if case let .denied(rule) = outcome { return rule.rawValue }
        return nil
    }

    private func resolveSafariScope(
        action: SafariActionDescriptor,
        active: ActiveSession
    ) async throws -> (
        context: ComputerUseScopeContext,
        outcome: ComputerUseScopeOutcome
    ) {
        guard let safariPageStateResolver else {
            throw DispatchError.missingDriver
        }
        let page = try await safariPageStateResolver(action.safariSessionId)
        let context = ComputerUseScopeContext(
            url: page.url,
            bundleId: "com.apple.Safari",
            windowTitle: page.title
        )
        var rulesByID: [ComputerUseScopeRuleID: ComputerUseScopeRule] = [:]
        for rule in ComputerUseDenyRegistry.builtInRules + active.state.manifest.scopeRules {
            rulesByID[rule.id] = rule
        }
        let rules = Array(rulesByID.values)
        let matcher = ComputerUseScopeMatcher()
        let liveOutcome = matcher.evaluate(rules: rules, context: context)

        guard action.kind == .navigate || action.kind == .openTab,
              let targetURL = action.url else {
            return (context, liveOutcome)
        }
        let targetContext = ComputerUseScopeContext(
            url: targetURL,
            bundleId: "com.apple.Safari",
            windowTitle: page.title
        )
        let targetOutcome = matcher.evaluate(rules: rules, context: targetContext)
        return (context, Self.combinedScopeOutcome(liveOutcome, targetOutcome))
    }

    private static func combinedScopeOutcome(
        _ live: ComputerUseScopeOutcome,
        _ target: ComputerUseScopeOutcome
    ) -> ComputerUseScopeOutcome {
        if case .denied = live { return live }
        if case .denied = target { return target }
        guard case .allowed = live, case .allowed = target else {
            return .notMatched
        }
        return live
    }

    private func isReadOnlyAction(action: ComputerUseAction) -> Bool {
        switch action {
        case .macInspect:
            return true
        case .safari(let safari):
            // Full-page capture is intentionally opt-in despite not modifying
            // the page because it can collect substantially more private data.
            return safari.isReadOnly && safari.kind != .fullPageScreenshot
        case .browser, .macInput, .phoneIntent, .remoteClipboard:
            return false
        }
    }

    private func consumeStepBurstApproval(
        for action: ComputerUseAction,
        scopeContext: ComputerUseScopeContext,
        active: inout ActiveSession,
        now: Date
    ) -> (approvedBy: ComputerUseAuditEntry.ApprovedBy, approvalId: String?)? {
        guard active.state.liveTrustMode == .step,
              var burst = active.stepBurstApproval else { return nil }

        let signature = stepBurstSignature(for: action, scopeContext: scopeContext)
        guard burst.covers(signature: signature, now: now) else {
            active.stepBurstApproval = nil
            return nil
        }

        burst.remainingActions -= 1
        active.stepBurstApproval = burst.remainingActions > 0 ? burst : nil
        return (burst.approvedBy, burst.approvalId)
    }

    private func shouldOpenStepBurst(
        from response: HermesRealtimeRelayApprovalResponse,
        active: ActiveSession
    ) -> Bool {
        guard active.state.liveTrustMode == .step,
              response.decision == .approve,
              let note = response.note?.lowercased() else { return false }
        return note.contains("step-mode burst approved")
    }

    private func stepBurstSignature(
        for action: ComputerUseAction,
        scopeContext: ComputerUseScopeContext
    ) -> String {
        switch action {
        case .browser(let action):
            return [
                "browser",
                action.kind.rawValue,
                scopeContext.url.flatMap(browserHost) ?? "",
                action.selector ?? "",
                action.url.flatMap(browserHost) ?? action.url ?? "",
                action.key?.lowercased() ?? "",
                action.value ?? "",
                coordinateSignature(x: action.positionX, y: action.positionY)
            ].joined(separator: "|")
        case .safari(let action):
            return [
                "safari",
                action.kind.rawValue,
                action.safariSessionId,
                action.tabId.map(String.init) ?? "",
                action.selector ?? "",
                action.url.flatMap(browserHost) ?? action.url ?? "",
                action.key?.lowercased() ?? "",
                action.value ?? "",
                coordinateSignature(x: action.positionX, y: action.positionY)
            ].joined(separator: "|")
        case .macInput(let action):
            return [
                "mac.input",
                action.kind.rawValue,
                scopeContext.bundleId ?? "",
                String(action.mouseButton),
                action.key?.lowercased() ?? "",
                (action.modifiers ?? []).map { $0.lowercased() }.sorted().joined(separator: "+"),
                action.text ?? "",
                coordinateSignature(x: action.displayX, y: action.displayY),
                coordinateSignature(x: action.dragEndX, y: action.dragEndY),
                coordinateSignature(x: action.deltaX, y: action.deltaY)
            ].joined(separator: "|")
        case .macInspect(let action):
            return [
                "mac.inspect",
                action.kind.rawValue,
                scopeContext.bundleId ?? "",
                coordinateSignature(x: action.displayX, y: action.displayY)
            ].joined(separator: "|")
        case .phoneIntent(let intent):
            return [
                "phone",
                intent.kind.rawValue,
                scopeContext.bundleId ?? "",
                intent.key?.lowercased() ?? "",
                (intent.modifiers ?? []).map { $0.lowercased() }.sorted().joined(separator: "+"),
                intent.text ?? ""
            ].joined(separator: "|")
        case .remoteClipboard(let action):
            return [
                "clipboard",
                action.kind.rawValue,
                scopeContext.bundleId ?? "",
                action.contentType,
                String(action.byteCount ?? 0),
                String(action.maxBytes)
            ].joined(separator: "|")
        }
    }

    private func browserHost(from url: String) -> String? {
        URL(string: url)?.host?.lowercased()
    }

    private func coordinateSignature(x: Int?, y: Int?) -> String {
        guard let x, let y else { return "" }
        return "\(x),\(y)"
    }

    private func coordinateSignature(x: Double?, y: Double?) -> String {
        guard let x, let y else { return "" }
        return "\(x),\(y)"
    }

    // MARK: Concrete dispatch

    private func dispatch(
        sessionId: ComputerUseSessionID,
        invocation: BurnBarToolInvocation,
        action: ComputerUseAction,
        activeDriver: OpenBurnBarPlaywrightDriver?
    ) async throws -> BurnBarToolResult {
        try Task.checkCancellation()
        switch action {
        case .browser(let browser):
            guard let driver = activeDriver else { throw DispatchError.missingDriver }
            let response = try await dispatch(browser: browser, on: driver)
            return BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: response.ok,
                output: response.result,
                errorMessage: response.error,
                completedAt: Date()
            )
        case .safari(let safari):
            guard let dispatcher = safariDispatcher else { throw DispatchError.missingDriver }
            let response = try await dispatcher(sessionId, safari)
            return BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: response.ok,
                output: response.result,
                errorMessage: response.error,
                completedAt: Date()
            )
        case .macInput(let input):
            guard let dispatcher = macInputDispatcher else { throw DispatchError.missingDriver }
            let value = try await dispatcher(sessionId, input)
            return BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: true,
                output: value,
                completedAt: Date()
            )
        case .macInspect(let inspect):
            guard let dispatcher = macInspectDispatcher else { throw DispatchError.missingDriver }
            let value = try await dispatcher(sessionId, inspect)
            return BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: true,
                output: value,
                completedAt: Date()
            )
        case .phoneIntent:
            // Phone intents are translated to mac.input or browser
            // actions by the PhoneControlReceiver before reaching this
            // path. A raw phoneIntent here is a wiring bug.
            throw DispatchError.unsupportedTool("phone_intent_in_run_dispatch")
        case .remoteClipboard:
            // Remote clipboard is handled by the Mac app's phone-control
            // coordinator because it touches NSPasteboard and focused app
            // context. It must never route through the daemon run dispatcher.
            throw DispatchError.unsupportedTool("remote_clipboard_in_run_dispatch")
        }
    }

    private struct ApprovalEvidence: Sendable, Equatable {
        var pngBase64: String
        var mimeType: String
        var sizeBytes: Int
        var hashHex: String
    }

    private func approvalEvidence(
        for action: ComputerUseAction,
        computerUseSessionId: ComputerUseSessionID,
        activeDriver: OpenBurnBarPlaywrightDriver?
    ) async -> ApprovalEvidence? {
        do {
            let result: BurnBarJSONValue?
            let fallbackMimeType: String
            switch action {
            case .browser:
                guard let activeDriver else { return nil }
                result = try await activeDriver.screenshot().result
                fallbackMimeType = "image/png"
            case .safari(let safari):
                guard let safariDispatcher else { return nil }
                let screenshot = SafariActionDescriptor(
                    kind: .screenshot,
                    safariSessionId: safari.safariSessionId,
                    tabId: safari.tabId,
                    expectedNavigationEpoch: safari.expectedNavigationEpoch,
                    timeoutMillis: min(
                        safari.timeoutMillis,
                        BurnBarSafariProtocol.defaultCommandTimeoutMillis
                    )
                )
                let response = try await safariDispatcher(computerUseSessionId, screenshot)
                guard response.ok else { return nil }
                result = response.result
                fallbackMimeType = "image/jpeg"
            case .macInput, .macInspect, .phoneIntent, .remoteClipboard:
                return nil
            }

            guard case .object(let object)? = result,
                  let base64 = object.stringValue(forKey: "base64"),
                  base64.isEmpty == false else {
                return nil
            }
            let decoded = Data(base64Encoded: base64)
            let sizeBytes = object.intValue(forKey: "sizeBytes") ?? decoded?.count ?? 0
            let hashHex = decoded.map(Self.sha256Hex(data:)) ?? Self.sha256Hex(string: base64)
            return ApprovalEvidence(
                pngBase64: base64,
                mimeType: object.stringValue(forKey: "mimeType") ?? fallbackMimeType,
                sizeBytes: sizeBytes,
                hashHex: hashHex
            )
        } catch {
            logger.warning("approval_screenshot_capture_failed", metadata: [
                "error": String(describing: error)
            ])
            return nil
        }
    }

    private static func sha256Hex(data: Data) -> String {
        PlatformCrypto.sha256Hex(data)
    }

    private static func sha256Hex(string: String) -> String {
        sha256Hex(data: Data(string.utf8))
    }

    private func dispatch(
        browser action: BrowserAction,
        on driver: OpenBurnBarPlaywrightDriver
    ) async throws -> OpenBurnBarPlaywrightDriver.Response {
        let response: OpenBurnBarPlaywrightDriver.Response
        switch action.kind {
        case .click:
            response = try await driver.click(
                selector: action.selector,
                positionX: action.positionX,
                positionY: action.positionY,
                timeoutMillis: action.timeoutMillis
            )
        case .fill:
            guard let selector = action.selector, let text = action.text else {
                throw DispatchError.invalidArguments("fill requires selector and text")
            }
            response = try await driver.fill(selector: selector, text: text, timeoutMillis: action.timeoutMillis)
        case .goto:
            guard let url = action.url else {
                throw DispatchError.invalidArguments("goto requires url")
            }
            // T-AI-04: validate the navigation target host AND its post-DNS
            // resolved IPs (anti-rebind) before navigating, so a hostname that
            // resolves to a loopback/private/metadata address is refused.
            let validatedURL = try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(
                url,
                allowDataURL: true,
                resolver: browserHostResolver
            )
            response = try await driver.goto(url: validatedURL.absoluteString, timeoutMillis: action.timeoutMillis)
        case .key:
            guard let key = action.key else {
                throw DispatchError.invalidArguments("key requires key")
            }
            response = try await driver.key(key)
        case .select:
            guard let selector = action.selector, let value = action.value else {
                throw DispatchError.invalidArguments("select requires selector and value")
            }
            response = try await driver.select(selector: selector, value: value)
        case .screenshot:
            return try await driver.screenshot()
        case .extract:
            return try await driver.extract(selector: action.selector)
        }
        // T-AI-04: per-navigation / redirect / JS-nav re-validation. Each action's
        // own response carries the URL the page LANDED on (the bridge attaches
        // `finalURL` on goto and the live `url` on every interactive action), so a
        // server-side redirect or in-page JS navigation onto a blocked host is
        // refused WITHOUT an extra driver round trip. Re-checking from the
        // response (not a fresh `currentURL()` call) preserves the driver's
        // request accounting and adds no latency.
        try Self.enforceLandedURL(from: response, resolver: browserHostResolver)
        return response
    }

    /// T-AI-04 — re-validate the URL the page landed on, read from the action's
    /// own response (`finalURL` for navigation, `url` for interactive actions). A
    /// blocked landed host is refused so a redirect / JS-nav cannot steer the
    /// agent's browser onto the loopback/metadata plane. Absent fields are a
    /// no-op (the action did not navigate); http/https hosts are checked through
    /// the same literal + live DNS policy as initial navigation.
    static func enforceLandedURL(
        from response: OpenBurnBarPlaywrightDriver.Response,
        resolver: BurnBarBrowserHostResolver = OpenBurnBarBrowserTargetPolicy.systemResolvedAddresses
    ) throws {
        let landed = urlString(from: response.result, key: "finalURL")
            ?? urlString(from: response.result, key: "url")
        guard let landed else { return }
        try enforceLandedURLString(landed, resolver: resolver)
    }

    static func enforceLandedURLString(
        _ landed: String,
        resolver: BurnBarBrowserHostResolver = OpenBurnBarBrowserTargetPolicy.systemResolvedAddresses
    ) throws {
        let trimmed = landed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        // Pages legitimately sit on about:blank / data: between navigations;
        // those carry no host to rebind and are not range-checked.
        let lower = trimmed.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") || lower.hasPrefix("blob:") {
            return
        }
        guard let url = URL(string: trimmed), let host = url.host, host.isEmpty == false else {
            return
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        do {
            _ = try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(trimmed, resolver: resolver)
        } catch {
            throw DispatchError.invalidArguments(
                "browser navigated to a blocked local, private, or metadata host: \(host) (\(error.localizedDescription))"
            )
        }
    }

    /// Extract a string URL field from a driver response result object.
    private static func urlString(from result: BurnBarJSONValue?, key: String) -> String? {
        guard case .object(let dict)? = result,
              case .string(let value)? = dict[key] else {
            return nil
        }
        return value
    }
}
