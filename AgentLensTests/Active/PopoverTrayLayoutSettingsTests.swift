import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class PopoverTrayLayoutSettingsTests: XCTestCase {

    func test_defaultLayout_includesQuotasFirst() {
        let settings = makeSettingsManager()
        XCTAssertEqual(settings.popoverTrayLayout.order.first, .quotas)
        XCTAssertFalse(settings.popoverTrayLayout.isHidden(.quotas))
        XCTAssertEqual(settings.popoverTrayLayout.spec(for: .quotas)?.weight, 1)
    }

    func test_layoutPersistsAcrossSettingsManagerInstances() {
        let defaults = makeIsolatedDefaults()
        let first = makeSettingsManager(defaults: defaults)
        var layout = first.popoverTrayLayout
        layout.setHidden(.quotas, hidden: true)
        layout.setWeight(.summary, weight: 2.5)
        layout.setPinnedHeight(.providers, height: 120)
        layout.move(.quotas, toSlot: 2)
        first.popoverTrayLayout = layout
        first.persistence.flush()

        let second = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(second.popoverTrayLayout.isHidden(.quotas))
        XCTAssertEqual(second.popoverTrayLayout.spec(for: .summary)?.weight, 2.5)
        XCTAssertEqual(second.popoverTrayLayout.spec(for: .providers)?.pinnedHeight, 120)
        XCTAssertEqual(second.popoverTrayLayout.order[2], .quotas)
        XCTAssertEqual(
            defaults.string(forKey: PopoverTrayLayout.legacyOrderKey)?.split(separator: ",").first.map(String.init),
            second.popoverTrayLayout.order.first?.rawValue
        )
    }

    func test_legacyOrderWithoutQuotas_migratesQuotasToFront() {
        let defaults = makeIsolatedDefaults()
        defaults.set("summary,insights,providers", forKey: PopoverTrayLayout.legacyOrderKey)
        defaults.set("{\"summary\":160}", forKey: PopoverTrayLayout.legacyHeightsKey)
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.popoverTrayLayout.order.first, .quotas)
        XCTAssertEqual(settings.popoverTrayLayout.order[1], .summary)
        XCTAssertEqual(settings.popoverTrayLayout.spec(for: .summary)?.pinnedHeight, 160)
        XCTAssertFalse(settings.popoverTrayLayout.isHidden(.quotas))
    }

    func test_hidingQuotas_postsAppearanceChangeAndLeavesNoAllocatedHeight() {
        let settings = makeSettingsManager()
        let expectation = XCTNSNotificationExpectation(name: .popoverTrayLayoutDidChange)
        var layout = settings.popoverTrayLayout
        layout.setHidden(.quotas, hidden: true)
        settings.popoverTrayLayout = layout
        wait(for: [expectation], timeout: 1.0)

        let heights = PopoverTrayLayoutMath.allocate(
            layout: settings.popoverTrayLayout,
            available: [.quotas, .summary],
            bodyHeight: 320
        )
        XCTAssertNil(heights[.quotas])
        XCTAssertEqual(heights[.summary] ?? 0, 320, accuracy: 0.2)
    }

    func test_collapseAndWeightPersistAcrossSettingsManagerInstances() {
        let defaults = makeIsolatedDefaults()
        let first = makeSettingsManager(defaults: defaults)
        var layout = first.popoverTrayLayout
        layout.setCollapsed(.quotas, collapsed: true)
        layout.setWeight(.insights, weight: 0.5)
        layout.setMinHeight(.summary, minHeight: 80)
        layout.setMaxHeight(.summary, maxHeight: 240)
        first.popoverTrayLayout = layout
        first.persistence.flush()

        let second = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(second.popoverTrayLayout.isCollapsed(.quotas))
        XCTAssertFalse(second.popoverTrayLayout.isHidden(.quotas))
        XCTAssertEqual(second.popoverTrayLayout.spec(for: .insights)?.weight, 0.5)
        XCTAssertEqual(second.popoverTrayLayout.spec(for: .summary)?.minHeight, 80)
        XCTAssertEqual(second.popoverTrayLayout.spec(for: .summary)?.maxHeight, 240)
        let storedJSON = defaults.string(forKey: PopoverTrayLayout.storageKey)
        XCTAssertNotNil(storedJSON)
        XCTAssertFalse(storedJSON?.isEmpty ?? true)
    }

    func test_restoreDefaults_unhidesQuotasAndClearsPins() {
        let settings = makeSettingsManager()
        var layout = settings.popoverTrayLayout
        layout.setHidden(.quotas, hidden: true)
        layout.setPinnedHeight(.summary, height: 200)
        settings.popoverTrayLayout = layout
        var restored = settings.popoverTrayLayout
        restored.restoreDefaults()
        settings.popoverTrayLayout = restored
        XCTAssertEqual(settings.popoverTrayLayout, .default())
    }
}
