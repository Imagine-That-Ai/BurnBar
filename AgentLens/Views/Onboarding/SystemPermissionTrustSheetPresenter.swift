#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import SwiftUI
import OpenBurnBarComputerUseCore

/// Presents ``SystemPermissionTrustSheet`` as an app-modal window and reports the
/// user's choice back to ``FirstRunPermissionLadder``.
///
/// A window rather than a SwiftUI `.sheet` because the ladder is reachable from places
/// that have no view to attach a sheet to -- a Control Deck tile, a settings row, a
/// runtime controller. Wiring one presenter at startup means every one of those paths
/// gets BurnBar's explanation without each having to host its own sheet.
@MainActor
enum SystemPermissionTrustSheetPresenter {

    /// Installs the presenter as the ladder's explainer. Call once during startup.
    static func install(into ladder: FirstRunPermissionLadder = .shared) {
        ladder.explainer = { kind, bundleId in
            await present(kind: kind, bundleId: bundleId)
        }
    }

    static func present(kind: SystemPermissionKind, bundleId: String?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false

            // Guards against the continuation being resumed twice if the window is
            // closed by something other than the buttons.
            var hasResumed = false
            let finish: (Bool) -> Void = { didAgree in
                guard !hasResumed else { return }
                hasResumed = true
                NSApp.stopModal()
                window.orderOut(nil)
                continuation.resume(returning: didAgree)
            }

            let sheet = SystemPermissionTrustSheet(
                kind: kind,
                bundleName: bundleId.flatMap(displayName(forBundleId:)),
                onDecision: finish
            )
            window.contentView = NSHostingView(rootView: sheet)
            window.center()

            NSApp.activate(ignoringOtherApps: true)
            NSApp.runModal(for: window)
        }
    }

    private static func displayName(forBundleId bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
#endif
