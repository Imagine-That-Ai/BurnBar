import Foundation

/// Builds the default fleet service for the daemon server: cadence from the
/// environment seam and the default per-agent probe set (signal probes for
/// claude-code/grok-cli/factory-droid, root-presence probes otherwise).
public enum BurnBarFleetServiceFactory {
    public static func makeDefault() -> BurnBarFleetService {
        let fleetConfiguration = BurnBarFleetConfiguration()
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: fleetConfiguration.cadenceSeconds,
            probes: BurnBarFleetProbeFactory.makeDefaultProbes(
                rootResolver: fleetConfiguration.rootResolver
            )
        )
        return BurnBarFleetService(builder: builder)
    }
}
