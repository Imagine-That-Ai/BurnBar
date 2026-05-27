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
///   2. The most recent `media.presence.heartbeat` for that same
///      connection, ingested via `MercuryRouter` (Phase 8 frame). Carries
///      the iPhone's display name and advertised capabilities.
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
    private var heartbeatsByConnectionID: [String: HermesRealtimeRelayPresenceHeartbeat] = [:]
    private var lastHeartbeatConnectionID: String?
    private static let cadenceID = "mercury-peer-source"

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
        // Coordinator-managed cadence: 2 s while the app is active and no
        // observer is delivering heartbeats, 30 s once heartbeats are
        // arriving (the iPhone is actively present), 30 s in the
        // background, and paused entirely while the display sleeps. The
        // poll exists as a fallback because the control-stream-registry
        // refresh in `MediaControlStreamRegistry` is push-driven and may
        // miss state changes on flaky networks.
        let interval = pollInterval
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceID,
                activeInterval: interval,
                backgroundInterval: 30,
                sleepInterval: nil,
                observerActiveInterval: 30,
                isEnabled: { true },
                fireImmediately: true,
                cancellableInFlight: false,
                work: { [weak self] in
                    await self?.refresh()
                }
            )
        )
        // Mark `pollTask` non-nil so re-entrant `start()` calls are no-ops.
        pollTask = Task { @MainActor in }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        BackgroundCadenceCoordinator.shared.unregister(id: Self.cadenceID)
    }

    /// Surface a freshly-received presence heartbeat from the iPhone.
    /// Called by `MercuryRouter` when an inbound
    /// `media.presence.heartbeat` frame arrives.
    func ingestHeartbeat(
        _ heartbeat: HermesRealtimeRelayPresenceHeartbeat,
        connectionID: String
    ) {
        heartbeatsByConnectionID[connectionID] = heartbeat
        lastHeartbeatConnectionID = connectionID
        BackgroundCadenceCoordinator.shared.observerDidEmit(id: Self.cadenceID)
        Task { @MainActor in await refresh() }
    }

    /// The transport registry already knows the stream is gone; drop any
    /// identity/capability cache for that specific peer so a later iPhone
    /// registration cannot inherit a stale Android heartbeat.
    func handleControlStreamClosed(connectionID: String) {
        heartbeatsByConnectionID.removeValue(forKey: connectionID)
        if lastHeartbeatConnectionID == connectionID {
            lastHeartbeatConnectionID = nil
        }
        BackgroundCadenceCoordinator.shared.observerDidGoSilent(id: Self.cadenceID)
        Task { @MainActor in await refresh() }
    }

    func refreshForTesting() async {
        await refresh()
    }

    private func refresh() async {
        let resolvedUID = uidProvider() ?? ""
        let registeredKey: MediaControlStreamRegistry.Key? = await {
            guard !resolvedUID.isEmpty else { return nil }
            return await registry.latestStream(uid: resolvedUID)?.key
        }()

        let isOnline = registeredKey != nil
        let heartbeatConnectionID =
            registeredKey?.connectionID
            ?? lastHeartbeatConnectionID
        let connectionID =
            registeredKey?.connectionID
            ?? heartbeatConnectionID
            ?? "paired-iphone:default"
        let heartbeat = heartbeatConnectionID.flatMap { heartbeatsByConnectionID[$0] }
        let displayName = resolveDisplayName(heartbeat: heartbeat)
        let capabilities = resolveCapabilities(heartbeat: heartbeat)
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

    private func resolveDisplayName(heartbeat: HermesRealtimeRelayPresenceHeartbeat?) -> String {
        if let heartbeatName = heartbeat?.deviceDisplayName,
           !heartbeatName.isEmpty {
            return heartbeatName
        }
        return "Paired iPhone"
    }

    private func resolveCapabilities(
        heartbeat: HermesRealtimeRelayPresenceHeartbeat?
    ) -> Set<MercuryPeer.Feature> {
        guard let heartbeat else {
            return MercuryPeer.iphoneFallbackCapabilities
        }
        let parsed = Set(heartbeat.capabilities.compactMap { MercuryPeer.Feature(rawValue: $0) })
        return parsed.isEmpty ? MercuryPeer.iphoneFallbackCapabilities : parsed
    }
}
