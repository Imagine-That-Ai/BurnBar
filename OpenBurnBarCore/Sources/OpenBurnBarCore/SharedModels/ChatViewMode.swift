import Foundation

/// Display mode for chat messages shared across platforms.
/// - `agent`: Rich bubble view with tool cards, badges, and formatting (default).
/// - `cli`: On macOS, raw monospaced view showing plain content like a terminal
///   transcript. On iOS/Android, inline screen mirror of the Mac's live agent
///   terminal with Smart Zoom auto-framing.
public enum ChatViewMode: String, CaseIterable, Identifiable, Sendable {
    case agent
    case cli

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agent: return "Agent"
        case .cli:   return "CLI"
        }
    }

    public var icon: String {
        switch self {
        case .agent: return "bubble.left.and.bubble.right"
        case .cli:   return "terminal"
        }
    }
}
