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
        "~/.cursor-agent/",
        "~/.codex/",
        "~/.kimi/",
        "~/.windsurf/",
        "~/.goose/",
        "~/.gemini/",
        "~/.augment/",
        "~/.cline/",
        "~/.roo/",
        "~/.forge/",
        "~/.grok/",
        "~/.hermes/",
        "~/.junie/",
        "~/.pi/",
        "~/.prime/",
        "~/.omp/",
        "~/.openclaude/",
        "~/.openclaw/",
        "~/.local/share/opencode/",
        "~/.local/share/muse/",
        "~/Library/Application Support/OpenBurnBar/"
    ]

    /// Expanded, canonicalized versions of the roots for safe prefix comparison.
    private static let expandedRoots: [String] = all.map {
        ($0 as NSString).expandingTildeInPath
    }

    private static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = (expanded as NSString).resolvingSymlinksInPath
        return (resolved as NSString).standardizingPath
    }

    /// Returns true if `path`, after tilde expansion and canonicalization, starts
    /// with one of the known-safe root prefixes.
    ///
    /// Fixes OPUS-F-010: previously compared an expanded candidate path against
    /// still-tilde-prefixed roots (`hasPrefix("~/.factory/")`), so every custom
    /// path was over-rejected. Now expands both sides and canonicalizes
    /// (`standardizingPath` + `resolvingSymlinksInPath`) to prevent traversal
    /// bypass via `..` or symlink chains.
    static func isKnownRoot(_ path: String) -> Bool {
        let canonical = canonicalPath(path)
        return expandedRoots.contains { rootExpanded in
            let rootCanonical = canonicalPath(rootExpanded)
            return canonical == rootCanonical || canonical.hasPrefix(rootCanonical + "/")
        }
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
