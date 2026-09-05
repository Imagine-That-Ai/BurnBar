import XCTest
@testable import OpenBurnBar

/// B11: the card is an aggregation of output that already exists. These tests pin
/// it field-for-field against a doctor payload shaped exactly like the one
/// `memory_engine/_admin.py`'s `doctor()` emits, so a drift on either side shows
/// up here rather than as a wrong number in Settings.
@MainActor
final class ProjectMemoryHealthCardTests: XCTestCase {

    /// A doctor payload with the members `_admin.py` actually emits, in its own
    /// severity vocabulary (`error` / `warn`).
    private static let doctorJSON: [String: Any] = [
        "status": "degraded",
        "projectID": "proj_fixture_openburnbar_123",
        "projectName": "OpenBurnBar",
        "projectRoot": "/Users/dewclaw/Documents/Projects/BurnBar",
        "engine": [
            "schemaVersion": 1,
            "dbPath": "/path/to/openburnbar.sqlite",
            "dbExists": true,
            "memories": 42
        ],
        "auditChain": ["ok": true, "events": 10],
        "findings": [
            [
                "severity": "error",
                "code": "UNDECRYPTABLE_ROWS",
                "detail": "1 of 10 sampled rows cannot be decrypted with key default",
                "fix": "Check encryption key configuration"
            ],
            [
                "severity": "warn",
                "code": "EMBEDDINGS_UNAVAILABLE",
                "detail": "lexical-only recall",
                "fix": "Run `ollama pull nomic-embed-text`"
            ],
            [
                "severity": "warn",
                "code": "LARGE_STORE",
                "detail": "42 memories; consider pruning"
            ]
        ]
    ]

    private static let analyticsJSON: [String: Any] = [
        "total": 42,
        "embeddingCoverage": 0.952,
        "vaultEntries": 3
    ]

    func test_health_card_matches_doctor_json_exactly_for_a_fixture_project() throws {
        let doctorJSON = Self.doctorJSON
        let card = ProjectMemoryHealthCardModel(doctorJSON: doctorJSON, analyticsJSON: Self.analyticsJSON)

        XCTAssertEqual(card.projectID, doctorJSON["projectID"] as? String)
        XCTAssertEqual(card.projectName, doctorJSON["projectName"] as? String)
        XCTAssertEqual(card.projectRoot, doctorJSON["projectRoot"] as? String)
        XCTAssertEqual(card.status, doctorJSON["status"] as? String)

        let engine = try XCTUnwrap(doctorJSON["engine"] as? [String: Any])
        XCTAssertEqual(card.totalMemories, engine["memories"] as? Int)

        let auditChain = try XCTUnwrap(doctorJSON["auditChain"] as? [String: Any])
        XCTAssertEqual(card.auditChainOK, auditChain["ok"] as? Bool)

        // Every finding survives, in order, member for member — no reshaping.
        let rawFindings = try XCTUnwrap(doctorJSON["findings"] as? [[String: Any]])
        XCTAssertEqual(card.findings.count, rawFindings.count)
        for (finding, raw) in zip(card.findings, rawFindings) {
            XCTAssertEqual(finding.code, raw["code"] as? String)
            XCTAssertEqual(finding.severity, raw["severity"] as? String)
            XCTAssertEqual(finding.detail, raw["detail"] as? String)
            XCTAssertEqual(finding.fix, raw["fix"] as? String)
        }

        XCTAssertEqual(card.errorCount, 1)
        XCTAssertEqual(card.warningCount, 2)
        XCTAssertEqual(card.infoCount, 0)
        XCTAssertEqual(card.severityCounts, ["error": 1, "warn": 2])

        XCTAssertEqual(card.embeddingCoverage, 0.952)
        XCTAssertEqual(card.vaultEntries, 3)
    }

    /// The rendered stats are pinned, not just the parsed model: this is what the
    /// member sees, placeholders included.
    func test_health_card_renders_a_placeholder_when_sync_observability_is_absent() {
        let card = ProjectMemoryHealthCardModel(
            doctorJSON: Self.doctorJSON,
            analyticsJSON: Self.analyticsJSON
        )

        XCTAssertEqual(
            card.statRows.map { [$0.title, $0.value] },
            [
                ["Memories", "42"],
                ["Audit chain", "Intact"],
                ["Last pull", "—"],
                ["Marker age", "—"],
                ["Embedded", "95%"],
                ["Vault", "3"]
            ],
            "sync observability is not in either payload yet, so the card says so"
        )
        XCTAssertEqual(card.lastPullAge, ProjectMemoryHealthCardModel.placeholder)
        XCTAssertEqual(card.markerAge, ProjectMemoryHealthCardModel.placeholder)

        // Once E19 supplies them, the same rows carry the real values.
        let observed = ProjectMemoryHealthCardModel(
            doctorJSON: Self.doctorJSON,
            analyticsJSON: Self.analyticsJSON,
            lastPullAge: "4 min ago",
            markerAge: "2 h"
        )
        XCTAssertEqual(
            observed.statRows.first { $0.title == "Last pull" }?.value,
            "4 min ago"
        )
        XCTAssertEqual(observed.statRows.first { $0.title == "Marker age" }?.value, "2 h")
    }

    /// A minimal payload — a healthy store with nothing to report — must not
    /// invent counts, findings, or a broken audit chain.
    func test_a_minimal_doctor_payload_reports_nothing_rather_than_zeroes_it_did_not_measure() {
        let card = ProjectMemoryHealthCardModel(doctorJSON: [
            "status": "ok",
            "projectID": "proj_minimal_fixture",
            "findings": []
        ])

        XCTAssertEqual(card.status, "ok")
        XCTAssertEqual(card.projectID, "proj_minimal_fixture")
        XCTAssertNil(card.projectName)
        XCTAssertNil(card.projectRoot)
        XCTAssertEqual(card.totalMemories, 0)
        XCTAssertEqual(card.errorCount, 0)
        XCTAssertEqual(card.warningCount, 0)
        XCTAssertTrue(card.findings.isEmpty)
        XCTAssertTrue(card.auditChainOK, "an unreported audit chain is not a broken one")
        XCTAssertNil(card.embeddingCoverage)
        XCTAssertNil(card.vaultEntries)
        XCTAssertEqual(
            card.statRows.map(\.title),
            ["Memories", "Audit chain", "Last pull", "Marker age"],
            "counters the engine did not report get no row at all"
        )
    }

    /// A broken audit chain is the one thing on this card that must shout.
    func test_a_broken_audit_chain_is_flagged() {
        let card = ProjectMemoryHealthCardModel(doctorJSON: [
            "status": "degraded",
            "projectID": "proj_broken",
            "auditChain": ["ok": false, "brokenAtSeq": 17],
            "findings": [[
                "severity": "error",
                "code": "AUDIT_CHAIN_BROKEN",
                "detail": "hash chain breaks at seq 17"
            ]]
        ])

        XCTAssertFalse(card.auditChainOK)
        XCTAssertEqual(card.errorCount, 1)
        let auditRow = card.statRows.first { $0.title == "Audit chain" }
        XCTAssertEqual(auditRow?.value, "Broken")
        XCTAssertEqual(auditRow?.emphasis, .bad)
    }
}
