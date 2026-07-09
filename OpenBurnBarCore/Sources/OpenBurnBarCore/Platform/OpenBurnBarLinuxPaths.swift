import Foundation

/// XDG and home-relative path resolution shared by the Linux daemon, desktop shell, and provider log discovery.
public enum OpenBurnBarLinuxPaths {
    public static let defaultSupportRelativeComponents = ["OpenBurnBar"]
    public static let defaultConfigRelativeComponents = ["openburnbar"]
    public static let defaultSocketFileName = "openburnbar-daemon.sock"
    public static let defaultAuthTokenFileName = "daemon-socket-auth-token"

    public static func supportDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = trimmedNonEmpty(environment["OPENBURNBAR_DAEMON_SUPPORT_DIR"])
            ?? trimmedNonEmpty(environment["BURNBAR_DAEMON_SUPPORT_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let xdg = trimmedNonEmpty(environment["XDG_CONFIG_HOME"]) {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("OpenBurnBar", isDirectory: true)
        }
        return currentHomeDirectory
            .appendingPathComponent(".config/OpenBurnBar", isDirectory: true)
    }

    public static func configDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = trimmedNonEmpty(environment["XDG_CONFIG_HOME"]) {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent(defaultConfigRelativeComponents[0], isDirectory: true)
        }
        return currentHomeDirectory
            .appendingPathComponent(".config/openburnbar", isDirectory: true)
    }

    public static func defaultDaemonSocketURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = trimmedNonEmpty(environment["OPENBURNBAR_SOCKET_PATH"])
            ?? trimmedNonEmpty(environment["OPENBURNBAR_DAEMON_SOCKET_PATH"])
            ?? trimmedNonEmpty(environment["BURNBAR_DAEMON_SOCKET_PATH"]) {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        return supportDirectoryURL(environment: environment)
            .appendingPathComponent(defaultSocketFileName, isDirectory: false)
    }

    public static func expandTildeInPath(_ path: String, homeDirectory: URL? = nil) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = homeDirectory ?? currentHomeDirectory
        if path == "~" {
            return home.path
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
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
