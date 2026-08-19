import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarVectorKit

final class OpenBurnBarSearchContractsTests: XCTestCase {

    // MARK: - BurnBarSQLValue Codable & Cases

    func test_sqlValue_null_encodesAndDecodes() throws {
        let value = BurnBarSQLValue.null
        let data = try JSONEncoder().encode(value)
        let jsonString = String(data: data, encoding: .utf8)
        XCTAssertEqual(jsonString, "null")

        let decoded = try JSONDecoder().decode(BurnBarSQLValue.self, from: data)
        XCTAssertEqual(decoded, .null)
    }

    func test_sqlValue_integer_encodesAndDecodes() throws {
        let value = BurnBarSQLValue.integer(42)
        let data = try JSONEncoder().encode(value)
        let jsonString = String(data: data, encoding: .utf8)
        XCTAssertEqual(jsonString, "42")

        let decoded = try JSONDecoder().decode(BurnBarSQLValue.self, from: data)
        XCTAssertEqual(decoded, .integer(42))
    }

    func test_sqlValue_real_encodesAndDecodes() throws {
        let value = BurnBarSQLValue.real(3.14159)
        let data = try JSONEncoder().encode(value)

        let decoded = try JSONDecoder().decode(BurnBarSQLValue.self, from: data)
        guard case .real(let r) = decoded else {
            XCTFail("Expected .real, got \(decoded)")
            return
        }
        XCTAssertEqual(r, 3.14159, accuracy: 0.00001)
    }

    func test_sqlValue_text_encodesAndDecodes() throws {
        let value = BurnBarSQLValue.text("hello world")
        let data = try JSONEncoder().encode(value)
        let jsonString = String(data: data, encoding: .utf8)
        XCTAssertEqual(jsonString, "\"hello world\"")

        let decoded = try JSONDecoder().decode(BurnBarSQLValue.self, from: data)
        XCTAssertEqual(decoded, .text("hello world"))
    }

    func test_sqlValue_blob_encodesToBlobEnvelopeAndDecodes() throws {
        let rawBytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]
        let blobData = Data(rawBytes)
        let value = BurnBarSQLValue.blob(blobData)

        let encoded = try JSONEncoder().encode(value)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(jsonObject?["$blob"] as? String, blobData.base64EncodedString())

        let decoded = try JSONDecoder().decode(BurnBarSQLValue.self, from: encoded)
        XCTAssertEqual(decoded, .blob(blobData))
    }

    func test_sqlValue_decodeFromRawJSONLiterals() throws {
        let decoder = JSONDecoder()

        // null literal
        let nullVal = try decoder.decode(BurnBarSQLValue.self, from: Data("null".utf8))
        XCTAssertEqual(nullVal, .null)

        // integer literal
        let intVal = try decoder.decode(BurnBarSQLValue.self, from: Data("12345".utf8))
        XCTAssertEqual(intVal, .integer(12345))

        // double literal
        let doubleVal = try decoder.decode(BurnBarSQLValue.self, from: Data("123.456".utf8))
        guard case .real(let d) = doubleVal else {
            XCTFail("Expected .real, got \(doubleVal)")
            return
        }
        XCTAssertEqual(d, 123.456, accuracy: 0.0001)

        // string literal
        let stringVal = try decoder.decode(BurnBarSQLValue.self, from: Data("\"test message\"".utf8))
        XCTAssertEqual(stringVal, .text("test message"))

        // blob envelope literal
        let expectedData = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let blobJson = "{\"$blob\": \"\(expectedData.base64EncodedString())\"}"
        let blobVal = try decoder.decode(BurnBarSQLValue.self, from: Data(blobJson.utf8))
        XCTAssertEqual(blobVal, .blob(expectedData))
    }

    func test_sqlValue_decodeCorruptedPayload_throwsError() {
        let decoder = JSONDecoder()

        // Array literal is unsupported
        XCTAssertThrowsError(try decoder.decode(BurnBarSQLValue.self, from: Data("[1, 2, 3]".utf8)))

        // Boolean literal is unsupported
        XCTAssertThrowsError(try decoder.decode(BurnBarSQLValue.self, from: Data("true".utf8)))

        // Object without $blob is unsupported
        XCTAssertThrowsError(try decoder.decode(BurnBarSQLValue.self, from: Data("{\"invalid\": 123}".utf8)))

        // Object with invalid base64 in $blob
        XCTAssertThrowsError(try decoder.decode(BurnBarSQLValue.self, from: Data("{\"$blob\": \"!!!not-valid-base64???\"}".utf8)))
    }

    func test_sqlValue_hashableAndEquatable() {
        let v1 = BurnBarSQLValue.integer(10)
        let v2 = BurnBarSQLValue.integer(10)
        let v3 = BurnBarSQLValue.text("10")
        let v4 = BurnBarSQLValue.null

        XCTAssertEqual(v1, v2)
        XCTAssertNotEqual(v1, v3)
        XCTAssertNotEqual(v1, v4)

        var set = Set<BurnBarSQLValue>()
        set.insert(v1)
        set.insert(v2)
        set.insert(v3)
        set.insert(v4)
        XCTAssertEqual(set.count, 3)
    }

    // MARK: - BurnBarSearchSQLRequest

    func test_searchSQLRequest_codableRoundTrip_defaults() throws {
        let req = BurnBarSearchSQLRequest(sql: "SELECT 1")
        XCTAssertEqual(req.sql, "SELECT 1")
        XCTAssertTrue(req.args.isEmpty)
        XCTAssertNil(req.maxRows)

        let encoded = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(BurnBarSearchSQLRequest.self, from: encoded)

        XCTAssertEqual(decoded.sql, "SELECT 1")
        XCTAssertEqual(decoded.args, [])
        XCTAssertNil(decoded.maxRows)
        XCTAssertEqual(req, decoded)
    }

    func test_searchSQLRequest_codableRoundTrip_full() throws {
        let blobData = Data([0xAA, 0xBB])
        let req = BurnBarSearchSQLRequest(
            sql: "SELECT * FROM t WHERE id = ? AND count > ? AND score >= ? AND data = ? AND active = ?",
            args: [
                .text("c1"),
                .integer(5),
                .real(1.5),
                .blob(blobData),
                .null
            ],
            maxRows: 500
        )

        let encoded = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(BurnBarSearchSQLRequest.self, from: encoded)

        XCTAssertEqual(decoded.sql, req.sql)
        XCTAssertEqual(decoded.args, req.args)
        XCTAssertEqual(decoded.maxRows, 500)
        XCTAssertEqual(req, decoded)
    }

    // MARK: - BurnBarSearchSQLResult

    func test_searchSQLResult_codableRoundTrip() throws {
        let result = BurnBarSearchSQLResult(
            columns: ["id", "count", "name", "blob_data", "extra"],
            rows: [
                [.text("row1"), .integer(10), .text("first"), .blob(Data([1, 2])), .null],
                [.text("row2"), .integer(20), .text("second"), .blob(Data([3, 4])), .real(4.5)]
            ],
            truncated: true
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BurnBarSearchSQLResult.self, from: encoded)

        XCTAssertEqual(decoded.columns, ["id", "count", "name", "blob_data", "extra"])
        XCTAssertEqual(decoded.rows.count, 2)
        XCTAssertEqual(decoded.rows[0], [.text("row1"), .integer(10), .text("first"), .blob(Data([1, 2])), .null])
        XCTAssertTrue(decoded.truncated)
        XCTAssertEqual(result, decoded)
    }

    // MARK: - BurnBarSearchQueryRequest / Hit / Plan / Result

    func test_searchQueryContracts_codableRoundTrip() throws {
        let req = BurnBarSearchQueryRequest(
            query: "test query",
            providerRaw: "claude",
            projectName: "burnbar",
            dateRangeStartEpoch: 1700000000.0,
            dateRangeEndEpoch: 1700003600.0,
            resultLimit: 25,
            queryEmbedding: [0.1, 0.2, 0.3],
            embeddingVersionID: "v1",
            embeddingDimension: 3,
            embeddingDistanceMetric: .cosine,
            skipSemanticSearch: false
        )

        let encodedReq = try JSONEncoder().encode(req)
        let decodedReq = try JSONDecoder().decode(BurnBarSearchQueryRequest.self, from: encodedReq)
        XCTAssertEqual(decodedReq.query, "test query")
        XCTAssertEqual(decodedReq.providerRaw, "claude")
        XCTAssertEqual(decodedReq.projectName, "burnbar")
        XCTAssertEqual(decodedReq.resultLimit, 25)
        XCTAssertEqual(decodedReq.queryEmbedding, [0.1, 0.2, 0.3])
        XCTAssertEqual(decodedReq.embeddingVersionID, "v1")
        XCTAssertEqual(decodedReq.embeddingDimension, 3)
        XCTAssertEqual(decodedReq.embeddingDistanceMetric, .cosine)
        XCTAssertFalse(decodedReq.skipSemanticSearch)
        XCTAssertEqual(req, decodedReq)

        let hit = BurnBarIndexedSearchHit(
            chunkID: "chunk-1",
            sourceKind: "conversation",
            sourceID: "source-1",
            title: "Hit Title",
            snippet: "Hit Snippet",
            provider: "claude",
            projectName: "burnbar",
            relevanceScore: 0.95,
            hitSource: .hybrid
        )

        let encodedHit = try JSONEncoder().encode(hit)
        let decodedHit = try JSONDecoder().decode(BurnBarIndexedSearchHit.self, from: encodedHit)
        XCTAssertEqual(decodedHit.chunkID, "chunk-1")
        XCTAssertEqual(decodedHit.relevanceScore, 0.95)
        XCTAssertEqual(decodedHit.hitSource, .hybrid)
        XCTAssertEqual(hit, decodedHit)

        XCTAssertEqual(BurnBarHitSource.lexical.rawValue, "lexical")
        XCTAssertEqual(BurnBarHitSource.semantic.rawValue, "semantic")
        XCTAssertEqual(BurnBarHitSource.hybrid.rawValue, "hybrid")

        let plan = BurnBarSearchPlan(
            mode: .retrieve,
            lexicalFTSQuery: "test",
            semanticText: "test",
            aggregatePatterns: [],
            note: "plan note"
        )
        let queryResult = BurnBarSearchQueryResult(
            plan: plan,
            aggregateOccurrenceCount: 42,
            hits: [hit],
            degradedMessage: "degraded",
            semanticSearchPerformed: true,
            semanticHitCount: 1
        )

        let encodedQueryResult = try JSONEncoder().encode(queryResult)
        let decodedQueryResult = try JSONDecoder().decode(BurnBarSearchQueryResult.self, from: encodedQueryResult)
        XCTAssertEqual(decodedQueryResult.aggregateOccurrenceCount, 42)
        XCTAssertEqual(decodedQueryResult.hits.count, 1)
        XCTAssertEqual(decodedQueryResult.degradedMessage, "degraded")
        XCTAssertTrue(decodedQueryResult.semanticSearchPerformed)
        XCTAssertEqual(decodedQueryResult.semanticHitCount, 1)
        XCTAssertEqual(queryResult, decodedQueryResult)
    }
}
