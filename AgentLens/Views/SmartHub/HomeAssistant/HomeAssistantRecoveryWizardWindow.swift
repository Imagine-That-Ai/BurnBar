import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Home Assistant Recovery Wizard Window
//
// Hosts `HomeAssistantRecoveryWizardView` inside a borderless 560×680
// NSWindow. Singleton owner so callers (Settings, Cast wizard recovery
// step) can present without re-creating the model on every open.

@MainActor
final class HomeAssistantRecoveryWizardWindow: NSObject, NSWindowDelegate {

    static let shared = HomeAssistantRecoveryWizardWindow()

    private var window: NSWindow?
    private var model: HomeAssistantRecoveryWizardModel?

    func present(settingsManager: SettingsManager) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configStore = HomeAssistantConfigStore(settingsManager: settingsManager)
        let model = HomeAssistantRecoveryWizardModel(
            configStore: configStore,
            suggestedFriendlyName: { [weak settingsManager] in
                settingsManager?.castSelectedDeviceFriendlyName ?? ""
            },
            dashboardURLProvider: { [weak settingsManager] in
                guard let raw = settingsManager?.smartHubQuotaDashboardURL,
                      let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                return url
            }
        )
        let view = HomeAssistantRecoveryWizardView(model: model) { [weak self] in
            self?.dismiss()
        }

        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Home Assistant Recovery"
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
        window?.orderOut(nil)
        window = nil
        model = nil
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
        window = nil
    }
}
