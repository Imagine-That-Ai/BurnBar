#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

/// Mac-side Agent Watch session.
///
/// It reuses Mercury's screen-share encoder but labels the outbound
/// video stream as `control.surface.frame`, while the sibling action-log
/// stream carries compact journal events for the phone overlay.
@MainActor
public final class AgentWatchHUDSession {
    public typealias FrameSink = @Sendable (HermesRealtimeRelayFrame) async throws -> Void

    private let mediaCoordinator: MediaSessionCoordinator
    private let surfaceSink: MediaStreamSink
    private let actionSink: FrameSink
    private let peerDeviceID: String
    private let uid: String
    private let connectionId: String
    private let sessionId: String
    private var actionPublisher: AgentWatchActionPublisher?

    init(
        mediaCoordinator: MediaSessionCoordinator,
        surfaceSink: MediaStreamSink,
        actionSink: @escaping FrameSink,
        peerDeviceID: String,
        uid: String,
        connectionId: String,
        sessionId: String = UUID().uuidString
    ) {
        self.mediaCoordinator = mediaCoordinator
        self.surfaceSink = surfaceSink
        self.actionSink = actionSink
        self.peerDeviceID = peerDeviceID
        self.uid = uid
        self.connectionId = connectionId
        self.sessionId = sessionId
    }

    public func start() async throws {
        let publisher = AgentWatchActionPublisher(
            sessionId: sessionId,
            uid: uid,
            connectionId: connectionId,
            sink: actionSink
        )
        self.actionPublisher = publisher
        try await actionSink(HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: uid,
            connectionId: connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: sessionId
            )
        ))
        try await mediaCoordinator.startScreenShare(
            peerDeviceID: peerDeviceID,
            sink: surfaceSink,
            streamClassOverride: .controlSurfaceFrame
        )
        try await publisher.publish(HermesRealtimeRelayActionLogEntry(
            entryIndex: 0,
            timestamp: Date(),
            actionKind: "agent_watch.started",
            summary: "Agent Watch stream started",
            status: .planned
        ))
    }

    public func publish(journalEvent: BurnBarRunJournalEvent) async throws {
        try await actionPublisher?.publish(journalEvent)
    }

    public func stop() async {
        await mediaCoordinator.stop(reason: .completedUserCancel)
        try? await actionSink(HermesRealtimeRelayFrame(
            type: .controlActionLogEntry,
            uid: uid,
            connectionId: connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: sessionId,
                actionLogEntry: HermesRealtimeRelayActionLogEntry(
                    entryIndex: 0,
                    timestamp: Date(),
                    actionKind: "agent_watch.stopped",
                    summary: "Agent Watch stream stopped",
                    status: .completed
                )
            )
        ))
        actionPublisher = nil
    }
}
#endif
