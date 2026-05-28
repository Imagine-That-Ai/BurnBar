import Foundation
import Combine
import OpenBurnBarCore
import OpenBurnBarMedia

/// iOS-side resolver for the "do I have a paired Mac to talk to right
/// now" snapshot. Drives the Mercury Square pinned tile's
/// online/offline dot, the Mercury Live sheet's button enablement, and
/// any future per-peer settings.
///
/// Resolves from two signals:
///   1. `MediaControlStreamCoordinator.phase` — once the persistent
///      iroh control stream is `.live`, we know the Mac is reachable.
///   2. `HermesConnectionRecord` relay presence — a fresh Firestore
///      relay heartbeat means the Mac can be dialed even before the
///      iOS control stream has completed its own handshake.
///
/// Capabilities default to `MercuryPeer.macFallbackCapabilities` until
/// the iOS app receives a `media.presence.heartbeat` from the Mac. The
/// capability advertise is best-effort, not load-bearing —
/// `canRequestMirror` keeps returning `true` for an online Mac on the
/// fallback set.
@MainActor
final class MercuryPeerSource: ObservableObject {
    static let relayFreshnessWindow: TimeInterval = 30 * 60

    @Published private(set) var peer: MercuryPeer?

    private let transport: HermesIrohRelayTransport
    private let relayConnectionProvider: @MainActor () -> HermesConnectionRecord?
    private let displayNameProvider: @MainActor () -> String?
    private let pollInterval: TimeInterval
    private let clock: @Sendable () -> Date

    private var pollTask: Task<Void, Never>?
    private var lastHeartbeat: HermesRealtimeRelayPresenceHeartbeat?

    init(
        transport: HermesIrohRelayTransport = .shared,
        relayConnectionProvider: @escaping @MainActor () -> HermesConnectionRecord? = { nil },
        displayNameProvider: @escaping @MainActor () -> String? = { nil },
        pollInterval: TimeInterval = 1.0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.relayConnectionProvider = relayConnectionProvider
        self.displayNameProvider = displayNameProvider
        self.pollInterval = pollInterval
        self.clock = clock
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(
                    nanoseconds: UInt64((self?.pollInterval ?? 1.0) * 1_000_000_000)
                )
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Surface a freshly-received presence heartbeat from the Mac. The
    /// next poll will fold its display name + capabilities into the
    /// published snapshot. Called by the `MediaControlStreamCoordinator`
    /// read loop through `HermesIrohRelayTransport.mediaPresenceHeartbeatHandler`.
    func ingestHeartbeat(_ heartbeat: HermesRealtimeRelayPresenceHeartbeat) {
        lastHeartbeat = heartbeat
        Task { @MainActor in await refresh() }
    }

    private func refresh() async {
        let phase = transport.currentMediaControlPhase
        let relay = relayConnectionProvider()
        let isOnline = phase == .live || Self.isFreshOnlineRelay(relay, now: clock())
        let connectionID = await currentConnectionID()
        let displayName = resolveDisplayName()
        let capabilities = resolveCapabilities()
        let lastSeen = resolveLastSeen(isOnline: isOnline, relay: relay)
        let next = MercuryPeer(
            connectionID: connectionID,
            displayName: displayName,
            isOnline: isOnline,
            lastSeenAt: lastSeen,
            capabilities: capabilities,
            blurredWallpaperBase64: lastHeartbeat?.blurredWallpaperBase64
        )

        if next != peer {
            peer = next
        }
    }

    static func isFreshOnlineRelay(
        _ relay: HermesConnectionRecord?,
        now: Date,
        freshnessWindow: TimeInterval = relayFreshnessWindow
    ) -> Bool {
        guard let relay else { return false }
        let statusOnline = relay.status == .online
        let realtimeOnline = relay.realtimeRelayStatus?.lowercased() == "online"
        guard statusOnline || realtimeOnline else { return false }

        let activityDate = relay.realtimeRelayLastSeenAt
            ?? relay.lastSeenAt
            ?? relay.updatedAt
        return now.timeIntervalSince(activityDate) <= freshnessWindow
    }

    private func resolveLastSeen(isOnline: Bool, relay: HermesConnectionRecord?) -> Date {
        if let heartbeat = lastHeartbeat {
            return heartbeat.sentAt
        }
        if let relayActivity = relay?.realtimeRelayLastSeenAt
            ?? relay?.lastSeenAt
            ?? relay?.updatedAt {
            return relayActivity
        }
        if isOnline {
            if peer?.isOnline == true, let existing = peer?.lastSeenAt {
                return existing
            }
            return clock()
        }
        return peer?.lastSeenAt ?? clock()
    }

    private func currentConnectionID() async -> String {
        if let relay = relayConnectionProvider() {
            return relay.id
        }
        // Legacy fallback only. Current Hermes Square injects a relay
        // provider so the tile URI matches Mac-side media frame filtering.
        return "paired-mac:default"
    }

    private func resolveDisplayName() -> String {
        if let heartbeatName = lastHeartbeat?.deviceDisplayName,
           !heartbeatName.isEmpty {
            return heartbeatName
        }
        if let relayName = relayConnectionProvider()?.displayName,
           !relayName.isEmpty {
            return relayName
        }
        if let provided = displayNameProvider(), !provided.isEmpty {
            return provided
        }
        return "My Mac"
    }

    private func resolveCapabilities() -> Set<MercuryPeer.Feature> {
        guard let heartbeat = lastHeartbeat else {
            return MercuryPeer.macFallbackCapabilities
        }
        let parsed = Set(heartbeat.capabilities.compactMap { MercuryPeer.Feature(rawValue: $0) })
        return parsed.isEmpty ? MercuryPeer.macFallbackCapabilities : parsed
    }
}
