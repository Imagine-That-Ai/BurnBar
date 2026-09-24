import Foundation

/// Shared Mercury capability tokens. Must match `MercuryPeer.Feature`.
public enum MobileMercuryCapability: String, Sendable, Equatable, CaseIterable {
    case mirrorViewer = "mirror.viewer"
    case mirrorHost = "mirror.host"
    case mirrorAutoAccept = "mirror.auto_accept"
    case remoteUnlockHost = "remote_unlock.host"
    case fileSend = "file.send"
    case fileReceive = "file.receive"
    case callReceive = "call.receive"
    case callOriginate = "call.originate"
}

public enum MobileMercuryInviteAck: String, Sendable, Equatable {
    case paired
    case mismatch
    case denied
}

public enum MobileMercurySessionPresentation: String, Sendable, Equatable {
    case idle
    case connected
    case reconnecting
    case denied
    case failed
}

/// Mercury/media.control decisions. Source: iOS `MercuryPeer` + 60s heartbeat.
public enum MobileMercuryMediaPolicy {
    public static let heartbeatIntervalMs: Int64 = 60_000

    public static let phoneHeartbeatCapabilities: [String] = [
        MobileMercuryCapability.mirrorViewer.rawValue,
        MobileMercuryCapability.fileSend.rawValue,
        MobileMercuryCapability.fileReceive.rawValue,
        MobileMercuryCapability.callReceive.rawValue
    ]

    public static func filterCapabilities(_ raw: [String]) -> [String] {
        let known = Set(MobileMercuryCapability.allCases.map(\.rawValue))
        return Array(Set(raw.filter { known.contains($0) })).sorted()
    }

    public static func inviteAckPair(
        inviteId: String,
        ackId: String,
        accepted: Bool
    ) -> MobileMercuryInviteAck {
        if inviteId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ackId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || inviteId != ackId {
            return .mismatch
        }
        return accepted ? .paired : .denied
    }

    /// Permission denial is never a connected session.
    public static func sessionPresentation(
        phase: String,
        denied: Bool
    ) -> MobileMercurySessionPresentation {
        if denied { return .denied }
        switch phase {
        case "live":
            return .connected
        case "reconnecting":
            return .reconnecting
        case "failed":
            return .failed
        default:
            return .idle
        }
    }

    public static func canRequestMirror(isOnline: Bool, capabilities: [String]) -> Bool {
        isOnline && capabilities.contains(MobileMercuryCapability.mirrorHost.rawValue)
    }

    public static func canPlaceCall(isOnline: Bool, capabilities: [String]) -> Bool {
        isOnline && capabilities.contains(MobileMercuryCapability.callReceive.rawValue)
    }

    public static func canSendFile(isOnline: Bool, capabilities: [String]) -> Bool {
        isOnline && capabilities.contains(MobileMercuryCapability.fileReceive.rawValue)
    }
}
