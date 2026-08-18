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
        let activeConnectionID = transport.currentMediaControlConnectionID
        guard Self.hasResolvedPeerEvidence(
            relay: relay,
            lastHeartbeat: lastHeartbeat,
            currentConnectionID: activeConnectionID,
            existingPeer: peer
        ) else {
            if peer != nil {
                peer = nil
            }
            return
        }
        let isOnline = phase == .live || Self.isFreshOnlineRelay(relay, now: clock())
        let connectionID = currentConnectionID(
            relay: relay,
            activeConnectionID: activeConnectionID,
            existingPeer: peer
        )
        let displayName = resolveDisplayName()
        let capabilities = resolveCapabilities(isOnline: isOnline)
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

    static func hasResolvedPeerEvidence(
        relay: HermesConnectionRecord?,
        lastHeartbeat: HermesRealtimeRelayPresenceHeartbeat?,
        currentConnectionID: String?,
        existingPeer: MercuryPeer?
    ) -> Bool {
        if relay != nil || lastHeartbeat != nil {
            return true
        }
        if let currentConnectionID,
           PairedMacAutoPinPolicy.isResolvedConnectionID(currentConnectionID) {
            return true
        }
        if let existingPeer,
           PairedMacAutoPinPolicy.isResolvedConnectionID(existingPeer.connectionID) {
            return true
        }
        return false
    }

    func refreshForTesting() async {
        await refresh()
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

    private func currentConnectionID(
        relay: HermesConnectionRecord?,
        activeConnectionID: String?,
        existingPeer: MercuryPeer?
    ) -> String {
        if let relay {
            return relay.id
        }
        if let activeConnectionID,
           PairedMacAutoPinPolicy.isResolvedConnectionID(activeConnectionID) {
            return activeConnectionID
        }
        if let existingPeer,
           PairedMacAutoPinPolicy.isResolvedConnectionID(existingPeer.connectionID) {
            return existingPeer.connectionID
        }
        // Legacy fallback only. Current Hermes Square injects a relay
        // provider so the tile URI matches Mac-side media frame filtering.
        return PairedMacAutoPinPolicy.legacyFallbackConnectionID
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
        if let existing = peer?.displayName, !existing.isEmpty {
            return existing
        }
        return "My Mac"
    }

    private func resolveCapabilities(isOnline: Bool) -> Set<MercuryPeer.Feature> {
        guard let heartbeat = lastHeartbeat else {
            guard isOnline else { return peer?.capabilities ?? [] }
            return Self.fallbackCapabilities(for: relayConnectionProvider())
        }
        let parsed = Set(heartbeat.capabilities.compactMap { MercuryPeer.Feature(rawValue: $0) })
        if parsed.isEmpty && heartbeat.capabilities.isEmpty {
            return MercuryPeer.macFallbackCapabilities
        }
        return parsed
    }

    /// Pre-heartbeat capability guess for an online Mac.
    ///
    /// The heartbeat only arrives once the `media.control` stream is live, so
    /// before that we fall back to `macFallbackCapabilities`. But a Mac whose
    /// iroh host failed to start still publishes `status: online` (its chat
    /// gateway is healthy) while omitting the realtime capability and reporting
    /// `realtimeRelayStatus: "offline"`. Handing back the full fallback set
    /// there advertised mirroring the Mac could not perform, so the Live sheet
    /// showed "connecting"/"reconnecting" forever instead of naming the fault.
    ///
    /// When the relay record is explicit that realtime is unavailable, drop the
    /// mirror/call features and keep only what the non-realtime path serves.
    /// An older Mac that predates the realtime advertise publishes neither
    /// signal, so an absent capability list is still treated as "assume
    /// capable" — this narrows only on a positive statement of offline.
    static func fallbackCapabilities(
        for relay: HermesConnectionRecord?
    ) -> Set<MercuryPeer.Feature> {
        guard let relay, isRealtimeExplicitlyUnavailable(relay) else {
            return MercuryPeer.macFallbackCapabilities
        }
        return MercuryPeer.macFallbackCapabilities.subtracting([
            .mirrorHost,
            .callReceive
        ])
    }

    /// True when the Mac positively reports that its realtime (iroh) relay is
    /// down — either an explicit `realtimeRelayStatus: "offline"`, or a
    /// populated capability list that omits the realtime marker.
    static func isRealtimeExplicitlyUnavailable(_ relay: HermesConnectionRecord) -> Bool {
        if relay.realtimeRelayStatus?.lowercased() == "offline" {
            return true
        }
        return !relay.capabilities.isEmpty
            && !relay.capabilities.contains(HermesRealtimeRelayProtocol.capability)
    }
}
