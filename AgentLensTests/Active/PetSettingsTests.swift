import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - PetSettings Tests
//
// Exercises the macOS AgentLens pet settings store: persistence round-trips,
// defaults, size clamping, and notification posting.
//
// All tests use `SettingsPersistenceCoordinator(flushDelayNanoseconds: 0)`
// (synchronous mode) with an isolated `UserDefaults(suiteName:)` suite so
// reads immediately observe the written state without async flushing.

@MainActor
final class PetSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "PetSettingsTests.\(UUID().uuidString)"

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

    // MARK: - Helpers

    private func makeCoordinator() -> SettingsPersistenceCoordinator {
        SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
    }

    private func makeSettings(coordinator: SettingsPersistenceCoordinator? = nil) -> PetSettings {
        PetSettings(persistence: coordinator ?? makeCoordinator())
    }

    // MARK: - Initial State

    func test_initialState_petDisabledByDefault() {
        let settings = makeSettings()
        XCTAssertFalse(settings.petEnabled, "Pet should be disabled by default")
    }

    func test_initialState_defaultPetIsEmberSprite() {
        let settings = makeSettings()
        XCTAssertEqual(settings.selectedPet, .emberSprite, "Default pet should be emberSprite")
    }

    func test_initialState_defaultSizeIs72() {
        let settings = makeSettings()
        XCTAssertEqual(settings.petSize, 72, "Default pet size should be 72px")
    }

    func test_initialState_positionUnset() {
        let settings = makeSettings()
        XCTAssertEqual(settings.petPositionX, -1, "Default position X should be -1 (unset)")
        XCTAssertEqual(settings.petPositionY, -1, "Default position Y should be -1 (unset)")
    }

    func test_initialState_chatBubbleEnabled() {
        let settings = makeSettings()
        XCTAssertTrue(settings.chatBubbleEnabled, "Chat bubble should be enabled by default")
    }

    func test_initialState_defaultDestinationIsPopover() {
        let settings = makeSettings()
        XCTAssertEqual(settings.preferredChatDestination, .popover, "Default chat destination should be popover")
    }

    // MARK: - Persistence Round-Trip

    func test_petEnabled_persistsAcrossInstances() {
        let coordinator = makeCoordinator()
        let settings1 = makeSettings(coordinator: coordinator)
        settings1.petEnabled = true

        let settings2 = makeSettings(coordinator: coordinator)
        XCTAssertTrue(settings2.petEnabled, "petEnabled should persist across instances")
    }

    func test_selectedPet_persistsAcrossInstances() {
        let coordinator = makeCoordinator()
        let settings1 = makeSettings(coordinator: coordinator)
        settings1.selectedPet = .cosmicOwl

        let settings2 = makeSettings(coordinator: coordinator)
        XCTAssertEqual(settings2.selectedPet, .cosmicOwl, "selectedPet should persist across instances")
    }

    func test_chatBubbleEnabled_persistsAcrossInstances() {
        let coordinator = makeCoordinator()
        let settings1 = makeSettings(coordinator: coordinator)
        settings1.chatBubbleEnabled = false

        let settings2 = makeSettings(coordinator: coordinator)
        XCTAssertFalse(settings2.chatBubbleEnabled, "chatBubbleEnabled should persist across instances")
    }

    func test_preferredChatDestination_persistsAcrossInstances() {
        let coordinator = makeCoordinator()
        let settings1 = makeSettings(coordinator: coordinator)
        settings1.preferredChatDestination = .dashboard

        let settings2 = makeSettings(coordinator: coordinator)
        XCTAssertEqual(settings2.preferredChatDestination, .dashboard, "preferredChatDestination should persist across instances")
    }

    func test_petSize_persistsAcrossInstances() {
        let coordinator = makeCoordinator()
        let settings1 = makeSettings(coordinator: coordinator)
        settings1.petSize = 100

        let settings2 = makeSettings(coordinator: coordinator)
        XCTAssertEqual(settings2.petSize, 100, "petSize should persist across instances")
    }

    func test_petPosition_persistsAcrossInstances() {
        let coordinator = makeCoordinator()
        let settings1 = makeSettings(coordinator: coordinator)
        settings1.petPositionX = 200.0
        settings1.petPositionY = 300.0

        let settings2 = makeSettings(coordinator: coordinator)
        XCTAssertEqual(settings2.petPositionX, 200.0, "petPositionX should persist across instances")
        XCTAssertEqual(settings2.petPositionY, 300.0, "petPositionY should persist across instances")
    }

    // MARK: - Size Clamping

    func test_petSize_clampsToMinimum() {
        let settings = makeSettings()
        settings.petSize = 10
        XCTAssertEqual(settings.petSize, 48, "petSize should clamp to 48 minimum")
    }

    func test_petSize_clampsToMaximum() {
        let settings = makeSettings()
        settings.petSize = 200
        XCTAssertEqual(settings.petSize, 128, "petSize should clamp to 128 maximum")
    }

    // MARK: - Notifications

    func test_petEnabled_postsNotificationOnChange() {
        let settings = makeSettings()
        let expectation = expectation(forNotification: .petSettingsDidChange, object: nil)
        settings.petEnabled = true
        wait(for: [expectation], timeout: 2.0)
    }

    func test_selectedPet_postsNotificationOnChange() {
        let settings = makeSettings()
        let expectation = expectation(forNotification: .petSettingsDidChange, object: nil)
        settings.selectedPet = .pixelCat
        wait(for: [expectation], timeout: 2.0)
    }

    func test_petSize_postsNotificationOnChange() {
        let settings = makeSettings()
        let expectation = expectation(forNotification: .petSettingsDidChange, object: nil)
        settings.petSize = 90
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - DesktopPetKind

    func test_desktopPetKind_allCasesHaveUniqueIDs() {
        let ids = DesktopPetKind.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "All pet kinds should have unique IDs")
    }

    func test_desktopPetKind_allCasesHaveNonEmptyNames() {
        for kind in DesktopPetKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) should have a non-empty display name")
            XCTAssertFalse(kind.sfSymbol.isEmpty, "\(kind) should have a non-empty SF Symbol")
            XCTAssertFalse(kind.accentColor.isEmpty, "\(kind) should have a non-empty accent color")
        }
    }

    // MARK: - PetChatDestination

    func test_petChatDestination_allCasesHaveUniqueIDs() {
        let ids = PetChatDestination.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "All chat destinations should have unique IDs")
    }

    func test_petChatDestination_allCasesHaveNonEmptyNames() {
        for dest in PetChatDestination.allCases {
            XCTAssertFalse(dest.displayName.isEmpty, "\(dest) should have a non-empty display name")
            XCTAssertFalse(dest.sfSymbol.isEmpty, "\(dest) should have a non-empty SF Symbol")
        }
    }
}
