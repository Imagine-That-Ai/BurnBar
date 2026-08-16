import BurnBarCore
@testable import BurnBarDaemon
import Foundation

extension BurnBarFleetRPCTestCase {
    /// Builds the persisted service used by the file/RPC parity tests.
    func makePersistedFleetService(
        configuration: BurnBarDaemonConfiguration,
        cadenceSeconds: Int,
        probes: [BurnBarFleetAgentID: any BurnBarFleetProbe]? = nil
    ) -> BurnBarFleetService {
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: probes ?? makeProbes()
        )
        let store = BurnBarFleetStore(databasePath: configuration.fleetStorePath)
        let writer = BurnBarFleetFileWriter(
            fileURL: URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        )
        return BurnBarFleetService(
            builder: builder,
            persister: BurnBarFleetPersister(store: store, fileWriter: writer)
        )
    }

    static func decodeSnapshot(from response: String) throws -> BurnBarFleetSnapshot {
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
            from: Data(response.utf8)
        )
        guard let snapshot = envelope.result?.snapshot else {
            throw BurnBarRPCTestError.invalidRPCResponse
        }
        return snapshot
    }

    static func rawJSONDictionary(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BurnBarRPCTestError.invalidFileJSON
        }
        return object
    }
}

private enum BurnBarRPCTestError: Error {
    case invalidRPCResponse
    case invalidFileJSON
}
