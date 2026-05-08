import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Cast Setup Wizard Window
//
// Hosts the Setup Cast Wizard inside a borderless 480×640 NSWindow. We
// own the window so we can show/hide it with one call from anywhere
// (Settings panel, menu bar, iPhone-triggered flow, etc.) without
// replicating SwiftUI lifecycle plumbing.

@MainActor
final class CastSetupWizardWindow: NSObject, NSWindowDelegate {

    static let shared = CastSetupWizardWindow()

    private var window: NSWindow?
    private var model: CastWizardModel?

    func present(settingsManager: SettingsManager) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = CastWizardModel(settingsManager: settingsManager)
        let view = CastSetupWizardView(model: model) { [weak self] in
            self?.dismiss()
        }

        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up your Smart Display"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentViewController = host
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        self.window = window
        self.model = model

        model.start()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        model?.cancel()
        window?.orderOut(nil)
        window = nil
        model = nil
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}
