import SwiftUI

// MARK: - PetAuthStatus chip presentation

extension PetAuthStatus {
    /// Indicator colour for the auth chip. Defined here in the view layer
    /// rather than inline in the view body so the status -> colour mapping
    /// stays directly testable: `.unavailable` must read as muted (an honest
    /// "cannot run here"), never as `.error`, which would imply something is
    /// broken. (Moved out of Services/Chat — presentation-layer dependency.)
    var chipColor: Color {
        switch self {
        case .ready: return DesignSystem.Colors.success
        case .needsLogin: return DesignSystem.Colors.warning
        case .error: return DesignSystem.Colors.error
        case .unavailable: return DesignSystem.Colors.textMuted
        case .unknown: return DesignSystem.Colors.textMuted
        }
    }
}
