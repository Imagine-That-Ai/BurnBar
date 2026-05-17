import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

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

    private struct ActiveSession {
        var state: ComputerUseSessionState
        var logger: ComputerUseAuditLogger
        var driver: OpenBurnBarPlaywrightDriver?
        var stepBurstApproval: StepBurstApproval?
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
    private let macAppVersion: String
    private let auditBaseDirectory: URL
    private let logger: BurnBarDaemonLogger
    private var sessions: [ComputerUseSessionID: ActiveSession] = [:]

    public init(
        gate: ComputerUseCapabilityGate = DefaultComputerUseCapabilityGate(),
        approvalIssuer: @escaping ApprovalIssuer,
        macInputDispatcher: MacInputDispatcher? = nil,
        macInspectDispatcher: MacInspectDispatcher? = nil,
        macAppVersion: String,
        auditBaseDirectory: URL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-coordinator")
    ) {
        self.gate = gate
        self.approvalIssuer = approvalIssuer
        self.macInputDispatcher = macInputDispatcher
        self.macInspectDispatcher = macInspectDispatcher
        self.macAppVersion = macAppVersion
        self.auditBaseDirectory = auditBaseDirectory
        self.logger = logger
    }

    // MARK: Session lifecycle

    public func startSession(
        manifest: ComputerUseSessionManifest,
        playwrightDriver: OpenBurnBarPlaywrightDriver? = nil
    ) async throws -> String {
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
        sessions[manifest.sessionId] = ActiveSession(
            state: state,
            logger: auditLogger,
            driver: playwrightDriver
        )
        try await playwrightDriver?.start()
        return auditLogger.headHashHex
    }

    public func endSession(
        sessionId: ComputerUseSessionID,
        reason: ComputerUseEndReason
    ) async {
        guard var active = sessions[sessionId] else { return }
        await active.driver?.stop()
        active.state.endReason = reason
        active.state.endedAt = Date()
        sessions[sessionId] = active
        sessions.removeValue(forKey: sessionId)
    }

    public func panicHalt(
        sessionId: ComputerUseSessionID,
        source: ComputerUsePanicSource
    ) async {
        guard sessions[sessionId] != nil else { return }
        let endReason: ComputerUseEndReason
        switch source {
        case .hotkey: endReason = .panicHotkey
        case .phoneGesture: endReason = .panicPhoneGesture
        case .macLock: endReason = .panicMacLock
        case .remoteConfig: endReason = .panicRemoteConfig
        case .accessibilityRevoked: endReason = .panicAccessibilityRevoked
        case .stalled: endReason = .timeout
        }
        if let active = sessions[sessionId] {
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
        }
        await endSession(sessionId: sessionId, reason: endReason)
    }

    @discardableResult
    public func panicHaltAll(source: ComputerUsePanicSource) async -> [ComputerUseSessionID] {
        let activeSessionIds = Array(sessions.keys)
        for sessionId in activeSessionIds {
            await panicHalt(sessionId: sessionId, source: source)
        }
        return activeSessionIds
    }

    public func session(_ id: ComputerUseSessionID) -> ComputerUseSessionState? {
        sessions[id]?.state
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
        guard var active = sessions[sessionId] else {
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .error,
                denyReason: "unknown_session"
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

        let gateOutcome = gate.check(
            action: action,
            scopeOutcome: scopeOutcome,
            accessibilityDeny: accessibilityDeny,
            context: capability
        )

        switch gateOutcome {
        case .denied(let reason):
            let entry: ComputerUseAuditEntry
            do {
                entry = try active.logger.makeEntry(
                    for: action,
                    approvedBy: .denied,
                    scopeRuleId: scopeRuleIfDenied(outcome: scopeOutcome),
                    denyReason: reason.rawValue,
                    scopeContext: scopeContext
                )
                try active.logger.append(entry)
                active.state.actionsRejected += 1
                sessions[sessionId] = active
            } catch {
                logger.warning("audit_append_failed", metadata: [
                    "session": sessionId.rawValue,
                    "error": String(describing: error)
                ])
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .error,
                    denyReason: reason.rawValue
                )
            }
            return ComputerUseInvokeResponse(
                sessionId: sessionId.rawValue,
                callID: invocation.callID,
                status: .denied,
                denyReason: reason.rawValue,
                auditEntryIndex: entry.entryIndex,
                auditHeadHashHex: active.logger.headHashHex
            )

        case .allowed(let approvedByCandidate):
            // Trusted-scope rules grant automatic approval — no sheet.
            // Manual / Step modes need an explicit approval unless the
            // action is purely read-only (mac.inspect).
            let approvedBy: ComputerUseAuditEntry.ApprovedBy
            var approvalId: String? = nil
            if approvedByCandidate == .trustedScope {
                approvedBy = .trustedScope
            } else if isReadOnlyInspect(action: action) {
                approvedBy = .mac
            } else if let burst = consumeStepBurstApproval(
                for: action,
                scopeContext: scopeContext,
                active: &active,
                now: Date()
            ) {
                approvedBy = burst.approvedBy
                approvalId = burst.approvalId
            } else {
                // Raise the approval. Wait for resolution.
                let request = HermesRealtimeRelayApprovalRequest(
                    approvalId: UUID().uuidString,
                    runId: invocation.runID.rawValue,
                    sessionId: sessionId.rawValue,
                    toolKind: invocation.tool.rawValue,
                    title: action.executableSummary(forApproval: scopeContext),
                    message: action.executableSummary(forApproval: scopeContext),
                    actionSummary: action.executableSummary(forApproval: scopeContext),
                    requestedAt: Date(),
                    trustMode: active.state.liveTrustMode.rawValue
                )
                do {
                    let response = try await approvalIssuer(request)
                    switch response.decision {
                    case .approve:
                        approvedBy = response.respondedBy == "phone" ? .phone : .mac
                        approvalId = response.approvalId
                        if shouldOpenStepBurst(from: response, active: active) {
                            active.stepBurstApproval = StepBurstApproval(
                                actionSignature: stepBurstSignature(for: action, scopeContext: scopeContext),
                                approvedBy: approvedBy,
                                approvalId: response.approvalId,
                                remainingActions: 9,
                                expiresAt: Date().addingTimeInterval(30)
                            )
                        }
                    case .reject, .rejectAndHalt:
                        let entry = try? active.logger.makeEntry(
                            for: action,
                            approvedBy: .denied,
                            denyReason: ComputerUseDenyReason.userRejected.rawValue,
                            scopeContext: scopeContext
                        )
                        if let entry { _ = try? active.logger.append(entry) }
                        active.state.actionsRejected += 1
                        sessions[sessionId] = active
                        if response.decision == .rejectAndHalt {
                            await panicHalt(sessionId: sessionId, source: .stalled)
                        }
                        return ComputerUseInvokeResponse(
                            sessionId: sessionId.rawValue,
                            callID: invocation.callID,
                            status: .denied,
                            denyReason: ComputerUseDenyReason.userRejected.rawValue,
                            auditEntryIndex: entry?.entryIndex,
                            auditHeadHashHex: active.logger.headHashHex
                        )
                    }
                } catch {
                    return ComputerUseInvokeResponse(
                        sessionId: sessionId.rawValue,
                        callID: invocation.callID,
                        status: .error,
                        denyReason: "approval_failed: \(error.localizedDescription)"
                    )
                }
            }

            // Dispatch.
            let result: BurnBarToolResult
            do {
                result = try await dispatch(
                    sessionId: sessionId,
                    invocation: invocation,
                    action: action,
                    activeDriver: active.driver
                )
            } catch {
                let failureEntry = try? active.logger.makeEntry(
                    for: action,
                    approvalId: approvalId,
                    approvedBy: approvedBy,
                    denyReason: String(describing: error),
                    scopeContext: scopeContext
                )
                if let failureEntry { _ = try? active.logger.append(failureEntry) }
                active.state.actionsRejected += 1
                sessions[sessionId] = active
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .error,
                    approvalId: approvalId,
                    denyReason: String(describing: error),
                    auditEntryIndex: failureEntry?.entryIndex,
                    auditHeadHashHex: active.logger.headHashHex
                )
            }

            do {
                let entry = try active.logger.makeEntry(
                    for: action,
                    approvalId: approvalId,
                    approvedBy: approvedBy,
                    scopeRuleId: scopeRuleIfAllowed(outcome: scopeOutcome),
                    scopeContext: scopeContext
                )
                try active.logger.append(entry)
                active.state.actionsExecuted += 1
                active.state.lastActionAt = Date()
                sessions[sessionId] = active
                return ComputerUseInvokeResponse(
                    sessionId: sessionId.rawValue,
                    callID: invocation.callID,
                    status: .executed,
                    approvalId: approvalId,
                    auditEntryIndex: entry.entryIndex,
                    auditHeadHashHex: active.logger.headHashHex,
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

    private func decodeMacInput(invocation: BurnBarToolInvocation, kind: MacInputAction.Kind) throws -> MacInputAction {
        MacInputAction(
            kind: kind,
            displayX: intArgument(invocation, key: "displayX"),
            displayY: intArgument(invocation, key: "displayY"),
            dragEndX: intArgument(invocation, key: "dragEndX"),
            dragEndY: intArgument(invocation, key: "dragEndY"),
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

    private func isReadOnlyInspect(action: ComputerUseAction) -> Bool {
        if case .macInspect = action { return true }
        return false
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
                coordinateSignature(x: action.dragEndX, y: action.dragEndY)
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
        }
    }

    private func browserHost(from url: String) -> String? {
        URL(string: url)?.host?.lowercased()
    }

    private func coordinateSignature(x: Int?, y: Int?) -> String {
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
        }
    }

    private func dispatch(
        browser action: BrowserAction,
        on driver: OpenBurnBarPlaywrightDriver
    ) async throws -> OpenBurnBarPlaywrightDriver.Response {
        switch action.kind {
        case .click:
            return try await driver.click(
                selector: action.selector,
                positionX: action.positionX,
                positionY: action.positionY,
                timeoutMillis: action.timeoutMillis
            )
        case .fill:
            guard let selector = action.selector, let text = action.text else {
                throw DispatchError.invalidArguments("fill requires selector and text")
            }
            return try await driver.fill(selector: selector, text: text, timeoutMillis: action.timeoutMillis)
        case .goto:
            guard let url = action.url else {
                throw DispatchError.invalidArguments("goto requires url")
            }
            return try await driver.goto(url: url, timeoutMillis: action.timeoutMillis)
        case .key:
            guard let key = action.key else {
                throw DispatchError.invalidArguments("key requires key")
            }
            return try await driver.key(key)
        case .select:
            guard let selector = action.selector, let value = action.value else {
                throw DispatchError.invalidArguments("select requires selector and value")
            }
            return try await driver.select(selector: selector, value: value)
        case .screenshot:
            return try await driver.screenshot()
        case .extract:
            return try await driver.extract(selector: action.selector)
        }
    }
}
