import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarInsights
@testable import OpenBurnBarRecap

// MARK: - Stubs

/// Serves prepared batches; records which months were asked for so the
/// "one scan, not twelve" contract can be observed.
private final class StubRecapSource: RecapSource, @unchecked Sendable {
    let batches: [RecapWindow: RecapRowBatch]
    private(set) var bulkRequests: [[RecapWindow]] = []
    private(set) var singleRequests: [RecapWindow] = []

    init(batches: [RecapWindow: RecapRowBatch]) { self.batches = batches }

    func rows(for window: RecapWindow) async throws -> RecapRowBatch {
        singleRequests.append(window)
        return batches[window] ?? .empty(window)
    }

    func rows(for windows: [RecapWindow]) async throws -> [RecapWindow: RecapRowBatch] {
        bulkRequests.append(windows)
        return windows.reduce(into: [:]) { $0[$1] = batches[$1] ?? .empty($1) }
    }
}

private struct StubVoiceAuthor: RecapVoiceAuthor {
    let json: String
    func author(_ request: RecapVoiceRequest) async throws -> RecapVoiceAuthorResult? {
        RecapVoiceAuthorResult(
            text: json,
            modelTag: InsightModelTag(
                providerKey: "test",
                modelID: "stub-1",
                displayName: "Stub",
                egressTier: .localOnly,
                stampedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }
}

// MARK: - Tests

final class RecapStoreAndComposerTests: XCTestCase {

    private let calendar = RecapFixtures.calendar()
    private let august = RecapWindow(year: 2026, month: 8)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func historyStore() throws -> RecapHistoryStore {
        try RecapHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    }

    private func recapStore() throws -> RecapStore {
        try RecapStore(fileURL: directory.appendingPathComponent("recaps.json"))
    }

    private func recap(
        _ window: RecapWindow,
        seal: RecapSealState,
        voiced: Bool = false,
        title: String = "Your August with AI"
    ) -> MonthlyRecap {
        MonthlyRecap(
            window: window,
            generatedAt: Date(timeIntervalSince1970: 0),
            title: title,
            cards: [],
            closingSentence: "A steady month.",
            isVoiceAuthored: voiced,
            sealState: seal
        )
    }

    // MARK: History store

    func testHistoryRoundTripsAndReportsGaps() async throws {
        let store = try historyStore()
        let july = august.previous
        try await store.upsert(RecapFixtures.facts(july, calendar: calendar))

        let stored = await store.facts(for: july)
        XCTAssertEqual(stored?.window, july)

        let missing = await store.monthsNeedingBackfill(endingAt: august, monthsBack: 3)
        XCTAssertEqual(missing.map(\.key), ["2026-05", "2026-06"])
    }

    /// A truncated read must never overwrite a complete one — that is how one
    /// bad fetch would poison every later comparison.
    func testPartialMonthCannotOverwriteAFullOne() async throws {
        let store = try historyStore()
        let full = RecapFixtures.facts(august, calendar: calendar)
        try await store.upsert(full)

        let partialBatch = RecapRowBatch(
            window: august,
            usages: Array(RecapFixtures.busyMonth(august, calendar: calendar).usages.prefix(3)),
            isPartial: true,
            hasSessionData: false
        )
        try await store.upsert(
            RecapFacts.build(batch: partialBatch, builtAt: august.end(calendar: calendar), calendar: calendar)
        )

        let kept = await store.facts(for: august)
        XCTAssertEqual(kept?.totalCostUSD, full.totalCostUSD)
        XCTAssertFalse(kept?.isPartial ?? true)
    }

    func testStaleSchemaMonthsAreDroppedOnLoad() async throws {
        let url = directory.appendingPathComponent("history.json")
        let stale = RecapFixtures.facts(august, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Hand-write a snapshot carrying a future fold version.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(RecapHistoryStore.Snapshot(months: [august.key: stale]))
            ) as? [String: Any]
        )
        var months = try XCTUnwrap(object["months"] as? [String: Any])
        var month = try XCTUnwrap(months[august.key] as? [String: Any])
        month["schemaVersion"] = RecapFacts.currentSchemaVersion + 1
        months[august.key] = month
        object["months"] = months
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let store = try RecapHistoryStore(fileURL: url)
        let loaded = await store.facts(for: august)
        XCTAssertNil(loaded, "a month folded by a different version must be dropped, not mis-compared")
    }

    // MARK: Recap store sealing

    func testSealedMonthRejectsOverwrite() async throws {
        let store = try recapStore()
        _ = try await store.save(recap(august, seal: .sealed, voiced: true, title: "Original"))
        let outcome = try await store.save(recap(august, seal: .sealed, voiced: true, title: "Rewritten"))

        XCTAssertEqual(outcome, .rejectedSealed)
        let kept = await store.recap(for: august)
        XCTAssertEqual(kept?.title, "Original", "last August must read the same way in December")
    }

    /// The one mutation a sealed month accepts: the writing it never got.
    /// Without this, enabling the AI toggle later would appear to do nothing.
    func testVoicelessSealAcceptsExactlyOneUpgrade() async throws {
        let store = try recapStore()
        _ = try await store.save(recap(august, seal: .sealedWithoutVoice, title: "Deterministic"))

        let upgrade = try await store.save(recap(august, seal: .sealed, voiced: true, title: "Edited"))
        XCTAssertEqual(upgrade, .storedAsVoiceUpgrade)
        let afterUpgrade = await store.recap(for: august)
        XCTAssertEqual(afterUpgrade?.title, "Edited")
        XCTAssertEqual(afterUpgrade?.sealState, .sealed)

        // And now it is closed for good.
        let second = try await store.save(recap(august, seal: .sealed, voiced: true, title: "Again"))
        XCTAssertEqual(second, .rejectedSealed)
    }

    func testUnvoicedSealRejectsAnotherDeterministicWrite() async throws {
        let store = try recapStore()
        _ = try await store.save(recap(august, seal: .sealedWithoutVoice, title: "Deterministic"))
        let outcome = try await store.save(recap(august, seal: .sealedWithoutVoice, title: "Rebuilt"))
        XCTAssertEqual(outcome, .rejectedSealed)
    }

    func testPreviewMonthsRemainRewritable() async throws {
        let store = try recapStore()
        _ = try await store.save(recap(august, seal: .preview, title: "First pass"))
        let outcome = try await store.save(recap(august, seal: .preview, title: "Second pass"))
        XCTAssertEqual(outcome, .stored)
        let kept = await store.recap(for: august)
        XCTAssertEqual(kept?.title, "Second pass")
    }

    // MARK: Composer

    private func events(_ stream: AsyncStream<RecapComposer.Event>) async -> [RecapComposer.Event] {
        var collected: [RecapComposer.Event] = []
        for await event in stream { collected.append(event) }
        return collected
    }

    func testComposerEmitsDeterministicDeckAndSealsWithoutVoice() async throws {
        let months = ([august] + august.priorMonths(3))
        let batches = Dictionary(uniqueKeysWithValues: months.map {
            ($0, RecapFixtures.busyMonth($0, calendar: calendar))
        })
        let source = StubRecapSource(batches: batches)
        let composer = RecapComposer(
            source: source,
            historyStore: try historyStore(),
            recapStore: try recapStore(),
            calendar: calendar
        )

        let now = RecapFixtures.date(2026, 9, 2, 9, calendar: calendar)
        let collected = await events(composer.build(window: august, now: now))

        guard case let .deterministic(first) = collected.first else {
            XCTFail("the deterministic deck must arrive first, always")
            return
        }
        XCTAssertFalse(first.cards.isEmpty)
        XCTAssertFalse(first.isVoiceAuthored)

        // With no author configured, a finished month seals on its own copy.
        guard case let .deterministic(last) = collected.last else {
            XCTFail("expected a sealing event")
            return
        }
        XCTAssertEqual(last.sealState, .sealedWithoutVoice)

        // The whole read is one bulk request — twelve history months plus the
        // target — and no separate single-month fetch. On a database-backed
        // source that is one covering scan for a first open, which matters
        // because `conversations` carries no index on time.
        XCTAssertEqual(source.bulkRequests.count, 1)
        XCTAssertEqual(source.bulkRequests.first?.count, 13)
        XCTAssertEqual(source.bulkRequests.first?.contains(august), true, "the target month must ride along")
        XCTAssertTrue(source.singleRequests.isEmpty, "no month should be fetched twice")
    }

    func testComposerKeepsAnInProgressMonthAsAPreview() async throws {
        let source = StubRecapSource(batches: [august: RecapFixtures.busyMonth(august, calendar: calendar)])
        let composer = RecapComposer(
            source: source,
            historyStore: try historyStore(),
            recapStore: try recapStore(),
            calendar: calendar
        )
        let midMonth = RecapFixtures.date(2026, 8, 19, 12, calendar: calendar)
        let collected = await events(composer.build(window: august, now: midMonth))

        guard case let .deterministic(recap) = collected.last else {
            XCTFail("expected a deck")
            return
        }
        XCTAssertEqual(recap.sealState, .preview, "a month still running must never seal")
    }

    func testComposerReportsThinMonths() async throws {
        let source = StubRecapSource(batches: [august: RecapFixtures.thinMonth(august, calendar: calendar)])
        let composer = RecapComposer(
            source: source,
            historyStore: try historyStore(),
            recapStore: try recapStore(),
            calendar: calendar
        )
        let now = RecapFixtures.date(2026, 9, 2, 9, calendar: calendar)
        let collected = await events(composer.build(window: august, now: now))

        guard case .notEnoughData = collected.last else {
            XCTFail("a month below the substance floor must say so, not ship a padded deck")
            return
        }
    }

    func testComposerAppliesValidatedVoice() async throws {
        // Digit-free copy, so acceptance turns purely on the voice rules.
        let json = """
        {"monthTitle":"August was your builder month",
         "monthInOneSentence":"You settled into one setup, kept at it most days, and let the sessions run long.",
         "cards":[{"id":"c1","headline":"A clear pattern.","body":"Something worth noticing about how you worked."}]}
        """
        let source = StubRecapSource(batches: [august: RecapFixtures.busyMonth(august, calendar: calendar)])
        let composer = RecapComposer(
            source: source,
            historyStore: try historyStore(),
            recapStore: try recapStore(),
            author: StubVoiceAuthor(json: json),
            calendar: calendar
        )
        let now = RecapFixtures.date(2026, 9, 2, 9, calendar: calendar)
        let collected = await events(composer.build(window: august, now: now))

        guard case let .voiced(voiced) = collected.last else {
            XCTFail("expected a voiced deck")
            return
        }
        XCTAssertTrue(voiced.isVoiceAuthored)
        XCTAssertEqual(voiced.title, "August was your builder month")
        XCTAssertEqual(voiced.sealState, .sealed)
        XCTAssertEqual(voiced.provenance?.modelID, "stub-1")
        // Exactly one card was rewritten; the rest kept their computed copy.
        XCTAssertEqual(voiced.cards.filter(\.isVoiceAuthored).count, 1)
        XCTAssertEqual(voiced.cards.count, collectedDeckSize(collected))
    }

    private func collectedDeckSize(_ events: [RecapComposer.Event]) -> Int {
        for event in events {
            if case let .deterministic(recap) = event { return recap.cards.count }
        }
        return 0
    }

    func testStoredSealedMonthIsServedWithoutRefetching() async throws {
        let store = try recapStore()
        _ = try await store.save(recap(august, seal: .sealed, voiced: true, title: "Sealed"))

        let source = StubRecapSource(batches: [:])
        let composer = RecapComposer(
            source: source,
            historyStore: try historyStore(),
            recapStore: store,
            calendar: calendar
        )
        let now = RecapFixtures.date(2026, 9, 2, 9, calendar: calendar)
        let collected = await events(composer.build(window: august, now: now))

        guard case let .deterministic(served) = collected.first else {
            XCTFail("expected the stored deck")
            return
        }
        XCTAssertEqual(served.title, "Sealed")
        XCTAssertTrue(source.singleRequests.isEmpty, "a sealed month must not re-read the database")
    }
}
