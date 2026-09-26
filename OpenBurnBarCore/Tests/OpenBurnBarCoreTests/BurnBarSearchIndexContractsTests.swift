import XCTest
@testable import OpenBurnBarCore

/// Wave 2.1c-iv: the search-index app lane rides stable wire keys. Dates
/// are GRDB timestamp text (`yyyy-MM-dd HH:mm:ss.SSS`, UTC) — the exact
/// representation GRDB persists in `.datetime` columns; every row field
/// crosses verbatim.
final class BurnBarSearchIndexContractsTests: XCTestCase {
    func testApplyRoundTripsWithStableWireKeys() throws {
        let request = BurnBarSearchIndexApplyRequest(
            documentUpsert: BurnBarSearchIndexDocumentRow(
                id: "doc-1",
                sourceKind: "conversation",
                sourceID: "source-1",
                sourceVersionID: "v1",
                provider: "test-provider",
                projectName: "test-project",
                title: "Test title",
                subtitle: "Test subtitle",
                bodyPreview: "preview",
                sourceUpdatedAtText: "2026-09-23 04:00:00.000",
                indexedAtText: "2026-09-23 05:00:00.000",
                contentHash: "hash-1",
                createdAtText: "2026-09-23 05:00:00.000",
                updatedAtText: "2026-09-23 06:00:00.000"
            ),
            documentDelete: BurnBarSearchIndexDeleteDocuments(
                sourceKind: "skill_doc",
                sourceID: "source-9"
            ),
            chunkMutations: BurnBarSearchIndexChunkMutations(
                documentID: "doc-1",
                ftsTitle: "Test title",
                ftsProjectName: "test-project",
                ftsProvider: "test-provider",
                chunkIDsToDelete: ["chunk-old"],
                chunksToInsert: [BurnBarSearchIndexChunkRow(
                    id: "chunk-1",
                    documentID: "doc-1",
                    sourceKind: "conversation",
                    sourceID: "source-1",
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 12,
                    messageStartOffset: 0,
                    messageEndOffset: 12,
                    sectionPath: "root",
                    text: "hello world",
                    contentHash: "chunk-hash-1",
                    createdAtText: "2026-09-23 05:00:00.000",
                    updatedAtText: "2026-09-23 06:00:00.000"
                )]
            )
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let document = try XCTUnwrap(object["documentUpsert"] as? [String: Any])
        XCTAssertEqual(document["id"] as? String, "doc-1")
        XCTAssertEqual(document["sourceKind"] as? String, "conversation")
        XCTAssertEqual(document["sourceID"] as? String, "source-1")
        XCTAssertEqual(document["sourceVersionID"] as? String, "v1")
        XCTAssertEqual(document["provider"] as? String, "test-provider")
        XCTAssertEqual(document["projectName"] as? String, "test-project")
        XCTAssertEqual(document["title"] as? String, "Test title")
        XCTAssertEqual(document["subtitle"] as? String, "Test subtitle")
        XCTAssertEqual(document["bodyPreview"] as? String, "preview")
        XCTAssertEqual(document["sourceUpdatedAtText"] as? String, "2026-09-23 04:00:00.000")
        XCTAssertEqual(document["indexedAtText"] as? String, "2026-09-23 05:00:00.000")
        XCTAssertEqual(document["contentHash"] as? String, "hash-1")
        XCTAssertEqual(document["createdAtText"] as? String, "2026-09-23 05:00:00.000")
        XCTAssertEqual(document["updatedAtText"] as? String, "2026-09-23 06:00:00.000")
        let delete = try XCTUnwrap(object["documentDelete"] as? [String: Any])
        XCTAssertEqual(delete["sourceKind"] as? String, "skill_doc")
        XCTAssertEqual(delete["sourceID"] as? String, "source-9")
        let mutations = try XCTUnwrap(object["chunkMutations"] as? [String: Any])
        XCTAssertEqual(mutations["documentID"] as? String, "doc-1")
        XCTAssertEqual(mutations["ftsTitle"] as? String, "Test title")
        XCTAssertEqual(mutations["ftsProjectName"] as? String, "test-project")
        XCTAssertEqual(mutations["ftsProvider"] as? String, "test-provider")
        XCTAssertEqual(mutations["chunkIDsToDelete"] as? [String], ["chunk-old"])
        let chunks = try XCTUnwrap(mutations["chunksToInsert"] as? [[String: Any]])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0]["id"] as? String, "chunk-1")
        XCTAssertEqual(chunks[0]["documentID"] as? String, "doc-1")
        XCTAssertEqual(chunks[0]["ordinal"] as? Int, 0)
        XCTAssertEqual(chunks[0]["startOffset"] as? Int, 0)
        XCTAssertEqual(chunks[0]["endOffset"] as? Int, 12)
        XCTAssertEqual(chunks[0]["text"] as? String, "hello world")
        XCTAssertNil(chunks[0]["ftsRowid"])
        XCTAssertEqual(try JSONDecoder().decode(BurnBarSearchIndexApplyRequest.self, from: data), request)

        let response = BurnBarSearchIndexApplyResponse(
            documentsUpserted: 1,
            documentsDeleted: 2,
            chunksAdded: 3,
            chunksDeleted: 4
        )
        let responseData = try JSONEncoder().encode(response)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(responseObject["documentsUpserted"] as? Int, 1)
        XCTAssertEqual(responseObject["documentsDeleted"] as? Int, 2)
        XCTAssertEqual(responseObject["chunksAdded"] as? Int, 3)
        XCTAssertEqual(responseObject["chunksDeleted"] as? Int, 4)
        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarSearchIndexApplyResponse.self, from: responseData),
            response
        )
    }

    func testSearchIndexMethodUsesStableWireString() {
        XCTAssertEqual(
            BurnBarRPCMethod.searchIndexApply.rawValue,
            "daemon.search.index.apply"
        )
    }
}
