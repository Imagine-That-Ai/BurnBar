import SwiftUI

// MARK: - Popover Tooltip

extension View {
    /// Tooltip helper kept as a semantic wrapper so popover controls do not
    /// carry custom AppKit overlay views that can interfere with hit-testing.
    func popoverTooltip(_ text: String) -> some View {
        help(text)
    }
}
