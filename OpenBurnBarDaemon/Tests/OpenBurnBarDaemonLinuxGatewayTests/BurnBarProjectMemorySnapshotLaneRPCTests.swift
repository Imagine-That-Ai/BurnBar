import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Wave 2.1c: dispatch coverage for the snapshot app lane. Storage semantics
/// live in `BurnBarProjectCodeMemoryStoreTests`; these pin the RPC surface —
/// typed envelopes, the `invalidParams` mapping for validation failures, and
/// the unavailable store.
final class BurnBarProjectMemorySnapshotLaneRPCTests: XCTestCase {
    func testSnapshotUpsertDeleteAndDeleteAllRoundTripOverRPC() async throws {
        let server = try makeServer()
        let contentHash = String(repeating: "ab", count: 32)
        let params = """
        {"projectSlug":"apollo","projectDisplayName":"Apollo","snapshotJSON":"{\\"schemaVersion\\":1}","contentHash":"\(contentHash)","sourceSessionCount":7,"sourceConversationCount":3,"generatedAt":"2026-07-10T12:00:00Z","schemaVersion":1,"updatedAt":"2026-07-11T08:30:05Z"}
        """
        let upsertData = try await server.handleMemoryRPC(
            method: .memorySnapshotUpsert,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"snap-up-1","method":"daemon.memory.snapshot.upsert","params":\#(params)}"#.utf8
            )
        )
        let upsert = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemorySnapshotUpsertResponse>.self,
            from: upsertData
        )
        XCTAssertNil(upsert.error)
        XCTAssertEqual(upsert.result?.projectSlug, "apollo")
        XCTAssertEqual(upsert.result?.updatedAt, "2026-07-11T08:30:05.000Z")

        let deleteData = try await server.handleMemoryRPC(
            method: .memorySnapshotDelete,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"snap-del-1","method":"daemon.memory.snapshot.delete","params":{"projectSlug":"apollo"}}"#.utf8
            )
        )
        let deleted = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemorySnapshotDeleteResponse>.self,
            from: deleteData
        )
        XCTAssertNil(deleted.error)
        XCTAssertEqual(deleted.result?.deleted, true)

        let deleteAllData = try await server.handleMemoryRPC(
            method: .memorySnapshotDeleteAll,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"snap-delall-1","method":"daemon.memory.snapshot.delete_all","params":{}}"#.utf8
            )
        )
        let wiped = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemorySnapshotDeleteAllResponse>.self,
            from: deleteAllData
        )
        XCTAssertNil(wiped.error)
        XCTAssertEqual(wiped.result?.deletedCount, 0)
    }

    func testSnapshotUpsertValidationFailureMapsToInvalidParams() async throws {
        let server = try makeServer()
        // Blank slug and a malformed hash: validation must reject before storage.
        let params = """
        {"projectSlug":"","projectDisplayName":"Apollo","snapshotJSON":"{}","contentHash":"nope","sourceSessionCount":1,"sourceConversationCount":1,"generatedAt":"2026-07-10T12:00:00Z","schemaVersion":1,"updatedAt":"2026-07-10T12:00:00Z"}
        """
        let data = try await server.handleMemoryRPC(
            method: .memorySnapshotUpsert,
            decoder: JSONDecoder(),
            requestData: Data(#"{"id":"snap-bad-1","method":"daemon.memory.snapshot.upsert","params":\#(params)}"#.utf8)
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProjectMemorySnapshotUpsertResponse>.self,
            from: data
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.invalidParams)
    }

    func testSnapshotMethodsReportUnavailableWithoutProjectMemoryStore() async throws {
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )
        let cases: [(BurnBarRPCMethod, String, String)] = [
            (
                .memorySnapshotUpsert,
                "daemon.memory.snapshot.upsert",
                #"{"projectSlug":"apollo","projectDisplayName":"Apollo","snapshotJSON":"{}","contentHash":"\#(String(repeating: "ab", count: 32))","sourceSessionCount":1,"sourceConversationCount":1,"generatedAt":"2026-07-10T12:00:00Z","schemaVersion":1,"updatedAt":"2026-07-10T12:00:00Z"}"#
            ),
            (
                .memorySnapshotDelete,
                "daemon.memory.snapshot.delete",
                #"{"projectSlug":"apollo"}"#
            ),
            (
                .memorySnapshotDeleteAll,
                "daemon.memory.snapshot.delete_all",
                "{}"
            )
        ]
        for (method, wire, params) in cases {
            let data = try await server.handleMemoryRPC(
                method: method,
                decoder: JSONDecoder(),
                requestData: Data(#"{"id":"snap-unavail","method":"\#(wire)","params":\#(params)}"#.utf8)
            )
            let response = try JSONDecoder().decode(
                BurnBarRPCResponseEnvelope<BurnBarProjectMemorySnapshotUpsertResponse>.self,
                from: data
            )
            XCTAssertNil(response.result, "method \(wire) must not succeed without a store")
            XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.internalError)
        }
    }

    func testSnapshotMethodsCarryMemoryWriteCapabilityInMemoryDomain() {
        for method in [
            BurnBarRPCMethod.memorySnapshotUpsert,
            .memorySnapshotDelete,
            .memorySnapshotDeleteAll
        ] {
            XCTAssertEqual(BurnBarRPCCapability.capability(for: method), .memoryWrite)
            XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), "memory")
        }
    }

    private func makeServer() throws -> BurnBarDaemonServer {
        let directory = try makeTemporaryDirectory()
        return BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                indexDatabasePath: directory.appendingPathComponent("openburnbar.sqlite").path,
                startsMissionControlBackgroundLoops: false
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotLaneRPCTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
