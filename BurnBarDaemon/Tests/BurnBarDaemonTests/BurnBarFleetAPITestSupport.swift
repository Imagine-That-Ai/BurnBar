import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

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

    func waitForNewerSnapshot(
        after previous: BurnBarFleetSnapshot,
        socketPath: String,
        timeout: TimeInterval = 10
    ) async throws -> BurnBarFleetSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try? rawRequest(
                #"{"id":"wait-after","method":"daemon.fleet.snapshot"}"#,
                socketPath: socketPath
            ),
               let snapshot = try? Self.decodeSnapshot(from: response),
               snapshot.generatedAt > previous.generatedAt {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BurnBarFleetTestTimeoutError.deadlineExceeded(
            operation: "newer snapshot poll after \(previous.generatedAt)",
            timeout: timeout
        )
    }
}

private enum BurnBarRPCTestError: Error {
    case invalidRPCResponse
    case invalidFileJSON
}
