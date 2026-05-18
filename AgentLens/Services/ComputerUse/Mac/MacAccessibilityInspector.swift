#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import AppKit
import ApplicationServices
import OpenBurnBarComputerUseCore

/// AX-tree reader used to translate a CGEvent target point into a
/// human-readable role + label (for approval-sheet copy) and to flag
/// regions that must NEVER be clicked (Decision A2 / threat model
/// item: agent clicks password field).
///
/// Pure AX queries — no synthesis. The deny matcher consumes the
/// inspector's role/subrole output via a `ComputerUseAccessibilityDenyReason`.
public final class MacAccessibilityInspector: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let role: String?
        public let subrole: String?
        public let roleDescription: String?
        public let label: String?
        public let title: String?
        public let bundleId: String?

        public init(
            role: String?,
            subrole: String?,
            roleDescription: String?,
            label: String?,
            title: String?,
            bundleId: String?
        ) {
            self.role = role
            self.subrole = subrole
            self.roleDescription = roleDescription
            self.label = label
            self.title = title
            self.bundleId = bundleId
        }
    }

    private let denyRegions: MacComputerUseDenyRegions

    public init(denyRegions: MacComputerUseDenyRegions = MacComputerUseDenyRegions()) {
        self.denyRegions = denyRegions
    }

    /// Read the role + subrole of the AX element under the given
    /// display point. Returns `nil` if Accessibility is denied or the
    /// system has no element at that point.
    public func snapshotAtPoint(x: Int, y: Int) -> Snapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        // AXUIElementCopyElementAtPosition uses x, y in display
        // coordinates from the top-left of the primary screen.
        let err = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(x),
            Float(y),
            &element
        )
        guard err == .success, let element = element else { return nil }

        let role = attributeString(element, kAXRoleAttribute as CFString)
        let subrole = attributeString(element, kAXSubroleAttribute as CFString)
        let roleDescription = attributeString(element, kAXRoleDescriptionAttribute as CFString)
        let label = attributeString(element, kAXDescriptionAttribute as CFString)
        let title = attributeString(element, kAXTitleAttribute as CFString)
        let bundleId = frontmostBundleIdentifier()
        return Snapshot(
            role: role,
            subrole: subrole,
            roleDescription: roleDescription,
            label: label,
            title: title,
            bundleId: bundleId
        )
    }

    /// Map an AX snapshot to a deny reason, if any.
    public func denyReason(for snapshot: Snapshot?) -> ComputerUseAccessibilityDenyReason? {
        denyRegions.denyReason(for: snapshot.map {
            MacComputerUseDenyRegions.Element(
                role: $0.role,
                subrole: $0.subrole,
                roleDescription: $0.roleDescription,
                label: $0.label,
                title: $0.title,
                bundleId: $0.bundleId
            )
        })
    }

    /// Live frontmost application context. Feeds the scope matcher's
    /// `ComputerUseScopeContext` builder.
    public func frontmostScopeContext() -> ComputerUseScopeContext {
        let bundleId = frontmostBundleIdentifier()
        let windowTitle = frontmostWindowTitle()
        // URL extraction would require app-specific AppleScript /
        // Accessibility bridges; the placeholder is nil and the
        // dispatcher fills in the URL for browser actions via the
        // Playwright driver's currentURL() probe.
        return ComputerUseScopeContext(url: nil, bundleId: bundleId, windowTitle: windowTitle)
    }

    // MARK: helpers

    private func attributeString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success else { return nil }
        return raw as? String
    }

    private func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func frontmostWindowTitle() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused)
        guard err == .success, let window = focused else { return nil }
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}
#endif
