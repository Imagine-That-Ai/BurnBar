import Foundation
import OpenBurnBarKernel

public enum BurnBarFlameServiceFactory {

    /// Capabilities every BurnBar daemon can honour. Advertised so a routing
    /// request that needs nothing special always finds the local machine
    /// eligible.
    public static let localCapabilities: Set<String> = ["hermes_chat", "fleet_probe"]

    /// A Flame that can only see this machine.
    ///
    /// This is the honest default, not a placeholder: until the Wire delivers
    /// `war.fleet.snapshot` frames from peers, the local Mac genuinely is the
    /// whole fleet, and routing to it is the correct answer. `BurnBarFlameService`
    /// takes its fleet through an injected provider precisely so swapping in the
    /// Wire's view later touches no routing code.
    public static func makeDefault() -> BurnBarFlameService {
        let local = FleetBodySnapshot(
            bodyID: localBodyID(),
            displayName: localDisplayName(),
            isLocal: true,
            isOnline: true,
            hermesGatewayReachable: true,
            wireReachable: false,
            capabilities: localCapabilities,
            activeRunCount: 0,
            performanceCores: ProcessInfo.processInfo.activeProcessorCount
        )
        return BurnBarFlameService(fleetProvider: { FleetSnapshot(bodies: [local]) })
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
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "This Mac" : host
    }
}
