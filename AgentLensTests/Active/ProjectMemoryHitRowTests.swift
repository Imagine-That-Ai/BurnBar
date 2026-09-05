import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// B9: the app's half is one explanation line per hit, formatted from the
/// daemon's ranking report. No scoring happens here.
@MainActor
final class ProjectMemoryHitRowTests: XCTestCase {

    private func hit(
        memoryID: String = "mem_fixture_1",
        matchedBy: String?,
        why: BurnBarMemoryWhyBreakdown?
    ) -> BurnBarProjectMemoryHit {
        BurnBarProjectMemoryHit(
            memoryID: memoryID,
            projectID: "proj_fixture",
            kind: "fact",
            scope: "project",
            confidence: 1.0,
            bodyRedacted: "Fixture fact snippet",
            tags: ["test"],
            sourcePath: "Sources/Test.swift",
            snippet: "Fixture fact snippet",
            rank: 0,
            reviewStatus: .approved,
            matchedBy: matchedBy,
            why: why
        )
    }

    func test_the_app_renders_one_explanation_line_per_hit() {
        let hits = [
            hit(
                memoryID: "mem_hybrid",
                matchedBy: "hybrid",
                why: BurnBarMemoryWhyBreakdown(
                    lexicalRank: 1,
                    bm25: 3.1416,
                    semanticRank: 2,
                    cosine: 0.8842,
                    salience: 0.95,
                    recency: 0.85
                )
            ),
            hit(
                memoryID: "mem_semantic",
                matchedBy: "semantic",
                why: BurnBarMemoryWhyBreakdown(semanticRank: 4, cosine: 0.71, salience: 0.2, recency: 1.0)
            ),
            hit(
                memoryID: "mem_reranked",
                matchedBy: "lexical",
                why: BurnBarMemoryWhyBreakdown(
                    lexicalRank: 3,
                    bm25: 2.0,
                    salience: 0.5,
                    recency: 0.5,
                    rerankScore: 0.98,
                    reranker: "cross-encoder"
                )
            )
        ]

        let lines = hits.map(\.whyExplanation)

        XCTAssertEqual(
            lines,
            [
                "Matched by hybrid: lexical #1 (bm25 3.14), semantic #2 (cos 0.88), salience 0.95, recency 0.85",
                "Matched by semantic: semantic #4 (cos 0.71), salience 0.20, recency 1.00",
                "Matched by lexical: lexical #3 (bm25 2.00), salience 0.50, recency 0.50, cross-encoder 0.98"
            ]
        )
        XCTAssertEqual(Set(lines.compactMap { $0 }).count, 3, "one distinct line per hit")

        // The row is a pure function of the hit; building it must not throw or
        // require any recall machinery.
        for hit in hits {
            _ = ProjectMemoryHitRow(hit: hit)
        }
    }

    /// An older daemon, or a browse listing, reports no breakdown. The row shows
    /// no explanation rather than an invented one.
    func test_a_hit_without_a_breakdown_has_no_explanation_line() throws {
        XCTAssertNil(hit(matchedBy: nil, why: nil).whyExplanation)

        // And a decode of an old payload (no `matchedBy`, no `why`) still works.
        let legacy = """
        {
          "memoryID": "mem_legacy", "projectID": "proj_fixture", "kind": "fact",
          "scope": "project", "confidence": 1.0, "bodyRedacted": "b", "tags": [],
          "snippet": "b", "rank": 0
        }
        """
        let decoded = try JSONDecoder().decode(BurnBarProjectMemoryHit.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.matchedBy)
        XCTAssertNil(decoded.why)
        XCTAssertNil(decoded.whyExplanation)
    }

    /// The breakdown travels on the wire in the engine's shape: `matchedBy` beside
    /// `why`, with `why` holding exactly the engine's eight members.
    func test_the_breakdown_round_trips_in_the_engines_shape() throws {
        let encoded = try JSONEncoder().encode(
            hit(
                matchedBy: "hybrid",
                why: BurnBarMemoryWhyBreakdown(
                    lexicalRank: 1,
                    bm25: 3.1416,
                    semanticRank: 2,
                    cosine: 0.8842,
                    salience: 0.95,
                    recency: 0.85
                )
            )
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["matchedBy"] as? String, "hybrid", "matchedBy is a sibling of why, as in _read.py")
        let why = try XCTUnwrap(object["why"] as? [String: Any])
        XCTAssertEqual(
            Set(why.keys),
            ["lexicalRank", "bm25", "semanticRank", "cosine", "salience", "recency"],
            "nil members are omitted; the present ones are the engine's names"
        )

        let decoded = try JSONDecoder().decode(BurnBarProjectMemoryHit.self, from: encoded)
        XCTAssertEqual(decoded.matchedBy, "hybrid")
        XCTAssertEqual(decoded.why?.lexicalRank, 1)
        XCTAssertEqual(decoded.why?.cosine, 0.8842)
        XCTAssertNil(decoded.why?.rerankScore)
    }
}
