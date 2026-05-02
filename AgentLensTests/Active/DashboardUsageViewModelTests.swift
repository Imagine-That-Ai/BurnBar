import XCTest
@testable import OpenBurnBar

// MARK: - DashboardUsageViewModelTests

@MainActor
final class DashboardUsageViewModelTests: XCTestCase {

    func test_initialState_isEmpty() {
        let vm = DashboardUsageViewModel()
        XCTAssertEqual(vm.usages.count, 0)
        XCTAssertEqual(vm.totalCostToday, 0)
        XCTAssertEqual(vm.totalCostThisWeek, 0)
        XCTAssertEqual(vm.totalCostThisMonth, 0)
        XCTAssertEqual(vm.totalCostAllTime, 0)
        XCTAssertEqual(vm.totalTokensToday, 0)
        XCTAssertEqual(vm.totalTokensThisWeek, 0)
        XCTAssertEqual(vm.totalTokensThisMonth, 0)
        XCTAssertEqual(vm.totalTokensAllTime, 0)
        XCTAssertEqual(vm.rollingDailyAverage, 0)
        XCTAssertTrue(vm.providerSummaries.isEmpty)
        XCTAssertTrue(vm.modelSummaries.isEmpty)
        XCTAssertTrue(vm.last7DayCosts.allSatisfy { $0 == 0 })
        XCTAssertTrue(vm.last7DayTokenTotals.allSatisfy { $0 == 0 })
    }

    func test_moodBand_withEmptyUsages_isBaseline() {
        let vm = DashboardUsageViewModel()
        XCTAssertEqual(vm.moodBand, .baseline)
    }

    func test_hasEstimatedProviders_withEmptySummaries_isFalse() {
        let vm = DashboardUsageViewModel()
        XCTAssertFalse(vm.hasEstimatedProviders)
    }

    func test_providerSummaries_inDateRange_withEmptyUsages_isEmpty() {
        let vm = DashboardUsageViewModel()
        XCTAssertTrue(vm.providerSummaries(in: nil).isEmpty)
    }

    func test_modelSummaries_inDateRange_withEmptyUsages_isEmpty() {
        let vm = DashboardUsageViewModel()
        XCTAssertTrue(vm.modelSummaries(in: nil).isEmpty)
    }

    func test_topProviderToday_withEmptyUsages_isNil() {
        let vm = DashboardUsageViewModel()
        XCTAssertNil(vm.topProviderToday())
    }
}
