import Foundation

/// Containment for Codex `rollout_path` values (Wave 2.7).
///
/// The path comes from Codex's own SQLite database — attacker-influenced
/// input. Both consumers (the subagent probe, which OPENS the file, and the
/// session scanner, which stats/reads it) resolve through here, so a
/// compromised `threads` row can never smuggle a read outside `~/.codex`.
/// Escapes resolve to nil and the thread parses from its database row alone.
public enum CodexRolloutJail {
    /// Expands `raw` against `homeDirectoryURL` and returns the contained
    /// path, or nil when it escapes the `~/.codex` jail. Tilde expansion is
    /// deliberate (Codex writes `~/`-prefixed paths); bare `~`, `~otheruser`
    /// and relative forms are refused outright. Symlinks resolve on both sides
    /// before the prefix check, so a link inside the jail pointing outside does
    /// not smuggle reads out, and the trailing-slash prefix blocks sibling
    /// directories (`~/.codex-evil`) and the jail root itself.
    public static func containedPath(
        _ raw: String,
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> String? {
        let expanded = raw.hasPrefix("~/")
            ? homeDirectoryURL.appendingPathComponent(String(raw.dropFirst(2))).path
            : raw
        #if os(Windows)
        return containedWindowsPath(expanded: expanded, homeDirectoryURL: homeDirectoryURL)
        #else
        guard expanded.hasPrefix("/") else { return nil }
        let jailRoot = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: expanded)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(jailRoot + "/") else { return nil }
        return resolved
        #endif
    }

    #if os(Windows)
    /// Windows half of the jail: drive-letter (`C:\…`) and UNC (`\\…`) paths
    /// never start with `/`, so the POSIX check would refuse every legitimate
    /// rollout (and silently downgrade parsing to heuristics). Same contract —
    /// symlinks resolve on both sides, comparison is case-insensitive, and the
    /// trailing-slash prefix blocks siblings and the jail root itself.
    private static func containedWindowsPath(expanded: String, homeDirectoryURL: URL) -> String? {
        let resolved = denormalizeWin32Namespace(
            URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        )
        let jailRoot = denormalizeWin32Namespace(
            homeDirectoryURL
                .appendingPathComponent(".codex", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
        )
        guard windowsPathIsContained(candidate: resolved, jailRoot: jailRoot) else { return nil }
        return resolved
    }

    /// Strip the `\\?\` / `\\?\UNC\` prefixes symlink resolution can return
    /// (GetFinalPathNameByHandle form) so both sides compare in one namespace.
    private static func denormalizeWin32Namespace(_ path: String) -> String {
        if path.hasPrefix(#"\\?\UNC\"#) {
            return #"\\"# + path.dropFirst(8)
        }
        if path.hasPrefix(#"\\?\"#) {
            return String(path.dropFirst(4))
        }
        return path
    }
    #endif

    /// Pure string core of the Windows containment check (internal for tests —
    /// the `#if os(Windows)` entry above does not compile on macOS/Linux, but
    /// this comparison must still be pinned by unit tests everywhere).
    static func windowsPathIsContained(candidate: String, jailRoot: String) -> Bool {
        func norm(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "/")
        }
        let candidate = norm(candidate)
        // Absolute only: drive-letter (`C:/…`) or UNC (`//server/share/…`).
        // Anything else (bare `~`, relative, unexpanded leftovers) refuses.
        let isDriveAbsolute =
            candidate.count >= 3
                && candidate.first?.isASCII == true
                && candidate.first?.isLetter == true
                && candidate[candidate.index(candidate.startIndex, offsetBy: 1)] == ":"
                && candidate[candidate.index(candidate.startIndex, offsetBy: 2)] == "/"
        guard isDriveAbsolute || candidate.hasPrefix("//") else { return false }
        let root = norm(jailRoot).lowercased()
        return candidate.lowercased().hasPrefix(root + "/")
    }
}
