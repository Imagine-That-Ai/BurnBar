import Foundation

/// Thin "do I have a Mercury peer I can talk to right now" snapshot.
///
/// v1 mental model is one paired Mac per iOS device and one paired
/// iPhone per Mac — the struct intentionally avoids becoming a generic
/// peer registry. Higher-arity layouts (multiple Macs, multiple phones)
/// can extend `MercuryPeerSource` later without churning this type.
///
/// Lives in `OpenBurnBarMedia` so both the Mac app (`AgentLens`) and
/// iOS app (`OpenBurnBarMobile`) consume the same model. Resolvers are
/// platform-specific (see `MercuryPeerSource` in each app target);
/// only the snapshot itself is shared.
public struct MercuryPeer: Hashable, Sendable, Codable {
    /// Capability advertised by the peer in its presence heartbeat.
    /// Forward-compat: `init(from:)` filters unknown raw values so
    /// older builds keep working when newer peers advertise new
    /// capabilities.
    public enum Feature: String, Codable, CaseIterable, Sendable, Hashable {
        case mirrorViewer = "mirror.viewer"       // can show a remote screen
        case mirrorHost = "mirror.host"           // can host its own screen
        case fileSend = "file.send"
        case fileReceive = "file.receive"
        case callReceive = "call.receive"
        case callOriginate = "call.originate"
    }

    /// Iroh connection identifier — opaque to consumers, used as the URI
    /// tail in `device://paired-mac/<connectionID>`.
    public let connectionID: String
    /// Display name for the pinned tile and incoming-call sheet. Falls
    /// back to `"Paired Mac"` or `"Paired iPhone"` when the platform
    /// resolver can't read a real name.
    public let displayName: String
    /// Live indicator. Drives the green/grey dot on the pinned tile.
    public let isOnline: Bool
    /// Last observation — either the most recent heartbeat or the most
    /// recent registry registration timestamp.
    public let lastSeenAt: Date
    /// Capabilities the peer advertised in its last heartbeat. Empty
    /// when no heartbeat has been received yet; resolvers may seed a
    /// default set when the peer is verifiably online via another
    /// channel.
    public let capabilities: Set<Feature>

    public init(
        connectionID: String,
        displayName: String,
        isOnline: Bool,
        lastSeenAt: Date,
        capabilities: Set<Feature>
    ) {
        self.connectionID = connectionID
        self.displayName = displayName
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
        self.capabilities = capabilities
    }

    /// True when the peer is online and advertises `.mirrorHost`. Drives
    /// the enabled-state of the iOS Mercury Live sheet's "Ask to Mirror"
    /// button.
    public var canRequestMirror: Bool {
        isOnline && capabilities.contains(.mirrorHost)
    }

    /// True when the peer is online and advertises `.callReceive`.
    public var canPlaceCall: Bool {
        isOnline && capabilities.contains(.callReceive)
    }

    /// True when the peer is online and advertises `.fileReceive`.
    public var canSendFile: Bool {
        isOnline && capabilities.contains(.fileReceive)
    }

    // MARK: - Forward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case connectionID
        case displayName
        case isOnline
        case lastSeenAt
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connectionID = try container.decode(String.self, forKey: .connectionID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.isOnline = try container.decode(Bool.self, forKey: .isOnline)
        self.lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        // Filter unknown capability strings rather than failing the
        // whole struct's decode. Capability discovery is best-effort,
        // not load-bearing.
        let rawCapabilities = try container.decode([String].self, forKey: .capabilities)
        self.capabilities = Set(rawCapabilities.compactMap { Feature(rawValue: $0) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connectionID, forKey: .connectionID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(isOnline, forKey: .isOnline)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        // Sort so the wire form is deterministic — friendlier for diffs
        // when these get logged.
        try container.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
    }
}

extension MercuryPeer {
    /// Sensible default capability set when a Mac is online but no
    /// heartbeat has been received yet. Mirrors what older Mac builds
    /// implicitly support before the Phase 8 heartbeat code path landed.
    public static let macFallbackCapabilities: Set<Feature> = [
        .mirrorHost,
        .fileSend,
        .fileReceive,
        .callReceive
    ]

    /// Sensible default capability set when an iPhone is online but no
    /// heartbeat has been received yet.
    public static let iphoneFallbackCapabilities: Set<Feature> = [
        .mirrorViewer,
        .fileSend,
        .fileReceive,
        .callReceive
    ]
}
