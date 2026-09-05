import AppKit
import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Receipt Flyout Controller

/// Manages the presentation, positioning, and auto-dismissal of the mini-flyout popover
/// anchored beneath the menu bar status item.
@MainActor
public final class ReceiptFlyoutController: NSObject {

    private weak var statusItem: NSStatusItem?
    private var flyoutPanel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let onOpenReceiptDetail: (ReceiptRecord) -> Void

    public init(
        statusItem: NSStatusItem?,
        onOpenReceiptDetail: @escaping (ReceiptRecord) -> Void
    ) {
        self.statusItem = statusItem
        self.onOpenReceiptDetail = onOpenReceiptDetail
        super.init()
    }

    public func updateStatusItem(_ item: NSStatusItem?) {
        self.statusItem = item
    }

    public func showFlyout(for receipt: ReceiptRecord) {
        dismissTask?.cancel()
        dismissTask = nil

        let panel = ensurePanel()

        let flyoutView = ReceiptMiniFlyoutView(
            receipt: receipt,
            onViewReceipt: { [weak self] in
                self?.dismiss()
                self?.onOpenReceiptDetail(receipt)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingController = NSHostingController(rootView: flyoutView)
        hostingController.view.setFrameSize(NSSize(width: 330, height: 160))
        panel.contentViewController = hostingController

        positionPanel(panel)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1.0
        }

        // Auto-dismiss after 8 seconds
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil

        guard let panel = flyoutPanel, panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let flyoutPanel {
            return flyoutPanel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.flyoutPanel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let button = statusItem?.button,
              let screen = button.window?.screen ?? NSScreen.main else {
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = button.window?.convertToScreen(buttonFrameInWindow) ?? buttonFrameInWindow

        let panelWidth: CGFloat = 330
        let panelHeight: CGFloat = 160

        // Center horizontally below status item button
        var x = buttonFrameOnScreen.midX - (panelWidth / 2.0)
        var y = buttonFrameOnScreen.minY - panelHeight - 6

        // Keep within screen bounds
        let screenFrame = screen.visibleFrame
        if x < screenFrame.minX + 12 {
            x = screenFrame.minX + 12
        } else if x + panelWidth > screenFrame.maxX - 12 {
            x = screenFrame.maxX - panelWidth - 12
        }

        if y < screenFrame.minY + 12 {
            y = buttonFrameOnScreen.maxY + 6
        }

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}
