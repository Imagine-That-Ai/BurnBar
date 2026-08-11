import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Tests the safety-critical invariant of the pane-tiling refactor: a controller created
/// with `persistsViewState == false` (a tiling pane) stays bound to its injected thread and
/// NEVER writes the global chat `UserDefaults` keys, so multi-pane usage cannot corrupt the
/// legacy single-pane chat state — while the app-wide controller (`persistsViewState == true`)
/// keeps persisting exactly as before.
@MainActor
final class ChatSessionControllerPaneModeTests: XCTestCase {

    private func makePane(threadID: String) throws -> ChatSessionController {
        let dataStore = try makeDiscoveryInMemoryStore()
        return ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:]),
            initialThreadID: threadID,
            persistsViewState: false
        )
    }

    private func makePrimary() throws -> ChatSessionController {
        let dataStore = try makeDiscoveryInMemoryStore()
        return ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
    }

    /// Save a UserDefaults value, run `body`, then restore it — so regression tests that
    /// exercise the *writing* path don't leak into other tests' global state.
    private func preservingDefault(_ key: String, _ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try body()
    }

    // MARK: - Pane controllers are isolated

    func test_paneController_bindsInjectedThread_andIsNonPersisting() throws {
        let pane = try makePane(threadID: "pane-thread-1")
        XCTAssertEqual(pane.activeThreadID, "pane-thread-1")
        XCTAssertFalse(pane.persistsViewState)
    }

    func test_paneController_modelChange_doesNotWriteGlobalModelKey() throws {
        let key = ChatSessionController.udChatModelCodex
        let before = UserDefaults.standard.string(forKey: key)
        let pane = try makePane(threadID: "t")
        pane.chatModelCodex = "pane-only-model-\(UUID().uuidString)"
        XCTAssertTrue(pane.chatModelCodex.hasPrefix("pane-only-model-"), "in-memory selection still works")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before,
                       "a pane must NOT persist the global per-backend model key")
    }

    func test_paneController_viewModeChange_doesNotWriteGlobalKey() throws {
        let key = "chatPanel.viewMode"
        let before = UserDefaults.standard.string(forKey: key)
        let pane = try makePane(threadID: "t")
        pane.chatViewMode = (pane.chatViewMode == .agent ? .cli : .agent)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before,
                       "a pane must NOT persist the global view-mode key")
    }

    func test_paneController_persistActiveThreadSlot_isNoop() throws {
        let pane = try makePane(threadID: "t")
        let slotKey = ChatSessionController.threadStorageKey(for: pane.chatBackend)
        let activeKey = ChatSessionController.udActiveThreadID
        let slotBefore = UserDefaults.standard.string(forKey: slotKey)
        let activeBefore = UserDefaults.standard.string(forKey: activeKey)

        pane.persistActiveThreadSlot()
        pane.persistPanelGeometry()

        XCTAssertEqual(UserDefaults.standard.string(forKey: slotKey), slotBefore,
                       "a pane must NOT write the per-backend thread slot")
        XCTAssertEqual(UserDefaults.standard.string(forKey: activeKey), activeBefore,
                       "a pane must NOT write the global active-thread key")
    }

    // MARK: - The app-wide controller still persists (regression guards)

    func test_primaryController_modelChange_stillPersistsGlobalKey() throws {
        try preservingDefault(ChatSessionController.udChatModelCodex) {
            let primary = try makePrimary()
            let value = "primary-model-\(UUID().uuidString)"
            primary.chatModelCodex = value
            XCTAssertEqual(UserDefaults.standard.string(forKey: ChatSessionController.udChatModelCodex), value,
                           "the app-wide controller must still persist model selection")
        }
    }

    func test_primaryController_persistActiveThreadSlot_stillWrites() throws {
        try preservingDefault(ChatSessionController.udActiveThreadID) {
            let primary = try makePrimary()
            primary.activeThreadID = "primary-thread-\(UUID().uuidString)"
            let expected = primary.activeThreadID
            preservingDefault(ChatSessionController.threadStorageKey(for: primary.chatBackend)) {
                primary.persistActiveThreadSlot()
                XCTAssertEqual(UserDefaults.standard.string(forKey: ChatSessionController.udActiveThreadID), expected,
                               "the app-wide controller must still persist its active thread")
            }
        }
    }
}
