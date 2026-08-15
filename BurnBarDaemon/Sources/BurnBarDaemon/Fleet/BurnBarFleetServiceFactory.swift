import Foundation

/// Builds the default fleet service for the daemon server: cadence from the
/// environment seam, the default per-agent probe set (signal probes for all
/// ten roster agents), and the daemon-owned persistence layer (fleet.sqlite
/// store + atomic well-known-file writer) rooted in the daemon's support dir.
///
/// Open semantics: the factory does NOT open the persister. The store is
/// opened (created/migrated) by `BurnBarDaemonServer.start()` before the
/// fleet ticker starts, so a corrupt store is recovered typed (delete +
/// recreate) with the rebuild window surfaced through `persistenceHealth` on
/// the first published recovery snapshot. The support dir is created lazily
/// by the store's open — read-only RPCs (health/catalog/config.get) never
/// write.
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
        // M4: the daemon-owned orchestrator state + directive records live in
        // the same fleet.sqlite store (orchestrator_state + fleet_directives).
        let controlStore = BurnBarFleetControlStore(store: store)

        return BurnBarFleetService(builder: builder, persister: persister, controlStore: controlStore)
    }
}
