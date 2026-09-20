import AppKit
import XCTest
@testable import OpenBurnBar

/// The Settings landing was drawing under the unified titlebar: the sidebar
/// search field and General's "Quick setup" header sat in the chrome and got
/// clipped. `SettingsWindowChrome` is the window-level invariant that keeps
/// that from coming back.
@MainActor
final class SettingsWindowChromeTests: XCTestCase {

    func test_applyStandardTitlebar_stripsFullSizeContentViewAndTransparency() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        SettingsWindowChrome.applyStandardTitlebar(to: window)

        XCTAssertFalse(
            window.styleMask.contains(.fullSizeContentView),
            "fullSizeContentView lets the titlebar overlay the first settings rows"
        )
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .line)
        XCTAssertEqual(window.toolbarStyle, .unified)
    }

    func test_applyStandardTitlebar_isIdempotentOnAnAlreadyStandardWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        SettingsWindowChrome.applyStandardTitlebar(to: window)
        SettingsWindowChrome.applyStandardTitlebar(to: window)

        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertFalse(window.titlebarAppearsTransparent)
    }
}
