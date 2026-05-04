import OpenBurnBarCore
import Foundation

// Public error surface for `BurnBarRunService` (actor + execution state remain in BurnBarRunService.swift).

public enum BurnBarRunRegistryEvictionPolicy: Sendable {
    case none
    case maxCount(Int)
}

public enum BurnBarRunServiceError: Error, LocalizedError {
    case runNotFound(BurnBarRunID)
    case retryRequiresFailedRun(BurnBarRunID)
    case approvalNotFound(BurnBarApprovalID)
    case approvalAlreadyResolved(BurnBarApprovalID)
    case routeFailed(String)
    case invalidToolResult(BurnBarRunID, String)
    case missingWorkflowInput(BurnBarRunID, String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let runID):
            return "Run '\(runID.rawValue)' was not found."
        case .retryRequiresFailedRun(let runID):
            return "Run '\(runID.rawValue)' is not in a failed state and cannot be retried."
        case .approvalNotFound(let approvalID):
            return "Approval '\(approvalID.rawValue)' was not found."
        case .approvalAlreadyResolved(let approvalID):
            return "Approval '\(approvalID.rawValue)' has already been resolved."
        case .routeFailed(let message):
            return "OpenBurnBar could not route the requested run: \(message)"
        case .invalidToolResult(let runID, let message):
            return "OpenBurnBar received an invalid tool result for run '\(runID.rawValue)': \(message)"
        case .missingWorkflowInput(let runID, let message):
            return "OpenBurnBar could not continue workflow for run '\(runID.rawValue)': \(message)"
        }
    }
}
