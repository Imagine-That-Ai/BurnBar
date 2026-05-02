import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - CLIAssistantConsentSheet

@MainActor
final class CLIAssistantConsentSheetTests: XCTestCase {

    private func makeSettings(allowed: Bool = false, consentShown: Bool = false) -> SettingsManager {
        let sm = SettingsManager.shared
        sm.cliAssistantAllowed = allowed
        sm.cliAssistantConsentShown = consentShown
        return sm
    }

    func test_renders() throws {
        let sm = makeSettings()
        let view = CLIAssistantConsentSheet(settingsManager: sm, onDismiss: {})
        XCTAssertNoThrow(try view.inspect())
    }

    func test_showsTitle() throws {
        let sm = makeSettings()
        let view = CLIAssistantConsentSheet(settingsManager: sm, onDismiss: {})
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("Claude Code or Codex") }))
    }

    func test_hasAllowAndDenyButtons() throws {
        let sm = makeSettings()
        let view = CLIAssistantConsentSheet(settingsManager: sm, onDismiss: {})
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        XCTAssertTrue(buttons.count >= 2, "Should have at least Allow and Not now buttons")
    }

    func test_denyButton_setsNotAllowed() throws {
        let sm = makeSettings()
        var dismissed = false
        let view = CLIAssistantConsentSheet(settingsManager: sm) {
            dismissed = true
        }
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        // "Not now" is the first button
        try buttons[0].tap()
        XCTAssertFalse(sm.cliAssistantAllowed)
        XCTAssertTrue(sm.cliAssistantConsentShown)
        XCTAssertTrue(dismissed)
    }

    func test_allowButton_setsAllowed() throws {
        let sm = makeSettings()
        var dismissed = false
        let view = CLIAssistantConsentSheet(settingsManager: sm) {
            dismissed = true
        }
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        // "Allow" is the second button
        try buttons[1].tap()
        XCTAssertTrue(sm.cliAssistantAllowed)
        XCTAssertTrue(sm.cliAssistantConsentShown)
        XCTAssertTrue(dismissed)
    }
}
