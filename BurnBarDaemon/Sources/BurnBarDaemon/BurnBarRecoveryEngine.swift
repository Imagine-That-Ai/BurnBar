import BurnBarCore
import Foundation

public struct BurnBarRecoveryEngine {
    private let policyEngine: BurnBarPolicyEngine

    public init(policyEngine: BurnBarPolicyEngine = BurnBarPolicyEngine()) {
        self.policyEngine = policyEngine
    }

    public func decide(
        for error: BurnBarToolExecutionError,
        toolCall: BurnBarToolCallSnapshot,
        attempt: Int
    ) -> BurnBarRecoveryDecision {
        switch error.code {
        case .trustGated, .noWorkspace, .remoteUnsupported:
            return BurnBarRecoveryDecision(
                action: .requestApproval,
                reason: "workspace_policy_gate",
                userMessage: error.message
            )
        case .applyFailed, .terminalFailed, .unknown:
            let reason = policyEngine.isRetryable(error) && attempt < 2
                ? "retryable_tool_failure"
                : "terminal_tool_failure"
            return BurnBarRecoveryDecision(
                action: policyEngine.isRetryable(error) && attempt < 2 ? .retryTool : .failRun,
                reason: reason,
                userMessage: error.message
            )
        }
    }

    public func decideLoopFailure(_ error: Error) -> BurnBarRecoveryDecision {
        BurnBarRecoveryDecision(
            action: .failRun,
            reason: "agent_loop_failure",
            userMessage: error.localizedDescription
        )
    }
}
