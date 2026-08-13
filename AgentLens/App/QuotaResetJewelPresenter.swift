#if canImport(AppKit)
import AppKit
import SwiftUI
import OpenBurnBarCore

@MainActor
final class QuotaResetJewelPresenter {
    static let shared = QuotaResetJewelPresenter()

    private var panel: NSPanel?
    private var hosting: NSHostingView<QuotaResetJewelView>?
    var statusItemButton: NSStatusBarButton?
    var onOpen: () -> Void = {}

    func show(_ performance: QuotaResetPerformance) {
        let view = QuotaResetJewelView(performance: performance, onOpen: { [weak self] in
            self?.hide()
            self?.onOpen()
        })
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
            self.hosting = hosting
            let panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.animationBehavior = .utilityWindow
            panel.contentView = hosting
            self.panel = panel
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionPanel() {
        guard let panel else { return }
        let size = NSSize(width: 320, height: 300)
        panel.setContentSize(size)
        if let button = statusItemButton, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let x = anchor.midX - size.width / 2
            let y = anchor.minY - size.height - 10
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.maxY - size.height - 48
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
#endif
