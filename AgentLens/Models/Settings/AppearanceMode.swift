import SwiftUI

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

extension View {
    @ViewBuilder
    func openBurnBarPreferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        if let colorScheme {
            self.preferredColorScheme(colorScheme)
        } else {
            self
        }
    }
}
