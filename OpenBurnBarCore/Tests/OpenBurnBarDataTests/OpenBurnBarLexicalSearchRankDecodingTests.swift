import Foundation
import GRDB
@testable import OpenBurnBarData
import XCTest

/// `lexicalSearch` reads FTS5's `bm25()` score out of a GRDB row. Unlike the
/// store-side reads this change also converted, this one was never broken:
/// `bm25()` yields REAL, so the previous `row["rank"] as? Double` cast did
/// succeed. It moved to the typed subscript because the untyped one casts raw
/// SQLite storage — the moment a column's storage class shifts, the cast nils
/// and the neighbouring `?? 0` swallows it silently, collapsing every hit to a
/// tie at zero and destroying the ORDER BY the caller depends on. These tests
/// pin the observable contract (a real score, in relevance order) so that
/// failure mode has to announce itself.
///
/// The Linux durability suite also calls `lexicalSearch`, but it skips itself
/// off Linux, so on the authoring host and in the package coverage lane these
/// lines had no executing test at all.
final class OpenBurnBarLexicalSearchRankDecodingTests: XCTestCase {
    private let passphrase = "openburnbar-lexical-rank-tests-passphrase-2026"

    /// A real `bm25()` score is strictly negative, so a rank of exactly zero is
    /// the `?? 0` default showing through rather than a plausible score.
    func testLexicalSearchDecodesTheBM25RankRatherThanFallingBackToZero() throws {
        let database = try makeDatabase(named: "lexical-rank")
        defer { try? database.close() }
        try database.indexSearchFixture(searchFixture())

        let hits = try database.lexicalSearch("Hermes")

        XCTAssertEqual(hits.map(\.chunkID), ["search-chunk-2"])
        let hit = try XCTUnwrap(hits.first)
        XCTAssertNotEqual(hit.rank, 0, "rank fell back to the ?? 0 default, so the row decode failed")
        XCTAssertLessThan(hit.rank, 0, "bm25() scores are negative; a non-negative rank is not a real score")
        XCTAssertTrue(hit.snippet.contains("Hermes"))
        XCTAssertEqual(hit.documentID, "search-doc-1")
        XCTAssertTrue(hit.text.contains("stable rank"))
    }

    /// Ordering is the reason the score is read at all: a decode that collapsed
    /// every rank to the default would still return both rows, just in an order
    /// that no longer reflects relevance.
    func testLexicalSearchRanksDistinctlyAcrossMatchingChunks() throws {
        let database = try makeDatabase(named: "lexical-rank-order")
        defer { try? database.close() }
        try database.indexSearchFixture(searchFixture())

        let hits = try database.lexicalSearch("quota OR Hermes")

        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.rank < 0 })
        XCTAssertEqual(hits.map(\.rank), hits.map(\.rank).sorted())
    }

    private func makeDatabase(named name: String) throws -> OpenBurnBarLocalDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-lexical-rank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try OpenBurnBarLocalDatabase.open(
            path: directory.appendingPathComponent("\(name).sqlite").path,
            options: OpenBurnBarDatabaseOpenOptions(
                secretStore: OpenBurnBarStaticSecretStore(passphrase: passphrase)
            )
        )
    }

    private func searchFixture() -> OpenBurnBarSearchFixture {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return OpenBurnBarSearchFixture(
            documentID: "search-doc-1",
            sourceID: "thread-search-1",
            projectName: "BurnBar",
            provider: "Claude Code",
            title: "Rank decoding transcript",
            bodyPreview: "Quota and Hermes search transcript.",
            chunks: [
                OpenBurnBarSearchFixtureChunk(
                    id: "search-chunk-1",
                    sourceID: "thread-search-1",
                    ordinal: 0,
                    sectionPath: "messages/0",
                    text: "The quota note mentions precise token ownership.",
                    tokenCount: 8,
                    vectorBlob: Data([0, 0, 128, 63, 0, 0, 0, 64])
                ),
                OpenBurnBarSearchFixtureChunk(
                    id: "search-chunk-2",
                    sourceID: "thread-search-1",
                    ordinal: 1,
                    sectionPath: "messages/1",
                    text: "Hermes shell search should return this provider transcript with stable rank.",
                    tokenCount: 11,
                    vectorBlob: Data([0, 0, 64, 64, 0, 0, 128, 64])
                )
            ],
            embeddingModelID: "fixture-model",
            embeddingVersionID: "fixture-version",
            embeddingDimension: 2,
            vectorBackendID: "sqlite-vector-fixture",
            snapshotPath: "/var/lib/openburnbar/vector-fixture.snapshot",
            vectorMetadataJSON: #"{"source":"lexical-rank-test","parity":"fixture"}"#,
            now: now
        )
    }
}
