import XCTest
@testable import OpenBurnBar

@MainActor
final class AnalyticsSharedTests: XCTestCase {
    func test_sharedSingletons_areStable_andCompileUnderSwift6() {
        let store = AnalyticsConsentStore.shared
        XCTAssertIdentical(store, AnalyticsConsentStore.shared)
        _ = Analytics.shared // must compile + be reachable under Swift 6 strict concurrency
    }
}
