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
        guard expanded.hasPrefix("/") else { return nil }
        let jailRoot = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: expanded)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(jailRoot + "/") else { return nil }
        return resolved
    }
}
