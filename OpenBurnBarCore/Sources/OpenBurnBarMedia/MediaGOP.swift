import Foundation

/// Receiver admission for GOP-tagged Mercury video on the muxed
/// `media.control` stream (and for any future per-GOP QUIC split).
///
/// A newer GOP is usable once its keyframe arrives. Remaining frames from
/// older GOPs are aborted. `endOfGroup` records the highest completed GOP
/// so late stragglers from a finished group never re-anchor the decoder.
public struct MediaGOPReceiveWindow: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case decode
        case dropStale
        case dropUnanchored
    }

    public private(set) var activeGopID: UInt32?
    public private(set) var highestCompletedGopID: UInt32?
    public private(set) var abortedGopCount: Int = 0

    public init() {}

    public mutating func reset() {
        activeGopID = nil
        highestCompletedGopID = nil
        abortedGopCount = 0
    }

    public mutating func admit(gopID: UInt32, isKeyframe: Bool, isEndOfGroup: Bool) -> Decision {
        if let completed = highestCompletedGopID, gopID < completed {
            return .dropStale
        }

        if isKeyframe {
            if let active = activeGopID, gopID < active {
                return .dropStale
            }
            if let previous = activeGopID, gopID > previous {
                markCompleted(previous)
            }
            activeGopID = gopID
            if isEndOfGroup {
                markCompleted(gopID)
            }
            return .decode
        }

        guard let active = activeGopID else {
            return .dropUnanchored
        }
        if gopID < active {
            return .dropStale
        }
        if gopID > active {
            return .dropUnanchored
        }
        if isEndOfGroup {
            markCompleted(gopID)
        }
        return .decode
    }

    private mutating func markCompleted(_ gopID: UInt32) {
        if let completed = highestCompletedGopID, gopID <= completed {
            return
        }
        if let active = activeGopID, active < gopID {
            abortedGopCount += 1
        }
        highestCompletedGopID = gopID
    }
}

/// One-frame hold that stamps `endOfGroup` on the last frame of GOP N when
/// GOP N+1's keyframe arrives. Does not add a second of latency: only the
/// already-encoded previous frame is delayed until the next encode callback.
public struct MediaGOPEndStamper: Sendable, Equatable {
    private var held: MediaFrame?

    public init() {}

    /// Hold `frame` and return the previous frame, marking it end-of-GOP when
    /// `frame` is a keyframe of a newer group.
    public mutating func push(_ frame: MediaFrame) -> MediaFrame? {
        guard var previous = held else {
            held = frame
            return nil
        }
        if frame.flags.contains(.keyframe), previous.gopID != frame.gopID {
            previous.flags.insert(.endOfGroup)
        }
        held = frame
        return previous
    }

    /// Emit the held frame as the last frame of its GOP. Used on session stop.
    public mutating func flush() -> MediaFrame? {
        guard var last = held else { return nil }
        last.flags.insert(.endOfGroup)
        held = nil
        return last
    }
}
