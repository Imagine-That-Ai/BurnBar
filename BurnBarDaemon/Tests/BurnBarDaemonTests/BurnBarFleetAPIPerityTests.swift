import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Regression coverage for the M5 agent-readable surfaces:
/// - the file and RPC expose the same completed generation;
/// - atomic replacement keeps concurrent file readers on complete JSON; and
/// - concurrent RPC readers remain successful while the ticker advances.
final class BurnBarFleetAPIPerityTests: BurnBarFleetRPCTestCase {
    private let requiredSnapshotKeys: Set<String> = [
        "schemaVersion",
        "generatedAt",
        "cadenceSeconds",
        "machine",
        "agents",
        "repos",
        "runningCount",
        "countsByAgent",
        "orchestrator",
        "probeHealth",
        "persistenceHealth"
    ]

    func testCompletedTick_fileAndRPCPayloadsAreFieldForFieldEqual() async throws {
        let configuration = makeConfiguration(name: "api-parity")
        let service = makePersistedFleetService(configuration: configuration, cadenceSeconds: 1)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let fileURL = URL(fileURLWithPath: configuration.fleetSnapshotFilePath)

        let parity = try await waitForMatchingSnapshot(
            fileURL: fileURL,
            socketPath: configuration.socketPath
        )

        XCTAssertEqual(
            try Self.canonicalJSONData(parity.rpcObject),
            try Self.canonicalJSONData(parity.fileObject),
            "RPC and file must expose one identical completed snapshot"
        )
        XCTAssertEqual(
            parity.fileObject["generatedAt"] as? String,
            Self.isoString(parity.snapshot.generatedAt)
        )
        XCTAssertEqual(parity.fileObject["cadenceSeconds"] as? Int, 1)
        XCTAssertTrue(
            requiredSnapshotKeys.isSubset(of: Set(parity.fileObject.keys)),
            "snapshot may add fields, but must retain every documented field"
        )
    }

    func testCadenceChurn_concurrentFileReadersNeverSeeTornJSON() async throws {
        let configuration = makeConfiguration(name: "api-file-readers")
        let service = makePersistedFleetService(configuration: configuration, cadenceSeconds: 1)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let fileURL = URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        _ = try await waitForMatchingSnapshot(
            fileURL: fileURL,
            socketPath: configuration.socketPath
        )

        let requiredKeys = requiredSnapshotKeys
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<50 {
                        let object = try Self.rawJSONDictionary(from: Data(contentsOf: fileURL))
                        guard requiredKeys.isSubset(of: Set(object.keys)) else {
                            throw APIPerityTestError.missingSnapshotKeys
                        }
                        guard object["schemaVersion"] as? Int == 1 else {
                            throw APIPerityTestError.invalidSchemaVersion
                        }
                        guard object["agents"] is [Any],
                              object["probeHealth"] is [Any] else {
                            throw APIPerityTestError.invalidSnapshotArrays
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    func testCadenceOverride_fileMtimeAdvancesForEachCompletedInterval() async throws {
        let configuration = makeConfiguration(name: "api-mtime")
        let service = makePersistedFleetService(configuration: configuration, cadenceSeconds: 1)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let fileURL = URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        _ = try await waitForMatchingSnapshot(
            fileURL: fileURL,
            socketPath: configuration.socketPath
        )

        var previousMTime = try modificationTime(of: fileURL)
        for _ in 0..<2 {
            let deadline = Date().addingTimeInterval(5)
            var currentMTime = previousMTime
            while Date() < deadline, currentMTime <= previousMTime {
                try await Task.sleep(nanoseconds: 50_000_000)
                currentMTime = try modificationTime(of: fileURL)
            }
            XCTAssertGreaterThan(
                currentMTime,
                previousMTime,
                "fleet-snapshot.json mtime must advance on each cadence interval"
            )
            previousMTime = currentMTime
        }
    }

    private func waitForMatchingSnapshot(
        fileURL: URL,
        socketPath: String,
        timeout: TimeInterval = 10
    ) async throws -> ParityPayload {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let response = try? rawRequest(
                   #"{"id":"wait","method":"daemon.fleet.snapshot"}"#,
                   socketPath: socketPath
               ),
               let snapshot = try? Self.decodeSnapshot(from: response),
               let fileObject = try? Self.rawJSONDictionary(from: Data(contentsOf: fileURL)),
               let rpcObject = try? Self.rawSnapshotObject(from: response),
               (try? Self.canonicalJSONData(fileObject)) == (try? Self.canonicalJSONData(rpcObject)) {
                return ParityPayload(snapshot: snapshot, rpcObject: rpcObject, fileObject: fileObject)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw APIPerityTestError.snapshotDidNotBecomeReady
    }

    private func modificationTime(of fileURL: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let modificationDate = attributes[.modificationDate] as? Date else {
            throw APIPerityTestError.missingModificationDate
        }
        return modificationDate
    }

    private static func rawSnapshotObject(from response: String) throws -> [String: Any] {
        guard let envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              let result = envelope["result"] as? [String: Any],
              let snapshot = result["snapshot"] as? [String: Any] else {
            throw APIPerityTestError.invalidRPCResponse
        }
        return snapshot
    }

    private static func canonicalJSONData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct ParityPayload {
    let snapshot: BurnBarFleetSnapshot
    let rpcObject: [String: Any]
    let fileObject: [String: Any]
}

private enum APIPerityTestError: Error {
    case snapshotDidNotBecomeReady
    case invalidRPCResponse
    case missingSnapshotKeys
    case invalidSchemaVersion
    case invalidSnapshotArrays
    case missingModificationDate
}
