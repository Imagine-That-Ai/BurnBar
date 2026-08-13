import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore

@MainActor
final class QuotaResetCelebrationStoreTests: XCTestCase {
    func test_ingestHonorsMasterSwitch() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: temp)
        let store = QuotaResetCelebrationStore(appPaths: paths)
        let defaults = UserDefaults(suiteName: "QuotaResetCelebrationStoreTests.\(UUID().uuidString)")!
        let settings = QuotaSettings(persistence: SettingsPersistenceCoordinator(defaults: defaults))
        settings.celebrateQuotaResets = false
        store.settingsProvider = { settings }

        let event = sampleEvent()
        store.ingest(QuotaResetDetection(events: [event], consumedBoundaries: [event.resetBoundary]))
        XCTAssertNil(store.activePerformance)
    }

    func test_sampleCreatesActivePerformance() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: temp)
        let store = QuotaResetCelebrationStore(appPaths: paths)
        store.playSample(kind: .scheduled, provider: .claudeCode)
        XCTAssertEqual(store.activeEvent?.kind, .scheduled)
        XCTAssertFalse(store.activeEvent?.mentionsTibo ?? true)
    }

    private func sampleEvent() -> QuotaResetEvent {
        let now = Date()
        return QuotaResetEvent(
            providerID: AgentProvider.codex.providerID,
            providerToken: "codex",
            accountID: "default",
            accountLabel: nil,
            bucketKey: "codex-7d",
            bucketLabel: "7-day window",
            resetBoundary: "test-boundary",
            kind: .surprise,
            windowClass: .weekly,
            presentation: .perform,
            freshness: .live,
            previousUsedPercent: 70,
            currentUsedPercent: 2,
            previousLimit: 100,
            currentLimit: 100,
            previousResetsAt: now.addingTimeInterval(3 * 86_400),
            currentResetsAt: now.addingTimeInterval(7 * 86_400),
            credits: [],
            observedAt: now,
            choreography: .plungerSlam,
            captionEyebrow: "SURPRISE",
            captionHeadline: "Tibo hit the button. Codex is full again.",
            mentionsTibo: true
        )
    }
}
