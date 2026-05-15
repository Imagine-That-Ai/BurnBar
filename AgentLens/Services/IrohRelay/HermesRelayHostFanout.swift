import Foundation
import OpenBurnBarCore

/// Runs an iroh host alongside the existing WSS host so users on the new
/// transport reach the Mac peer-to-peer while users on older builds (or
/// users whose pairing record is stale) continue to fall back through the
/// hosted relay. Mirrors the iOS-side `HermesCompositeRelayTransport` cascade
/// — iroh first, WSS second.
///
/// Wiring: `CloudSyncService` instantiates this when
/// `SettingsManager.hermesIrohTransportEnabled == true`. When the flag is
/// off (the v1 default) the WSS-only client is used directly and this type
/// is never constructed, so the iroh dependency graph is dormant.
@MainActor
final class HermesRelayHostFanout: HermesRealtimeRelayHosting {
    private let primary: any HermesRealtimeRelayHosting
    private let fallback: any HermesRealtimeRelayHosting

    init(
        primary: any HermesRealtimeRelayHosting,
        fallback: any HermesRealtimeRelayHosting
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Surfaces the WSS URL because that's what the Firestore connection
    /// document advertises today. The iroh host publishes its NodeId via a
    /// separate `iroh_pairing` document iOS reads directly, so it does not
    /// need to round-trip through `publishableRelayURLString`.
    var publishableRelayURLString: String? {
        fallback.publishableRelayURLString
    }

    @discardableResult
    func start(uid: String, connectionID: String) async -> Bool {
        // Boot the iroh host best-effort. A failure here (e.g., missing
        // xcframework, missing pairing key) must not take the WSS host
        // offline — that would be a regression vs. the v1 cascade.
        _ = await primary.start(uid: uid, connectionID: connectionID)
        return await fallback.start(uid: uid, connectionID: connectionID)
    }

    func stop() {
        primary.stop()
        fallback.stop()
    }
}
