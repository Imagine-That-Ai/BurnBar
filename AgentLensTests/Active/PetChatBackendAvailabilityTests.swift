import XCTest
@testable import OpenBurnBar

/// C7 — the pet bubble's brain switcher only offers the Settings-enabled engines
/// (CSV in `SettingsManager.enabledChatBackends`), preserving the user's picker
/// order, and falls back to every backend when the setting is absent (empty list).
@MainActor
final class PetChatBackendAvailabilityTests: XCTestCase {

    func test_resolveAvailableBackends_usesEnabledListInOrder() {
        let enabled: [ChatBackendID] = [.hermes, .codex]
        let resolved = PetChatController.resolveAvailableBackends(enabled: enabled)
        XCTAssertEqual(resolved, [.hermes, .codex],
                       "Should offer exactly the enabled engines, in Settings order")
    }

    func test_resolveAvailableBackends_singleEnabledOffersOnlyThatBrain() {
        let resolved = PetChatController.resolveAvailableBackends(enabled: [.claude])
        XCTAssertEqual(resolved, [.claude])
    }

    func test_resolveAvailableBackends_emptyFallsBackToAllCases() {
        let resolved = PetChatController.resolveAvailableBackends(enabled: [])
        XCTAssertEqual(resolved, ChatBackendID.allCases,
                       "Absent setting (empty list) should fall back to every backend")
    }
}
