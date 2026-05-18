#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

/// Converts daemon run-journal events into the small action-log stream
/// the phone overlay renders during Agent Watch.
@MainActor
public final class AgentWatchActionPublisher {
    public typealias FrameSink = @Sendable (HermesRealtimeRelayFrame) async throws -> Void

    private let sessionId: String
    private let uid: String
    private let connectionId: String
    private let sink: FrameSink
    private var nextIndex = 0

    public init(
        sessionId: String,
        uid: String,
        connectionId: String,
        sink: @escaping FrameSink
    ) {
        self.sessionId = sessionId
        self.uid = uid
        self.connectionId = connectionId
        self.sink = sink
    }

    public func publish(_ event: BurnBarRunJournalEvent) async throws {
        guard let entry = entry(from: event) else { return }
        try await publish(entry)
    }

    public func publish(_ entry: HermesRealtimeRelayActionLogEntry) async throws {
        let frame = HermesRealtimeRelayFrame(
            type: .controlActionLogEntry,
            uid: uid,
            connectionId: connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: sessionId,
                actionLogEntry: entry
            )
        )
        try await sink(frame)
    }

    private func entry(from event: BurnBarRunJournalEvent) -> HermesRealtimeRelayActionLogEntry? {
        let status: HermesRealtimeRelayActionLogEntry.Status
        switch event.kind {
        case .approvalRequested:
            status = .awaitingApproval
        case .toolDispatched:
            status = .executing
        case .toolCompleted, .runCompleted:
            status = .completed
        case .runFailed, .runCancelled:
            status = .failed
        case .runCreated, .planGenerated, .loopDecided, .stateTransitioned, .approvalResponded, .recoveryDecided:
            status = .planned
        }

        let summary = Self.summary(for: event)
        let entry = HermesRealtimeRelayActionLogEntry(
            entryIndex: nextIndex,
            timestamp: event.emittedAt,
            actionKind: event.kind.rawValue,
            summary: summary,
            status: status
        )
        nextIndex += 1
        return entry
    }

    private static func summary(for event: BurnBarRunJournalEvent) -> String {
        guard let payload = event.payload else {
            return event.kind.rawValue.replacingOccurrences(of: "_", with: " ")
        }
        if case let .object(fields) = payload {
            for key in ["summary", "message", "title", "tool", "error"] {
                if case let .string(value)? = fields[key], !value.isEmpty {
                    return value
                }
            }
        }
        return event.kind.rawValue.replacingOccurrences(of: "_", with: " ")
    }
}
#endif
