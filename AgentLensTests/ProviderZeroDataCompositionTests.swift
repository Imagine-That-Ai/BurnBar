@testable import BurnBar
import GRDB
import XCTest

@MainActor
final class ProviderZeroDataCompositionTests: XCTestCase {
    func test_unsupportedDetailRouteComposesTypedFallbackAcrossAllSections() throws {
        let store = try makeInMemoryStore()
        let view = ProviderDashboardView(
            provider: .grokBot,
            dataStore: store,
            timeRange: .today
        )

        let presentation = view.routePresentation

        XCTAssertFalse(presentation.showsAnalytics)
        XCTAssertEqual(
            presentation.headerSubtitle,
            "\(ProviderSupportLevel.unsupported.label) • \(DataConfidence.unavailable.label) — no usage data"
        )
        XCTAssertEqual(presentation.headerMetrics.map(\.value), [
            ProviderSupportLevel.unsupported.label,
            DataConfidence.unavailable.label,
            "None"
        ])
        XCTAssertTrue(presentation.emptyMessage.contains(ProviderSupportLevel.unsupported.label))
        XCTAssertTrue(presentation.emptyMessage.contains(DataConfidence.unavailable.label))
        XCTAssertEqual(presentation.emptyIconName, "eye.slash")
        assertNoFabricatedZeroCopy(presentation)
    }

    func test_partialAndSupportedDetailRoutesKeepTheirDistinctFallbacks() throws {
        let store = try makeInMemoryStore()
        let partialView = ProviderDashboardView(provider: .grokCLI, dataStore: store, timeRange: .today)
        let supportedView = ProviderDashboardView(provider: .claudeCode, dataStore: store, timeRange: .today)
        let partial = partialView.routePresentation
        let supported = supportedView.routePresentation

        XCTAssertFalse(partial.showsAnalytics)
        XCTAssertTrue(partial.headerSubtitle.contains(DataConfidence.estimated.label))
        XCTAssertTrue(partial.emptyMessage.contains(ProviderSupportLevel.partial.label))
        XCTAssertTrue(partial.emptyMessage.contains(DataConfidence.estimated.label))
        XCTAssertEqual(partial.emptyIconName, "clock")

        XCTAssertFalse(supported.showsAnalytics)
        XCTAssertEqual(supported.headerSubtitle, "No sessions in range")
        XCTAssertTrue(supported.emptyMessage.contains(ProviderSupportLevel.supported.label))
        XCTAssertEqual(supported.emptyIconName, "clock")
    }

    private func assertNoFabricatedZeroCopy(_ presentation: ProviderDetailRoutePresentation) {
        let copy = [
            presentation.headerSubtitle,
            presentation.emptyMessage,
            presentation.headerMetrics.map(\.value).joined(separator: " ")
        ].joined(separator: " ")
        XCTAssertFalse(copy.contains("$0.00"))
        XCTAssertFalse(copy.contains("0 sessions"))
        XCTAssertFalse(copy.contains("0 tokens"))
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}
