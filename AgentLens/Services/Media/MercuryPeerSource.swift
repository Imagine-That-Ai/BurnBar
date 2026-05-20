import Foundation
import Combine
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Mac-side resolver for the "do I have a paired iPhone to talk to
/// right now" snapshot. Drives the Mercury popover section's
/// online/offline dot and gates outbound triggers ("Call iPhone",
/// "Send file…").
///
/// Resolves from two signals:
///   1. `MediaControlStreamRegistry.latestStream(uid:)` — if a control
///      stream is registered for the current user, the iPhone is
///      currently dialed in.
///   2. The most recent `media.presence.heartbeat` ingested via
///      `MercuryRouter` (Phase 8 frame). Carries the iPhone's display
///      name and advertised capabilities.
///
/// Capabilities default to `MercuryPeer.iphoneFallbackCapabilities` until
/// the first heartbeat arrives — Macs always assume an online iPhone can
/// at least receive files and incoming calls.
@MainActor
final class MercuryPeerSource: ObservableObject {
    @Published private(set) var peer: MercuryPeer?

    private let registry: MediaControlStreamRegistry
    private let uidProvider: @MainActor () -> String?
    private let pollInterval: TimeInterval
    private let clock: @Sendable () -> Date

    private var pollTask: Task<Void, Never>?
    private var lastHeartbeat: HermesRealtimeRelayPresenceHeartbeat?
    private var lastHeartbeatConnectionID: String?

    init(
        registry: MediaControlStreamRegistry,
        uidProvider: @escaping @MainActor () -> String?,
        pollInterval: TimeInterval = 2.0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.uidProvider = uidProvider
        self.pollInterval = pollInterval
        self.clock = clock
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(
                    nanoseconds: UInt64((self?.pollInterval ?? 2.0) * 1_000_000_000)
                )
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Surface a freshly-received presence heartbeat from the iPhone.
    /// Called by `MercuryRouter` when an inbound
    /// `media.presence.heartbeat` frame arrives.
    func ingestHeartbeat(
        _ heartbeat: HermesRealtimeRelayPresenceHeartbeat,
        connectionID: String
    ) {
        lastHeartbeat = heartbeat
        lastHeartbeatConnectionID = connectionID
        Task { @MainActor in await refresh() }
    }

    private func refresh() async {
        let resolvedUID = uidProvider() ?? ""
        let registeredKey: MediaControlStreamRegistry.Key? = await {
            guard !resolvedUID.isEmpty else { return nil }
            return await registry.latestStream(uid: resolvedUID)?.key
        }()

        let isOnline = registeredKey != nil
        let connectionID =
            lastHeartbeatConnectionID
            ?? registeredKey?.connectionID
            ?? "paired-iphone:default"
        let displayName = resolveDisplayName()
        let capabilities = resolveCapabilities()
        let lastSeen = isOnline ? clock() : (peer?.lastSeenAt ?? clock())

        let next = MercuryPeer(
            connectionID: connectionID,
            displayName: displayName,
            isOnline: isOnline,
            lastSeenAt: lastSeen,
            capabilities: capabilities,
            blurredWallpaperBase64: nil
        )

        if next != peer {
            peer = next
        }
    }

    private func resolveDisplayName() -> String {
        if let heartbeatName = lastHeartbeat?.deviceDisplayName,
           !heartbeatName.isEmpty {
            return heartbeatName
        }
        return "Paired iPhone"
    }

    private func resolveCapabilities() -> Set<MercuryPeer.Feature> {
        guard let heartbeat = lastHeartbeat else {
            return MercuryPeer.iphoneFallbackCapabilities
        }
        let parsed = Set(heartbeat.capabilities.compactMap { MercuryPeer.Feature(rawValue: $0) })
        return parsed.isEmpty ? MercuryPeer.iphoneFallbackCapabilities : parsed
    }
}
