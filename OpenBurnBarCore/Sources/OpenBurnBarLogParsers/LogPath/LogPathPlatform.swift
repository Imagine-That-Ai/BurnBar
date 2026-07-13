import Foundation
import OpenBurnBarKernel

// MARK: - Log directory path remap (macOS logical form -> platform on-disk root)
//
// Windows-port Phase-2 (parser path-remap, G2 headline of
// `docs/WINDOWS_PORT_MASTER_PLAN.md`).
//
// The 16 log parsers describe *where* a provider writes its session logs with a
// single macOS-logical string — `AgentProvider.logDirectory` — expressed as a
// `~/…` path (e.g. `~/.claude/projects`, `~/Library/Application Support/Code/…`,
// `~/.local/share/goose/sessions`). On macOS that string is expanded with
// `NSString.expandingTildeInPath` and read directly.
//
// On Windows the *root* of each of those three families lives somewhere else:
//
//   • `~/.foo/…`                        -> `%USERPROFILE%\.foo\…`
//   • `~/Library/Application Support/X`  -> `%APPDATA%\X`        (Roaming AppData)
//   • `~/.local/share/X`                 -> `%LOCALAPPDATA%\X`   (XDG data dir)
//
// `LogPathPlatform.resolveLogDirectory` is the single, Foundation-only,
// Windows-buildable seam that performs that remap. It lives in the Engine
// (`OpenBurnBarCore`) — not the macOS app — so the *exact* resolver the Windows
// parser build uses is compiled and byte-diffed by the Windows parser-parity CI
// gate, and so the macOS app extension (`AgentProvider.logDirectory`) can call it
// without pulling in any Apple-only dependency.
//
// Determinism + testability: `os` and `environment` are injectable, so the
// Windows branch is exercised (and byte-asserted) on the macOS host — the
// resolver never reads real process state unless the caller lets it default.
//
// macOS invariant: for `os == .posix` this returns the input `~/…` string
// **unchanged**, so every existing macOS caller (which then applies
// `expandingTildeInPath` itself) is byte-for-byte identical to today. The remap
// is a Windows-only transform; the POSIX side is a pass-through by construction.

public enum LogPathPlatform {

    /// The host families the log-directory remap distinguishes.
    public enum HostOS: String, Sendable {
        /// macOS + Linux: `~/…` logical paths, `/` separators, tilde expansion.
        case posix
        /// Windows: `%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%` roots, `\` separators.
        case windows
    }

    /// The family of the current build host, resolved at compile time.
    public static var current: HostOS {
        #if os(Windows)
        return .windows
        #else
        return .posix
        #endif
    }

    /// Resolve a macOS-logical `~/…` provider log directory to the correct on-disk
    /// path for the target host.
    ///
    /// - On `.posix` the `~/…` string is returned **verbatim** (the caller expands
    ///   the tilde exactly as before — zero behavior change on macOS/Linux).
    /// - On `.windows` the tilde root is rewritten to the matching Windows base
    ///   directory (`%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%`) and the
    ///   remainder is re-separated with backslashes.
    ///
    /// - Parameters:
    ///   - macLogDirectory: the `~/…` logical directory from `AgentProvider.logDirectory`.
    ///   - os: target host family (defaults to the build host).
    ///   - environment: process environment, injectable for deterministic tests.
    /// - Returns: the platform-resolved directory. Absolute on Windows; the
    ///   unchanged `~/…` string on POSIX.
    public static func resolveLogDirectory(
        _ macLogDirectory: String,
        os: HostOS = current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        switch os {
        case .posix:
            // Pass-through: the POSIX caller expands `~` exactly as it does today.
            return macLogDirectory
        case .windows:
            return windowsPath(forMacLogDirectory: macLogDirectory, environment: environment)
        }
    }

    // MARK: Windows remap

    /// The three tilde-root families and the Windows base each maps to.
    private enum WindowsRoot {
        /// `%APPDATA%` (Roaming) — where macOS `~/Library/Application Support` lands
        /// (VS Code, Windsurf, Warp, … globalStorage all live under Roaming AppData).
        static let appDataPrefixes = ["Library/Application Support/", "Library/Application Support"]
        /// `%LOCALAPPDATA%` — the Windows analog of the XDG `~/.local/share` data dir.
        static let localAppDataPrefixes = [".local/share/", ".local/share"]
    }

    private static func windowsPath(
        forMacLogDirectory macLogDirectory: String,
        environment: [String: String]
    ) -> String {
        // 1. Strip the leading tilde-root (`~/`, `~\`, or a bare `~`).
        var rest = macLogDirectory
        if rest.hasPrefix("~/") || rest.hasPrefix("~\\") {
            rest = String(rest.dropFirst(2))
        } else if rest.hasPrefix("~") {
            rest = String(rest.dropFirst(1))
        }
        // Normalize any stray backslashes in the logical form to `/` before we
        // classify the prefix, so classification is separator-agnostic.
        let posixRest = rest.replacingOccurrences(of: "\\", with: "/")

        // 2. Classify the root family and peel its prefix.
        let base: String
        let sub: String
        if let stripped = stripPrefix(WindowsRoot.appDataPrefixes, from: posixRest) {
            base = appData(environment)
            sub = stripped
        } else if let stripped = stripPrefix(WindowsRoot.localAppDataPrefixes, from: posixRest) {
            base = localAppData(environment)
            sub = stripped
        } else {
            // `~/.foo/…` and everything else hang directly off the user profile,
            // preserving the leading dot-directory (`.claude/projects`, `.codex`, …).
            base = userProfile(environment)
            sub = posixRest
        }

        // 3. Re-separate the remainder with backslashes and join to the base.
        return windowsJoin(base: base, subpath: sub)
    }

    /// Return the remainder after the first matching prefix, or `nil` if none match.
    private static func stripPrefix(_ prefixes: [String], from path: String) -> String? {
        for prefix in prefixes where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return nil
    }

    /// Join a Windows base directory to a `/`-separated subpath, converting `/` to
    /// `\` and collapsing the joint so there is never a doubled or trailing `\`.
    private static func windowsJoin(base: String, subpath: String) -> String {
        let trimmedBase = trimTrailing("\\", from: base)
        let backslashed = subpath.replacingOccurrences(of: "/", with: "\\")
        let trimmedSub = trimLeading("\\", from: trimTrailing("\\", from: backslashed))
        if trimmedSub.isEmpty { return trimmedBase }
        return trimmedBase + "\\" + trimmedSub
    }

    // MARK: Windows base directories (env-driven, with documented fallbacks)

    private static func userProfile(_ environment: [String: String]) -> String {
        if let up = environment["USERPROFILE"], !up.isEmpty { return up }
        if let drive = environment["HOMEDRIVE"], let path = environment["HOMEPATH"],
           !drive.isEmpty, !path.isEmpty {
            return drive + path
        }
        return NSHomeDirectory()
    }

    private static func appData(_ environment: [String: String]) -> String {
        if let appData = environment["APPDATA"], !appData.isEmpty { return appData }
        return windowsJoin(base: userProfile(environment), subpath: "AppData/Roaming")
    }

    private static func localAppData(_ environment: [String: String]) -> String {
        if let localAppData = environment["LOCALAPPDATA"], !localAppData.isEmpty { return localAppData }
        return windowsJoin(base: userProfile(environment), subpath: "AppData/Local")
    }

    // MARK: String trims

    private static func trimTrailing(_ character: Character, from string: String) -> String {
        var result = Substring(string)
        while result.last == character { result = result.dropLast() }
        return String(result)
    }

    private static func trimLeading(_ character: Character, from string: String) -> String {
        var result = Substring(string)
        while result.first == character { result = result.dropFirst() }
        return String(result)
    }
}
