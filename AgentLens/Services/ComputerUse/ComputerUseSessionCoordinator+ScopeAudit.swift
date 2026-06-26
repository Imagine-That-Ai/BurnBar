#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

// Clipboard timeline, scope context, mac input args, and audit timeline.
// Extracted from ComputerUseSessionCoordinator.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ComputerUseSessionCoordinator {

    func remoteClipboardTimelineSummary(
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

    func phoneControlAttestationRequirement() async -> PhoneControlAttestationRequirement {
        let strict = configuration.phoneControlAttestationRequired
        return await MacAppCheckAttestationReader.attestationRequirement(strictMode: strict)
    }

    func controlDeniedReason(for denyReason: String) -> HermesRealtimeRelayControlDenied.Reason {
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

    func invocationFromPhoneAction(
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
            case .pointerClick: tool = .macInputClick
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

    func decodeAction(
        invocation: BurnBarToolInvocation,
        trustedPhoneOrigin: Bool = false
    ) throws -> ComputerUseAction {
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
            return .macInput(try decodeMacInput(
                invocation: invocation,
                kind: .click,
                trustedPhoneOrigin: trustedPhoneOrigin
            ))
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

    func decodeMacInput(
        invocation: BurnBarToolInvocation,
        kind: MacInputAction.Kind,
        trustedPhoneOrigin: Bool = false
    ) throws -> MacInputAction {
        guard case let .object(arguments) = invocation.arguments else {
            return MacInputAction(kind: kind)
        }
        let decodedKind: MacInputAction.Kind
        if kind == .click,
           trustedPhoneOrigin,
           invocation.requestedBy.rawValue == "phone-control",
           case let .object(arguments) = invocation.arguments,
           arguments.stringValue(forKey: "kind") == MacInputAction.Kind.pointerClick.rawValue {
            decodedKind = .pointerClick
        } else {
            decodedKind = kind
        }

        return MacInputAction(
            kind: decodedKind,
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

    func scopeContext(for action: ComputerUseAction) -> ComputerUseScopeContext {
        switch action {
        case .browser(let browser):
            if let url = browser.url { return ComputerUseScopeContext(url: url) }
            return macDispatcher.currentScopeContext()
        case .macInput, .macInspect, .phoneIntent, .remoteClipboard:
            return macDispatcher.currentScopeContext()
        }
    }

    func accessibilityDeny(for action: ComputerUseAction) -> ComputerUseAccessibilityDenyReason? {
        guard case .macInput(let input) = action else { return nil }
        return macDispatcher.accessibilityDenyReason(at: input)
    }

    /// Reserve a pending audit entry on the chain BEFORE the action runs.
    /// Throws if the chain append fails so the caller can fail closed and
    /// abort dispatch. The reservation is marked with the
    /// `audit_reserved_pending` sentinel denyReason; the post-dispatch
    /// completion entry carries the real outcome.
    func reserveAuditEntry(
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

    func appendAuditEntry(
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

    func captureEvidence(
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

    func captureData(forHash hash: String?) -> Data? {
        guard let hash else { return nil }
        return screenshotEvidenceDataByHash[hash]
    }

    func macInputArguments(_ action: MacInputAction) -> BurnBarJSONValue {
        var object: [String: BurnBarJSONValue] = [:]
        if let displayX = action.displayX { object["displayX"] = .number(Double(displayX)) }
        if let displayY = action.displayY { object["displayY"] = .number(Double(displayY)) }
        if let dragEndX = action.dragEndX { object["dragEndX"] = .number(Double(dragEndX)) }
        if let dragEndY = action.dragEndY { object["dragEndY"] = .number(Double(dragEndY)) }
        if let deltaX = action.deltaX { object["deltaX"] = .number(Double(deltaX)) }
        if let deltaY = action.deltaY { object["deltaY"] = .number(Double(deltaY)) }
        if action.kind == .pointerClick { object["kind"] = .string(action.kind.rawValue) }
        object["mouseButton"] = .number(Double(action.mouseButton))
        if let text = action.text { object["text"] = .string(text) }
        if let key = action.key { object["key"] = .string(key) }
        if let modifiers = action.modifiers { object["modifiers"] = .array(modifiers.map { .string($0) }) }
        return .object(object)
    }

    func scopeRuleIfAllowed(outcome: ComputerUseScopeOutcome) -> String? {
        if case let .allowed(rule) = outcome { return rule.rawValue }
        return nil
    }

    func scopeRuleIfDenied(outcome: ComputerUseScopeOutcome) -> String? {
        if case let .denied(rule) = outcome { return rule.rawValue }
        return nil
    }

    func isReadOnlyInspect(action: ComputerUseAction) -> Bool {
        if case .macInspect = action { return true }
        return false
    }

    func endReason(for source: ComputerUsePanicSource) -> ComputerUseEndReason {
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

    func appendTimeline(
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

    func appendTimeline(
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

    func emitControlFrame(
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
            try? await latestReplySender(frame) // try?-ok(fire-and-forget control frame)
        }
    }

    func sendControlFrame(
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
            try? await latestReplySender(frame) // try?-ok(fire-and-forget focus frame)
        }
    }

    func cancelPendingApprovals(
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
