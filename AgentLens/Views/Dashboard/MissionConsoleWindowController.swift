import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Mission Console Window Controller (macOS)
//
// Hosts `MissionControlConsoleView` in a floating utility panel. Lives across
// dashboard navigations so the console state survives sidebar switches. One
// shared instance per `OpenBurnBarOperatingLayer`.

@MainActor
final class MissionConsoleWindowController: NSObject, NSWindowDelegate {
    static var shared: MissionConsoleWindowController?

    private let operatingLayer: OpenBurnBarOperatingLayer
    let host: MissionConsoleMacHost
    private(set) var window: NSWindow?

    init(operatingLayer: OpenBurnBarOperatingLayer) {
        self.operatingLayer = operatingLayer
        self.host = MissionConsoleMacHost(operatingLayer: operatingLayer)
        super.init()
    }

    func makeOrShow() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            host.rebuildSnapshot()
            return
        }

        let rect = idealFrame()
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        let window = NSWindow(
            contentRect: rect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 540)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = "Mission Console"
        window.appearance = NSAppearance(named: .darkAqua) ?? window.appearance

        let console = MissionControlConsoleView(host: host) { [weak self] in
            self?.window?.performClose(nil)
        }
        .frame(minWidth: 720, minHeight: 540)
        .ignoresSafeArea(.container)
        .preferredColorScheme(.dark)

        let hosting = NSHostingController(rootView: console)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        host.rebuildSnapshot()

        Task { [weak self] in
            await self?.host.refresh()
        }
    }

    func close() {
        window?.performClose(nil)
    }

    private func idealFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 980
        let h: CGFloat = 680
        return NSRect(
            x: screen.midX - w / 2,
            y: screen.midY - h / 2,
            width: w,
            height: h
        )
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            window = nil
        }
    }
}

// MARK: - Sharing

extension MissionConsoleWindowController {
    /// Bind a single shared controller to the given operating layer the first
    /// time it's requested, then return it on subsequent calls.
    static func bind(to operatingLayer: OpenBurnBarOperatingLayer) -> MissionConsoleWindowController {
        if let existing = shared { return existing }
        let controller = MissionConsoleWindowController(operatingLayer: operatingLayer)
        shared = controller
        return controller
    }
}
