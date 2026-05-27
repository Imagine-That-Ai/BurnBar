import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class QuotaStoreOrderTests: XCTestCase {
    private var store: QuotaStore!
    private var testDefaults: UserDefaults!
    private let suiteName = "com.openburnbar.mobile.tests.quotastoreordertests"

    override func setUp() async throws {
        try await super.setUp()
        // Create an isolated UserDefaults suite
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults.removePersistentDomain(forName: suiteName)

        cleanUserDefaults()
    }

    override func tearDown() async throws {
        cleanUserDefaults()
        try await super.tearDown()
    }

    private func cleanUserDefaults() {
        let keys = ["quota_providerOrderCSV", "quota_visibleProvidersCSV", "quota_hiddenBucketsJSON", "quota_bucketOrdersJSON", "quota_percentageDisplayMode"]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testInitialProviderOrder() {
        store = QuotaStore()

        // Verify that the initial providerOrderTokens matches the default order CSV
        let expectedDefaults = ["codex", "opencode", "claudecode", "openai", "deepseek", "copilot", "minimax", "zai", "factory", "cursor", "warp", "ollama", "kimi", "antigravity", "xai", "mimo"]
        XCTAssertEqual(store.providerOrderTokens, expectedDefaults)
    }

    func testUpdateProviderOrder() {
        store = QuotaStore()

        let newOrder = ["openai", "deepseek", "claudecode"]
        store.updateProviderOrder(newOrder)

        // The store's providerOrderTokens should now place these at the front (or match the saved ones)
        XCTAssertEqual(Array(store.providerOrderTokens.prefix(3)), newOrder)
    }

    func testHideProvider() {
        store = QuotaStore()

        // Hide "openai"
        store.hideProvider("openai")

        let settingsStore = QuotaSettingsStore()
        XCTAssertFalse(settingsStore.visibleProviders.contains(.openAI))
    }
}
