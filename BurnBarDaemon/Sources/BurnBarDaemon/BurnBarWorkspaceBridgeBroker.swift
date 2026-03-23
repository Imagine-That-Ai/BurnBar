import BurnBarCore
import Foundation

public enum BurnBarWorkspaceBridgeBrokerError: Error, LocalizedError {
    case runNotFound(BurnBarRunID)
    case callNotFound(runID: BurnBarRunID, callID: String)
    case duplicateActiveCall(BurnBarRunID)
    case staleToolResult(runID: BurnBarRunID, callID: String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let runID):
            return "Run '\(runID.rawValue)' was not found."
        case .callNotFound(let runID, let callID):
            return "Tool call '\(callID)' for run '\(runID.rawValue)' was not found."
        case .duplicateActiveCall(let runID):
            return "Run '\(runID.rawValue)' already has an active workspace tool call."
        case .staleToolResult(let runID, let callID):
            return "Tool result '\(callID)' for run '\(runID.rawValue)' is stale."
        }
    }
}

public actor BurnBarWorkspaceBridgeBroker {
    private var activeCalls: [BurnBarRunID: BurnBarToolCallSnapshot] = [:]

    public init() {}

    @discardableResult
    public func enqueueToolCall(_ invocation: BurnBarToolInvocation) throws -> BurnBarToolCallSnapshot {
        if activeCalls[invocation.runID] != nil {
            throw BurnBarWorkspaceBridgeBrokerError.duplicateActiveCall(invocation.runID)
        }

        let snapshot = BurnBarToolCallSnapshot(
            callID: invocation.callID,
            runID: invocation.runID,
            tool: invocation.tool,
            arguments: invocation.arguments,
            status: .pending,
            requestedBy: invocation.requestedBy,
            requestedAt: invocation.requestedAt
        )
        activeCalls[invocation.runID] = snapshot
        return snapshot
    }

    public func activeCall(for runID: BurnBarRunID) -> BurnBarToolCallSnapshot? {
        activeCalls[runID]
    }

    public func activeCallsList(for runIDs: Set<BurnBarRunID>? = nil) -> [BurnBarToolCallSnapshot] {
        let values: [BurnBarToolCallSnapshot]
        if let runIDs {
            values = runIDs.compactMap { activeCalls[$0] }
        } else {
            values = Array(activeCalls.values)
        }

        return values.sorted { $0.requestedAt > $1.requestedAt }
    }

    public func claimToolCall(runID: BurnBarRunID?, clientID: BurnBarClientID) -> BurnBarToolCallSnapshot? {
        guard let selectedRunID = resolveRunID(for: runID) else {
            return nil
        }
        guard let current = activeCalls[selectedRunID] else {
            return nil
        }

        switch current.status {
        case .pending:
            let claimed = BurnBarToolCallSnapshot(
                callID: current.callID,
                runID: current.runID,
                tool: current.tool,
                arguments: current.arguments,
                status: .inProgress,
                requestedBy: current.requestedBy,
                requestedAt: current.requestedAt,
                claimedBy: clientID,
                claimedAt: Date(),
                completedAt: nil,
                output: nil,
                error: nil
            )
            activeCalls[selectedRunID] = claimed
            return claimed
        case .inProgress:
            guard current.claimedBy == clientID else {
                return nil
            }
            return current
        case .completed, .failed, .cancelled:
            return nil
        }
    }

    public func applyToolResult(_ request: BurnBarToolResultSubmissionRequest) throws -> BurnBarToolCallSnapshot {
        guard let current = activeCalls[request.runID] else {
            throw BurnBarWorkspaceBridgeBrokerError.callNotFound(runID: request.runID, callID: request.callID)
        }
        guard current.callID == request.callID else {
            throw BurnBarWorkspaceBridgeBrokerError.staleToolResult(runID: request.runID, callID: request.callID)
        }
        guard current.status == .inProgress || current.status == .pending else {
            throw BurnBarWorkspaceBridgeBrokerError.staleToolResult(runID: request.runID, callID: request.callID)
        }

        let nextStatus: BurnBarToolCallStatus = request.succeeded ? .completed : .failed
        let completed = BurnBarToolCallSnapshot(
            callID: current.callID,
            runID: current.runID,
            tool: current.tool,
            arguments: current.arguments,
            status: nextStatus,
            requestedBy: current.requestedBy,
            requestedAt: current.requestedAt,
            claimedBy: current.claimedBy,
            claimedAt: current.claimedAt,
            completedAt: request.completedAt,
            output: request.output,
            error: request.error
        )
        activeCalls[request.runID] = completed
        return completed
    }

    @discardableResult
    public func clearActiveCall(runID: BurnBarRunID, callID: String) -> BurnBarToolCallSnapshot? {
        guard let current = activeCalls[runID], current.callID == callID else {
            return nil
        }

        activeCalls.removeValue(forKey: runID)
        return current
    }

    @discardableResult
    public func cancelActiveCall(for runID: BurnBarRunID) -> BurnBarToolCallSnapshot? {
        guard let current = activeCalls[runID] else {
            return nil
        }

        let cancelled = BurnBarToolCallSnapshot(
            callID: current.callID,
            runID: current.runID,
            tool: current.tool,
            arguments: current.arguments,
            status: .cancelled,
            requestedBy: current.requestedBy,
            requestedAt: current.requestedAt,
            claimedBy: current.claimedBy,
            claimedAt: current.claimedAt,
            completedAt: Date(),
            output: nil,
            error: BurnBarToolExecutionError(
                code: .unknown,
                message: "Cancelled while waiting for workspace completion."
            )
        )
        activeCalls.removeValue(forKey: runID)
        return cancelled
    }

    public func restoreActiveCall(_ snapshot: BurnBarToolCallSnapshot) {
        guard snapshot.status == .pending || snapshot.status == .inProgress else {
            return
        }
        activeCalls[snapshot.runID] = snapshot
    }

    private func resolveRunID(for requestedRunID: BurnBarRunID?) -> BurnBarRunID? {
        if let requestedRunID {
            return activeCalls[requestedRunID] == nil ? nil : requestedRunID
        }

        return activeCalls.values
            .sorted { $0.requestedAt < $1.requestedAt }
            .first(where: { $0.status == .pending || $0.status == .inProgress })?
            .runID
    }
}
