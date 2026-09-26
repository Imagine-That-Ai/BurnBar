import XCTest
@testable import OpenBurnBarCore

/// Wave 2.1c: the snapshot app lane rides stable wire keys. Timestamps are
/// ISO 8601 on the wire (the daemon persists GRDB `Date` text); the JSON and
/// hash cross untouched.
final class BurnBarProjectMemorySnapshotContractsTests: XCTestCase {
    func testUpsertRoundTripsWithStableWireKeys() throws {
        let request = BurnBarProjectMemorySnapshotUpsertRequest(
            projectSlug: "apollo",
            projectDisplayName: "Apollo",
            snapshotJSON: #"{"schemaVersion":1}"#,
            contentHash: String(repeating: "ab", count: 32),
            sourceSessionCount: 7,
            sourceConversationCount: 3,
            generatedAt: "2026-07-10T12:00:00Z",
            schemaVersion: 1,
            updatedAt: "2026-07-11T08:30:05Z"
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["projectSlug"] as? String, "apollo")
        XCTAssertEqual(object["projectDisplayName"] as? String, "Apollo")
        XCTAssertEqual(object["snapshotJSON"] as? String, #"{"schemaVersion":1}"#)
        XCTAssertEqual(object["contentHash"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(object["sourceSessionCount"] as? Int, 7)
        XCTAssertEqual(object["sourceConversationCount"] as? Int, 3)
        XCTAssertEqual(object["generatedAt"] as? String, "2026-07-10T12:00:00Z")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["updatedAt"] as? String, "2026-07-11T08:30:05Z")
        XCTAssertEqual(try JSONDecoder().decode(BurnBarProjectMemorySnapshotUpsertRequest.self, from: data), request)

        let response = BurnBarProjectMemorySnapshotUpsertResponse(
            projectSlug: "apollo",
            updatedAt: "2026-07-11T08:30:05.000Z"
        )
        let responseData = try JSONEncoder().encode(response)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(responseObject["projectSlug"] as? String, "apollo")
        XCTAssertEqual(responseObject["updatedAt"] as? String, "2026-07-11T08:30:05.000Z")
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarProjectMemorySnapshotUpsertResponse.self, from: responseData),
            response
        )
    }

    func testDeleteRoundTripsWithStableWireKeys() throws {
        let request = BurnBarProjectMemorySnapshotDeleteRequest(projectSlug: "apollo")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["projectSlug"] as? String, "apollo")
        XCTAssertEqual(try JSONDecoder().decode(BurnBarProjectMemorySnapshotDeleteRequest.self, from: data), request)

        let response = BurnBarProjectMemorySnapshotDeleteResponse(projectSlug: "apollo", deleted: true)
        let responseData = try JSONEncoder().encode(response)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(responseObject["projectSlug"] as? String, "apollo")
        XCTAssertEqual(responseObject["deleted"] as? Bool, true)
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarProjectMemorySnapshotDeleteResponse.self, from: responseData),
            response
        )
    }

    func testDeleteAllRoundTripsWithStableWireKeys() throws {
        let request = BurnBarProjectMemorySnapshotDeleteAllRequest()
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).count,
            0
        )
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarProjectMemorySnapshotDeleteAllRequest.self, from: data),
            request
        )

        let response = BurnBarProjectMemorySnapshotDeleteAllResponse(deletedCount: 2)
        let responseData = try JSONEncoder().encode(response)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(responseObject["deletedCount"] as? Int, 2)
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarProjectMemorySnapshotDeleteAllResponse.self, from: responseData),
            response
        )
    }

    func testSnapshotMethodsUseStableWireStrings() {
        XCTAssertEqual(BurnBarRPCMethod.memorySnapshotUpsert.rawValue, "daemon.memory.snapshot.upsert")
        XCTAssertEqual(BurnBarRPCMethod.memorySnapshotDelete.rawValue, "daemon.memory.snapshot.delete")
        XCTAssertEqual(BurnBarRPCMethod.memorySnapshotDeleteAll.rawValue, "daemon.memory.snapshot.delete_all")
    }
}
