import XCTest
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardConsentCoordinatorTests

@MainActor
final class DashboardConsentCoordinatorTests: XCTestCase {

    private var settingsManager: SettingsManager!

    override func setUp() {
        super.setUp()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        settingsManager.conversationIndexingConsentShown = false
        settingsManager.conversationIndexingEnabled = false
        settingsManager.sessionLogCloudBackupConsentShown = false
        settingsManager.cliAssistantConsentShown = false
    }

    override func tearDown() {
        if let suiteName = UserDefaults(suiteName: #file) {
            suiteName.removePersistentDomain(forName: #file)
        }
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

    func test_openChatPanelIfConsented_showsCLIConsentWhenNotShown() {
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        XCTAssertFalse(coordinator.showCLIConsentSheet)
        coordinator.openChatPanelIfConsented(chatController: controller, open: {})
        XCTAssertTrue(coordinator.showCLIConsentSheet)
    }

    func test_openChatPanelIfConsented_callsOpenWhenConsented() {
        settingsManager.cliAssistantConsentShown = true
        let coordinator = DashboardConsentCoordinator(settingsManager: settingsManager, accountManager: .shared)
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        var didOpen = false
        coordinator.openChatPanelIfConsented(chatController: controller, open: { didOpen = true })
        XCTAssertFalse(coordinator.showCLIConsentSheet)
        XCTAssertTrue(didOpen)
    }
}
