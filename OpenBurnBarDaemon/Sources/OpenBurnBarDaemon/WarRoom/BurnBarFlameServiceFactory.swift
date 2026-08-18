import Foundation
import OpenBurnBarKernel

public enum BurnBarFlameServiceFactory {

    /// What this daemon can honour regardless of Hermes.
    public static let baseCapabilities: Set<String> = ["fleet_probe"]

    /// Advertised only while the gateway answers. Claiming `hermes_chat` on a
    /// machine whose Hermes is down would route chat work to a dead end.
    public static let hermesCapabilities: Set<String> = ["hermes_chat"]

    /// A Flame that can only see this machine.
    ///
    /// This is the honest default, not a placeholder: until the Wire delivers
    /// `war.fleet.snapshot` frames from peers, the local Mac genuinely is the
    /// whole fleet, and routing to it is the correct answer. `BurnBarFlameService`
    /// takes its fleet through an injected provider precisely so swapping in the
    /// Wire's view later touches no routing code.
    /// `gatewayReachable` is asked at call time rather than frozen at
    /// construction, because a gateway that was up when the daemon started is
    /// not evidence that it is up now — the same rule the fleet snapshot
    /// applies to every other machine.
    public static func makeDefault(
        gatewayReachable: @escaping @Sendable () -> Bool = { HermesGatewayProbe().isReachable() }
    ) -> BurnBarFlameService {
        let bodyID = localBodyID()
        let displayName = localDisplayName()
        return BurnBarFlameService(fleetProvider: {
            let hermesUp = gatewayReachable()
            return FleetSnapshot(bodies: [
                FleetBodySnapshot(
                    bodyID: bodyID,
                    displayName: displayName,
                    isLocal: true,
                    isOnline: true,
                    hermesGatewayReachable: hermesUp,
                    wireReachable: false,
                    // Capabilities and reachability come from one answer, so the
                    // machine cannot advertise Hermes work it cannot accept.
                    capabilities: hermesUp ? baseCapabilities.union(hermesCapabilities) : baseCapabilities,
                    activeRunCount: 0,
                    // Left unknown rather than filled with `activeProcessorCount`,
                    // which counts efficiency cores too. Peers report real
                    // P-core counts, so a mixed unit here would silently
                    // outrank a genuinely faster machine.
                    performanceCores: nil
                )
            ])
        })
    }

    /// The daemon has no access to the app's machine-bound body id, so it uses
    /// the host name. Stable across restarts on the same machine, which is all
    /// the local-only case needs; the app's published `hermes_bodies` id remains
    /// the identity of record once the Wire is up.
    static func localBodyID() -> String {
        let host = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "local" : "local-\(host)"
    }

    static func localDisplayName() -> String {
        var host = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Suffix, not substring: `mac.localdomain` must not become `macdomain`.
        if host.hasSuffix(".local") {
            host = String(host.dropLast(6))
        }
        return host.isEmpty ? "This Mac" : host
    }
}
