#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarKernel
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

// Session lifecycle and approval-response flow.
// Collaborator type owned by ComputerUseSessionCoordinator (not an extension of it).

@MainActor
@dynamicMemberLookup
final class ComputerUseApprovalPipeline {
    unowned let session: ComputerUseSessionCoordinator

    init(session: ComputerUseSessionCoordinator) {
        self.session = session
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ComputerUseSessionCoordinator, T>) -> T {
        get { session[keyPath: keyPath] }
        set { session[keyPath: keyPath] = newValue }
    }

    subscript<T>(dynamicMember keyPath: KeyPath<ComputerUseSessionCoordinator, T>) -> T {
        session[keyPath: keyPath]
    }

    func endSession(reason: ComputerUseEndReason = .completed) async {
        endSessionNow(reason: reason)
    }

    func endSessionNow(reason: ComputerUseEndReason = .completed) {
        guard let sessionId = session.activeSessionId else { return }
        let startedAt = session.state?.manifest.startedAt
        let endedAt = Date()
        session.cancelPendingApprovals(decision: .reject, note: "session ended")
        finalizeAuditSignedHeadIfPossible()
        session.activeSessionId = nil
        // F2: controller authority is per-session — drop every admitted peer so
        // the next session must re-establish it via a fresh controlClassify
        // registration (pins, revocations, and replay counters persist).
        session.phoneValidator.deregisterAllPeers()
        // F10: seal sessions are per-classify; force re-establishment.
        session.controlSealSessions.removeAll()
        session.phoneReceiver = nil
        session.systemPermissionReceiver = nil
        SystemPermissionMonitor.shared.detach()
        session.focusFollowController?.stop()
        let coordinator = session
        Task { @MainActor in
            await coordinator.releaseSessionScopedHolds()
        }
        session.auditLogger = nil
        session.screenshotEvidenceDataByHash.removeAll()
        session.phoneFirstActionConfirmedSessionKeys.removeAll()
        session.pendingApproval = nil
        session.pendingApprovalScreenshotPNG = nil
        session.state?.endReason = reason
        session.state?.endedAt = endedAt
        completeLocalQuotaSession(sessionId: sessionId, startedAt: startedAt, endedAt: endedAt)
        enqueueCloudSessionEnd(sessionId: sessionId, endedAt: endedAt, reason: reason)
        session.appendTimeline(
            kind: "session.end",
            summary: "Computer Use session ended: \(reason.rawValue)",
            status: .completed
        )
    }

    func panicHalt(source: ComputerUsePanicSource) async {
        guard let sessionId = session.activeSessionId else { return }
        PrivilegedInputKillSwitch.activate(reason: source.rawValue)
        session.cancelPendingApprovals(decision: .rejectAndHalt, note: "panic halt")
        if let logger = session.auditLogger {
            let action: ComputerUseAction = .macInspect(MacInspectAction(kind: .accessibility))
            do {
                let entry = try logger.makeEntry(
                    for: action,
                    approvedBy: .panic,
                    denyReason: source.rawValue,
                    macHostNodeId: session.configuration.macHostNodeId,
                    scopeContext: session.macDispatcher.currentScopeContext()
                )
                try logger.append(entry)
                session.state?.auditChainHeadHashHex = logger.headHashHex
            } catch {
                // A dropped panic-halt entry is a gap in the tamper-evident audit
                // chain — surface it instead of swallowing; the halt still proceeds.
                ComputerUseSessionCoordinator.log.error("computer_use_panic_audit_entry_failed reason=\(String(describing: error), privacy: .public)")
            }
            finalizeAuditSignedHeadIfPossible()
        }
        session.activeSessionId = nil
        session.phoneValidator.deregisterAllPeers()
        session.controlSealSessions.removeAll()
        session.phoneReceiver = nil
        session.systemPermissionReceiver = nil
        SystemPermissionMonitor.shared.detach()
        session.focusFollowController?.stop()
        await session.releaseSessionScopedHolds()
        session.auditLogger = nil
        session.screenshotEvidenceDataByHash.removeAll()
        session.phoneFirstActionConfirmedSessionKeys.removeAll()
        session.pendingApproval = nil
        session.pendingApprovalScreenshotPNG = nil
        let endedAt = Date()
        session.state?.endReason = session.endReason(for: source)
        session.state?.endedAt = endedAt
        completeLocalQuotaSession(
            sessionId: sessionId,
            startedAt: session.state?.manifest.startedAt,
            endedAt: endedAt
        )
        enqueueCloudSessionEnd(
            sessionId: sessionId,
            endedAt: endedAt,
            reason: session.endReason(for: source)
        )
        session.appendTimeline(
            kind: "panic.\(source.rawValue)",
            summary: "Panic halt: \(source.rawValue)",
            status: .panicHalted
        )
        _ = sessionId
    }

    private func completeLocalQuotaSession(
        sessionId: ComputerUseSessionID,
        startedAt: Date?,
        endedAt: Date
    ) {
        do {
            let reservation = try session.quotaLedger.completeSession(
                idempotencyKey: sessionId.rawValue,
                startedAt: startedAt,
                endedAt: endedAt
            )
            session.configuration.quotaUsage = reservation.usage
        } catch {
            ComputerUseSessionCoordinator.log.error(
                "computer_use_session_completion_metering_failed reason=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func enqueueCloudSessionEnd(
        sessionId: ComputerUseSessionID,
        endedAt: Date,
        reason: ComputerUseEndReason
    ) {
        guard let cloudMeteringRecorder = session.cloudMeteringRecorder else { return }
        let userID = session.configuration.currentUserId
        let currentState = session.state
        Task { @MainActor in
            do {
                try await cloudMeteringRecorder.recordSessionEnd(
                    userID: userID,
                    sessionID: sessionId.rawValue,
                    endedAt: endedAt,
                    reason: reason,
                    state: currentState,
                    auditHeadHashHex: currentState?.auditChainHeadHashHex
                )
            } catch {
                ComputerUseSessionCoordinator.log.error(
                    "computer_use_session_end_cloud_metering_failed reason=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    func finalizeAuditSignedHeadIfPossible() {
        guard let logger = session.auditLogger else { return }
        let legacyKey = OpenBurnBarKernel.OpenBurnBarAppPaths.live().supportDirectory
            .appendingPathComponent("computer-use-audit", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("audit-export-ed25519.raw", isDirectory: false)
        do {
            let signer = try ComputerUseKeychainAuditExportSignerProvider(legacyRawKeyURL: legacyKey).signer()
            try ComputerUseAuditHeadFinalizer.finalize(logger: logger, signer: signer)
        } catch {
            // An unsigned audit head loses its tamper-evidence guarantee — make
            // a missing/inaccessible signer or a failed finalize observable.
            ComputerUseSessionCoordinator.log.error("computer_use_audit_head_finalize_failed reason=\(String(describing: error), privacy: .public)")
        }
    }

    func haltForBudgetHardCap() {
        guard let sessionId = session.activeSessionId else { return }
        let startedAt = session.state?.manifest.startedAt
        let endedAt = Date()
        PrivilegedInputKillSwitch.activate(reason: ComputerUseDenyReason.hardCap.rawValue)
        session.cancelPendingApprovals(decision: .rejectAndHalt, note: "budget hard cap")
        if let logger = session.auditLogger {
            let action: ComputerUseAction = .macInspect(MacInspectAction(kind: .accessibility))
            do {
                let entry = try logger.makeEntry(
                    for: action,
                    approvedBy: .panic,
                    denyReason: ComputerUseDenyReason.hardCap.rawValue,
                    macHostNodeId: session.configuration.macHostNodeId,
                    scopeContext: session.macDispatcher.currentScopeContext()
                )
                try logger.append(entry)
                session.state?.auditChainHeadHashHex = logger.headHashHex
            } catch {
                // A dropped hard-cap entry is a gap in the tamper-evident audit
                // chain — surface it instead of swallowing; the halt still proceeds.
                ComputerUseSessionCoordinator.log.error("computer_use_hardcap_audit_entry_failed reason=\(String(describing: error), privacy: .public)")
            }
        }
        session.state?.endReason = .budgetHardCap
        session.state?.endedAt = endedAt
        completeLocalQuotaSession(sessionId: sessionId, startedAt: startedAt, endedAt: endedAt)
        enqueueCloudSessionEnd(sessionId: sessionId, endedAt: endedAt, reason: .budgetHardCap)
        session.activeSessionId = nil
        session.phoneReceiver = nil
        session.focusFollowController?.stop()
        let coordinator = session
        Task { @MainActor in
            await coordinator.releaseSessionScopedHolds()
        }
        session.auditLogger = nil
        session.screenshotEvidenceDataByHash.removeAll()
        session.phoneFirstActionConfirmedSessionKeys.removeAll()
        session.pendingApproval = nil
        session.pendingApprovalScreenshotPNG = nil
        session.approvalContexts.removeAll()
        session.lastDeniedReason = .hardCap
        session.appendTimeline(
            kind: "budget.hard_cap",
            summary: "Budget hard cap reached",
            status: .panicHalted
        )
    }

    /// Decodes the wire trust mode carried by a phone `set_trust_mode`
    /// intent. Unknown values are ignored — `setTrustMode` still enforces
    /// downgrade-only.
    func applyPhoneTrustModeIntent(_ intent: PhoneControlIntent) {
        guard let raw = intent.text, let mode = ComputerUseTrustMode(rawValue: raw) else { return }
        setTrustMode(mode)
    }

    func setTrustMode(_ mode: ComputerUseTrustMode) {
        guard var current = session.state else { return }
        // R-L5 (Computer Use safety): while a session is LIVE, trust is
        // downgrade-only. A running session may only *lower* trust
        // (trusted -> step -> manual) — never elevate mid-session — because
        // ComputerUseCapabilityGate treats `.trusted` as auto-allow for scoped
        // actions, so a mid-session elevation is a silent privilege escalation.
        // Elevation requires starting a fresh session. Mirrors the phone-path
        // guard in AgentWatchReceiver.downgradeTrustMode
        // ('guard mode <= liveTrustMode').
        //
        // Once a session ends, `session.activeSessionId` is cleared but `session.state` is left
        // populated (it seeds the *next* session's trust). In that no-active-
        // session window the Mac UI is the legitimate elevation surface —
        // trust is chosen per session (Decision 2) — so any selection, raise
        // included, is allowed. Gate the clamp on the same `session.activeSessionId`
        // liveness signal every teardown path in this file guards on.
        current.liveTrustMode = ComputerUseTrustModePolicy.resolve(
            requested: mode,
            current: current.liveTrustMode,
            sessionIsLive: session.activeSessionId != nil
        )
        session.state = current
    }

    func setRemoteUnlockResultHandler(
        _ handler: (@MainActor @Sendable (HermesRealtimeRelayRemoteUnlockResult) async -> Void)?
    ) {
        session.remoteUnlockResultHandler = handler
    }

    func submitApprovalResponse(_ response: HermesRealtimeRelayApprovalResponse) {
        submitApprovalResponse(response, source: .localPresenter)
    }

    func submitApprovalResponse(
        _ response: HermesRealtimeRelayApprovalResponse,
        source: ComputerUseSessionCoordinator.ApprovalResponseSource
    ) {
        guard let context = session.approvalContexts[response.approvalId] else {
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
                ComputerUseSessionCoordinator.log.warning("Rejected remote approval response that did not match the pending requester.")
                return
            }
            guard let authority = response.authority else {
                ComputerUseSessionCoordinator.log.warning("Rejected remote approval response without a signed authority envelope.")
                return
            }
            do {
                _ = try session.phoneValidator.validate(
                    envelope: authority,
                    approvalResponse: response,
                    expectedRequestHashBlake3: context.requestHashBlake3,
                    now: Date()
                )
            } catch {
                ComputerUseSessionCoordinator.log.warning("Rejected remote approval response with invalid authority: \(String(describing: error), privacy: .public)")
                return
            }
        }
        guard let continuation = session.approvalContinuations.removeValue(forKey: response.approvalId) else {
            session.approvalContexts.removeValue(forKey: response.approvalId)
            return
        }
        session.approvalContexts.removeValue(forKey: response.approvalId)
        if session.pendingApproval?.approvalId == response.approvalId {
            session.pendingApproval = nil
            session.pendingApprovalScreenshotPNG = nil
        }
        continuation.resume(returning: response)
    }

    func invoke(_ invocation: BurnBarToolInvocation) async -> ComputerUseInvokeResponse {
        await invoke(invocation, trustedPhoneOrigin: false)
    }

    func invokeTrustedPhoneControlAction(_ invocation: BurnBarToolInvocation) async -> ComputerUseInvokeResponse {
        await invoke(invocation, trustedPhoneOrigin: true)
    }

    private func invoke(
        _ invocation: BurnBarToolInvocation,
        trustedPhoneOrigin: Bool
    ) async -> ComputerUseInvokeResponse {
        guard let sessionId = session.activeSessionId, var currentState = session.state, let logger = session.auditLogger else {
            return ComputerUseInvokeResponse(
                sessionId: session.activeSessionId?.rawValue ?? "",
                callID: invocation.callID,
                status: .error,
                denyReason: "no_active_session"
            )
        }

        let action: ComputerUseAction
        do {
            action = try session.decodeAction(invocation: invocation, trustedPhoneOrigin: trustedPhoneOrigin)
        } catch {
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .error,
                denyReason: "invalid_arguments: \(String(describing: error))"
            )
        }

        let effectiveUsage: ComputerUseQuotaUsage
        do {
            effectiveUsage = try session.quotaLedger.reconcile(session.configuration.quotaUsage)
            session.configuration.quotaUsage = effectiveUsage
        } catch {
            session.lastDeniedReason = .auditFailure
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .denied,
                denyReason: ComputerUseDenyReason.auditFailure.rawValue,
                auditHeadHashHex: logger.headHashHex
            )
        }

        let beforeCapture = session.captureEvidence(
            label: "before-\(action.auditKind)",
            sessionId: sessionId,
            logger: logger
        )
        let scopeContext = session.scopeContext(for: action)
        let scopeOutcome = session.scopeMatcher.evaluate(
            rules: session.scopeRulesProvider(),
            context: scopeContext
        )
        let accessibilityDeny = session.accessibilityDeny(for: action)
        let originatedFromPhone = trustedPhoneOrigin
            && invocation.requestedBy.rawValue == "phone-control"
            && session.activeSessionIsDirectPhoneControl
        let phoneSessionFirstActionConfirmed = !originatedFromPhone || session.isPhoneFirstActionConfirmed()
        let capability = ComputerUseCapabilityContext(
            entitlement: session.configuration.entitlement,
            envelope: session.configuration.budgetEnvelope,
            usage: effectiveUsage,
            session: currentState,
            concurrentSessionActive: false,
            killSwitch: session.configuration.killSwitch,
            accessibilityTrusted: session.inputController.isAccessibilityTrusted(),
            originatedFromPhone: originatedFromPhone,
            phoneControlRespectsDenyRegions: session.configuration.phoneControlRespectsDenyRegions,
            phoneSessionFirstActionConfirmed: phoneSessionFirstActionConfirmed
        )

        switch session.gate.check(
            action: action,
            scopeOutcome: scopeOutcome,
            accessibilityDeny: accessibilityDeny,
            context: capability
        ) {
        case .denied(let reason):
            session.lastDeniedReason = reason
            let entry = session.appendAuditEntry(
                logger: logger,
                action: action,
                approvedBy: .denied,
                scopeRuleId: session.scopeRuleIfDenied(outcome: scopeOutcome),
                denyReason: reason.rawValue,
                scopeContext: scopeContext,
                beforeScreenshotHashHex: beforeCapture?.sha256Hex
            )
            currentState.actionsRejected += 1
            currentState.auditChainHeadHashHex = logger.headHashHex
            session.state = currentState
            let response = ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .denied,
                denyReason: reason.rawValue,
                auditEntryIndex: entry?.entryIndex,
                auditHeadHashHex: logger.headHashHex,
                meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
            )
            session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
            return response

        case .allowed(let approvedByCandidate):
            let needsPhoneFirstActionApproval = originatedFromPhone && !phoneSessionFirstActionConfirmed
            let approval: ApprovalDecision
            if approvedByCandidate == .trustedScope ||
                approvedByCandidate == .phone ||
                (session.isReadOnlyInspect(action: action) && !needsPhoneFirstActionApproval) {
                approval = ApprovalDecision(approvedBy: approvedByCandidate, approvalId: nil)
            } else if needsPhoneFirstActionApproval {
                let summary = action.executableSummary(forApproval: scopeContext)
                approval = await requestMacOnlyApproval(
                    toolKind: invocation.tool.rawValue,
                    title: "Approve phone control",
                    message: summary,
                    actionSummary: summary
                )
                switch approval.decision {
                case .approve:
                    session.markPhoneFirstActionConfirmed()
                case .reject, .rejectAndHalt:
                    session.lastDeniedReason = .userRejected
                    let entry = session.appendAuditEntry(
                        logger: logger,
                        action: action,
                        approvedBy: .denied,
                        scopeRuleId: session.scopeRuleIfDenied(outcome: scopeOutcome),
                        denyReason: ComputerUseDenyReason.userRejected.rawValue,
                        scopeContext: scopeContext,
                        beforeScreenshotHashHex: beforeCapture?.sha256Hex
                    )
                    currentState.actionsRejected += 1
                    currentState.auditChainHeadHashHex = logger.headHashHex
                    session.state = currentState
                    let response = ComputerUseInvokeResponse(
                        sessionId: sessionId.rawValue,
                        callID: invocation.callID,
                        status: .denied,
                        denyReason: ComputerUseDenyReason.userRejected.rawValue,
                        auditEntryIndex: entry?.entryIndex,
                        auditHeadHashHex: logger.headHashHex,
                        meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                    )
                    session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                    if approval.decision == .rejectAndHalt {
                        await panicHalt(source: .phoneGesture)
                    }
                    return response
                }
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
                    session.lastDeniedReason = .userRejected
                    let entry = session.appendAuditEntry(
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
                    session.state = currentState
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
                        auditHeadHashHex: logger.headHashHex,
                        meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                    )
                    session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                    return response
                }
            }

            // AUDIT-BEFORE-ACTION (fail-closed): reserve a pending audit
            // entry on the chain BEFORE dispatch. If the reservation append
            // throws we must NOT execute the action.
            let reservation: ComputerUseAuditEntry
            do {
                reservation = try session.reserveAuditEntry(
                    logger: logger,
                    action: action,
                    approvalId: approval.approvalId,
                    approvedBy: approval.approvedBy,
                    scopeRuleId: session.scopeRuleIfAllowed(outcome: scopeOutcome),
                    scopeContext: scopeContext,
                    beforeScreenshotHashHex: beforeCapture?.sha256Hex
                )
                currentState.auditChainHeadHashHex = logger.headHashHex
                session.state = currentState
            } catch {
                session.lastDeniedReason = .auditFailure
                currentState.actionsRejected += 1
                currentState.auditChainHeadHashHex = logger.headHashHex
                session.state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .denied,
                    approvalId: approval.approvalId,
                    denyReason: ComputerUseDenyReason.auditFailure.rawValue,
                    auditHeadHashHex: logger.headHashHex
                )
                session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: nil)
                return response
            }

            let actionClass: ComputerUseLocalQuotaLedger.ActionClass
            switch action {
            case .browser:
                actionClass = .browser
            case .macInput, .macInspect, .phoneIntent, .remoteClipboard:
                actionClass = .system
            }
            let exemptsMeteredCap = originatedFromPhone && {
                switch action {
                case .macInput, .phoneIntent, .remoteClipboard: return true
                case .browser, .macInspect: return false
                }
            }()
            var quotaReservationInserted = false
            do {
                let quotaReservation = try session.quotaLedger.reserveAction(
                    idempotencyKey: "\(sessionId.rawValue)|\(invocation.callID)",
                    actionClass: actionClass,
                    originatedFromPhone: originatedFromPhone,
                    exemptFromMeteredCap: exemptsMeteredCap,
                    authoritativeUsage: effectiveUsage,
                    maximumMeteredActions: session.configuration.budgetEnvelope.activeActionsPerDay
                )
                guard quotaReservation.inserted else {
                    let entry = session.appendAuditEntry(
                        logger: logger,
                        action: action,
                        approvalId: approval.approvalId,
                        approvedBy: .denied,
                        scopeRuleId: session.scopeRuleIfAllowed(outcome: scopeOutcome),
                        denyReason: ComputerUseDenyReason.counterReplay.rawValue,
                        scopeContext: scopeContext,
                        beforeScreenshotHashHex: beforeCapture?.sha256Hex
                    )
                    currentState.actionsRejected += 1
                    currentState.auditChainHeadHashHex = logger.headHashHex
                    session.state = currentState
                    let response = ComputerUseInvokeResponse(
                        sessionId: sessionId.rawValue,
                        callID: invocation.callID,
                        status: .denied,
                        approvalId: approval.approvalId,
                        denyReason: ComputerUseDenyReason.counterReplay.rawValue,
                        auditEntryIndex: entry?.entryIndex,
                        auditHeadHashHex: logger.headHashHex,
                        meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                    )
                    session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                    return response
                }
                quotaReservationInserted = true
                session.configuration.quotaUsage = quotaReservation.usage
            } catch {
                let reason: ComputerUseDenyReason = error as? ComputerUseLocalQuotaLedger.LedgerError == .quotaExceeded
                    ? .dailyLimit
                    : .auditFailure
                session.lastDeniedReason = reason
                let entry = session.appendAuditEntry(
                    logger: logger,
                    action: action,
                    approvalId: approval.approvalId,
                    approvedBy: .denied,
                    scopeRuleId: session.scopeRuleIfAllowed(outcome: scopeOutcome),
                    denyReason: reason.rawValue,
                    scopeContext: scopeContext,
                    beforeScreenshotHashHex: beforeCapture?.sha256Hex
                )
                currentState.actionsRejected += 1
                currentState.auditChainHeadHashHex = logger.headHashHex
                session.state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .denied,
                    approvalId: approval.approvalId,
                    denyReason: reason.rawValue,
                    auditEntryIndex: entry?.entryIndex,
                    auditHeadHashHex: logger.headHashHex,
                    meteringHeader: entry.map { ComputerUseActionMeteringHeader(auditEntry: $0) }
                )
                session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                return response
            }

            do {
                let result = try await dispatch(action: action, invocation: invocation)
                let afterCapture = session.captureEvidence(
                    label: "after-\(action.auditKind)",
                    sessionId: sessionId,
                    logger: logger
                )
                let entry = session.appendAuditEntry(
                    logger: logger,
                    action: action,
                    approvalId: approval.approvalId,
                    approvedBy: approval.approvedBy,
                    scopeRuleId: session.scopeRuleIfAllowed(outcome: scopeOutcome),
                    scopeContext: scopeContext,
                    beforeScreenshotHashHex: beforeCapture?.sha256Hex,
                    afterScreenshotHashHex: afterCapture?.sha256Hex
                ) ?? reservation
                currentState.actionsExecuted += 1
                currentState.lastActionAt = Date()
                currentState.auditChainHeadHashHex = logger.headHashHex
                session.state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .executed,
                    approvalId: approval.approvalId,
                    auditEntryIndex: entry.entryIndex,
                    auditHeadHashHex: logger.headHashHex,
                    meteringHeader: ComputerUseActionMeteringHeader(auditEntry: entry),
                    result: result
                )
                session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                return response
            } catch {
                if quotaReservationInserted {
                    do {
                        try session.quotaLedger.rollbackAction(
                            idempotencyKey: "\(sessionId.rawValue)|\(invocation.callID)",
                            actionClass: actionClass,
                            exemptFromMeteredCap: exemptsMeteredCap
                        )
                    } catch let rollbackError {
                        ComputerUseSessionCoordinator.log.error(
                            "computer_use_quota_reservation_rollback_failed reason=\(String(describing: rollbackError), privacy: .public)"
                        )
                    }
                }
                let afterCapture = session.captureEvidence(
                    label: "error-\(action.auditKind)",
                    sessionId: sessionId,
                    logger: logger
                )
                let entry = session.appendAuditEntry(
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
                session.state = currentState
                let response = ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .error,
                    approvalId: approval.approvalId,
                    denyReason: String(describing: error),
                    auditEntryIndex: entry.entryIndex,
                    auditHeadHashHex: logger.headHashHex,
                    meteringHeader: ComputerUseActionMeteringHeader(auditEntry: entry)
                )
                session.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
                return response
            }
        }
    }

    func requestApproval(
        invocation: BurnBarToolInvocation,
        action: ComputerUseAction,
        scopeContext: ComputerUseScopeContext,
        beforeScreenshotHashHex: String?
    ) async -> ApprovalDecision {
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: UUID().uuidString,
            runId: invocation.runID.rawValue,
            sessionId: session.activeSessionId?.rawValue ?? "",
            toolKind: invocation.tool.rawValue,
            title: action.executableSummary(forApproval: scopeContext),
            message: action.executableSummary(forApproval: scopeContext),
            beforeScreenshotBlake3: beforeScreenshotHashHex,
            actionSummary: action.executableSummary(forApproval: scopeContext),
            requestedAt: Date(),
            trustMode: (session.state?.liveTrustMode ?? .manual).rawValue
        )
        session.pendingApproval = request
        session.pendingApprovalScreenshotPNG = session.captureData(forHash: beforeScreenshotHashHex)
        session.appendTimeline(
            kind: invocation.tool.rawValue,
            summary: request.actionSummary,
            status: .awaitingApproval
        )

        let expectedRequestHashBlake3: String
        do {
            expectedRequestHashBlake3 = try ComputerUsePhoneControlSigner()
                .canonicalApprovalRequestHashHex(request: request)
        } catch {
            // Fail closed: an uncomputable expected hash is left empty, which the
            // PhoneControlAuthorityValidator now rejects outright — so a later
            // signed response cannot satisfy the request-binding check. Surface
            // why instead of silently weakening the binding to "".
            ComputerUseSessionCoordinator.log.error("computer_use_approval_request_hash_unavailable reason=\(String(describing: error), privacy: .public)")
            expectedRequestHashBlake3 = ""
        }
        let response = await withCheckedContinuation { continuation in
            session.approvalContinuations[request.approvalId] = continuation
            session.approvalContexts[request.approvalId] = ComputerUseSessionCoordinator.ApprovalContext(
                uid: session.latestControlUID,
                connectionID: session.latestControlConnectionID,
                sessionID: request.sessionId,
                requestedAt: request.requestedAt,
                requestHashBlake3: expectedRequestHashBlake3
            )
            session.emitControlFrame(
                type: .controlApprovalRequest,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.approval",
                    sessionId: request.sessionId,
                    approvalRequest: request
                )
            )
            Task { @MainActor in
                let presenterResponse = await session.approvalPresenter(request, session.pendingApprovalScreenshotPNG)
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

    func requestMacOnlyApproval(
        toolKind: String,
        title: String,
        message: String,
        actionSummary: String
    ) async -> ApprovalDecision {
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: UUID().uuidString,
            runId: session.activeSessionId?.rawValue ?? "mac-local-security-approval",
            sessionId: session.activeSessionId?.rawValue ?? "",
            toolKind: toolKind,
            title: title,
            message: message,
            beforeScreenshotBlake3: nil,
            actionSummary: actionSummary,
            requestedAt: Date(),
            trustMode: (session.state?.liveTrustMode ?? .manual).rawValue
        )
        session.pendingApproval = request
        session.pendingApprovalScreenshotPNG = nil
        session.appendTimeline(
            kind: toolKind,
            summary: actionSummary,
            status: .awaitingApproval
        )
        let response = await session.approvalPresenter(request, nil)
        if session.pendingApproval?.approvalId == request.approvalId {
            session.pendingApproval = nil
            session.pendingApprovalScreenshotPNG = nil
        }
        return ApprovalDecision(
            decision: response.decision,
            approvedBy: .mac,
            approvalId: response.approvalId
        )
    }

    func dispatch(
        action: ComputerUseAction,
        invocation: BurnBarToolInvocation
    ) async throws -> BurnBarToolResult {
        let output: BurnBarJSONValue
        switch action {
        case .browser(let browser):
            guard let browserDispatcher = session.browserDispatcher else { throw ComputerUseSessionCoordinator.CoordinatorError.missingBrowserDispatcher }
            output = try await browserDispatcher(browser)
        case .macInput(let input):
            if session.shouldUseVirtualHIDForLockedInput() {
                ComputerUseSessionCoordinator.log.info("mac_phone_action_virtual_hid_dispatch kind=\(input.kind.rawValue, privacy: .public)")
                ComputerUseSessionCoordinator.debugTrace("mac_phone_action_virtual_hid_dispatch kind=\(input.kind.rawValue)")
                let capability = try await session.mintVirtualHIDCapabilityDispatch(actionKind: input.kind.rawValue)
                output = try await RemoteUnlockVirtualHIDInputClient().dispatch(
                    input,
                    capabilityToken: capability.token,
                    presentingEscrowDeviceId: capability.presentingEscrowDeviceId,
                    requiredAttestationHashBlake3: capability.requiredAttestationHashBlake3
                )
            } else {
                output = try session.macDispatcher.dispatch(input)
            }
        case .macInspect(let inspect):
            output = try session.macDispatcher.inspect(inspect)
        case .remoteClipboard:
            throw ComputerUseSessionCoordinator.CoordinatorError.noActiveSession
        case .phoneIntent(let intent):
            if intent.kind == .panic {
                await panicHalt(source: .phoneGesture)
                output = .object(["ok": .bool(true), "kind": .string("panic")])
            } else if intent.kind == .setTrustMode {
                applyPhoneTrustModeIntent(intent)
                output = .object(["ok": .bool(true), "kind": .string("set_trust_mode")])
            } else {
                throw ComputerUseSessionCoordinator.CoordinatorError.noActiveSession
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
}

#endif
