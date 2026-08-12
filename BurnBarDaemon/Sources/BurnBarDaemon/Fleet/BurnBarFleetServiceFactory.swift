import Foundation

/// Builds the default fleet service for the daemon server: cadence from the
/// environment seam, the default per-agent probe set (signal probes for all
/// ten roster agents), and the daemon-owned persistence layer (fleet.sqlite
/// store + atomic well-known-file writer) rooted in the daemon's support dir.
public enum BurnBarFleetServiceFactory {
    public static func makeDefault(
        configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration()
    ) -> BurnBarFleetService {
        let fleetConfiguration = BurnBarFleetConfiguration()
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: fleetConfiguration.cadenceSeconds,
            probes: BurnBarFleetProbeFactory.makeDefaultProbes(
                rootResolver: fleetConfiguration.rootResolver
            )
        )

        let store = BurnBarFleetStore(
            databasePath: configuration.fleetStorePath,
            eventRetentionSeconds: configuration.fleetEventRetentionSeconds,
            snapshotRetentionCount: configuration.fleetSnapshotRetentionCount
        )
        let fileWriter = BurnBarFleetFileWriter(fileURL: URL(fileURLWithPath: configuration.fleetSnapshotFilePath))
        let persister = BurnBarFleetPersister(store: store, fileWriter: fileWriter)
        try? persister.open()

        return BurnBarFleetService(builder: builder, persister: persister)
    }
}
