import Foundation

/// XDG and home-relative path resolution shared by the Linux daemon, desktop shell, and provider log discovery.
///
/// Canonical contract (VAL-PATH-001):
/// - Runtime socket: `$XDG_RUNTIME_DIR/openburnbar/daemon.sock`
/// - Support / data: `$XDG_DATA_HOME/openburnbar` (default `~/.local/share/openburnbar`)
/// - Config: `$XDG_CONFIG_HOME/openburnbar` (default `~/.config/openburnbar`)
/// - Auth token: `<support>/daemon-socket-auth-token`
///
/// Historical `~/.config/OpenBurnBar` support paths are no longer the default; operators may
/// override with `OPENBURNBAR_DAEMON_SUPPORT_DIR` during migration.
public enum OpenBurnBarLinuxPaths {
    public static let defaultAppDirName = "openburnbar"
    public static let defaultSupportRelativeComponents = ["openburnbar"]
    public static let defaultConfigRelativeComponents = ["openburnbar"]
    public static let defaultRuntimeSocketFileName = "daemon.sock"
    public static let defaultSocketFileName = "openburnbar-daemon.sock"
    public static let defaultAuthTokenFileName = "daemon-socket-auth-token"

    public static func supportDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = trimmedNonEmpty(environment["OPENBURNBAR_DAEMON_SUPPORT_DIR"])
            ?? trimmedNonEmpty(environment["BURNBAR_DAEMON_SUPPORT_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let xdg = trimmedNonEmpty(environment["XDG_DATA_HOME"]) {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent(defaultAppDirName, isDirectory: true)
        }
        return currentHomeDirectory
            .appendingPathComponent(".local/share/\(defaultAppDirName)", isDirectory: true)
    }

    public static func configDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = trimmedNonEmpty(environment["XDG_CONFIG_HOME"]) {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent(defaultConfigRelativeComponents[0], isDirectory: true)
        }
        return currentHomeDirectory
            .appendingPathComponent(".config/\(defaultAppDirName)", isDirectory: true)
    }

    /// Preferred AF_UNIX path when a user runtime directory is available.
    public static func runtimeDaemonSocketURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let runtime = trimmedNonEmpty(environment["XDG_RUNTIME_DIR"]) else { return nil }
        return URL(fileURLWithPath: runtime, isDirectory: true)
            .appendingPathComponent(defaultAppDirName, isDirectory: true)
            .appendingPathComponent(defaultRuntimeSocketFileName, isDirectory: false)
    }

    public static func defaultDaemonSocketURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = trimmedNonEmpty(environment["OPENBURNBAR_SOCKET_PATH"])
            ?? trimmedNonEmpty(environment["OPENBURNBAR_DAEMON_SOCKET_PATH"])
            ?? trimmedNonEmpty(environment["BURNBAR_DAEMON_SOCKET_PATH"]) {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        if let runtimeSocket = runtimeDaemonSocketURL(environment: environment) {
            return runtimeSocket
        }
        return supportDirectoryURL(environment: environment)
            .appendingPathComponent(defaultSocketFileName, isDirectory: false)
    }

    public static func authTokenURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        supportDirectoryURL(environment: environment)
            .appendingPathComponent(defaultAuthTokenFileName, isDirectory: false)
    }

    public static func expandTildeInPath(_ path: String, homeDirectory: URL? = nil) -> String {
        expandPath(path, homeDirectory: homeDirectory, environment: ProcessInfo.processInfo.environment)
    }

    /// Expand `~` and apply XDG_CONFIG_HOME / XDG_DATA_HOME rewrites so UI display
    /// paths and parser discovery agree under custom XDG layouts (VAL-PARSER-002).
    public static func expandPath(
        _ path: String,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = homeDirectory ?? currentHomeDirectory
        if path == "~" {
            return home.path
        }
        guard path.hasPrefix("~/") else { return path }
        let rest = String(path.dropFirst(2)) // path after ~/

        if rest.hasPrefix(".config/"),
           let xdg = trimmedNonEmpty(environment["XDG_CONFIG_HOME"]) {
            let suffix = String(rest.dropFirst(".config/".count))
            return (suffix.isEmpty ? URL(fileURLWithPath: xdg, isDirectory: true)
                    : URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent(suffix)).path
        }
        if rest.hasPrefix(".local/share/"),
           let xdg = trimmedNonEmpty(environment["XDG_DATA_HOME"]) {
            let suffix = String(rest.dropFirst(".local/share/".count))
            return (suffix.isEmpty ? URL(fileURLWithPath: xdg, isDirectory: true)
                    : URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent(suffix)).path
        }
        return home.appendingPathComponent(rest).path
    }

    /// Detect legacy support dir from pre-VAL-PATH-001 layouts (`~/.config/OpenBurnBar`).
    public static func legacySupportDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let xdg = trimmedNonEmpty(environment["XDG_CONFIG_HOME"]) {
            candidates.append(
                URL(fileURLWithPath: xdg, isDirectory: true)
                    .appendingPathComponent("OpenBurnBar", isDirectory: true)
            )
        }
        candidates.append(
            currentHomeDirectory.appendingPathComponent(".config/OpenBurnBar", isDirectory: true)
        )
        for url in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }

    /// Human-readable migration hint when legacy support data exists and the new path is empty.
    public static func legacySupportMigrationHint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let legacy = legacySupportDirectoryURL(environment: environment) else { return nil }
        let modern = supportDirectoryURL(environment: environment)
        if legacy.path == modern.path { return nil }
        if FileManager.default.fileExists(atPath: modern.path) { return nil }
        return "Legacy support data found at \(legacy.path). Set OPENBURNBAR_DAEMON_SUPPORT_DIR=\(legacy.path) or move it to \(modern.path)."
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static var currentHomeDirectory: URL {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
        #endif
    }
}
