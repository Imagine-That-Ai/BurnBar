import XCTest
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardConsentCoordinatorTests

@MainActor
final class DashboardConsentCoordinatorTests: XCTestCase {

    private var settingsManager: SettingsManager!

    override func setUp() {
        super.setUp()
        settingsManager = makeSettingsManager()
        settingsManager.conversationIndexingConsentShown = false
        settingsManager.conversationIndexingEnabled = false
        settingsManager.sessionLogCloudBackupConsentShown = false
        settingsManager.cliAssistantConsentShown = false
    }

    override func tearDown() {
        settingsManager = nil
        super.tearDown()
    }

    func test_shouldShowIndexingConsent_whenNotShown() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        XCTAssertTrue(coordinator.shouldShowIndexingConsent)
    }

    func test_shouldNotShowIndexingConsent_whenShown() {
        settingsManager.conversationIndexingConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        XCTAssertFalse(coordinator.shouldShowIndexingConsent)
    }

    func test_confirmIndexingConsent_enablesIndexing() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.confirmIndexingConsent(enable: true, aggregator: nil)
        XCTAssertTrue(settingsManager.conversationIndexingEnabled)
        XCTAssertTrue(settingsManager.conversationIndexingConsentShown)
    }

    func test_confirmIndexingConsent_disablesIndexing() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.confirmIndexingConsent(enable: false, aggregator: nil)
        XCTAssertFalse(settingsManager.conversationIndexingEnabled)
        XCTAssertTrue(settingsManager.conversationIndexingConsentShown)
    }

    func test_onDashboardAppear_showsConsentWhenNotShown() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        XCTAssertFalse(coordinator.showIndexingConsent)
        coordinator.onDashboardAppear(aggregator: nil)
        XCTAssertTrue(coordinator.showIndexingConsent)
    }

    func test_onDashboardAppear_doesNotShowConsentWhenAlreadyShown() {
        settingsManager.conversationIndexingConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.onDashboardAppear(aggregator: nil)
        XCTAssertFalse(coordinator.showIndexingConsent)
    }

    func test_openChatPanelIfConsented_showsCLIConsentWhenNotShown() throws {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        let store = try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false))
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        XCTAssertFalse(coordinator.showCLIConsentSheet)
        coordinator.openChatPanelIfConsented(chatController: controller, open: {})
        XCTAssertTrue(coordinator.showCLIConsentSheet)
    }

    func test_openChatPanelIfConsented_callsOpenWhenConsented() throws {
        settingsManager.cliAssistantConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        let store = try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false))
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        var didOpen = false
        coordinator.openChatPanelIfConsented(chatController: controller, open: { didOpen = true })
        XCTAssertFalse(coordinator.showCLIConsentSheet)
        XCTAssertTrue(didOpen)
    }

    // MARK: - Usage-memory consent (U2: third link in the first-run chain)

    func test_onDashboardAppear_showsOnlyIndexingConsentWhenNothingShown() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.onDashboardAppear(aggregator: nil)
        XCTAssertTrue(coordinator.showIndexingConsent)
        XCTAssertFalse(coordinator.showMemoryConsent)
        XCTAssertFalse(coordinator.showUsageMemoryConsent)
    }

    func test_onDashboardAppear_showsMemoryConsentSecond_notUsageConsent() {
        settingsManager.conversationIndexingConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.onDashboardAppear(aggregator: nil)
        XCTAssertFalse(coordinator.showIndexingConsent)
        XCTAssertTrue(coordinator.showMemoryConsent)
        XCTAssertFalse(coordinator.showUsageMemoryConsent)
    }

    func test_onDashboardAppear_showsUsageMemoryConsentThird() {
        settingsManager.conversationIndexingConsentShown = true
        settingsManager.memoryConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.onDashboardAppear(aggregator: nil)
        XCTAssertFalse(coordinator.showIndexingConsent)
        XCTAssertFalse(coordinator.showMemoryConsent)
        XCTAssertTrue(coordinator.showUsageMemoryConsent)
    }

    func test_onDashboardAppear_showsNothingWhenAllThreeShown() {
        settingsManager.conversationIndexingConsentShown = true
        settingsManager.memoryConsentShown = true
        settingsManager.usageMemoryConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.onDashboardAppear(aggregator: nil)
        XCTAssertFalse(coordinator.showIndexingConsent)
        XCTAssertFalse(coordinator.showMemoryConsent)
        XCTAssertFalse(coordinator.showUsageMemoryConsent)
    }

    func test_shouldShowUsageMemoryConsent_requiresIndexingConsentShown() {
        settingsManager.memoryConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        XCTAssertFalse(coordinator.shouldShowUsageMemoryConsent)
    }

    func test_shouldShowUsageMemoryConsent_requiresMemoryConsentShown() {
        settingsManager.conversationIndexingConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        XCTAssertFalse(coordinator.shouldShowUsageMemoryConsent)
    }

    func test_shouldShowUsageMemoryConsent_falseOnceShown() {
        settingsManager.conversationIndexingConsentShown = true
        settingsManager.memoryConsentShown = true
        settingsManager.usageMemoryConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        XCTAssertFalse(coordinator.shouldShowUsageMemoryConsent)
    }

    func test_confirmUsageMemoryConsent_grantSetsGrantedAndShown() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.confirmUsageMemoryConsent(grant: true)
        XCTAssertTrue(settingsManager.usageMemoryConsentGranted)
        XCTAssertTrue(settingsManager.usageMemoryConsentShown)
    }

    func test_confirmUsageMemoryConsent_declineOnlyMarksShown() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        coordinator.confirmUsageMemoryConsent(grant: false)
        XCTAssertFalse(settingsManager.usageMemoryConsentGranted)
        XCTAssertTrue(settingsManager.usageMemoryConsentShown)
        // Declining leaves the whole usage loop dormant.
        XCTAssertFalse(settingsManager.usageMemoryExtractionEnabled)
    }
}
