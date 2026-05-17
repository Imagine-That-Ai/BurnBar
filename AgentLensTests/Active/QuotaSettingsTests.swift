import Foundation
import XCTest
@testable import OpenBurnBar

@MainActor
final class QuotaSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "QuotaSettingsTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Cumulative across accounts

    func test_cumulativeAcrossAccounts_defaultsToFalse() {
        let coordinator = SettingsPersistenceCoordinator(defaults: defaults)
        let settings = QuotaSettings(persistence: coordinator)
        XCTAssertFalse(settings.cumulativeAcrossAccounts)
    }

    func test_cumulativeAcrossAccounts_persistsAcrossRecreate() {
        let coordinator = SettingsPersistenceCoordinator(defaults: defaults)
        let settings = QuotaSettings(persistence: coordinator)
        settings.cumulativeAcrossAccounts = true
        coordinator.flush()

        // Recreate to simulate app relaunch.
        let coordinator2 = SettingsPersistenceCoordinator(defaults: defaults)
        let settings2 = QuotaSettings(persistence: coordinator2)
        XCTAssertTrue(settings2.cumulativeAcrossAccounts)
    }

    func test_cumulativeAcrossAccounts_canBeToggledBackOff() {
        let coordinator = SettingsPersistenceCoordinator(defaults: defaults)
        let settings = QuotaSettings(persistence: coordinator)
        settings.cumulativeAcrossAccounts = true
        coordinator.flush()
        settings.cumulativeAcrossAccounts = false
        coordinator.flush()

        let coordinator2 = SettingsPersistenceCoordinator(defaults: defaults)
        let settings2 = QuotaSettings(persistence: coordinator2)
        XCTAssertFalse(settings2.cumulativeAcrossAccounts)
    }

    // MARK: - Tokenizer assisted fallback (smoke — same persistence shape)

    func test_tokenizerAssistedFallbackEnabled_persistsAcrossRecreate() {
        let coordinator = SettingsPersistenceCoordinator(defaults: defaults)
        let settings = QuotaSettings(persistence: coordinator)
        settings.tokenizerAssistedFallbackEnabled = true
        coordinator.flush()

        let coordinator2 = SettingsPersistenceCoordinator(defaults: defaults)
        let settings2 = QuotaSettings(persistence: coordinator2)
        XCTAssertTrue(settings2.tokenizerAssistedFallbackEnabled)
    }
}
