import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - NarrativeCardView

@MainActor
final class NarrativeCardViewTests: XCTestCase {

    func test_emptyDataStore_rendersEmpty() throws {
        let store = try makeIsolatedStore()
        let view = NarrativeCardView(dataStore: store)
        XCTAssertTrue(store.usages.isEmpty)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_nonEmptyDataStore_rendersCard() throws {
        let store = try makeIsolatedStore()
        store.replaceUsages(ViewTestFixtures.makeWeekOfUsages())
        let view = NarrativeCardView(dataStore: store)
        let sut = try view.inspect()
        // Should not be EmptyView when usages exist
        let hasEmpty = (try? sut.find(ViewType.EmptyView.self)) != nil
        XCTAssertFalse(hasEmpty, "Should not render EmptyView when usages exist")
    }

    private func makeIsolatedStore() throws -> DataStore {
        try DataStore(databaseQueue: DatabaseQueue(), refreshOnInit: false)
    }
}

// MARK: - Insight Engine Logic Tests (exercised by NarrativeCardView)

@MainActor
final class InsightEngineLogicTests: XCTestCase {

    func test_emptyUsages_generatesNarrative() throws {
        let store = try makeIsolatedStore()
        let narrative = InsightEngine.generateNarrative(from: store)
        // Narrative should have at least an icon and headline
        XCTAssertFalse(narrative.icon.isEmpty)
        XCTAssertFalse(narrative.headline.isEmpty)
    }

    func test_usagesWithSpend_generatesNarrative() throws {
        let store = try makeIsolatedStore()
        store.replaceUsages(ViewTestFixtures.makeWeekOfUsages(baseCost: 2.0))
        let narrative = InsightEngine.generateNarrative(from: store)
        XCTAssertFalse(narrative.icon.isEmpty)
        XCTAssertFalse(narrative.headline.isEmpty)
    }

    private func makeIsolatedStore() throws -> DataStore {
        try DataStore(databaseQueue: DatabaseQueue(), refreshOnInit: false)
    }
}
