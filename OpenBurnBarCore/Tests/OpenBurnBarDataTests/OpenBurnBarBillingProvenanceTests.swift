import Foundation
import GRDB
@testable import OpenBurnBarData
import XCTest

/// v60 billing provenance, proven at the two places it can go wrong:
///
///  1. **Agreement.** Three surfaces can decide a row's `billingKind` — the SQL
///     backfill (`OpenBurnBarDatabase.billingKindBackfillSQL`), this module's
///     `OpenBurnBarBillingProvenance` write-time classifier, and the Windows
///     `BillingProvenance.Classify` peer. A disagreement would corrupt the
///     money-vs-imputed split permanently and silently. These tests run the REAL
///     backfill SQL against a REAL migrated database for every combination the
///     classifier distinguishes and require identical answers — a copy of the
///     CASE arms in a test fixture would only prove the copy agrees with itself.
///  2. **Write-through.** The Linux/daemon write seam
///     (`OpenBurnBarLocalDatabase.recordUsage`) must actually PERSIST the kind.
///     Before v60's write-seam fix it wrote no `billingKind` column at all, so
///     every Linux-written row sat at the `'unknown'` default forever even
///     though the column existed.
///
/// Runs on macOS as well as Linux: `OpenBurnBarData` is the same storage module
/// on both, so the Linux gate and the authoring host prove the same code.
final class OpenBurnBarBillingProvenanceTests: XCTestCase {
    private let passphrase = "openburnbar-billing-provenance-tests-passphrase-2026"

    /// Every provider name the v60 CASE distinguishes, plus names it must NOT.
    private static let providers: [String] = [
        // Plan-first harnesses (the `subscription` arm).
        "Claude Code", "Codex", "Copilot", "Cursor", "Cursor Agent",
        "Factory", "Junie", "Windsurf", "Warp",
        // Bring-your-own-key harnesses (the `api` arm).
        "Aider", "Hermes", "DeepSeek", "OpenAI", "xAI",
        // Neither: must stay `unknown` under provider_log, and must NOT stop
        // billing_api/daemon rows from being `api`.
        "Gemini", "Kimi", "", "cursor", "CLAUDE CODE", "Unheard-Of Harness"
    ]

    /// Every `UsageSource` raw value, plus values no enum case produces (a row
    /// written by an older/newer build, or the historical schema default).
    private static let usageSources: [String] = [
        "provider_log", "in_app_chat", "cursor_bridge", "billing_api",
        "daemon", "unknown", "measured", ""
    ]

    // MARK: - 1. The classifier and the SQL backfill agree, row for row

    func test_backfillSQL_classifiesEveryCombination_exactlyLikeTheSwiftClassifier() throws {
        let database = try makeDatabase(named: "backfill-parity")
        defer { try? database.close() }

        var expected: [String: String] = [:]
        for usageSource in Self.usageSources {
            for provider in Self.providers {
                let id = Self.rowID(provider: provider, usageSource: usageSource)
                try database.recordUsage(usageRow(
                    id: id,
                    provider: provider,
                    usageSource: usageSource,
                    // Force the backfill to be the thing under test: land every
                    // row at the schema default and let the SQL classify it.
                    billingKind: OpenBurnBarBillingProvenance.unknown
                ))
                expected[id] = OpenBurnBarBillingProvenance.classify(
                    provider: provider,
                    usageSource: usageSource
                )
            }
        }

        // The migration's own SQL, not a paraphrase of it.
        try database.execute(sql: OpenBurnBarDatabase.billingKindBackfillSQL)

        let actual = try database.billingKindsByID()
        XCTAssertEqual(actual.count, expected.count)
        for (id, expectedKind) in expected {
            XCTAssertEqual(
                actual[id],
                expectedKind,
                "SQL backfill and Swift classifier disagree for \(id)"
            )
        }
    }

    func test_classifier_matchesTheDocumentedCaseArms() {
        // billing_api / daemon ingest is real money by construction — the
        // provider column is not consulted, not even for a plan-first harness.
        for provider in Self.providers {
            XCTAssertEqual(
                OpenBurnBarBillingProvenance.classify(provider: provider, usageSource: "billing_api"),
                OpenBurnBarBillingProvenance.api
            )
            XCTAssertEqual(
                OpenBurnBarBillingProvenance.classify(provider: provider, usageSource: "daemon"),
                OpenBurnBarBillingProvenance.api
            )
        }

        for provider in OpenBurnBarBillingProvenance.subscriptionFirstProviders {
            XCTAssertEqual(
                OpenBurnBarBillingProvenance.classify(provider: provider, usageSource: "provider_log"),
                OpenBurnBarBillingProvenance.subscription
            )
        }
        for provider in OpenBurnBarBillingProvenance.apiKeyFirstProviders {
            XCTAssertEqual(
                OpenBurnBarBillingProvenance.classify(provider: provider, usageSource: "provider_log"),
                OpenBurnBarBillingProvenance.api
            )
        }

        // Unrecognized harness, or an ingest route with no billing meaning:
        // `unknown` is the honest answer, never a guess.
        XCTAssertEqual(
            OpenBurnBarBillingProvenance.classify(provider: "Gemini", usageSource: "provider_log"),
            OpenBurnBarBillingProvenance.unknown
        )
        XCTAssertEqual(
            OpenBurnBarBillingProvenance.classify(provider: "Claude Code", usageSource: "in_app_chat"),
            OpenBurnBarBillingProvenance.unknown
        )
        XCTAssertEqual(
            OpenBurnBarBillingProvenance.classify(provider: "Claude Code", usageSource: "cursor_bridge"),
            OpenBurnBarBillingProvenance.unknown
        )

        // Provider matching is exact, never case- or whitespace-folded: the SQL
        // `IN (…)` comparison is exact, so the classifier must be too.
        XCTAssertEqual(
            OpenBurnBarBillingProvenance.classify(provider: "claude code", usageSource: "provider_log"),
            OpenBurnBarBillingProvenance.unknown
        )
    }

    func test_backfill_leavesAlreadyClassifiedRowsAlone() throws {
        let database = try makeDatabase(named: "backfill-sticky")
        defer { try? database.close() }

        // A row stamped `subscription` whose provider/usageSource would classify
        // as `api`: the backfill's `WHERE billingKind = 'unknown'` must not
        // relitigate a decision a writer already made.
        try database.recordUsage(usageRow(
            id: "stamped",
            provider: "OpenAI",
            usageSource: "provider_log",
            billingKind: OpenBurnBarBillingProvenance.subscription
        ))
        try database.execute(sql: OpenBurnBarDatabase.billingKindBackfillSQL)

        XCTAssertEqual(
            try database.billingKindsByID()["stamped"],
            OpenBurnBarBillingProvenance.subscription
        )
    }

    // MARK: - 2. The write seam persists the kind

    func test_recordUsage_persistsExplicitBillingKind() throws {
        let database = try makeDatabase(named: "write-explicit")
        defer { try? database.close() }

        try database.recordUsage(usageRow(
            id: "explicit",
            provider: "Claude Code",
            usageSource: "provider_log",
            billingKind: OpenBurnBarBillingProvenance.api
        ))

        // The explicit stamp wins over what the classifier would have derived.
        XCTAssertEqual(try database.billingKindsByID()["explicit"], OpenBurnBarBillingProvenance.api)
    }

    func test_recordUsage_derivesBillingKind_whenTheCallerDidNotClassify() throws {
        let database = try makeDatabase(named: "write-derived")
        defer { try? database.close() }

        try database.recordUsage(usageRow(id: "plan", provider: "Claude Code", usageSource: "provider_log"))
        try database.recordUsage(usageRow(id: "byok", provider: "OpenAI", usageSource: "provider_log"))
        try database.recordUsage(usageRow(id: "gateway", provider: "Gemini", usageSource: "daemon"))
        try database.recordUsage(usageRow(id: "opaque", provider: "Gemini", usageSource: "provider_log"))

        let kinds = try database.billingKindsByID()
        XCTAssertEqual(kinds["plan"], OpenBurnBarBillingProvenance.subscription)
        XCTAssertEqual(kinds["byok"], OpenBurnBarBillingProvenance.api)
        XCTAssertEqual(kinds["gateway"], OpenBurnBarBillingProvenance.api)
        XCTAssertEqual(kinds["opaque"], OpenBurnBarBillingProvenance.unknown)
    }

    func test_recordUsage_survivesReopen_withNonDefaultBillingKind() throws {
        let directory = try makeTempDirectory()
        let path = directory.appendingPathComponent("reopen.sqlite").path

        let database = try openDatabase(path: path)
        try database.recordUsage(usageRow(id: "durable", provider: "Codex", usageSource: "provider_log"))
        try database.close()

        let reopened = try openDatabase(path: path)
        defer { try? reopened.close() }
        XCTAssertEqual(
            try reopened.billingKindsByID()["durable"],
            OpenBurnBarBillingProvenance.subscription,
            "a non-default billingKind must survive close/reopen, not just live in the page cache"
        )
    }

    func test_usageRowDefaults_preserveThePreV60WrittenValue() throws {
        // The row gained `usageSource` alongside `billingKind`; a caller that
        // sets neither must still write exactly what the column defaulted to
        // before the fields existed, so no existing writer changes meaning.
        let row = OpenBurnBarUsageRow(
            id: "defaulted",
            provider: "Claude Code",
            sessionID: "session",
            projectName: "BurnBar",
            model: "claude-opus-4-8",
            inputTokens: 1,
            outputTokens: 1,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 2,
            cost: 0,
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_000),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            providerID: "claude-code",
            providerAccountID: "acct",
            providerAccountLabel: "acct",
            providerAccountSource: "secret_store"
        )
        XCTAssertEqual(row.usageSource, "unknown")
        XCTAssertNil(row.billingKind)
        XCTAssertEqual(row.effectiveBillingKind, OpenBurnBarBillingProvenance.unknown)
    }

    // MARK: - Helpers

    private static func rowID(provider: String, usageSource: String) -> String {
        "row|\(usageSource)|\(provider)"
    }

    private func makeDatabase(named name: String) throws -> OpenBurnBarLocalDatabase {
        let directory = try makeTempDirectory()
        return try openDatabase(path: directory.appendingPathComponent("\(name).sqlite").path)
    }

    private func openDatabase(path: String) throws -> OpenBurnBarLocalDatabase {
        try OpenBurnBarLocalDatabase.open(
            path: path,
            options: OpenBurnBarDatabaseOpenOptions(
                secretStore: OpenBurnBarStaticSecretStore(passphrase: passphrase)
            )
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-billing-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func usageRow(
        id: String,
        provider: String,
        usageSource: String,
        billingKind: String? = nil
    ) -> OpenBurnBarUsageRow {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return OpenBurnBarUsageRow(
            id: id,
            provider: provider,
            // The natural-key unique index is (provider, sessionId, model, …);
            // give every row its own session so combinations never collide.
            sessionID: "session-\(id)",
            projectName: "BurnBar",
            model: "claude-opus-4-8",
            inputTokens: 100,
            outputTokens: 25,
            cacheCreationTokens: 10,
            cacheReadTokens: 5,
            totalTokens: 140,
            cost: 0.01,
            startTime: now,
            endTime: now.addingTimeInterval(4),
            createdAt: now,
            providerID: "provider-id",
            providerAccountID: "acct-\(id)",
            providerAccountLabel: "acct",
            providerAccountSource: "secret_store",
            usageSource: usageSource,
            billingKind: billingKind
        )
    }
}

private extension OpenBurnBarLocalDatabase {
    func execute(sql: String) throws {
        try pool.write { db in
            try db.execute(sql: sql)
        }
    }

    func billingKindsByID() throws -> [String: String] {
        try pool.read { db in
            var kinds: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, billingKind FROM token_usage")
            for row in rows {
                kinds[row["id"]] = row["billingKind"]
            }
            return kinds
        }
    }
}
