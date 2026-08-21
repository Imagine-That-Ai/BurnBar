import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarRecap
@testable import OpenBurnBarInsights

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

private let stubModelTag = InsightModelTag(
    providerKey: "test",
    modelID: "stub-1",
    displayName: "Stub",
    egressTier: .localOnly,
    stampedAt: Date(timeIntervalSince1970: 0)
)

private struct StubVoiceAuthor: RecapVoiceAuthor {
    let json: String
    func author(_ request: RecapVoiceRequest) async throws -> RecapVoiceAuthorResult? {
        RecapVoiceAuthorResult(text: json, modelTag: stubModelTag)
    }
}

/// Keeps the requests it was handed, so what the composer put in front of the
/// model — including how much history it claimed to have — can be asserted on.
private final class CapturingVoiceAuthor: RecapVoiceAuthor, @unchecked Sendable {
    let json: String
    private(set) var requests: [RecapVoiceRequest] = []

    init(json: String) { self.json = json }

    func author(_ request: RecapVoiceRequest) async throws -> RecapVoiceAuthorResult? {
        requests.append(request)
        return RecapVoiceAuthorResult(text: json, modelTag: stubModelTag)
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

    /// A month persisted partial is excluded from every comparison, so leaving
    /// it out of the backfill set would strand it out of history for good.
    func testPartialMonthsStayEligibleForBackfill() async throws {
        let store = try historyStore()
        let july = august.previous
        let june = july.previous
        try await store.upsert(RecapFixtures.facts(june, calendar: calendar))

        let truncated = RecapRowBatch(
            window: july,
            usages: Array(RecapFixtures.busyMonth(july, calendar: calendar).usages.prefix(3)),
            isPartial: true,
            hasSessionData: false
        )
        try await store.upsert(
            RecapFacts.build(batch: truncated, builtAt: july.end(calendar: calendar), calendar: calendar)
        )

        let missing = await store.monthsNeedingBackfill(endingAt: august, monthsBack: 2)
        XCTAssertEqual(
            missing.map(\.key), [july.key],
            "the half-read month must be re-fetched; the complete one must not"
        )

        // And once the retry lands a complete read, the month leaves the set.
        try await store.upsert(RecapFixtures.facts(july, calendar: calendar))
        let repaired = await store.facts(for: july)
        XCTAssertEqual(repaired?.isPartial, false)
        let afterRepair = await store.monthsNeedingBackfill(endingAt: august, monthsBack: 2)
        XCTAssertTrue(afterRepair.isEmpty)
    }

    /// Eligible is not the same as eligible *every open*.
    ///
    /// `isPartial` does not record why a month was truncated, and the mobile source
    /// returns partial whenever its 24-page x 300-row budget runs out with a live
    /// cursor — so a large month is deterministically partial on every retry. Without
    /// a bound, every recap open re-paginates it: thousands of billed reads to reach
    /// the same answer. A freshly-stored partial month therefore waits.
    func testFreshlyStoredPartialMonthIsNotRefetchedOnEveryOpen() async throws {
        let store = try historyStore()
        let july = august.previous
        let now = Date()

        let truncated = RecapRowBatch(
            window: july,
            usages: Array(RecapFixtures.busyMonth(july, calendar: calendar).usages.prefix(3)),
            isPartial: true,
            hasSessionData: false
        )
        try await store.upsert(RecapFacts.build(batch: truncated, builtAt: now, calendar: calendar))

        // Just stored: the next open must not re-read it.
        let immediately = await store.monthsNeedingBackfill(endingAt: august, monthsBack: 2, now: now)
        XCTAssertFalse(
            immediately.contains(july),
            "a partial month stored seconds ago must not be re-paginated on the next open"
        )

        // An hour later, still not.
        let anHourOn = await store.monthsNeedingBackfill(
            endingAt: august, monthsBack: 2, now: now.addingTimeInterval(3600)
        )
        XCTAssertFalse(immediately.contains(july) || anHourOn.contains(july))

        // Past the retry interval it becomes eligible again, so a recovered
        // connection still repairs the month.
        let nextDay = await store.monthsNeedingBackfill(
            endingAt: august,
            monthsBack: 2,
            now: now.addingTimeInterval(RecapHistoryStore.partialRetryInterval + 1)
        )
        XCTAssertTrue(
            nextDay.contains(july),
            "a partial month must not be stranded — it retries once the interval passes"
        )
    }

    /// All-time records read whatever history they are handed, so the store
    /// hands over every month it holds — not a year of them.
    func testHistoryReturnsEveryStoredMonth() async throws {
        let store = try historyStore()
        for month in august.priorMonths(14) {
            try await store.upsert(RecapFixtures.facts(month, calendar: calendar))
        }

        let all = await store.history(before: august)
        XCTAssertEqual(all.count, 14, "an all-time comparison must see every stored month")
        XCTAssertEqual(all.first?.window, august.previous, "newest first")
        XCTAssertEqual(all.last?.window, august.priorMonths(14).last)
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

    /// A stored preview is a snapshot of a month still running. Serving it back
    /// unchanged would freeze the current month at whatever it looked like the
    /// first time the page was opened.
    func testStoredPreviewIsRebuiltSoNewUsageAppears() async throws {
        let store = try recapStore()
        _ = try await store.save(recap(august, seal: .preview, title: "Stale preview"))

        let source = StubRecapSource(batches: [august: RecapFixtures.busyMonth(august, calendar: calendar)])
        let composer = RecapComposer(
            source: source,
            historyStore: try historyStore(),
            recapStore: store,
            calendar: calendar
        )
        let midMonth = RecapFixtures.date(2026, 8, 19, 12, calendar: calendar)
        let collected = await events(composer.build(window: august, now: midMonth))

        guard case let .deterministic(rebuilt) = collected.last else {
            XCTFail("expected a freshly built deck")
            return
        }
        XCTAssertNotEqual(rebuilt.title, "Stale preview")
        XCTAssertFalse(rebuilt.cards.isEmpty)
        XCTAssertEqual(rebuilt.sealState, .preview)
        let read = source.bulkRequests.flatMap { $0 } + source.singleRequests
        XCTAssertTrue(read.contains(august), "the running month must be re-read")
    }

    /// `.unsealed` is the state a month is left in when its sealing pass was
    /// interrupted. Serving it back would freeze it there forever.
    func testInterruptedUnsealedMonthFinishesSealing() async throws {
        let store = try recapStore()
        _ = try await store.save(recap(august, seal: .unsealed, title: "Interrupted"))

        let source = StubRecapSource(batches: [august: RecapFixtures.busyMonth(august, calendar: calendar)])
        let composer = RecapComposer(
            source: source,
            historyStore: try historyStore(),
            recapStore: store,
            calendar: calendar
        )
        let now = RecapFixtures.date(2026, 9, 2, 9, calendar: calendar)
        let collected = await events(composer.build(window: august, now: now))

        guard case let .deterministic(sealed) = collected.last else {
            XCTFail("expected the sealing event")
            return
        }
        XCTAssertEqual(sealed.sealState, .sealedWithoutVoice)
        XCTAssertNotEqual(sealed.title, "Interrupted")
    }

    /// `historyDepth` budgets the *fetch*, not the claim. A device that has
    /// accumulated more months than it backfills must compare against all of
    /// them — otherwise "your biggest month yet" silently means "biggest of the
    /// last few".
    func testAllTimeComparisonsSeeMoreHistoryThanTheBackfillDepth() async throws {
        let history = try historyStore()
        let stored = august.priorMonths(14)
        for month in stored {
            try await history.upsert(RecapFixtures.facts(month, calendar: calendar))
        }

        let json = """
        {"monthTitle":"August was your builder month",
         "monthInOneSentence":"You settled into one setup, kept at it most days, and let the sessions run long.",
         "cards":[{"id":"c1","headline":"A clear pattern.","body":"Something worth noticing about how you worked."}]}
        """
        let author = CapturingVoiceAuthor(json: json)
        let source = StubRecapSource(batches: [august: RecapFixtures.busyMonth(august, calendar: calendar)])
        let composer = RecapComposer(
            source: source,
            historyStore: history,
            recapStore: try recapStore(),
            author: author,
            calendar: calendar,
            // Mobile's budget: three months of fetching, fourteen months of memory.
            historyDepth: 3
        )

        let now = RecapFixtures.date(2026, 9, 2, 9, calendar: calendar)
        _ = await events(composer.build(window: august, now: now))

        let prompt = try XCTUnwrap(author.requests.first?.userPrompt)
        XCTAssertTrue(
            prompt.contains("\"monthsOfHistoryAvailable\":14"),
            "the context must carry every stored month, not just the backfill depth"
        )
    }
}
