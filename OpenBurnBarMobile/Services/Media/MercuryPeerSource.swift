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
///   2. (Optional) paired-Mac display name supplied by the host
///      caller — usually drawn from Firestore `users/{uid}/devices/*`
///      or the cached `pairing` document.
///
/// Capabilities default to `MercuryPeer.macFallbackCapabilities` until
/// the iOS app receives a `media.presence.heartbeat` from the Mac. The
/// capability advertise is best-effort, not load-bearing —
/// `canRequestMirror` keeps returning `true` for an online Mac on the
/// fallback set.
@MainActor
final class MercuryPeerSource: ObservableObject {
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
        let isOnline = (phase == .live)
        let connectionID = await currentConnectionID()
        let displayName = resolveDisplayName()
        let capabilities = resolveCapabilities()
        let lastSeen = isOnline ? clock() : (peer?.lastSeenAt ?? clock())
        let next = MercuryPeer(
            connectionID: connectionID,
            displayName: displayName,
            isOnline: isOnline,
            lastSeenAt: lastSeen,
            capabilities: capabilities
        )
        if next != peer {
            peer = next
        }
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
