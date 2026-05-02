import Foundation

// MARK: - Known Log Roots

/// Approved path roots for log file access.
///
/// Used to restrict parser log-file operations to known-safe locations when
/// `restrictedLogAccess` is enabled in SettingsManager. Any custom log path
/// whose expanded path does not start with one of these roots will be rejected
/// and the parser will fall back to the provider's default log directory.
enum KnownLogRoots {
    /// All known log root path prefixes (tilde-expanded on access).
    static let all: [String] = [
        "~/.factory/",
        "~/.claude/",
        "~/.copilot/",
        "~/.aider/",
        "~/.cursor/",
        "~/.codex/",
        "~/.kimi/",
        "~/.windsurf/",
        "~/.goose/",
        "~/.gemini/",
        "~/.augment/",
        "~/.cline/",
        "~/.roo/",
        "~/.forge/",
        "~/Library/Application Support/OpenBurnBar/"
    ]

    /// Returns true if `path`, after tilde expansion, starts with one of the
    /// known-safe root prefixes.
    static func isKnownRoot(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return all.contains { expanded.hasPrefix($0) }
    }
}

// MARK: - Restricted Log Path Validator

/// Validates log file paths against known-safe roots when restricted mode is on.
///
/// Injected into parsers so that custom user-configured log paths can be checked
/// before any file I/O is performed. When a path is rejected, the caller should
/// fall back to the provider's default `logDirectory`.
struct RestrictedLogPathValidator: Sendable {
    /// Whether restricted mode is active. When false, all paths are allowed.
    let restrictedMode: Bool

    init(restrictedMode: Bool) {
        self.restrictedMode = restrictedMode
    }

    /// Returns the resolved path to use for the given provider.
    ///
    /// If `restrictedMode` is true and `customPath` is non-nil but not under a
    /// known root, returns `nil` to signal that the caller should use the
    /// provider's default directory instead.
    func resolvePath(customPath: String?, providerDefault: String) -> String? {
        guard restrictedMode else {
            return customPath ?? providerDefault
        }
        guard let custom = customPath else {
            return providerDefault
        }
        if KnownLogRoots.isKnownRoot(custom) {
            return custom
        }
        // Custom path outside known roots — reject and fall back to default.
        return nil
    }
}
