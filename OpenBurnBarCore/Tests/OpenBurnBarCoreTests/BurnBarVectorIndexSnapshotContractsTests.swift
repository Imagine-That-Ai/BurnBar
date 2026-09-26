import XCTest
@testable import OpenBurnBarCore

/// Wave 2.1c-ii: the vector-snapshot app lane rides stable wire keys.
/// Timestamps are ISO 8601 on the wire (the daemon persists GRDB `Date`
/// text); every row field crosses verbatim.
final class BurnBarVectorIndexSnapshotContractsTests: XCTestCase {
    func testUpsertRoundTripsWithStableWireKeys() throws {
        let request = BurnBarVectorIndexSnapshotUpsertRequest(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw",
            state: "ready",
            fingerprint: "fp-9f2c",
            dimensions: 1536,
            distanceMetric: "dot_product",
            vectorCount: 12_000,
            storageRelativePath: "snapshots/version-1/usearch-hnsw/gen-7",
            fileBytes: 48_234_496,
            backendVersion: "usearch-2.17",
            createdAt: "2026-06-15T15:06:40Z",
            updatedAt: "2026-06-15T15:08:20Z",
            lastBuiltAt: "2026-06-15T15:08:20Z"
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["embeddingVersionID"] as? String, "version-1")
        XCTAssertEqual(object["backendID"] as? String, "usearch-hnsw")
        XCTAssertEqual(object["state"] as? String, "ready")
        XCTAssertEqual(object["fingerprint"] as? String, "fp-9f2c")
        XCTAssertEqual(object["dimensions"] as? Int, 1536)
        XCTAssertEqual(object["distanceMetric"] as? String, "dot_product")
        XCTAssertEqual(object["vectorCount"] as? Int, 12_000)
        XCTAssertEqual(object["storageRelativePath"] as? String, "snapshots/version-1/usearch-hnsw/gen-7")
        XCTAssertEqual(object["fileBytes"] as? Int, 48_234_496)
        XCTAssertEqual(object["backendVersion"] as? String, "usearch-2.17")
        XCTAssertEqual(object["createdAt"] as? String, "2026-06-15T15:06:40Z")
        XCTAssertEqual(object["updatedAt"] as? String, "2026-06-15T15:08:20Z")
        XCTAssertEqual(object["lastBuiltAt"] as? String, "2026-06-15T15:08:20Z")
        XCTAssertEqual(try JSONDecoder().decode(BurnBarVectorIndexSnapshotUpsertRequest.self, from: data), request)

        let response = BurnBarVectorIndexSnapshotUpsertResponse(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw",
            updatedAt: "2026-06-15T15:08:20.000Z"
        )
        let responseData = try JSONEncoder().encode(response)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(responseObject["embeddingVersionID"] as? String, "version-1")
        XCTAssertEqual(responseObject["backendID"] as? String, "usearch-hnsw")
        XCTAssertEqual(responseObject["updatedAt"] as? String, "2026-06-15T15:08:20.000Z")
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarVectorIndexSnapshotUpsertResponse.self, from: responseData),
            response
        )
    }

    func testVectorSnapshotMethodUsesStableWireString() {
        XCTAssertEqual(
            BurnBarRPCMethod.searchVectorSnapshotUpsert.rawValue,
            "daemon.search.vector_snapshot.upsert"
        )
    }
}
