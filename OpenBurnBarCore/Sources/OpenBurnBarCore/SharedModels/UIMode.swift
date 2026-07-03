import Foundation

// MARK: - UI Mode
/// App-wide visual persona. Each mode adapts typography, color, spacing,
/// and motion to fit a specific use-case or mood.
///
/// This raw enum is Foundation-only so it stays available to the engine on
/// non-Apple platforms. The SwiftUI token/typography accessors that read this
/// mode (`UIModeTheme`, the `EnvironmentValues.uiMode`/`uiTheme` bridge) live in
/// `UIModeTheme.swift`, compiled only where SwiftUI is available.
public enum UIMode: String, CaseIterable, Identifiable, Sendable {
    case standard
    case cooking

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .cooking:  return "Cooking"
        }
    }

    public var description: String {
        switch self {
        case .standard: return "The classic Aurora experience"
        case .cooking:  return "Big, bright, and finger-friendly"
        }
    }

    public var iconName: String {
        switch self {
        case .standard: return "sparkles"
        case .cooking:  return "frying.pan" // SF Symbol fallback; replaced by SVG asset in picker
        }
    }
}
