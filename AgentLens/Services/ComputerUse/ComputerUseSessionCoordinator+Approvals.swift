#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

// Approval/lifecycle forwards onto ComputerUseApprovalPipeline.

extension ComputerUseSessionCoordinator {
    public func endSession(reason: ComputerUseEndReason = .completed) async {
        await approvalPipeline.endSession(reason: reason)
    }

    func endSessionNow(reason: ComputerUseEndReason = .completed) {
        approvalPipeline.endSessionNow(reason: reason)
    }

    public func panicHalt(source: ComputerUsePanicSource) async {
        await approvalPipeline.panicHalt(source: source)
    }

    func finalizeAuditSignedHeadIfPossible() {
        approvalPipeline.finalizeAuditSignedHeadIfPossible()
    }

    func haltForBudgetHardCap() {
        approvalPipeline.haltForBudgetHardCap()
    }

    func applyPhoneTrustModeIntent(_ intent: PhoneControlIntent) {
        approvalPipeline.applyPhoneTrustModeIntent(intent)
    }

    public func setTrustMode(_ mode: ComputerUseTrustMode) {
        approvalPipeline.setTrustMode(mode)
    }

    func setRemoteUnlockResultHandler(
        _ handler: (@MainActor @Sendable (HermesRealtimeRelayRemoteUnlockResult) async -> Void)?
    ) {
        approvalPipeline.setRemoteUnlockResultHandler(handler)
    }

    public func submitApprovalResponse(_ response: HermesRealtimeRelayApprovalResponse) {
        approvalPipeline.submitApprovalResponse(response)
    }

    func submitApprovalResponse(
        _ response: HermesRealtimeRelayApprovalResponse,
        source: ApprovalResponseSource
    ) {
        approvalPipeline.submitApprovalResponse(response, source: source)
    }

    public func invoke(_ invocation: BurnBarToolInvocation) async -> ComputerUseInvokeResponse {
        return await approvalPipeline.invoke(invocation)
    }

    func invokeTrustedPhoneControlAction(_ invocation: BurnBarToolInvocation) async -> ComputerUseInvokeResponse {
        return await approvalPipeline.invokeTrustedPhoneControlAction(invocation)
    }

    func requestApproval(
        invocation: BurnBarToolInvocation,
        action: ComputerUseAction,
        scopeContext: ComputerUseScopeContext,
        beforeScreenshotHashHex: String?
    ) async -> ApprovalDecision {
        return await approvalPipeline.requestApproval(invocation: invocation, action: action, scopeContext: scopeContext, beforeScreenshotHashHex: beforeScreenshotHashHex)
    }

    func requestMacOnlyApproval(
        toolKind: String,
        title: String,
        message: String,
        actionSummary: String
    ) async -> ApprovalDecision {
        return await approvalPipeline.requestMacOnlyApproval(toolKind: toolKind, title: title, message: message, actionSummary: actionSummary)
    }

    func dispatch(
        action: ComputerUseAction,
        invocation: BurnBarToolInvocation
    ) async throws -> BurnBarToolResult {
        return try await approvalPipeline.dispatch(action: action, invocation: invocation)
    }

}

#endif
