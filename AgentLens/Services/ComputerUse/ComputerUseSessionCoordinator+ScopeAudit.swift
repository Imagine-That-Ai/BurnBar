#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

// Audit/scope forwards onto ComputerUseAuditPipeline.

extension ComputerUseSessionCoordinator {
    func remoteClipboardTimelineSummary(
        for response: HermesRealtimeRelayClipboardResponse,
        action: ComputerUseAction
    ) -> String {
        return auditPipeline.remoteClipboardTimelineSummary(for: response, action: action)
    }

    func phoneControlAttestationRequirement() async -> PhoneControlAttestationRequirement {
        return await auditPipeline.phoneControlAttestationRequirement()
    }

    func controlDeniedReason(for denyReason: String) -> HermesRealtimeRelayControlDenied.Reason {
        return auditPipeline.controlDeniedReason(for: denyReason)
    }

    func invocationFromPhoneAction(
        _ action: ComputerUseAction,
        sessionId: ComputerUseSessionID
    ) -> BurnBarToolInvocation {
        return auditPipeline.invocationFromPhoneAction(action, sessionId: sessionId)
    }

    func decodeAction(
        invocation: BurnBarToolInvocation,
        trustedPhoneOrigin: Bool = false
    ) throws -> ComputerUseAction {
        return try auditPipeline.decodeAction(invocation: invocation, trustedPhoneOrigin: trustedPhoneOrigin)
    }

    func decodeMacInput(
        invocation: BurnBarToolInvocation,
        kind: MacInputAction.Kind,
        trustedPhoneOrigin: Bool = false
    ) throws -> MacInputAction {
        return try auditPipeline.decodeMacInput(invocation: invocation, kind: kind, trustedPhoneOrigin: trustedPhoneOrigin)
    }

    func scopeContext(for action: ComputerUseAction) -> ComputerUseScopeContext {
        return auditPipeline.scopeContext(for: action)
    }

    func accessibilityDeny(for action: ComputerUseAction) -> ComputerUseAccessibilityDenyReason? {
        return auditPipeline.accessibilityDeny(for: action)
    }

    func reserveAuditEntry(
        logger: ComputerUseAuditLogger,
        action: ComputerUseAction,
        approvalId: String?,
        approvedBy: ComputerUseAuditEntry.ApprovedBy,
        scopeRuleId: String?,
        scopeContext: ComputerUseScopeContext?,
        beforeScreenshotHashHex: String?
    ) throws -> ComputerUseAuditEntry {
        return try auditPipeline.reserveAuditEntry(logger: logger, action: action, approvalId: approvalId, approvedBy: approvedBy, scopeRuleId: scopeRuleId, scopeContext: scopeContext, beforeScreenshotHashHex: beforeScreenshotHashHex)
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
        return auditPipeline.appendAuditEntry(logger: logger, action: action, approvalId: approvalId, approvedBy: approvedBy, scopeRuleId: scopeRuleId, denyReason: denyReason, scopeContext: scopeContext, beforeScreenshotHashHex: beforeScreenshotHashHex, afterScreenshotHashHex: afterScreenshotHashHex)
    }

    func captureEvidence(
        label: String,
        sessionId: ComputerUseSessionID,
        logger: ComputerUseAuditLogger
    ) -> MacScreenshotService.Capture? {
        return auditPipeline.captureEvidence(label: label, sessionId: sessionId, logger: logger)
    }

    func captureData(forHash hash: String?) -> Data? {
        return auditPipeline.captureData(forHash: hash)
    }

    func macInputArguments(_ action: MacInputAction) -> BurnBarJSONValue {
        return auditPipeline.macInputArguments(action)
    }

    func scopeRuleIfAllowed(outcome: ComputerUseScopeOutcome) -> String? {
        return auditPipeline.scopeRuleIfAllowed(outcome: outcome)
    }

    func scopeRuleIfDenied(outcome: ComputerUseScopeOutcome) -> String? {
        return auditPipeline.scopeRuleIfDenied(outcome: outcome)
    }

    func isReadOnlyInspect(action: ComputerUseAction) -> Bool {
        return auditPipeline.isReadOnlyInspect(action: action)
    }

    func endReason(for source: ComputerUsePanicSource) -> ComputerUseEndReason {
        return auditPipeline.endReason(for: source)
    }

    func appendTimeline(
        for action: ComputerUseAction,
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse,
        auditEntry: ComputerUseAuditEntry?
    ) {
        auditPipeline.appendTimeline(for: action, invocation: invocation, response: response, auditEntry: auditEntry)
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
        auditPipeline.appendTimeline(kind: kind, summary: summary, status: status, entryIndex: entryIndex, screenshotHashBlake3: screenshotHashBlake3, parentEntryBlake3: parentEntryBlake3, errorCategory: errorCategory)
    }

    func emitControlFrame(
        type: HermesRealtimeRelayFrameType,
        payload: HermesRealtimeRelayControlPayload
    ) {
        auditPipeline.emitControlFrame(type: type, payload: payload)
    }

    func sendControlFrame(
        type: HermesRealtimeRelayFrameType,
        payload: HermesRealtimeRelayControlPayload
    ) async throws {
        try await auditPipeline.sendControlFrame(type: type, payload: payload)
    }

    func emitFocusContext(_ context: HermesRealtimeRelayFocusContext) {
        auditPipeline.emitFocusContext(context)
    }

    func cancelPendingApprovals(
        decision: HermesRealtimeRelayApprovalResponse.Decision,
        note: String
    ) {
        auditPipeline.cancelPendingApprovals(decision: decision, note: note)
    }

}

#endif
