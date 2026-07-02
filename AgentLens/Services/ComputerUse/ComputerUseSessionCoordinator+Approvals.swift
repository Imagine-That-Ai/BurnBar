#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

// Session lifecycle and approval-response flow.
// Extracted from ComputerUseSessionCoordinator.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ComputerUseSessionCoordinator {

    public func endSession(reason: ComputerUseEndReason = .completed) async {
        endSessionNow(reason: reason)
    }

    func endSessionNow(reason: ComputerUseEndReason = .completed) {
        guard activeSessionId != nil else { return }
        cancelPendingApprovals(decision: .reject, note: "session ended")
        finalizeAuditSignedHeadIfPossible()
        activeSessionId = nil
        // F2: controller authority is per-session — drop every admitted peer so
        // the next session must re-establish it via a fresh controlClassify
        // registration (pins, revocations, and replay counters persist).
        phoneValidator.deregisterAllPeers()
        // F10: seal sessions are per-classify; force re-establishment.
        controlSealSessions.removeAll()
        phoneReceiver = nil
        systemPermissionReceiver = nil
        SystemPermissionMonitor.shared.detach()
        focusFollowController?.stop()
        auditLogger = nil
        screenshotEvidenceDataByHash.removeAll()
        phoneFirstActionConfirmedSessionKeys.removeAll()
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
            do {
                let entry = try logger.makeEntry(
                    for: action,
                    approvedBy: .panic,
                    denyReason: source.rawValue,
                    macHostNodeId: configuration.macHostNodeId,
                    scopeContext: macDispatcher.currentScopeContext()
                )
                try logger.append(entry)
                state?.auditChainHeadHashHex = logger.headHashHex
            } catch {
                // A dropped panic-halt entry is a gap in the tamper-evident audit
                // chain — surface it instead of swallowing; the halt still proceeds.
                Self.log.error("computer_use_panic_audit_entry_failed reason=\(String(describing: error), privacy: .public)")
            }
            finalizeAuditSignedHeadIfPossible()
        }
        activeSessionId = nil
        phoneValidator.deregisterAllPeers()
        controlSealSessions.removeAll()
        phoneReceiver = nil
        systemPermissionReceiver = nil
        SystemPermissionMonitor.shared.detach()
        focusFollowController?.stop()
        auditLogger = nil
        screenshotEvidenceDataByHash.removeAll()
        phoneFirstActionConfirmedSessionKeys.removeAll()
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

    func finalizeAuditSignedHeadIfPossible() {
        guard let logger = auditLogger else { return }
        let legacyKey = OpenBurnBarAppPaths.live().supportDirectory
            .appendingPathComponent("computer-use-audit", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("audit-export-ed25519.raw", isDirectory: false)
        do {
            let signer = try ComputerUseKeychainAuditExportSignerProvider(legacyRawKeyURL: legacyKey).signer()
            try ComputerUseAuditHeadFinalizer.finalize(logger: logger, signer: signer)
        } catch {
            // An unsigned audit head loses its tamper-evidence guarantee — make
            // a missing/inaccessible signer or a failed finalize observable.
            Self.log.error("computer_use_audit_head_finalize_failed reason=\(String(describing: error), privacy: .public)")
        }
    }

    func haltForBudgetHardCap() {
        guard activeSessionId != nil else { return }
        PrivilegedInputKillSwitch.activate(reason: ComputerUseDenyReason.hardCap.rawValue)
        cancelPendingApprovals(decision: .rejectAndHalt, note: "budget hard cap")
        if let logger = auditLogger {
            let action: ComputerUseAction = .macInspect(MacInspectAction(kind: .accessibility))
            do {
                let entry = try logger.makeEntry(
                    for: action,
                    approvedBy: .panic,
                    denyReason: ComputerUseDenyReason.hardCap.rawValue,
                    macHostNodeId: configuration.macHostNodeId,
                    scopeContext: macDispatcher.currentScopeContext()
                )
                try logger.append(entry)
                state?.auditChainHeadHashHex = logger.headHashHex
            } catch {
                // A dropped hard-cap entry is a gap in the tamper-evident audit
                // chain — surface it instead of swallowing; the halt still proceeds.
                Self.log.error("computer_use_hardcap_audit_entry_failed reason=\(String(describing: error), privacy: .public)")
            }
        }
        activeSessionId = nil
        phoneReceiver = nil
        focusFollowController?.stop()
        auditLogger = nil
        screenshotEvidenceDataByHash.removeAll()
        phoneFirstActionConfirmedSessionKeys.removeAll()
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
        // R-L5 (Computer Use safety): while a session is LIVE, trust is
        // downgrade-only. A running session may only *lower* trust
        // (trusted -> step -> manual) — never elevate mid-session — because
        // ComputerUseCapabilityGate treats `.trusted` as auto-allow for scoped
        // actions, so a mid-session elevation is a silent privilege escalation.
        // Elevation requires starting a fresh session. Mirrors the phone-path
        // guard in AgentWatchReceiver.downgradeTrustMode
        // ('guard mode <= liveTrustMode').
        //
        // Once a session ends, `activeSessionId` is cleared but `state` is left
        // populated (it seeds the *next* session's trust). In that no-active-
        // session window the Mac UI is the legitimate elevation surface —
        // trust is chosen per session (Decision 2) — so any selection, raise
        // included, is allowed. Gate the clamp on the same `activeSessionId`
        // liveness signal every teardown path in this file guards on.
        if activeSessionId != nil {
            guard mode <= current.liveTrustMode else { return }
        }
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

    func submitApprovalResponse(
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
            guard let authority = response.authority else {
                Self.log.warning("Rejected remote approval response without a signed authority envelope.")
                return
            }
            do {
                _ = try phoneValidator.validate(
                    envelope: authority,
                    approvalResponse: response,
                    expectedRequestHashBlake3: context.requestHashBlake3,
                    now: Date()
                )
            } catch {
                Self.log.warning("Rejected remote approval response with invalid authority: \(String(describing: error), privacy: .public)")
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
        await invoke(invocation, trustedPhoneOrigin: false)
    }

    func invokeTrustedPhoneControlAction(_ invocation: BurnBarToolInvocation) async -> ComputerUseInvokeResponse {
        await invoke(invocation, trustedPhoneOrigin: true)
    }

    private func invoke(
        _ invocation: BurnBarToolInvocation,
        trustedPhoneOrigin: Bool
    ) async -> ComputerUseInvokeResponse {
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
            action = try decodeAction(invocation: invocation, trustedPhoneOrigin: trustedPhoneOrigin)
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
        let originatedFromPhone = trustedPhoneOrigin
            && invocation.requestedBy.rawValue == "phone-control"
            && activeSessionIsDirectPhoneControl
        let phoneSessionFirstActionConfirmed = !originatedFromPhone || isPhoneFirstActionConfirmed()
        let capability = ComputerUseCapabilityContext(
            entitlement: configuration.entitlement,
            envelope: configuration.budgetEnvelope,
            usage: configuration.quotaUsage,
            session: currentState,
            concurrentSessionActive: false,
            killSwitch: configuration.killSwitch,
            accessibilityTrusted: inputController.isAccessibilityTrusted(),
            originatedFromPhone: originatedFromPhone,
            phoneControlRespectsDenyRegions: configuration.phoneControlRespectsDenyRegions,
            phoneSessionFirstActionConfirmed: phoneSessionFirstActionConfirmed
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
            let needsPhoneFirstActionApproval = originatedFromPhone && !phoneSessionFirstActionConfirmed
            let approval: ApprovalDecision
            if approvedByCandidate == .trustedScope ||
                approvedByCandidate == .phone ||
                (isReadOnlyInspect(action: action) && !needsPhoneFirstActionApproval) {
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
                    markPhoneFirstActionConfirmed()
                case .reject, .rejectAndHalt:
                    lastDeniedReason = .userRejected
                    let entry = appendAuditEntry(
                        logger: logger,
                        action: action,
                        approvedBy: .denied,
                        scopeRuleId: scopeRuleIfDenied(outcome: scopeOutcome),
                        denyReason: ComputerUseDenyReason.userRejected.rawValue,
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
                        denyReason: ComputerUseDenyReason.userRejected.rawValue,
                        auditEntryIndex: entry?.entryIndex,
                        auditHeadHashHex: logger.headHashHex
                    )
                    appendTimeline(for: action, invocation: invocation, response: response, auditEntry: entry)
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

    func requestApproval(
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

        let expectedRequestHashBlake3: String
        do {
            expectedRequestHashBlake3 = try ComputerUsePhoneControlSigner()
                .canonicalApprovalRequestHashHex(request: request)
        } catch {
            // Fail closed: an uncomputable expected hash is left empty, which the
            // PhoneControlAuthorityValidator now rejects outright — so a later
            // signed response cannot satisfy the request-binding check. Surface
            // why instead of silently weakening the binding to "".
            Self.log.error("computer_use_approval_request_hash_unavailable reason=\(String(describing: error), privacy: .public)")
            expectedRequestHashBlake3 = ""
        }
        let response = await withCheckedContinuation { continuation in
            approvalContinuations[request.approvalId] = continuation
            approvalContexts[request.approvalId] = ApprovalContext(
                uid: latestControlUID,
                connectionID: latestControlConnectionID,
                sessionID: request.sessionId,
                requestedAt: request.requestedAt,
                requestHashBlake3: expectedRequestHashBlake3
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

    func requestMacOnlyApproval(
        toolKind: String,
        title: String,
        message: String,
        actionSummary: String
    ) async -> ApprovalDecision {
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: UUID().uuidString,
            runId: activeSessionId?.rawValue ?? "mac-local-security-approval",
            sessionId: activeSessionId?.rawValue ?? "",
            toolKind: toolKind,
            title: title,
            message: message,
            beforeScreenshotBlake3: nil,
            actionSummary: actionSummary,
            requestedAt: Date(),
            trustMode: (state?.liveTrustMode ?? .manual).rawValue
        )
        pendingApproval = request
        pendingApprovalScreenshotPNG = nil
        appendTimeline(
            kind: toolKind,
            summary: actionSummary,
            status: .awaitingApproval
        )
        let response = await approvalPresenter(request, nil)
        if pendingApproval?.approvalId == request.approvalId {
            pendingApproval = nil
            pendingApprovalScreenshotPNG = nil
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
            guard let browserDispatcher else { throw CoordinatorError.missingBrowserDispatcher }
            output = try await browserDispatcher(browser)
        case .macInput(let input):
            if shouldUseVirtualHIDForLockedInput() {
                Self.log.info("mac_phone_action_virtual_hid_dispatch kind=\(input.kind.rawValue, privacy: .public)")
                Self.debugTrace("mac_phone_action_virtual_hid_dispatch kind=\(input.kind.rawValue)")
                let capability = try await mintVirtualHIDCapabilityDispatch(actionKind: input.kind.rawValue)
                output = try await RemoteUnlockVirtualHIDInputClient().dispatch(
                    input,
                    capabilityToken: capability.token,
                    presentingEscrowDeviceId: capability.presentingEscrowDeviceId,
                    requiredAttestationHashBlake3: capability.requiredAttestationHashBlake3
                )
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
}

#endif
