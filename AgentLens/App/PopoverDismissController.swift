import AppKit

/// Owns the explicit menu-popover dismissal affordances that are not already
/// routed through the status item or SwiftUI content.
final class PopoverDismissController {
    private static let escapeKeyCode: UInt16 = 53

    private var escapeKeyMonitor: Any?
    func installEscapeKeyMonitor(onDismiss: @escaping @MainActor () -> Void) {
        uninstall()
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            MainActor.assumeIsolated {
                onDismiss()
            }
            return event
        }
    }

    func uninstall() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    deinit {
        uninstall()
    }
}
