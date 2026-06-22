import AppKit
import SwiftUI

// MARK: - PetOnboardingWindowPresenter

/// Owns the one-shot pet first-run window outside `AgentLensApp.swift`, whose
/// size is ratcheted. The startup hook stays one line; the pet feature owns its
/// own presentation chrome.
@MainActor
enum PetOnboardingWindowPresenter {
    private static var window: NSWindow?

    static func openIfNeeded(chatController: ChatSessionController) {
        guard PetCompanionFeature.shouldRunFirstRun else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = PetFirstRunView(
            model: PetFirstRunModel(bridge: chatController.cliBridge),
            onDone: {
                window?.close()
                window = nil
            }
        )

        let onboardingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        onboardingWindow.title = "Set Up Pet Companion"
        onboardingWindow.titleVisibility = .hidden
        onboardingWindow.titlebarAppearsTransparent = true
        onboardingWindow.backgroundColor = NSColor(DesignSystem.Colors.background)
        onboardingWindow.contentView = NSHostingView(rootView: contentView)
        onboardingWindow.center()
        onboardingWindow.makeKeyAndOrderFront(nil)
        onboardingWindow.isReleasedWhenClosed = false

        window = onboardingWindow
    }
}
