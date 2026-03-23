import BurnBarCore
import Foundation

public enum BurnBarToolRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high
}

public struct BurnBarApprovalDescriptor: Hashable, Sendable {
    public let tool: BurnBarToolKind
    public let title: String
    public let message: String
    public let risk: BurnBarToolRisk

    public init(tool: BurnBarToolKind, title: String, message: String, risk: BurnBarToolRisk) {
        self.tool = tool
        self.title = title
        self.message = message
        self.risk = risk
    }
}

public struct BurnBarPolicyEngine {
    public init() {}

    public func risk(for tool: BurnBarToolKind?) -> BurnBarToolRisk {
        switch tool {
        case .readFile, .searchWorkspace, .none:
            return .low
        case .applyPatch:
            return .medium
        case .runTerminal:
            return .high
        }
    }

    public func approvalDescriptor(
        explicitApprovalRequired: Bool,
        intent: BurnBarAgentIntent,
        tool: BurnBarToolKind?,
        customTitle: String?,
        customMessage: String?
    ) -> BurnBarApprovalDescriptor? {
        guard explicitApprovalRequired else {
            return nil
        }

        let effectiveTool = tool ?? intent.requestedTools.last ?? .applyPatch
        return BurnBarApprovalDescriptor(
            tool: effectiveTool,
            title: customTitle ?? "Approve \(effectiveTool.rawValue)",
            message: customMessage ?? defaultApprovalMessage(for: intent, tool: effectiveTool),
            risk: risk(for: effectiveTool)
        )
    }

    public func isRetryable(_ error: BurnBarToolExecutionError) -> Bool {
        switch error.code {
        case .trustGated, .noWorkspace, .remoteUnsupported:
            return true
        case .applyFailed, .terminalFailed, .unknown:
            return false
        }
    }

    public func indicatesProgress(for toolCall: BurnBarToolCallSnapshot) -> Bool {
        guard toolCall.status == .completed else {
            return false
        }

        switch toolCall.tool {
        case .readFile, .searchWorkspace:
            return toolCall.output != nil
        case .applyPatch, .runTerminal:
            return true
        }
    }

    public func shouldHonorModelRequestedApproval(for tool: BurnBarToolKind?) -> Bool {
        risk(for: tool) != .low
    }

    private func defaultApprovalMessage(for intent: BurnBarAgentIntent, tool: BurnBarToolKind) -> String {
        switch tool {
        case .readFile:
            return "BurnBar needs approval before reading additional workspace files for \(intent.summary.lowercased())."
        case .searchWorkspace:
            return "BurnBar needs approval before searching the workspace for additional context."
        case .applyPatch:
            return "BurnBar needs approval before applying workspace edits."
        case .runTerminal:
            return "BurnBar needs approval before running terminal commands in this workspace."
        }
    }
}
