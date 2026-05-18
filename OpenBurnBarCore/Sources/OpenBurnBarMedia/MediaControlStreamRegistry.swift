import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Mac-side registry of active media-control streams keyed by paired-
/// connection identity. iOS opens one of these streams immediately after
/// the chat connection establishes (sending `media.classify { streamClass:
/// "media.control" }` as the first frame) and keeps it open for the
/// lifetime of the iroh connection. The registry lets
/// `MacFileTransferService` push outbound `media.blob.advertise` frames
/// whenever the user starts a send, regardless of whether iOS happens to
/// have an active chat request in flight.
///
/// Concurrency model: the registry is an actor so race-prone hand-off
/// (register → consume in a different task → invalidate on close) stays
/// linearizable. The registered stream itself is reference-counted; both
/// the read loop and outbound sends hold the same `any IrohRelayStream`
/// without copying.
public actor MediaControlStreamRegistry {
    public struct Key: Hashable, Sendable {
        public let uid: String
        public let connectionID: String

        public init(uid: String, connectionID: String) {
            self.uid = uid
            self.connectionID = connectionID
        }
    }

    private var streams: [Key: any IrohRelayStream] = [:]
    private var lastUpdatedAt: [Key: Date] = [:]
    private let pollInterval: UInt64

    public init(pollIntervalNanoseconds: UInt64 = 200_000_000) {
        self.pollInterval = pollIntervalNanoseconds
    }

    public func register(stream: any IrohRelayStream, uid: String, connectionID: String) {
        let key = Key(uid: uid, connectionID: connectionID)
        // Replace any stale entry — if iOS reconnected and re-dialed a
        // control stream while the previous one was orphaned, the new
        // one wins.
        if let existing = streams[key] {
            Task { await existing.close() }
        }
        streams[key] = stream
        lastUpdatedAt[key] = Date()
    }

    public func invalidate(uid: String, connectionID: String) {
        let key = Key(uid: uid, connectionID: connectionID)
        if let existing = streams.removeValue(forKey: key) {
            Task { await existing.close() }
        }
        lastUpdatedAt.removeValue(forKey: key)
    }

    public func stream(uid: String, connectionID: String) -> (any IrohRelayStream)? {
        streams[Key(uid: uid, connectionID: connectionID)]
    }

    /// Most recently registered stream for a given user, regardless of
    /// connectionID. `MacFileTransferService.sendFile` uses this when the
    /// caller doesn't have a known connectionID — common during ad-hoc
    /// pair-debug from the Mac chat input.
    public func latestStream(uid: String) -> (key: Key, stream: any IrohRelayStream)? {
        let candidates = streams.filter { $0.key.uid == uid }
        guard !candidates.isEmpty else { return nil }
        let mostRecent = candidates.max { lhs, rhs in
            (lastUpdatedAt[lhs.key] ?? .distantPast) <
                (lastUpdatedAt[rhs.key] ?? .distantPast)
        }
        guard let chosen = mostRecent else { return nil }
        return (key: chosen.key, stream: chosen.value)
    }

    /// Wait up to `timeout` seconds for a stream to appear for the given
    /// user. Used by `MacFileTransferService.sendFile` so a freshly-typed
    /// attachment doesn't fail immediately if iOS is still in the middle
    /// of dialing the control stream.
    public func awaitStream(uid: String, timeout: TimeInterval) async -> (any IrohRelayStream)? {
        if let existing = latestStream(uid: uid) {
            return existing.stream
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
            if let existing = latestStream(uid: uid) {
                return existing.stream
            }
        }
        return nil
    }

    public func activeStreamCount() -> Int { streams.count }
}
