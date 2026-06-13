import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Closure that decides whether an inbound peer is still permitted. The host
/// supplies one backed by the freshly-refreshed `IrohInboundPeerPolicy` so the
/// registry can tear down streams for a de-allowlisted / revoked peer without
/// importing the policy type itself.
public typealias MediaInboundPeerAllowChecker = @Sendable (_ remotePeerNodeId: String?) -> Bool

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

    public struct Lease: Sendable {
        public let key: Key
        public let remotePeerNodeId: String?
        public var id: UUID { generation }
        fileprivate let generation: UUID

        fileprivate init(key: Key, remotePeerNodeId: String?, generation: UUID) {
            self.key = key
            self.remotePeerNodeId = remotePeerNodeId
            self.generation = generation
        }
    }

    public struct InvalidationResult: Sendable, Equatable {
        public let didInvalidate: Bool
        public let removedLastStreamForConnection: Bool
    }

    private struct Entry: Sendable {
        let stream: any IrohRelayStream
        let generation: UUID
        let order: UInt64
    }

    private var streams: [Key: [Entry]] = [:]
    private var nextOrder: UInt64 = 0
    private let pollInterval: UInt64

    public init(pollIntervalNanoseconds: UInt64 = 200_000_000) {
        self.pollInterval = pollIntervalNanoseconds
    }

    @discardableResult
    public func register(stream: any IrohRelayStream, uid: String, connectionID: String) -> Lease {
        let key = Key(uid: uid, connectionID: connectionID)
        // Keep sibling streams for the same Mac connection alive. iPhone
        // and Android share the Mac pairing `connectionID`, so replacing
        // here makes them close each other in a reconnect loop. Latest
        // still wins for Mac-initiated sends; each lease cleans up only
        // the stream it registered.
        let generation = UUID()
        nextOrder += 1
        streams[key, default: []].append(
            Entry(stream: stream, generation: generation, order: nextOrder)
        )
        return Lease(key: key, remotePeerNodeId: stream.remotePeerNodeId, generation: generation)
    }

    @discardableResult
    public func invalidate(uid: String, connectionID: String) -> Bool {
        let key = Key(uid: uid, connectionID: connectionID)
        guard let entries = streams.removeValue(forKey: key), !entries.isEmpty else {
            return false
        }
        for entry in entries {
            Task { await entry.stream.close() }
        }
        return true
    }

    @discardableResult
    public func invalidate(_ lease: Lease) -> Bool {
        invalidateWithResult(lease).removedLastStreamForConnection
    }

    @discardableResult
    public func invalidateWithResult(_ lease: Lease) -> InvalidationResult {
        guard var entries = streams[lease.key],
              let index = entries.firstIndex(where: { $0.generation == lease.generation }) else {
            return InvalidationResult(
                didInvalidate: false,
                removedLastStreamForConnection: false
            )
        }
        let entry = entries.remove(at: index)
        if entries.isEmpty {
            streams.removeValue(forKey: lease.key)
        } else {
            streams[lease.key] = entries
        }
        Task { await entry.stream.close() }
        return InvalidationResult(
            didInvalidate: true,
            removedLastStreamForConnection: entries.isEmpty
        )
    }

    /// RR-18 mid-stream teardown. The accept loop only checks the inbound
    /// allowlist once, at accept; a peer that is de-allowlisted or revoked
    /// while its control stream is live keeps mirroring until the stream
    /// closes naturally. On every allowlist/policy refresh the host calls this
    /// with a checker backed by the fresh policy, and the registry closes —
    /// per-peer — any registered stream whose `remotePeerNodeId` is no longer
    /// allowed, mirroring how `invalidate` closes a single lease. Streams whose
    /// `remotePeerNodeId` is unknown (`nil`) are treated as not-allowed and
    /// purged, since a stream the policy can no longer identify must not keep a
    /// privileged media lane open. Returns the node ids that were torn down so
    /// the caller can also cancel any sibling serve tasks it owns for the same
    /// peers.
    @discardableResult
    public func purgeStreamsNotAllowed(by isAllowed: MediaInboundPeerAllowChecker) -> [String?] {
        var purgedPeerNodeIds: [String?] = []
        for (key, entries) in streams {
            var survivors: [Entry] = []
            for entry in entries {
                if isAllowed(entry.stream.remotePeerNodeId) {
                    survivors.append(entry)
                } else {
                    purgedPeerNodeIds.append(entry.stream.remotePeerNodeId)
                    Task { await entry.stream.close() }
                }
            }
            if survivors.isEmpty {
                streams.removeValue(forKey: key)
            } else if survivors.count != entries.count {
                streams[key] = survivors
            }
        }
        return purgedPeerNodeIds
    }

    public func stream(uid: String, connectionID: String) -> (any IrohRelayStream)? {
        streams[Key(uid: uid, connectionID: connectionID)]?
            .max { lhs, rhs in lhs.order < rhs.order }?
            .stream
    }

    /// Most recently registered stream for a given user, regardless of
    /// connectionID. `MacFileTransferService.sendFile` uses this when the
    /// caller doesn't have a known connectionID — common during ad-hoc
    /// pair-debug from the Mac chat input.
    public func latestStream(uid: String) -> (key: Key, stream: any IrohRelayStream)? {
        let candidates = streams.compactMap { key, entries -> (key: Key, entry: Entry)? in
            guard key.uid == uid,
                  let entry = entries.max(by: { lhs, rhs in lhs.order < rhs.order }) else {
                return nil
            }
            return (key, entry)
        }
        guard let chosen = candidates.max(by: { lhs, rhs in
            lhs.entry.order < rhs.entry.order
        }) else {
            return nil
        }
        return (key: chosen.key, stream: chosen.entry.stream)
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

    public func activeStreamCount() -> Int {
        streams.values.reduce(0) { $0 + $1.count }
    }
}
