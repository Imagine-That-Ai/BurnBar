import AppKit
import Foundation

// MARK: - Hermes data directory (Finder)

/// Resolves the Hermes home directory (`~/.hermes` by default) where session logs and `state.db` live.
/// Tool-written project files may be elsewhere; this is the canonical Hermes data root OpenBurnBar already tracks.
@MainActor
enum HermesDataFolder {
    static func resolvedHomeURL(settings: SettingsManager = .shared) -> URL {
        guard let resolved = settings.resolvedPath(for: .hermes) else {
            return URL(fileURLWithPath: ("~/.hermes" as NSString).expandingTildeInPath)
        }
        if resolved.lastPathComponent == "sessions" {
            return resolved.deletingLastPathComponent()
        }
        return resolved
    }

    /// Opens Finder at the Hermes data directory, creating it if needed.
    static func revealInFinder(settings: SettingsManager = .shared) {
        let url = resolvedHomeURL(settings: settings)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // try?-ok(reveal-dir best-effort)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens Finder at a per-chat workspace (Application Support → OpenBurnBar → HermesChatWorkspaces → thread).
    static func revealChatWorkspace(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // try?-ok(workspace-dir best-effort)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
