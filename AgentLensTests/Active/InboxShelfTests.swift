import XCTest
@testable import OpenBurnBar

/// Covers the AI Inbox's local management store: the record's forward- and
/// backward-compatible decoding, pruning, the capacity ceiling, write
/// coalescing, and category normalization.
///
/// Every test runs against its own `UserDefaults` suite so the developer's real
/// arrangement is never read or written.
@MainActor
final class InboxShelfTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "inbox.shelf.tests.\(UUID().uuidString)"
        suiteNames.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("could not create a scratch UserDefaults suite")
        }
        return defaults
    }

    private func makeStore(
        _ defaults: UserDefaults? = nil,
        debounce: TimeInterval = 0
    ) -> InboxShelfStore {
        InboxShelfStore(defaults: defaults ?? makeDefaults(), persistDebounce: debounce)
    }

    // MARK: - Encoding

    func testEntryRoundTripsEveryField() throws {
        let saved = Date(timeIntervalSince1970: 1_780_000_000)
        let deleted = Date(timeIntervalSince1970: 1_780_000_500)
        let updated = Date(timeIntervalSince1970: 1_780_001_000)
        let entry = InboxShelfEntry(
            pinned: true,
            colorTag: .watching,
            category: "Costs",
            sortIndex: 3,
            savedAt: saved,
            deletedAt: deleted,
            updatedAt: updated
        )

        let data = try XCTUnwrap(InboxShelfStore.encode(["item-1": entry]))
        let decoded = InboxShelfStore.decode(data)

        XCTAssertEqual(decoded["item-1"], entry)
    }

    /// A record written before a field existed must decode with that field's
    /// default rather than failing the whole shelf. `pinned` is the hazard: it
    /// is non-optional, so the synthesized decoder would have thrown.
    func testOlderShapedRecordDecodesWithDefaultsInsteadOfThrowing() throws {
        let json = """
            { "legacy": { "category": "Reading" } }
            """
        let decoded = InboxShelfStore.decode(Data(json.utf8))

        let entry = try XCTUnwrap(decoded["legacy"], "a record missing fields must still decode")
        XCTAssertFalse(entry.pinned)
        XCTAssertEqual(entry.category, "Reading")
        XCTAssertNil(entry.colorTag)
        XCTAssertNil(entry.sortIndex)
        XCTAssertNil(entry.savedAt)
        XCTAssertNil(entry.deletedAt)
        XCTAssertEqual(entry.updatedAt, .distantPast)
    }

    /// The mirror case: a tag written by a newer build drops to "no tag"
    /// instead of throwing away the pin that sits beside it.
    func testUnknownColorTagDegradesWithoutLosingTheRestOfTheRecord() throws {
        let json = """
            { "future": { "pinned": true, "colorTag": "chartreuse", "category": "Costs" } }
            """
        let decoded = InboxShelfStore.decode(Data(json.utf8))

        let entry = try XCTUnwrap(decoded["future"])
        XCTAssertTrue(entry.pinned)
        XCTAssertNil(entry.colorTag)
        XCTAssertEqual(entry.category, "Costs")
    }

    func testUnreadablePayloadResetsToAnEmptyShelf() {
        XCTAssertTrue(InboxShelfStore.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(InboxShelfStore.decode(nil).isEmpty)
        XCTAssertTrue(InboxShelfStore.decode(Data()).isEmpty)
    }

    func testArrangementSurvivesAStoreRestart() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        store.setPinned(true, ids: ["a"])
        store.setColorTag(.idea, ids: ["b"])
        store.setCategory("  Reliability  ", ids: ["b"])
        store.flush()

        let reopened = makeStore(defaults)
        XCTAssertTrue(reopened.isPinned("a"))
        XCTAssertEqual(reopened.colorTag("b"), .idea)
        XCTAssertEqual(reopened.category("b"), "Reliability")
    }

    // MARK: - Pruning

    func testPruneDropsUnknownIDsAndKeepsTheRest() {
        let store = makeStore()
        store.setPinned(true, ids: ["keep-1"])
        store.setColorTag(.urgent, ids: ["keep-2"])
        store.setCategory("Costs", ids: ["gone-1"])
        store.setSaved(true, ids: ["gone-2"])
        XCTAssertEqual(store.entries.count, 4)

        store.prune(keeping: ["keep-1", "keep-2", "never-seen"])

        XCTAssertEqual(Set(store.entries.keys), ["keep-1", "keep-2"])
        XCTAssertTrue(store.isPinned("keep-1"))
        XCTAssertEqual(store.colorTag("keep-2"), .urgent)
    }

    func testPruneIsPersistedImmediately() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        store.setPinned(true, ids: ["keep", "drop"])
        store.prune(keeping: ["keep"])

        let reopened = makeStore(defaults)
        XCTAssertEqual(Set(reopened.entries.keys), ["keep"])
    }

    /// Growth is bounded even if `prune` is never called with an authoritative
    /// id set: the capacity ceiling evicts the least recently touched records,
    /// and prefers records that only carry an arrangement over records that
    /// carry an explicit keep-or-kill decision.
    func testCapacityCeilingEvictsOldestNonStickyRecordsFirst() {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_000_000)

        store.setPinned(true, ids: ["sticky"], at: base)
        for index in 0..<InboxShelfStore.maxEntries {
            store.setCategory("Costs", ids: ["plain-\(index)"], at: base.addingTimeInterval(Double(index + 1)))
        }

        XCTAssertEqual(store.entries.count, InboxShelfStore.maxEntries)
        XCTAssertTrue(store.isPinned("sticky"), "an explicit pin outranks an arrangement-only record")
        XCTAssertNil(store.entry("plain-0"), "the oldest arrangement-only record is evicted")
        XCTAssertNotNil(store.entry("plain-\(InboxShelfStore.maxEntries - 1)"))
    }

    // MARK: - Mutation semantics

    func testEmptyRecordsAreDroppedRatherThanStored() {
        let store = makeStore()
        store.setPinned(true, ids: ["a"])
        XCTAssertEqual(store.entries.count, 1)

        store.setPinned(false, ids: ["a"])
        XCTAssertTrue(store.entries.isEmpty, "a record with no user intent left must not be kept")
    }

    func testCategoryNormalizationTrimsBlanksAndCaps() {
        XCTAssertNil(InboxShelfStore.normalizeCategory(nil))
        XCTAssertNil(InboxShelfStore.normalizeCategory("   "))
        XCTAssertEqual(InboxShelfStore.normalizeCategory("  Costs \n"), "Costs")
        let long = String(repeating: "x", count: InboxShelfStore.maxCategoryLength + 20)
        XCTAssertEqual(
            InboxShelfStore.normalizeCategory(long)?.count,
            InboxShelfStore.maxCategoryLength
        )
    }

    func testCategoriesInUseIgnoresDeletedItemsAndDeduplicates() {
        let store = makeStore()
        store.setCategory("Costs", ids: ["a"])
        store.setCategory("costs", ids: ["b"])
        store.setCategory("Reading", ids: ["c"])
        store.markDeleted(ids: ["c"])

        // "Costs" and "costs" collapse to one entry, and the deleted item's
        // "Reading" does not survive in the picker at all.
        XCTAssertEqual(store.categoriesInUse.count, 1, "a deleted item must not keep its category alive")
        XCTAssertEqual(store.categoriesInUse.first?.lowercased(), "costs")
    }

    func testSavedAndDeletedTimestampsAreStable() {
        let store = makeStore()
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)

        store.setSaved(true, ids: ["a"], at: first)
        store.setSaved(true, ids: ["a"], at: second)
        XCTAssertEqual(store.entry("a")?.savedAt, first, "re-saving must not restamp the original save")

        store.markDeleted(ids: ["a"], at: first)
        store.markDeleted(ids: ["a"], at: second)
        XCTAssertEqual(store.entry("a")?.deletedAt, first)

        store.clearDeleted(ids: ["a"])
        XCTAssertFalse(store.isDeleted("a"))
        XCTAssertTrue(store.isSaved("a"), "undoing a delete must not undo the save")
    }

    // MARK: - Write coalescing

    /// A drag rewrites the whole run on every frame. Those writes must collapse
    /// into one, or reordering ten rows means ten `UserDefaults` round trips.
    func testManualOrderWritesAreCoalesced() async {
        let store = makeStore(debounce: 0.05)
        let baseline = store.writeCount

        for step in 0..<12 {
            store.applyManualOrder(step.isMultiple(of: 2) ? ["a", "b", "c"] : ["c", "b", "a"])
        }
        XCTAssertEqual(store.writeCount, baseline, "no write should have landed yet")

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.writeCount, baseline + 1, "twelve reorders must collapse into one write")
        XCTAssertEqual(store.sortIndex("c"), 0, "the surviving write is the last one, not the first")
    }

    func testFlushWritesPendingOrderImmediately() {
        let defaults = makeDefaults()
        let store = makeStore(defaults, debounce: 10)
        store.applyManualOrder(["x", "y"])
        store.flush()

        let reopened = makeStore(defaults)
        XCTAssertEqual(reopened.sortIndex("x"), 0)
        XCTAssertEqual(reopened.sortIndex("y"), 1)
    }

    // MARK: - Vocabulary

    func testEveryColorTagCarriesANameAndAGlyph() {
        for tag in InboxColorTag.allCases {
            XCTAssertFalse(tag.displayName.isEmpty, "\(tag) must not rely on colour alone")
            XCTAssertFalse(tag.symbolName.isEmpty, "\(tag) needs shape redundancy")
            XCTAssertEqual(tag.id, tag.rawValue)
        }
        XCTAssertEqual(
            Set(InboxColorTag.allCases.map(\.displayName)).count,
            InboxColorTag.allCases.count,
            "two tags reading the same aloud would be indistinguishable to VoiceOver"
        )
    }
}
